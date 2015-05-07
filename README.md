# put-arch-onto-disk

This repo contains a script which creates a bootable (BIOS, non-UEFI at the moment) disk image based on the latest Arch Linux and then optionally uses dd to write it to a disk. The indended use is for creating bootable USB flash drives, so the default root file system is F2FS, although that is configurable.

### Requirements
1. Be running Arch Linux
1. `sudo pacman -S --needed util-linux coreutils gptfdisk f2fs-tools e2fsprogs btrfs-progs arch-install-scripts procps-ng sed`
