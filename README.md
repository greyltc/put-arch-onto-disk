# put-arch-onto-disk

This repo contains a script which creates a ready-to-use Arch Linux installation. I can be used to install to a USB thumb drive, or to a permanently installed SSD or HDD or whatever.

### Features
 - Installations are bootable on both BIOS and UEFI systems
 - Create a disk image (suitable for dding later) or install directly to target disk
 - Optimized for removable flash storage (choose `f2fs` as root file system type)
 - Optimized for HDD and SSD targets (choose `btrfs` as root file system type)
 - Installations have persistant storage
 - Installations have (optional) AUR suport (in the form of yaourt)
 - Installtions are up-to-date as of the minute you run the script
 - Easily set many installtion parameters programatically:


Variable Name|Description|Default Value
---|---|---
`TARGET_ARCH`|target architecture|`x86_64`
`ROOT_FS_TYPE`|root file system type|`f2fs`
`MAKE_SWAP_PARTITION`|create swap partition|`false`
`SWAP_SIZE_IS_RAM_SIZE`|use amount of installed ram as swap size|`false`
`SWAP_SIZE`|swap partition size (if `SWAP_SIZE_IS_RAM_SIZE`=`false`)|`100MiB`
`TARGET`|installation target. if this is a block deivce, you'll get a direct install, if it's a file you'll get a disk image|`./bootable_arch.img`
`IMG_SIZE`|disk image size|`2GiB`
`TIME_ZONE`|installed system's timezone|`Europe/London`
`LANGUAGE`|installed system's language|`en_US`
`KEYMAP`|keyboard layout|`uk`
`TEXT_ENCODING`|installed system's text encoding|`UTF-8`
`ROOT_PASSWORD`|password for root user|`toor`
`MAKE_ADMIN_USER`|create a user with sudo powers|`false`
`ADMIN_USER_NAME`|user name for admin user|`l3iggs`
`ADMIN_USER_PASSWORD`|password for admin user|`sggi3l`
`THIS_HOSTNAME`|installed system's hostname|`bootdisk`
`PACKAGE_LIST`|list of additional official packages to install|
`ENABLE_AUR`|install `yaourt` for easy installs from AUR|`true`
`AUR_PACKAGE_LIST`|list of packages to install from the AUR|
`GDM_AUTOLOGIN_ADMIN`|autologin admin user through gdm login page|`false`
`FIRST_BOOT_SCRIPT`|path to a (local) script you wish to run on first boot|
`DD_TO_DISK`|dd the created disk image to this block device|`false`
`TARGET_IS_REMOVABLE`|the target block device is removable|`false`
`CLEAN_UP`|delete the disk image created here (if created)|`false`

### Requirements
1. This script must be run from a x86_64 Arch Linux environment
1. Do not expect the installation created here to work on any machine which does not supoprt x86_64
1. `sudo pacman -Syyu --needed util-linux coreutils gptfdisk f2fs-tools e2fsprogs btrfs-progs arch-install-scripts procps-ng sed`
1. Understand that the script provided here comes with no guarentees that it won't destroy your computer and everything attached to it :-), although I believe it's safe (unless you're careless). There are no warnings or "Are you sure you want to..." messages. It will happily dd over all your cat pictures, your homework, your bitcoin wallet, its self, your family photos and even your nealry competed PhD dissertation if you ask it to, so be careful.

### Usage

1. Examine the variables listed here and make sure you understand what the defaults are (they should be safe, since there is no dding by default).
1. Define the appropriate environment variables to override the defaults and call the script.

You must run the script with root permissions.
### Recipes
In to following recipes, `./put-arch-onto-disk.sh` can be replaced with `bash -c "$(curl -fsSL https://raw.githubusercontent.com/l3iggs/put-arch-onto-disk/master/put-arch-onto-disk.sh)"` to run the script directly from this repo.

This will generate a 2GiB disk image (suitable for dding to a USB stick) in the current directory called bootable_arch.img:
```
./put-arch-onto-disk.sh
```
---
This will generate a 4GiB disk image (suitable for dding to a USB stick) in the current directory called bootable_arch.img, then use dd to copy it to a USB stick at /dev/sdX and then delete the image file:
```
IMG_SIZE=4GiB DD_TO_DISK=/dev/sdX CLEAN_UP=true TARGET_IS_REMOVABLE=true sudo -E ./put-arch-onto-disk.sh
```
---
This will install directly to a device at /dev/sdX with a root file system suitable for a USB stick:
```
TARGET=/dev/sdX TARGET_IS_REMOVABLE=true sudo -E ./put-arch-onto-disk.sh
```
---
(Author favorite) This will install directly to a device at /dev/sdX with a root file system suitable for a USB stick and include a full gnome desktop with the gparted disk management utility:
```
TARGET=/dev/sdX TARGET_IS_REMOVABLE=true PACKAGE_LIST="gnome gnome-extra gparted" sudo -E ./put-arch-onto-disk.sh
```
---
This will install directly to a device at /dev/sdX with a root file system suitable for a SSD/HDD and create a swap partition sized to match the amount of ram installed in the current machine and install a few addidional packages to the target system:
```
TARGET=/dev/sdX ROOT_FS_TYPE=btrfs MAKE_SWAP_PARTITION=true SWAP_SIZE_IS_RAM_SIZE=true PACKAGE_LIST="vim sl" sudo -E ./put-arch-onto-disk.sh
```
---
This will make a .vdi disk image suitable for running in virtualbox:
```
MAKE_ADMIN_USER=true PACKAGE_LIST="virtualbox-guest-utils" ROOT_FS_TYPE=btrfs sudo -E bash -c "$(curl -fsSL https://raw.githubusercontent.com/l3iggs/put-arch-onto-disk/master/put-arch-onto-disk.sh)"
VBoxManage convertfromraw --format VDI bootable_arch.img bootable_arch.vdi
```
### Moar Recipes
```
TARGET=/dev/sdX MAKE_ADMIN_USER=true TIME_ZONE="US/Eastern" THIS_HOSTNAME="optiplex745" ROOT_FS_TYPE=btrfs MAKE_SWAP_PARTITION=true SWAP_SIZE_IS_RAM_SIZE=true PACKAGE_LIST="vim gparted cinnamon" sudo -E ./put-arch-onto-disk.sh
```
```
TARGET=/dev/sdX MAKE_ADMIN_USER=true ADMIN_USER_NAME=grey TIME_ZONE="Europe/London" THIS_HOSTNAME="epozz" ROOT_FS_TYPE=btrfs MAKE_SWAP_PARTITION=true SWAP_SIZE_IS_RAM_SIZE=true PACKAGE_LIST="gnome gnome-extra gparted" sudo -E ./put-arch-onto-disk.sh
```

Tested on a Raspberry Pi 2:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-firmware linux-raspberrypi raspberrypi-firmware" sudo -E bash -c "$(curl -fsSL https://raw.githubusercontent.com/l3iggs/put-arch-onto-disk/master/put-arch-onto-disk.sh)"
```

Pi with gnome gui:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-firmware linux-raspberrypi raspberrypi-firmware gnome gnome-extra xf86-video-fbturbo-git" sudo -E bash -c "$(curl -fsSL https://raw.githubusercontent.com/l3iggs/put-arch-onto-disk/master/put-arch-onto-disk.sh)"
```
Pi with lxde gui:
```
TARGET=/dev/sdX TARGET_ARCH=armv7h THIS_HOSTNAME="pi" PACKAGE_LIST="linux-firmware linux-raspberrypi raspberrypi-firmware lxde xf86-video-fbturbo-git" sudo -E bash -c "$(curl -fsSL https://raw.githubusercontent.com/l3iggs/put-arch-onto-disk/master/put-arch-onto-disk.sh)"
```
