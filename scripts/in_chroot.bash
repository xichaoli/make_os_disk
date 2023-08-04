#!/bin/bash
#
# 进入chroot环境，安装 grub

function main() {
    # 需要目标系统中已安装 grub2-common、grub-efi-arm64, 此需求不在此脚本中实现
    mount "$1" /boot/efi
    grub-install
    umount -l /boot/efi
}

main "$@"
