# put-arch-onto-disk

This repo contains a script which creates a bootable (BIOS, non-UEFI at the moment) disk image based on the latest Arch Linux and then optionally uses dd to write it to a disk. The indended use is for creating bootable USB flash drives, so the default root file system is F2FS, although that is configurable (like many other things).

### Requirements
1. Be running Arch Linux
1. `sudo pacman -S --needed util-linux coreutils gptfdisk f2fs-tools e2fsprogs btrfs-progs arch-install-scripts procps-ng sed sudo`
1. Understand that the script provided here comes with no guarentees that it won't destroy your computer and everything attached to it :-) although I believe it's safe. It will happily dd over your homework, your bitcoin wallet, its self, your family photos and even your PhD dissertation if you ask it to, so be careful.

### Usage

1. Examine the top of the `put-arch-onto-disk.sh` scipt to make sure you understand what the defaults are (they should be safe, since there is no dding by default).
1. Define the appropriate environment variables to override the defaults and call the script.

### Example

For a useful install onto a USB flash drive at /dev/sdz I like to run:
```
TARGET_DISK=/dev/sdz DD_TO_TARGET=true CLEAN_UP=true USE_TARGET_DISK=true PACKAGE_LIST="base-devel networkmanager bash-completion sudo vim efibootmgr btrfs-progs arch-install-scripts fuse dosfstools os-prober mtools freetype2 fuse dialog ifplugd wpa_actiond mkinitcpio-nfs-utils linux-atm libmicrohttpd openssh fail2ban vim" ./put-arch-onto-disk.sh
```
You can run the script without root permissions and you'll be prompted for your sudo password for parts that need root access.
