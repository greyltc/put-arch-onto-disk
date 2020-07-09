# put-arch-onto-disk

This repo contains a script which creates a ready-to-use Arch Linux installation, tailored the way I like it. It can be used to install to a USB thumb drive, or to a permanently installed SSD or HDD or whatever or even make a .img file which can later be dd'd to some media.

### Features
 - Installations are bootable on both BIOS and UEFI systems
 - LUKS whole partition encryption support
 - Create a disk image (suitable for dding later) or install directly to target disk
 - Optimized for removable flash storage (choose `f2fs` as root file system type)
 - Optimized for HDD and SSD targets (choose `btrfs` as root file system type)
 - Installations have persistant storage
 - Installations have (optional) AUR support (in the form of yay)
 - Installtions are up-to-date as of the minute you run the script
 - Can install into disks with pre-existing operating systems (like windows) for multi-booting
 - Easily set many installtion parameters programatically for an one-shot, no-further-setup-required Arch install:

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
`LOCALE`|installed system's locale|`en_US.UTF-8`
`CHARSET`|installed system's character set|`UTF-8`
`PORTABLE`|true if you want this media to run on multiple computers|`true`
`KEYMAP`|keyboard layout|`uk`
`ROOT_PASSWORD`|password for root user|
`MAKE_ADMIN_USER`|create a user with sudo powers (and install sudo)|`true`
`ADMIN_USER_NAME`|user name for admin user (requires `MAKE_ADMIN_USER`=`true`)|`admin`
`ADMIN_USER_PASSWORD`|password for admin user (requires `MAKE_ADMIN_USER`=`true`)|`admin`
`THIS_HOSTNAME`|target system's hostname|`archthing`
`PACKAGE_LIST`|list of additional official packages to install|
`ENABLE_AUR`|install `yay` an [AUR helper](https://wiki.archlinux.org/index.php/AUR_helpers) (requires `MAKE_ADMIN_USER`=`true`)|`true`
`AUR_PACKAGE_LIST`|list of packages to install from the AUR (requires `ENABLE_AUR`=`true`)|
`AUTOLOGIN_ADMIN`|autologin admin user through display manager login page (works for gdm and lxdm)|`false`
`FIRST_BOOT_SCRIPT`|path to a (local) script you wish to run on first boot of the media|
`USE_TESTING`|enables the testing repo|`false`
`LUKS_KEYFILE`|[keyfile](https://wiki.archlinux.org/index.php/Dm-crypt/Device_encryption#Keyfiles) used for LUKS encryption|

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
TARGET=/dev/sdX PORTABLE=true LEGACY_BOOTLOADER=false S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
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
Put arch onto a SD card which can boot a raspberry pi (3 & 4 only bleeding edge 64bit install with mainline kernel):
```
TARGET=/dev/sdX TARGET_ARCH=aarch64 THIS_HOSTNAME="pi" AUR_PACKAGE_LIST="yay raspberrypi-bootloader-git rpi-eeprom-git uboot-raspberrypi4-rc" PACKAGE_LIST="linux-aarch64 firmware-raspberrypi" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Put arch onto a SD card which can boot a raspberry pi4:  
ENABLE_AUR must be false with armv7h due to a lack of emulation support in qemu (`git clone` segfaults). Just aurify the system manually after install.
```
TARGET=/dev/sdX ENABLE_AUR="false" TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-raspberrypi4 raspberrypi-firmware raspberrypi-bootloader raspberrypi-bootloader-x firmware-raspberrypi" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Put arch onto a SD card which can boot a raspberry pi (everything except 4):  
ENABLE_AUR must be false with armv7h due to a lack of emulation support in qemu (`git clone` segfaults). Just aurify the system manually after install.
```
TARGET=/dev/sdX ENABLE_AUR="false" TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-raspberrypi raspberrypi-firmware raspberrypi-bootloader raspberrypi-bootloader-x firmware-raspberrypi" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Permanent install onto internal drive:
```
TARGET=/dev/sdX ROOT_FS_TYPE=btrfs MAKE_SWAP_PARTITION=true SWAP_SIZE_IS_RAM_SIZE=true ADMIN_USER_NAME=grey UEFI_BOOTLOADER=true LEGACY_BOOTLOADER=false PORTABLE=false TIME_ZONE=Europe/Oslo PACKAGE_LIST="gnome vim gnome-extra" THIS_HOSTNAME=okra S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Pi with gnome gui:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-raspberrypi raspberrypi-firmware raspberrypi-bootloader raspberrypi-bootloader-x gnome xf86-video-fbturbo-git" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Pi with lxde gui:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-raspberrypi raspberrypi-firmware raspberrypi-bootloader raspberrypi-bootloader-x lxde xf86-video-fbturbo-git" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
---
Pi with official touchscreen:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h AUTOLOGIN_ADMIN=true THIS_HOSTNAME="pi" PACKAGE_LIST="linux-raspberrypi raspberrypi-firmware raspberrypi-bootloader raspberrypi-bootloader-x gnome gnome-extra networkmanager xf86-video-fbturbo-git" S=put-arch-onto-disk sudo -E bash -c 'curl -fsSL -o /tmp/$S.sh https://raw.githubusercontent.com/greyltc/$S/master/$S.sh; bash /tmp/$S.sh; rm /tmp/$S.sh' |& tee archInstall.log
```
