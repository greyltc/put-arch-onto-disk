#/usr/bin/env bash
TLD='..'
TARGET="$1" \
TARGET_ARCH=aarch64 \
ROOT_FS_TYPE=btrfs \
SKIP_NSPAWN="true" \
SIZE="3GiB" \
AUR_HELPER="paru-bin" \
PACKAGE_LIST="linux-rpi-16k linux-rpi-16k-headers raspberrypi-bootloader rpi5-eeprom byobu vim less wireguard-tools man-db" \
sudo -E "${TLD}/put-arch-onto-disk.sh" |& tee archInstall.log
