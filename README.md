# put-arch-onto-disk

This repo contains a script which creates a bootable (BIOS, non-UEFI at the moment) disk image based on the latest Arch Linux and then optionally uses dd to write it to a disk. The indended use is for creating bootable USB flash drives, so the default root file system is F2FS, although that is configurable (like many other things).

### Requirements
1. Be running Arch Linux
1. `sudo pacman -S --needed util-linux coreutils gptfdisk f2fs-tools e2fsprogs btrfs-progs arch-install-scripts procps-ng sed sudo`
1. Understand that the script provided here comes with no guarentees that it won't destroy your computer and everything attached to it :-), although I believe it's safe. There are no warnings or "Are you sure you want to..." messages. It will happily dd over all your cat pictures, your homework, your bitcoin wallet, its self, your family photos and even your PhD dissertation if you ask it to, so be careful.

### Usage

1. Examine the top of the `put-arch-onto-disk.sh` scipt to make sure you understand what the defaults are (they should be safe, since there is no dding by default).
1. Define the appropriate environment variables to override the defaults and call the script.

You can run the script without root permissions and you'll be prompted for your sudo password for parts that need root access.
### Recipes

- This will generate a 2GiB bootable disk image in the current directory called bootable_arch.img suitable for dd'ing to a USB stick:
```
./put-arch-onto-disk.sh
```
---
- This will generate a 2GiB bootable disk image in the current directory called bootable_arch.img, then use dd to copy it to a USB stick at /dev/sdz and then delete the .img:
```
DD_TO_DISK=/dev/sdz CLEAN_UP=true TARGET_IS_REMOVABLE=true ./put-arch-onto-disk.sh
```
---
- This will install directly to a device at /dev/sdz with a root file system suitable for a USB stick:
```
TARGET=/dev/sdz TARGET_IS_REMOVABLE=true ./put-arch-onto-disk.sh
```
---
- This will install directly to a device at /dev/sdz with a root file system suitable for a SSD/HDD and create a swap partition sized to match the amount of ram installed in the current machine and install a few addidional packages to the target system:
```
TARGET=/dev/sdz ROOT_FS_TYPE=btrfs MAKE_SWAP_PARTITION=true SWAP_SIZE_IS_RAM_SIZE=true PACKAGE_LIST="vim sl" ./put-arch-onto-disk.sh
```
