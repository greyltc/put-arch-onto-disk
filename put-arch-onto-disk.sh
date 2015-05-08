#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
set -o verbose
set -o xtrace

# put-arch-onto-disk.sh
# This script installs Arch Linux onto media (making it bootable)
# or into a disk image which can later be dd'd onto some media to make it bootable
# this is an unattedded, one-shot command for making an Arch install that works out-of-the-box
# I've made attempts to make it reasonably configurable, but there is some stuff in here
# that you may not want (eg. the network comes up and sshd runs) so don't use this blindly

# example usage:
# TARGET=/dev/sdX PORTABLE=true sudo ./put-arch-onto-disk.sh |& tee archInstall.log

if test $EUID -ne 0
then
  echo "Please run with root permissions"
  exit 1
fi

# store off the absolute path to *this* script
THIS="$( cd "$(dirname "$0")" ; pwd -P )"/$(basename $0)

# set variable defaults. if any of these are defined elsewhere,
# those values will be used instead of those listed here
: ${TARGET_ARCH:=x86_64}
: ${ROOT_FS_TYPE:=f2fs}
: ${MAKE_SWAP_PARTITION:=false}
: ${SWAP_SIZE_IS_RAM_SIZE:=false}
: ${SWAP_SIZE:=100MiB}
: ${TARGET:=./bootable_arch.img}
 #set true when the target will be a removable drive, false when the install is only for the machine runnning this script
: ${PORTABLE:=true}
: ${IMG_SIZE:=2GiB}
: ${TIME_ZONE:=Europe/London}
# possible keymap options can be seen by `localectl list-keymaps`
: ${KEYMAP:=uk}
: ${LOCALE:=en_US.UTF-8}
: ${CHARSET:=UTF-8}
: ${LEGACY_BOOTLOADER:=false}
: ${UEFI_BOOTLOADER:=true}
: ${UEFI_COMPAT_STUB:=false}
: ${ROOT_PASSWORD:=""}
: ${MAKE_ADMIN_USER:=true}
: ${ADMIN_USER_NAME:=admin}
: ${ADMIN_USER_PASSWORD:=admin}
: ${THIS_HOSTNAME:=archthing}
: ${PACKAGE_LIST:=""}
: ${ENABLE_AUR:=true}
: ${AUR_PACKAGE_LIST:=""}
: ${AUTOLOGIN_ADMIN:=false}
: ${FIRST_BOOT_SCRIPT:=""}
: ${USE_TESTING:=false}
: ${LUKS_KEYFILE:=""}
: ${PREEXISTING_BOOT_PARTITION_NUM:=""} # this will not be formatted
: ${PREEXISTING_ROOT_PARTITION_NUM:=""} # this WILL be formatted
# any pre-existing swap partition will just be used via systemd magic

contains() {
  string="$1"
  substring="$2"
  if test "${string#*$substring}" != "$string"
  then
    true    # $substring is in $string
  else
    false    # $substring is not in $string
  fi
}

TO_EXISTING=true
if test -z "${PREEXISTING_BOOT_PARTITION_NUM}" || test -z "${PREEXISTING_ROOT_PARTITION_NUM}"
then
  if test -z "${PREEXISTING_BOOT_PARTITION_NUM}" && test -z "${PREEXISTING_ROOT_PARTITION_NUM}"
  then
    TO_EXISTING=false
  else
    echo "You must specify both root and boot pre-existing partition numbers"
    exit 1
  fi
fi

if contains "${TARGET_ARCH}" "arm" || test "${TARGET_ARCH}" = "aarch64"
then
  if pacman -Q qemu-user-static-bin > /dev/null 2>/dev/null && pacman -Q binfmt-qemu-static > /dev/null 2>/dev/null
  then
    NON_ARM_PKGS=""
  else
    echo "Please install qemu-user-static-bin and binfmt-qemu-static from the AUR"
    echo "so that we can chroot into the ARM install"
    exit 1
  fi
else
  # alarm does not like/need these
  NON_ARM_PKGS="linux grub efibootmgr reflector os-prober linux-firmware amd-ucode intel-ucode"
fi

# here are a baseline set of packages for the new install
DEFAULT_PACKAGES="base ${NON_ARM_PKGS} mkinitcpio haveged btrfs-progs dosfstools exfat-utils f2fs-tools openssh gpart parted mtools nilfs-utils ntfs-3g gdisk arch-install-scripts bash-completion rsync dialog ifplugd cpupower ntp vi"

# install these packages on the host now. they're needed for the install process
pacman -Syu --needed --noconfirm efibootmgr btrfs-progs dosfstools f2fs-tools gpart parted gdisk arch-install-scripts

# flush writes to disks and re-probe partitions
sync
partprobe

# is this a block device?
if test -b "${TARGET}"
then
  TARGET_DEV="${TARGET}"
  for n in ${TARGET_DEV}* ; do umount $n || true; done
  for n in ${TARGET_DEV}* ; do umount $n || true; done
  for n in ${TARGET_DEV}* ; do umount $n || true; done
  IMG_NAME=""
else
  IMG_NAME=$TARGET
  rm -f "${IMG_NAME}"
  su -c "fallocate -l $IMG_SIZE ${IMG_NAME}" $SUDO_USER
  TARGET_DEV=$(losetup --find)
  losetup -P ${TARGET_DEV} "${IMG_NAME}"
fi

if test ! -b "${TARGET}"
then
  echo "ERROR: Install target ${TARGET} is not a block device."
  exit 1
fi

# check that install to existing will work here
if test "${TO_EXISTING}" = "true"
then
  PARTLINE=$(parted -s ${TARGET_DEV} print | sed -n "/^ ${PREEXISTING_BOOT_PARTITION_NUM}/p")
  if contains "${PARTLINE}" "fat32" && contains "${PARTLINE}" "boot" && contains "${PARTLINE}" "esp"
  then
    echo "Pre-existing boot partition looks good"
  else
    echo "Pre-existing boot partition must be fat32 with boot and esp flags"
    exit 1
  fi
  BOOT_PARTITION=${PREEXISTING_BOOT_PARTITION_NUM}
  ROOT_PARTITION=${PREEXISTING_ROOT_PARTITION_NUM}
  
  # do we need to p? (depends on what the media is we're installing to)
  if test -b "${TARGET_DEV}p1"; then PEE=p; else PEE=""; fi
else # non-preexisting
  # destroy all file systems and partition tables on the target
  for n in ${TARGET_DEV}+([[:alnum:]]) ; do wipefs -a -f $n || true; done # wipe the partitions' file systems
  for n in ${TARGET_DEV}+([[:alnum:]]) ; do sgdisk -Z $n || true; done # zap the partitions' part tables
  wipefs -a -f ${TARGET_DEV} || true # wipe the device file system
  sgdisk -Z ${TARGET_DEV}  || true # wipe the device partition table
  
  NEXT_PARTITION=1
  if contains "${TARGET_ARCH}" "arm" || test "${TARGET_ARCH}" = "aarch64"
  then
    echo "No bios grub for arm"
    BOOT_P_TYPE=0700
  else
    sgdisk -n 0:+0:+1MiB -t 0:ef02 -c 0:"Legacy BIOS GRUB partition" "${TARGET_DEV}"; ((NEXT_PARTITION++))
    BOOT_P_TYPE=ef00
  fi
  BOOT_P_SIZE_MB=300
  sgdisk -n 0:+0:+${BOOT_P_SIZE_MB}MiB -t 0:${BOOT_P_TYPE} -c 0:"EFI system parition" "${TARGET_DEV}"; BOOT_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))
  if test "${MAKE_SWAP_PARTITION}" = "true"
  then
    if test "${SWAP_SIZE_IS_RAM_SIZE}" = "true"
    then
      SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
    fi
    sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:swap "${TARGET_DEV}"; SWAP_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))
  fi
  #sgdisk -N 0 -t 0:8300 -c 0:${ROOT_FS_TYPE}Root "${TARGET_DEV}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
  sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8300 -c ${NEXT_PARTITION}:"Linux ${ROOT_FS_TYPE} data parition" "${TARGET_DEV}"; ROOT_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))

  # make hybrid/protective MBR
  #sgdisk -h "1 2" "${TARGET_DEV}"
  echo -e "r\nh\n1 2\nN\n0c\nN\n\nN\nN\nw\nY\n" | sudo gdisk "${TARGET_DEV}"

  # do we need to p? (depends on what the media is we're installing to)
  if test -b "${TARGET_DEV}p1"; then PEE=p; else PEE=""; fi

  wipefs -a -f ${TARGET_DEV}${PEE}${BOOT_PARTITION}
  mkfs.fat -F32 -n BOOT ${TARGET_DEV}${PEE}${BOOT_PARTITION}
  if test "${MAKE_SWAP_PARTITION}" = "true"
  then
    wipefs -a -f ${TARGET_DEV}${PEE}${SWAP_PARTITION}
    mkswap -L swap ${TARGET_DEV}${PEE}${SWAP_PARTITION}
  fi
fi

ROOT_DEVICE=${TARGET_DEV}${PEE}${ROOT_PARTITION}
wipefs -a -f ${ROOT_DEVICE} || true

LUKS_UUID=""
if test -z "${LUKS_KEYFILE}"
then
  echo "Not using encryption"
else
  if test -f "${LUKS_KEYFILE}"
  then
    echo "LUKS encryption with keyfile: $(readlink -f "${LUKS_KEYFILE}")"
    cryptsetup -q luksFormat ${ROOT_DEVICE} "${LUKS_KEYFILE}"
    LUKS_UUID=$(cryptsetup luksUUID ${ROOT_DEVICE})
    cryptsetup -q --key-file ${LUKS_KEYFILE} open ${ROOT_DEVICE} luks-${LUKS_UUID}
    ROOT_DEVICE=/dev/mapper/luks-${LUKS_UUID}
  else
    echo "Could not find ${LUKS_KEYFILE}"
    echo "Not using encryption"
    exit 1
  fi
fi

if test "${ROOT_FS_TYPE}" = "f2fs"; then ELL=l; else ELL=L; fi
mkfs.${ROOT_FS_TYPE} -${ELL} ${ROOT_FS_TYPE}Root ${ROOT_DEVICE}

sgdisk -p "${TARGET_DEV}"  # just prints the current partition table

rm -f "${IMG_NAME}"
if [ "$USE_TARGET_DISK" = true ] ; then
  DISK_INFO=$(lsblk -n -b -o SIZE,PHY-SEC ${TARGET_DISK})
  IFS=' ' read -a DISK_INFO_A <<< "$DISK_INFO"
  IMG_SIZE=$(numfmt --to-unit=K ${DISK_INFO_A[0]})KiB
  PHY_SEC_BYTES=${DISK_INFO_A[1]}
fi
fallocate -l $IMG_SIZE "${IMG_NAME}"
wipefs -a -f "${IMG_NAME}"
sgdisk -n 0:+0:+1MiB -t 0:ef02 -c 0:biosGrub "${IMG_NAME}"
sgdisk -n 0:+0:+200MiB -t 0:8300 -c 0:ext4Boot "${IMG_NAME}"
NEXT_PARTITION=3
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  if [ "$SWAP_SIZE_IS_RAM_SIZE" = true ] ; then
    SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
  fi
  sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:swap "${IMG_NAME}"
  NEXT_PARTITION=4
fi
#sgdisk -N 0 -t 0:8300 -c 0:${ROOT_FS_TYPE}Root "${IMG_NAME}"
sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8300 -c ${NEXT_PARTITION}:${ROOT_FS_TYPE}Root "${IMG_NAME}"

LOOPDEV=$(sudo losetup --find)
sudo losetup -P ${LOOPDEV} "${IMG_NAME}"
sudo wipefs -a -f ${LOOPDEV}p2
sudo mkfs.ext4 -L ext4Boot ${LOOPDEV}p2
ELL=L
sudo wipefs -a -f ${LOOPDEV}p${NEXT_PARTITION}
[ "$ROOT_FS_TYPE" = "f2fs" ] && ELL=l
sudo mkfs.${ROOT_FS_TYPE} -${ELL} ${ROOT_FS_TYPE}Root ${LOOPDEV}p${NEXT_PARTITION}
sgdisk -p "${IMG_NAME}"
TMP_ROOT=/tmp/diskRootTarget
mkdir -p ${TMP_ROOT}
sudo mount -t${ROOT_FS_TYPE} ${LOOPDEV}p${NEXT_PARTITION} ${TMP_ROOT}
sudo mkdir ${TMP_ROOT}/boot
sudo mount -text4 ${LOOPDEV}p2 ${TMP_ROOT}/boot
sudo pacstrap ${TMP_ROOT} base grub ${PACKAGE_LIST}
sudo sh -c "genfstab -U ${TMP_ROOT} >> ${TMP_ROOT}/etc/fstab"
sudo sed -i '/swap/d' ${TMP_ROOT}/etc/fstab
sudo sed -i '$ d' ${TMP_ROOT}/etc/fstab
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  SWAP_UUID=$(lsblk -n -b -o UUID ${LOOPDEV}p3)
  sudo sed -i '$a #swap' ${TMP_ROOT}/etc/fstab
  sudo sed -i '$a UUID='${SWAP_UUID}'	none      	swap      	defaults  	0 0' ${TMP_ROOT}/etc/fstab
fi

cat > /tmp/chroot.sh <<EOF
#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
set -o verbose
set -o xtrace

# set hostname
echo ${THIS_HOSTNAME} > /etc/hostname

# set timezone
ln -sf /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime

# generate adjtime
hwclock --systohc

# do locale things
sed -i "s,^#${LOCALE} ${CHARSET},${LOCALE} ${CHARSET},g" /etc/locale.gen
locale-gen
localectl set-locale LANG=${LOCALE}
unset LANG
set +o nounset
source /etc/profile.d/locale.sh
set -o nounset
localectl set-keymap ${KEYMAP}
localectl status

# setup gnupg
mkdir -p /etc/skel/.gnupg
echo "keyserver hkps://hkps.pool.sks-keyservers.net:443" >> /etc/skel/.gnupg/gpg.conf
echo "keyserver-options auto-key-retrieve" >> /etc/skel/.gnupg/gpg.conf

# change password for root
if [ "$ROOT_PASSWORD" = "" ]
then
   echo "No password for root"
else
   echo "root:${ROOT_PASSWORD}"|chpasswd
fi

# copy over the skel files for the root user
cp -r \$(find /etc/skel -name ".*") /root

# update pacman keys
haveged -w 1024
pacman-key --init
pkill haveged || true
pacman -Rs --noconfirm haveged
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "nameserver 1.0.0.1" >> /etc/resolv.conf
if [[ \$(uname -m) == *"arm"*  || \$(uname -m) == "aarch64" ]] ; then
  pacman -S --noconfirm --needed archlinuxarm-keyring
  pacman-key --init
  pacman-key --populate archlinuxarm
else
  pacman-key --populate archlinux
  reflector --latest 200 --protocol http --protocol https --sort rate --save /etc/pacman.d/mirrorlist
fi
pkill gpg-agent || true

# make pacman color
sed -i 's/#Color/Color/g' /etc/pacman.conf

# do an update
pacman -Syyu --noconfirm

# setup admin user
if [ "$MAKE_ADMIN_USER" = true ] ; then
  useradd -m -G wheel -s /bin/bash ${ADMIN_USER_NAME}
  echo "${ADMIN_USER_NAME}:${ADMIN_USER_PASSWORD}"|chpasswd
  pacman -S --needed --noconfirm sudo
  
  # users in the wheel group have sudo powers
  sed -i 's/# %wheel ALL=(ALL)/%wheel ALL=(ALL)/g' /etc/sudoers

  # AUR can only be enabled if a non-root user exists, so we'll do it in here
  if [ "$ENABLE_AUR" = true ] ; then
    pacman -S --needed --noconfirm base-devel go git # needed to build aur packages and for yay
    # backup makepkg built packages
    MAKEPKG_BACKUP="/var/cache/makepkg/pkg"
    mkdir -p "\${MAKEPKG_BACKUP}"
    groupadd yay
    usermod -a -G yay ${ADMIN_USER_NAME}
    chgrp yay "\${MAKEPKG_BACKUP}"
    chmod g+w "\${MAKEPKG_BACKUP}"
    sed -i "s,#PKGDEST=/home/packages,PKGDEST=\${MAKEPKG_BACKUP},g" /etc/makepkg.conf
    
    # make and install yay 
    su -c "(cd; git clone https://aur.archlinux.org/yay.git)" -s /bin/bash ${ADMIN_USER_NAME}
    
    # temporarily give wheel users passwordless sudo powers
    sed -i 's/# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
    
    su -c "(cd; cd yay; makepkg -i --noconfirm)" -s /bin/bash ${ADMIN_USER_NAME}
    if [ !  -z  $AUR_PACKAGE_LIST  ] ; then # this seems to be broken (tested with rpi, yay doesn't work here)
      su -c "(EDITOR=vi VISUAL=vi yay -Syyu --needed --noconfirm ${AUR_PACKAGE_LIST})" -s /bin/bash ${ADMIN_USER_NAME}
    fi

    # make sudo prompt wheel users for a password again
    sed -i 's/%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers

    su -c "(cd; rm -rf yay)" -s /bin/bash ${ADMIN_USER_NAME}
  fi
fi

# if cpupower is installed, enable the service
if pacman -Q cpupower > /dev/null 2>/dev/null; then
  systemctl enable cpupower.service
  if pacman -Q | grep raspberry > /dev/null 2>/dev/null ; then
    # set the ondemand governor for arm
    sed -i "s/#governor='ondemand'/governor='ondemand'/g" /etc/default/cpupower
  fi
fi

# if ntp is installed, enable the service
if pacman -Q ntp > /dev/null 2>/dev/null; then
  systemctl enable ntpd.service
fi

# if openssh is installed, enable the service
if pacman -Q openssh > /dev/null 2>/dev/null; then
  systemctl enable sshd.service
fi

# if networkmanager is installed, enable it, otherwise let systemd things manage the network
if pacman -Q networkmanager > /dev/null 2>/dev/null; then
  echo "Enabling NetworkManager service"
  systemctl enable NetworkManager.service
else
  echo "Enabling systemd-networkd service"
  systemctl enable systemd-networkd
  systemctl enable systemd-resolved
  sed -i -e 's/hosts: files dns myhostname/hosts: files resolve myhostname/g' /etc/nsswitch.conf
  touch /link_resolv_conf #leave a marker so we can complete this setup at first boot
  cat > /etc/systemd/network/DHCPany.network << END
[Match]
Name=*

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
END
fi

# setup for encfs
if [ "$LUKS_UUID" = "" ]; then
  echo "No encryption"
else
  sed -i 's/MODULES=(/MODULES=(nls_cp437 /g' /etc/mkinitcpio.conf
  sed -i 's/block filesystems/block encrypt filesystems/g' /etc/mkinitcpio.conf

fi
mkinitcpio -p linux
grub-install --modules=part_gpt --target=i386-pc --recheck --debug ${LOOPDEV}
grub-mkconfig -o /boot/grub/grub.cfg

if [ "$ROOT_FS_TYPE" = "f2fs" ] ; then
  ROOT_UUID=$(lsblk -n -b -o UUID ${LOOPDEV}p${NEXT_PARTITION})
  sed -i 's,root=${LOOPDEV}p${NEXT_PARTITION},root=UUID='\$ROOT_UUID',g' /boot/grub/grub.cfg
fi
EOF
if [ "$DD_TO_TARGET" = true ] ; then
  sudo wipefs -a ${TARGET_DISK}
fi
chmod +x /tmp/chroot.sh
mv /tmp/chroot.sh "${TMP_ROOT}/root/chroot.sh"
set +o errexit
arch-chroot "${TMP_ROOT}" /root/chroot.sh; CHROOT_RESULT=$? || true
set -o errexit

sync
sudo umount ${TMP_ROOT}/boot
sudo umount ${TMP_ROOT}
sudo losetup -D
sync
if [ "$DD_TO_TARGET" = true ] ; then
  sudo dd if="${IMG_NAME}" of=${TARGET_DISK} bs=1M
  sync
  sudo sgdisk -e ${TARGET_DISK}
  sudo sgdisk -v ${TARGET_DISK}
fi

if test "${CHROOT_RESULT}" -eq 0
then
  echo "Image sucessfully created"
  if eject ${TARGET_DEV}
  then
    echo "It's now safe to remove $TARGET_DEV"
  fi
else
  echo "There was some failure while setting up the operating system."
fi
