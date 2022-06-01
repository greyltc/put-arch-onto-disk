#/usr/bin/env bash
TLD='..'
TARGET=/dev/sdX \
ROOT_FS_TYPE=f2fs \
PACKAGE_LIST="vim" \
ADMIN_HOMED="true" \
sudo -E "${TLD}/put-arch-onto-disk.sh" |& tee archInstall.log
