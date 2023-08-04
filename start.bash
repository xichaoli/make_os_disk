#!/bin/bash
#
# 程序入口

# 一但有任何一个语句返回非真的值，则退出bash
set -e

# 使用说明
function usage() {
    echo -e "\e[33mUsage: $0\e[0m"
    exit 1
}

# 判断程序执行时是否有root权限
# 使用 $EUID 环境变量来获取当前进程的有效用户ID，
# 如果其值为 0，则说明当前进程拥有 root 权限
function check_permission() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\e[31m运行此脚本需要拥有root权限!\e[0m"
        exit 1
    fi
}

# 检查依赖
# 将程序中使用到的命令及其所在的软件包名词放到一个数组中，
# 依次检查这些命令是否存在，如果不存在，就提示自动安装
function check_dependencies() {
    local dependencies=("whiptail,whiptail" "lsblk,util-linux" "parted,parted"
        "mkfs.vfat,dosfstools" "mkfs.ext4,e2fsprogs" "rsync,rsync"
        "qemu-aarch64-static,qemu-user-static binfmt-support")
    local dependency
    for dependency in "${dependencies[@]}"; do
        local command
        command=$(echo "$dependency" | cut -d ',' -f 1)
        local package
        package=$(echo "$dependency" | cut -d ',' -f 2)
        if ! which "$command" >/dev/null 2>&1; then
            echo "检测到 $command 不存在，正在安装 $package"
            apt-get install -y "$package"
        fi
    done
}

# 选择目标主板型号，并将结果保存到全局变量 BOARD_TYPE 中
function select_board_type() {
    BOARD_TYPE=$(whiptail --title "选择主板型号" --menu "选择目标主板型号" 15 60 5 \
        "1" "F4128 D2000/8" \
        "2" "S6040 SW831" \
        3>&1 1>&2 2>&3)
    export BOARD_TYPE
}

# 选择目标系统版本，并将结果保存到全局变量 OS_VERSION 中
function select_OS_version() {
    #    OS_VERSION=$(whiptail --title "选择系统版本" --menu "选择目标系统版本" 15 60 5 \
    #        "1" "Kylin V10" \
    #        "2" "UOS20 1050" \
    #        3>&1 1>&2 2>&3)

    # 飞腾版本的UOS需要授权才能使用root权限，所以这里只提供kylin版本
    # 而S6040的kylin系统默认不包含ds3232和ins590x的驱动，所以这里只提供uos版本
    if [[ $BOARD_TYPE == 1 ]]; then
        OS_VERSION="kylin"
    elif [[ $BOARD_TYPE == 2 ]]; then
        OS_VERSION="uos"
    fi
    export OS_VERSION
}

# 获取当前设备的硬盘信息, 并选择将系统安装到哪个硬盘
# SELECTED_DISK 为全局变量，用于存储用户选择的硬盘
function select_disk() {
    local disk_info
    disk_info=$(lsblk -d -n -o NAME,SIZE)
    local menu
    # 下面的 %-10s 没有生效，暂时不知道如何修改
    menu=$(echo "$disk_info" | awk '{printf "%-10s %s\n", $1, $2}')
    # shellcheck disable=SC2086
    SELECTED_DISK=$(whiptail --title "选择硬盘" --menu "选择将系统安装到哪个硬盘" \
        15 60 5 ${menu} 3>&1 1>&2 2>&3)
    export SELECTED_DISK
    # 警告,此操作会清空磁盘数据,请确认已做好数据备份
    if (
        whiptail --title "警告" --yesno \
            "此操作会清空磁盘数据,请确认已做好数据备份" 15 60 3>&1 1>&2 2>&3
    ); then
        echo "用户确认已做好数据备份"
    else
        echo "用户取消安装"
        exit 1
    fi
}

# 判断磁盘 disk 下的分区是否已经挂载，如果已经挂载，则卸载
function umount_partition() {
    local disk
    disk=$1
    # 查找该设备下已经挂载的分区
    local mounted_partitions
    mounted_partitions=$(mount | grep "$disk" | awk '{print $1}')
    local partition
    if [ -n "$mounted_partitions" ]; then
        echo "磁盘 $disk 有分区被挂载，开始卸载..."
        for partition in $mounted_partitions; do
            umount -l "$partition"
        done
        echo "磁盘 $disk 分区卸载完成..."
    fi
}

# 在 SELECTED_DISK 硬盘上创建分区
# 为方便起见，只创建两个分区
# 第一个分区大小为 512M,
#   当主板型号是F4128时,格式化为 vfat32;
#   当主板型号是S6040时,格式化为 ext4;
# 另一个为剩余空间的 ext4 格式分区
function prepare_partition() {
    local disk
    disk=/dev/"$SELECTED_DISK"
    umount_partition "$disk"

    # 使用 parted 创建分区
    echo "正在创建分区..."
    parted -s "$disk" mklabel gpt
    if [[ $BOARD_TYPE == 1 ]]; then
        parted -s "$disk" mkpart primary fat32 1MiB 512MiB
    elif [[ $BOARD_TYPE == 2 ]]; then
        parted -s "$disk" mkpart primary ext4 1MiB 512MiB
    fi
    parted -s "$disk" mkpart primary ext4 512MiB 100%
    partprobe "${disk}"
    sync

    echo "格式化第一个分区..."
    if [[ $BOARD_TYPE == 1 ]]; then
        mkfs.vfat -F32 "${disk}1"
    elif [[ $BOARD_TYPE == 2 ]]; then
        mkfs.ext4 -q -F "${disk}1" >/dev/null
    fi
    echo "格式化第二个分区..."
    mkfs.ext4 -q -F "${disk}2" >/dev/null
    # 挂载分区
    echo "挂载分区..."
    mount "${disk}1" "$(pwd)"/mountpoint/1
    mount "${disk}2" "$(pwd)"/mountpoint/2
}

# 拷贝系统文件
function copy_files() {
    if [[ $BOARD_TYPE == 1 ]]; then
        echo "拷贝EFI分区文件..."
        rsync -rtD -h --no-i-r --info=progress2 \
            "$(pwd)"/os_files/F4128/"${OS_VERSION}"/partition1/* \
            "$(pwd)"/mountpoint/1/
        echo "拷贝根分区文件..."
        rsync -aHAX -h --no-i-r --info=progress2 \
            "$(pwd)"/os_files/F4128/"${OS_VERSION}"/partition2/* \
            "$(pwd)"/mountpoint/2/
    elif [[ $BOARD_TYPE == 2 ]]; then
        echo "拷贝boot分区文件..."
        rsync -aHAX -h --no-i-r --info=progress2 \
            "$(pwd)"/os_files/S6040/"${OS_VERSION}"/partition1/* \
            "$(pwd)"/mountpoint/1/
        echo "拷贝根分区文件..."
        rsync -aHAX -h --no-i-r --info=progress2 \
            "$(pwd)"/os_files/S6040/"${OS_VERSION}"/partition2/* \
            "$(pwd)"/mountpoint/2/
    fi

    echo "执行sync操作,时间较长,请耐心等待..."
    sync
}

# 解析 os_files 下的 fstab 文件, 获取各个分区的UUID及对应的挂载点,放入一个数组中
function get_old_partitions_info() {
    # 获取 fstab 文件路径
    local fstab_file
    if [[ $BOARD_TYPE == 1 ]]; then
        fstab_file="$(pwd)"/os_files/F4128/"${OS_VERSION}"/partition2/etc/fstab
    elif [[ $BOARD_TYPE == 2 ]]; then
        fstab_file="$(pwd)"/os_files/S6040/"${OS_VERSION}"/partition2/etc/fstab
    fi

    # Initialize the array
    declare -A -g old_partitions_info=()

    # some local variables
    local line
    local uuid
    local mount_point

    # Read the fstab file line by line
    while read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^#|^$ ]]; then
            continue
        fi
        # Extract the UUID and mount point from the line
        uuid=$(echo "$line" | awk '{print $1}' | cut -d= -f2)
        mount_point=$(echo "$line" | awk '{print $2}')
        # Add the UUID and mount point to the array
        old_partitions_info["$mount_point"]="$uuid"
    done <"${fstab_file}"

    # 打印数组,用于调试
    #    local key
    #    for key in "${!old_partitions_info[@]}"; do
    #        echo "key: $key, value: ${old_partitions_info[$key]}"
    #    done
}

# 进入chroot环境
function into_chroot() {
    local disk
    disk=/dev/"$SELECTED_DISK"
    # 挂载宿主机设备节点
    mount -t proc /proc "$(pwd)"/mountpoint/2/proc
    mount -t sysfs /sys "$(pwd)"/mountpoint/2/sys
    mount -o bind /dev "$(pwd)"/mountpoint/2/dev
    mount -o bind /dev/pts "$(pwd)"/mountpoint/2/dev/pts
    mount -o bind /run "$(pwd)"/mountpoint/2/run
    # 执行chroot，并记录日志
    # 在x86平台chroot到arm64平台的rootfs，需要安装 qemu-user-static、binfmt-support
    chroot "$(pwd)"/mountpoint/2 \
        /usr/bin/in_chroot.bash "${disk}1" 2>&1 |
        tee "$(pwd)"/logs/os_installer_inchroot.log
}

# 安装 grub,修正grub.cfg
# 仅当主板型号为 F4128 时，才需要安装 grub
# 另因为是新的磁盘分区,所以UUID已经改变,需要修正grub.cfg
function fix_grub() {
    local grub_cfg
    local disk
    disk=/dev/"$SELECTED_DISK"

    if [[ $BOARD_TYPE == 1 ]]; then
        # 拷贝in_chroot.bash到target中
        cp "$(pwd)"/scripts/in_chroot.bash \
            "$(pwd)"/mountpoint/2/usr/bin/in_chroot.bash

        # 进入chroot环境,安装grub
        into_chroot

        # delete script in_chroot.bash
        rm -f "$(pwd)"/mountpoint/2/usr/bin/in_chroot.bash

        # 卸载宿主设备节点
        umount -l "$(pwd)"/mountpoint/2/dev/pts >/dev/null 2>&1
        umount -l "$(pwd)"/mountpoint/2/dev >/dev/null 2>&1
        umount -l "$(pwd)"/mountpoint/2/proc >/dev/null 2>&1
        umount -l "$(pwd)"/mountpoint/2/sys >/dev/null 2>&1
        umount -l "$(pwd)"/mountpoint/2/run >/dev/null 2>&1
    elif [[ $BOARD_TYPE == 2 ]]; then
        echo "主板型号为S6040，不需要安装 grub..."
    fi

    # 查找 grub.cfg 文件
    grub_cfg=$(find "$(pwd)"/mountpoint/1/boot/grub/ -name grub.cfg)

    echo "修正 grub.cfg..."
    sed -i "s/${old_partitions_info["/"]}/$(
        blkid -p -s UUID -o value "${disk}2"
    )/g" "$grub_cfg"
}

# 修改 fstab 文件, 用新分区的UUID替换fstab文件中旧的UUID
function fix_fstab() {
    local fstab_file
    local disk
    local d1_mount_point
    disk=/dev/"$SELECTED_DISK"
    fstab_file="$(pwd)"/mountpoint/2/etc/fstab

    echo "修正 fstab..."
    # 替换根分区的UUID
    sed -i "s/${old_partitions_info["/"]}/$(
        blkid -p -s UUID -o value "${disk}2"
    )/g" "$fstab_file"

    # 当主板型号是F4128时该分区挂载点为 /boot/efi;
    # 当主板型号为S6040时, 该分区挂载点为 /boot
    if [[ $BOARD_TYPE == 1 ]]; then
        d1_mount_point="/boot/efi"
    elif [[ $BOARD_TYPE == 2 ]]; then
        d1_mount_point="/boot"
    fi
    # 替换第一个分区的UUID
    sed -i "s/${old_partitions_info[${d1_mount_point}]}/$(
        blkid -p -s UUID -o value "${disk}1"
    )/g" "$fstab_file"
}

# 文件系统拷贝完成后的一些修复工作
function post_operation() {
    get_old_partitions_info
    fix_grub
    fix_fstab
}

# 安装完成，重启系统
function install_complete() {
    # 卸载分区
    echo "卸载分区..."
    local disk
    disk=/dev/"$SELECTED_DISK"
    umount_partition "$disk"
    echo "安装完成，请将硬盘装入目标设备并上电启动..."
}

# main 函数
function main() {
    if [[ $# -ne 0 ]]; then
        usage
    fi
    check_permission
    check_dependencies
    select_board_type
    select_OS_version
    select_disk
    prepare_partition
    copy_files
    post_operation
    install_complete
}

main "$@"
