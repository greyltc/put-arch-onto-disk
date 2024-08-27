#/usr/bin/env bash
# run like: ./time_machine.sh /dev/sdX 2023-06-01

TLD='..'
TARGET="$1" \
AS_OF="$2" \
PACKAGE_LIST="vim" \
sudo -E "${TLD}/put-arch-onto-disk.sh" |& tee archInstall.log
