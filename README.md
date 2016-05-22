# put-arch-onto-disk

This repo contains a script which creates a ready-to-use Arch Linux installation. I can be used to install to a USB thumb drive, or to a permanently installed SSD or HDD or whatever or even make a .img file which can later be dd'd to some media.

### Features
 - Installations are bootable on both BIOS and UEFI systems
 - Create a disk image (suitable for dding later) or install directly to target disk
 - Optimized for removable flash storage (choose `f2fs` as root file system type)
 - Optimized for HDD and SSD targets (choose `btrfs` as root file system type)
 - Installations have persistant storage
 - Installations have (optional) AUR suport (in the form of yaourt)
 - Installtions are up-to-date as of the minute you run the script
 - Easily set many installtion parameters programatically:

### Variables
Variable Name|Description|Default Value
---|---|---
`TARGET_ARCH`|target architecture|`x86_64`
`ROOT_FS_TYPE`|root file system type|`f2fs`
`MAKE_SWAP_PARTITION`|create swap partition|`false`
`SWAP_SIZE_IS_RAM_SIZE`|use amount of installed ram as swap size|`false`
`SWAP_SIZE`|swap partition size (if `SWAP_SIZE_IS_RAM_SIZE`=`false`)|`100MiB`
`TARGET`|installation target. if this is a block deivce, you'll get a direct install onto that media (repartitioning it and filling it entirely), if it's a file you'll get a dd-able disk image of size `IMG_SIZE`|`./bootable_arch.img`
`IMG_SIZE`|disk image size|`2GiB`
`TIME_ZONE`|installed system's timezone|`Europe/London`
`LANGUAGE`|installed system's language|`en_US`
`KEYMAP`|keyboard layout|`uk`
`TEXT_ENCODING`|installed system's text encoding|`UTF-8`
`ROOT_PASSWORD`|password for root user|`toor`
`MAKE_ADMIN_USER`|create a user with sudo powers (and install sudo)|`true`
`ADMIN_USER_NAME`|user name for admin user (requires `MAKE_ADMIN_USER`=`true`)|`admin`
`ADMIN_USER_PASSWORD`|password for admin user (requires `MAKE_ADMIN_USER`=`true`)|`admin`
`THIS_HOSTNAME`|target system's hostname|`archthing`
`PACKAGE_LIST`|list of additional official packages to install|
`ENABLE_AUR`|install `yaourt` and cower (requires `MAKE_ADMIN_USER`=`true`)|`true`
`AUR_PACKAGE_LIST`|list of packages to install from the AUR (requires `ENABLE_AUR`=`true`)|
`AUTOLOGIN_ADMIN`|autologin admin user through display manager login page (works for gdm and lxdm)|`false`
`FIRST_BOOT_SCRIPT`|path to a (local) script you wish to run on first boot of the media|
`USE_TESTING`|enables the testing repo|`false`

### Requirements and notes
1. This script must be run from a x86_64 Arch Linux environment
1. You must have internet access when running this script (it needs to download the Arch packages).
1. It's been tested mostly for making x86_64 installs. i686 installs *might* work by changing 'TARGET_ARCH'. See examples below for installs to ARM targets (this makes use of [Arch Linux ARM](http://archlinuxarm.org/) repos). 
1. Understand that the script provided here comes with no guarentees that it won't destroy your computer and everything attached to it :-), although I believe it's safe (unless you're careless). There are no warnings or "Are you sure you want to..." messages. It will happily obliterate all your cat pictures, your homework, your bitcoin wallet, its self, your family photos and even your nealry competed PhD dissertation if you ask it to, so be careful.

### Usage

You can run the script like this:
```
S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
and prefix new definitions for any variables you'd like to override.  
The [recipes](README.md#recipes) section has a bunch of examples of this.  
[Here are the variables](README.md#variables) you can override to tune your Arch install.

### Recipes

This will generate a 2GiB disk image (suitable for dding to a USB stick) in the current directory called bootable_arch.img:
```
S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
This will install directly to a device at /dev/sdX with a root file system suitable for flash media (f2fs):
```
TARGET=/dev/sdX LEGACY_BOOTLOADER=false S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
(Author favorite) This will install directly to a device at /dev/sdX with a root file system suitable for flash media and include a full gnome desktop with the gparted disk management utility:
```
TARGET=/dev/sdX PACKAGE_LIST="gnome gparted" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
This will install directly to a device at /dev/sdX with a root file system suitable for a SSD/HDD and create a swap partition sized to match the amount of ram installed in the current machine and install a few addidional packages to the target system:
```
TARGET=/dev/sdX ROOT_FS_TYPE=btrfs MAKE_SWAP_PARTITION=true SWAP_SIZE_IS_RAM_SIZE=true PACKAGE_LIST="vim sl" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
This will make a .vdi disk image suitable for running in virtualbox:
```
PACKAGE_LIST="virtualbox-guest-utils" ROOT_FS_TYPE=btrfs S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
VBoxManage convertfromraw --format VDI bootable_arch.img bootable_arch.vdi
```
### Moar Recipes
```
TARGET=/dev/sdX TIME_ZONE="US/Eastern" THIS_HOSTNAME="optiplex745" ROOT_FS_TYPE=btrfs MAKE_SWAP_PARTITION=true SWAP_SIZE_IS_RAM_SIZE=true PACKAGE_LIST="vim gparted cinnamon" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
```
TARGET=/dev/sdX TIME_ZONE="Europe/London" THIS_HOSTNAME="epozz" ROOT_FS_TYPE=btrfs MAKE_SWAP_PARTITION=true SWAP_SIZE_IS_RAM_SIZE=true PACKAGE_LIST="gnome gnome-extra gparted" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Put arch onto a SD card which can boot a raspberry pi:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-raspberrypi raspberrypi-firmware" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Pi with gnome gui:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-raspberrypi raspberrypi-firmware gnome xf86-video-fbturbo-git" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Pi with lxde gui:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-raspberrypi raspberrypi-firmware lxde xf86-video-fbturbo-git" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
