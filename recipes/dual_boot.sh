#/usr/bin/env bash

TLD='..'
TARGET="$1" \
PACKAGE_LIST='vim gnome gnome-extra pipewire-jack networkmanager byobu intel-media-driver vulkan-intel' \
ADMIN_USER_NAME='admin' \
PREEXISTING_BOOT_PARTITION_NUM=1 \
PREEXISTING_ROOT_PARTITION_NUM=5 \
PORTABLE='false' \
THIS_HOSTNAME='archthing' \
sudo -E "${TLD}/put-arch-onto-disk.sh" |& tee archInstall.log
