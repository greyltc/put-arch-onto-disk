#/usr/bin/env bash
TLD='..'
TARGET=/dev/nvme0n1 \
PACKAGE_LIST='vim' \
ADMIN_USER_NAME='admin' \
PREEXISTING_BOOT_PARTITION_NUM=1 \
PREEXISTING_ROOT_PARTITION_NUM=5 \
PORTABLE='false' \
THIS_HOSTNAME='archthing' \
sudo -E "${TLD}/put-arch-onto-disk.sh" |& tee archInstall.log
