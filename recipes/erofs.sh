#/usr/bin/env bash

TLD='..'
SIZE="3G" \
ROFS_OUT="fs.erofs" \
ROOT_FS_TYPE=btrfs \
PACKAGE_LIST="vim" \
sudo -E "${TLD}/put-arch-onto-disk.sh" |& tee archInstall.log
