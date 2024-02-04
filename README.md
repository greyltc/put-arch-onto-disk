# put-arch-onto-disk

n.b. this project is pretty much just for me. If you find it helpful, that's great!

This repo contains a script which creates a ready-to-use Arch Linux installation, tailored the way I like it. It can be used to install to a USB thumb drive, or to a permanently installed SSD or HDD or whatever or even make a .img file which can later be dd'd to some media. It reads a bunch of environment variables to decide how to build the system.

- The default login/password is `admin/admin`

## Features
 - Multi architecture support (tested mostly with `x86_64` and `aarch64`)
 - LUKS whole partition encryption support
 - Create a disk image (suitable for dding later) or install directly to target disk
 - Multi root file system support (tested mostly with `btrfs` and `f2fs`)
 - Installations have persistant storage
 - Installations have (optional) AUR support (in the form of paru)
 - Installtions are up-to-date as of the minute you run the script
 - Can install into disks with pre-existing operating systems (like windows) for multi-booting
 - Easily set many installtion parameters programatically for an one-shot, unattended Arch install

## Requirements and notes
1. This script must be run from a x86_64 Arch Linux environment
1. You must have internet access when running this script (it needs to download the Arch packages).
1. It's been tested mostly for making x86_64 installs. i686 installs *might* work by changing 'TARGET_ARCH'. See examples below for installs to ARM targets (this makes use of [Arch Linux ARM](http://archlinuxarm.org/) repos). 
1. Understand that the script provided here comes with no guarentees that it won't destroy your computer and everything attached to it :-), although I believe it's safe (unless you're careless). There are no warnings or "Are you sure you want to..." messages. It will happily obliterate all your cat pictures, your homework, your bitcoin wallet, its self, your family photos and even your nealry competed PhD dissertation if you ask it to, so be careful.
1. The first boot of the installed system does some setup tasks automatically. You should have internet for that.

## Usage
This "one line" will fetch and run the script with all the defaults:
```
S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
Or if you clone the repo you can run it from a local copy like this:
```
sudo -E ./put-arch-onto-disk.sh |& tee archInstall.log
```
you'll need to prefix new definitions for any variables you'd like to override.  
The [recipes](README.md#recipes) section has a bunch of examples of this.  
Look in the script for variables you can set and their defaults.

## Recipes
Here are some fun combos of environment variables to use when running the script.

### Fixed disk in a desktop or laptop
```
TARGET=/dev/nvmeX \
PORTABLE=false \
ADMIN_USER_NAME=wentworth \
UCODES=intel-ucode \
THIS_HOSTNAME=atomsmasher \
AUR_HELPER=paru \
PACKAGE_LIST="vim gnome gnome-extra pipewire-jack networkmanager byobu intel-media-driver" \
```

### Raspberry Pi 5
Where "/dev/mmcblkX" might be the SD card device
```
TARGET=/dev/mmcblkX \
TARGET_ARCH=aarch64 \
ROOT_FS_TYPE=f2fs \
AUR_HELPER="" \
PACKAGE_LIST="linux-rpi-16k linux-rpi-16k-headers raspberrypi-bootloader rpi5-eeprom byobu vim"
```

### Raspberry Pi 4
Where "/dev/mmcblkX" might be the SD card device
```
# with mainline kernel
TARGET=/dev/mmcblkX \
TARGET_ARCH=aarch64 \
ROOT_FS_TYPE=f2fs \
AUR_HELPER="" \
PACKAGE_LIST="linux-aarch64 linux-aarch64-headers firmware-raspberrypi raspberrypi-bootloader uboot-raspberrypi uboot-tools rpi4-eeprom vim byobu" \

# kernel from raspberrypi.org's tree
TARGET=/dev/mmcblkX \
TARGET_ARCH=aarch64 \
ROOT_FS_TYPE=f2fs \
AUR_HELPER="" \
PACKAGE_LIST="linux-rpi linux-rpi-headers raspberrypi-bootloader rpi4-eeprom byobu vim" \
```
### Bootable Flash Drive
```
# where "/dev/sdX" is your flash drive

TARGET=/dev/sdX \
ROOT_FS_TYPE=f2fs \
THIS_HOSTNAME=usbthing \
PACKAGE_LIST="vim" \
```
