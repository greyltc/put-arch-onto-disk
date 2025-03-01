#/usr/bin/env bash

TLD='..'
SIZE="3G" \
ROFS_OUT="fs.sfs" \
ROOT_FS_TYPE=btrfs \
PACKAGE_LIST="vim" \
sudo -E "${TLD}/put-arch-onto-disk.sh" |& tee archInstall.log
