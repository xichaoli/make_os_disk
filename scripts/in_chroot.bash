#!/bin/bash
#
# 进入chroot环境，安装 grub

function main() {
    # 需要在目标系统中安装 grub2-common、grub-efi-arm64
    grub-install
}

main "$@"
