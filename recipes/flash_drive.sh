#/usr/bin/env bash

TLD='..'
TARGET="$1" \
ROOT_FS_TYPE=f2fs \
PACKAGE_LIST="vim" \
ADMIN_HOMED="true" \
sudo -E "${TLD}/put-arch-onto-disk.sh" |& tee archInstall.log
