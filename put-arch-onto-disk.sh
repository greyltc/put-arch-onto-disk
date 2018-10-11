#!/usr/bin/env bash
set -eu -o pipefail
set -vx #echo on

# put-arch-onto-disk.sh
# This script installs Arch Linux onto media (making it bootable)
# or into a disk image which can later be dd'd onto some media to make it bootable
# this is an unattedded, one-shot command for making an Arch install that works out-of-the-box
# I've made attempts to make it reasonably configurable, but there is some stuff in here
# that you may not want (eg. the network comes up and sshd runs) so don't use this blindly

if [[ $EUID -ne 0 ]]; then
  echo "Please run with root permissions"
  exit
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
: ${KEYMAP:=uk}
: ${LANGUAGE:=en_US}
: ${TEXT_ENCODING:=UTF-8}
: ${LEGACY_BOOTLOADER:=true}
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

if [[ $TARGET_ARCH == *"arm"* || $TARGET_ARCH == "aarch64" ]]; then
  if pacman -Q qemu-user-static-bin > /dev/null 2>/dev/null && pacman -Q binfmt-qemu-static > /dev/null 2>/dev/null; then
    NON_ARM_PKGS=""
  else
    echo "Please install qemu-user-static-bin and binfmt-qemu-static from the AUR"
    echo "so that we can chroot into the ARM install"
    exit
  fi
else
  # alarm does not like/need these
  NON_ARM_PKGS="grub efibootmgr reflector jfsutils os-prober"
fi

# here are a baseline set of packages for the new install
DEFAULT_PACKAGES="base ${NON_ARM_PKGS} haveged btrfs-progs dosfstools exfat-utils f2fs-tools openssh gpart parted mtools nilfs-utils ntfs-3g gdisk arch-install-scripts bash-completion rsync dialog wpa_actiond ifplugd cpupower ntp"

# install these packages on the host now. they're needed for the install process
pacman -Sy --needed --noconfirm efibootmgr btrfs-progs dosfstools f2fs-tools gpart parted gdisk arch-install-scripts

# flush writes to disks and re-probe partitions
sync
partprobe

# is this a block device?
if [ -b $TARGET ] ; then
  TARGET_DEV=$TARGET
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

wipefs -a -f "${TARGET_DEV}"
sgdisk -Z "${TARGET_DEV}"  || true # zap (destroy) all partition tables

NEXT_PARTITION=1
if [[ $TARGET_ARCH == *"arm"*  || $TARGET_ARCH == "aarch64" ]]; then
  echo "No bios grub for arm"
  BOOT_P_TYPE=0700
else
  sgdisk -n 0:+0:+1MiB -t 0:ef02 -c 0:"Legacy BIOS GRUB partition" "${TARGET_DEV}" && ((NEXT_PARTITION++))
  BOOT_P_TYPE=ef00
fi
BOOT_P_SIZE_MB=300
sgdisk -n 0:+0:+${BOOT_P_SIZE_MB}MiB -t 0:${BOOT_P_TYPE} -c 0:"EFI system parition" "${TARGET_DEV}"; BOOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  if [ "$SWAP_SIZE_IS_RAM_SIZE" = true ] ; then
    SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
  fi
  sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:swap "${TARGET_DEV}"; SWAP_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
fi
#sgdisk -N 0 -t 0:8300 -c 0:${ROOT_FS_TYPE}Root "${TARGET_DEV}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8300 -c ${NEXT_PARTITION}:"Linux ${ROOT_FS_TYPE} data parition" "${TARGET_DEV}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))

# make hybrid/protective MBR
#sgdisk -h "1 2" "${TARGET_DEV}"
echo -e "r\nh\n1 2\nN\n0c\nN\n\nN\nN\nw\nY\n" | sudo gdisk "${TARGET_DEV}"

# do we need to p? (depends on what the media is we're installing to)
if [ -b ${TARGET_DEV}p1 ] ; then
  PEE="p"
else
  PEE=""
fi

wipefs -a -f ${TARGET_DEV}${PEE}${BOOT_PARTITION}
mkfs.fat -F32 -n BOOT ${TARGET_DEV}${PEE}${BOOT_PARTITION}
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  wipefs -a -f ${TARGET_DEV}${PEE}${SWAP_PARTITION}
  mkswap -L swap ${TARGET_DEV}${PEE}${SWAP_PARTITION}
fi

ROOT_DEVICE=${TARGET_DEV}${PEE}${ROOT_PARTITION}
wipefs -a -f ${ROOT_DEVICE}
LUKS_UUID=""
if [ "$LUKS_KEYFILE" = "" ]; then
  echo "Not using encryption"
else
  if [ -f "$LUKS_KEYFILE" ]; then
    echo "LUKS encryption with keyfile: $(readlink -f "$LUKS_KEYFILE")"
    cryptsetup -q luksFormat ${ROOT_DEVICE} "${LUKS_KEYFILE}"
    LUKS_UUID=$(cryptsetup luksUUID ${ROOT_DEVICE})
    cryptsetup -q --key-file ${LUKS_KEYFILE} open ${ROOT_DEVICE} luks-${LUKS_UUID}
    ROOT_DEVICE=/dev/mapper/luks-${LUKS_UUID}
  else
    echo "Could not find $LUKS_KEYFILE"
    echo "Not using encryption"
  fi
fi

ELL=L
[ "$ROOT_FS_TYPE" = "f2fs" ] && ELL=l
mkfs.${ROOT_FS_TYPE} -${ELL} ${ROOT_FS_TYPE}Root ${ROOT_DEVICE}
sgdisk -p "${TARGET_DEV}"
TMP_ROOT=/tmp/diskRootTarget
mkdir -p ${TMP_ROOT}
mount -t${ROOT_FS_TYPE} ${ROOT_DEVICE} ${TMP_ROOT}
if [ "$ROOT_FS_TYPE" = "btrfs" ] ; then
  btrfs subvolume create ${TMP_ROOT}/root
  btrfs subvolume create ${TMP_ROOT}/home
  umount ${TMP_ROOT}
  mount ${ROOT_DEVICE} -o subvol=root,compress=lzo ${TMP_ROOT}
  mkdir ${TMP_ROOT}/home
  mount ${ROOT_DEVICE} -o subvol=home,compress=lzo ${TMP_ROOT}/home
fi
mkdir ${TMP_ROOT}/boot
mount ${TARGET_DEV}${PEE}${BOOT_PARTITION} ${TMP_ROOT}/boot
cp /etc/pacman.d/mirrorlist /tmp/mirrorlist
cat <<EOF > /tmp/pacman.conf
[options]
HoldPkg     = pacman glibc
Architecture = ${TARGET_ARCH}
CheckSpace
SigLevel = Never
EOF

# enable the testing repo
if [ "$USE_TESTING" = true ] ; then
  cat <<EOF >> /tmp/pacman.conf

[testing]
Include = /tmp/mirrorlist
EOF
fi

cat <<EOF >> /tmp/pacman.conf

[core]
Include = /tmp/mirrorlist

[extra]
Include = /tmp/mirrorlist

[community]
Include = /tmp/mirrorlist
EOF

if [[ $TARGET_ARCH == *"arm"*  || $TARGET_ARCH == "aarch64" ]]; then
  cat <<EOF >> /tmp/pacman.conf

[alarm]
Include = /tmp/mirrorlist

[aur]
Include = /tmp/mirrorlist
EOF
  mkdir -p ${TMP_ROOT}/usr/bin
  cp /usr/bin/qemu-arm-static ${TMP_ROOT}/usr/bin
  cp /usr/bin/qemu-aarch64-static ${TMP_ROOT}/usr/bin
  echo 'Server = http://mirror.archlinuxarm.org/$arch/$repo' > /tmp/mirrorlist
fi

pacstrap -C /tmp/pacman.conf -M -G ${TMP_ROOT} ${DEFAULT_PACKAGES} ${PACKAGE_LIST} 
genfstab -U ${TMP_ROOT} >> ${TMP_ROOT}/etc/fstab
sed -i '/swap/d' ${TMP_ROOT}/etc/fstab
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  SWAP_UUID=$(lsblk -n -b -o UUID ${TARGET_DEV}${PEE}${SWAP_PARTITION})
  sed -i '$a #swap' ${TMP_ROOT}/etc/fstab
  sed -i '$a UUID='${SWAP_UUID}'	none      	swap      	defaults  	0 0' ${TMP_ROOT}/etc/fstab
fi
[ -f "$FIRST_BOOT_SCRIPT" ] && cp "$FIRST_BOOT_SCRIPT" ${TMP_ROOT}/usr/sbin/runOnFirstBoot.sh && chmod +x ${TMP_ROOT}/usr/sbin/runOnFirstBoot.sh

cat > /tmp/chroot.sh <<EOF
#!/usr/bin/env bash
set -eu -o pipefail
set -vx #echo on

# set hostname
echo ${THIS_HOSTNAME} > /etc/hostname

# set timezone
ln -sf /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime

# do locale things
echo "${LANGUAGE}.${TEXT_ENCODING} ${TEXT_ENCODING}" >> /etc/locale.gen
if [[ $TARGET_ARCH == *"arm"*  || $TARGET_ARCH == "aarch64" ]]; then
  echo "locale-gen is broken in qemu"
else
  locale-gen
  locale > /etc/locale.conf
  #echo "LANG=${LANGUAGE}.${TEXT_ENCODING}" >> /etc/locale.conf
  sed -i "s,LANG=.*,LANG=${LANGUAGE}.${TEXT_ENCODING},g" /etc/locale.conf
  #localectl set-locale LANG=${LANGUAGE}.${TEXT_ENCODING}
  locale-gen
  source /etc/locale.conf
fi

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
  sed -i 's/# %wheel ALL=(ALL)/%wheel ALL=(ALL)/g' /etc/sudoers
  
  # AUR can only be enabled if a non-root user exists, so we'll do it in here
  if [ "$ENABLE_AUR" = true ] ; then
    pacman -S --needed --noconfirm base-devel # needed to build aur packages
    # bootstrap yay
    pacman -S --needed --noconfirm go git # needed for yay

    su -c "(cd; git clone https://aur.archlinux.org/yay.git)" -s /bin/bash ${ADMIN_USER_NAME}
    su -c "(cd; cd yay; makepkg -i --noconfirm; cd; rm -rf yay)" -s /bin/bash ${ADMIN_USER_NAME}
    su -c "(EDITOR=vi VISUAL=vi yay -Syyu --needed --noconfirm $AUR_PACKAGE_LIST)" -s /bin/bash ${ADMIN_USER_NAME}
  fi
  # make sudo prompt for password
  sed -i 's/%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
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

# add come modules to initcpio (needed for f2fs and usb)
sed -i 's/MODULES=(/MODULES=(usbcore ehci_hcd uhci_hcd crc32_generic crc32-pclmul libcrc32c crc32c_generic crc32c-intel crc32 f2fs /g' /etc/mkinitcpio.conf

# if bcache is installed, make sure its module is loaded super early in case / is bcache
if pacman -Q bcache-tools > /dev/null 2>/dev/null; then
  sed -i 's/MODULES=("/MODULES=(bcache /g' /etc/mkinitcpio.conf
  sed -i 's/HOOKS=(base udev autodetect modconf block/HOOKS=(base udev autodetect modconf block bcache/g' /etc/mkinitcpio.conf
fi

# if gdm was installed, let's do a few things
if pacman -Q gdm > /dev/null 2>/dev/null; then
  systemctl enable gdm
  #TODO: set keyboard layout for gnome
  if [ "$MAKE_ADMIN_USER" = true ] && [ "$AUTOLOGIN_ADMIN" = true ] ; then
    echo "# Enable automatic login for user" >> /etc/gdm/custom.conf
    echo "[daemon]" >> /etc/gdm/custom.conf
    echo "AutomaticLogin=$ADMIN_USER_NAME" >> /etc/gdm/custom.conf
    echo "AutomaticLoginEnable=True" >> /etc/gdm/custom.conf
  fi
fi

# if lxdm was installed, let's do a few things
if pacman -Q lxdm > /dev/null 2>/dev/null; then
  systemctl enable lxdm
  #TODO: set keyboard layout
  if [ "$MAKE_ADMIN_USER" = true ] && [ "$AUTOLOGIN_ADMIN" = true ] ; then
    echo "# Enable automatic login for user" >> /etc/lxdm/lxdm.conf
    echo "autologin=$ADMIN_USER_NAME" >> /etc/lxdm/lxdm.conf
  fi
fi

if [ -f /usr/sbin/runOnFirstBoot.sh ]; then
  cat > /etc/systemd/system/firstBootScript.service <<END
[Unit]
Description=Runs a user defined script on first boot
ConditionPathExists=/usr/sbin/runOnFirstBoot.sh

[Service]
Type=forking
ExecStart=/usr/sbin/runOnFirstBoot.sh
ExecStop=systemctl disable firstBootScript.service
TimeoutSec=0
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
END
systemctl enable firstBootScript.service
fi

cat > /etc/systemd/system/nativeSetupTasks.service <<END
[Unit]
Description=Some system setup tasks to be run once at first boot
ConditionPathExists=/usr/sbin/nativeSetupTasks.sh
Before=multi-user.target

[Service]
Type=notify
ExecStart=/usr/sbin/nativeSetupTasks.sh
ExecStopPost=/usr/bin/systemctl disable nativeSetupTasks.service

[Install]
WantedBy=multi-user.target
END
systemctl enable nativeSetupTasks.service

# enable magic sysrq
cat > /etc/sysctl.d/99-sysctl.conf <<END
kernel.sysrq = 1
END

cat > /usr/sbin/nativeSetupTasks.sh <<END
#!/usr/bin/env bash
set -eu -o pipefail
echo "Running first boot script."

locale-gen
locale > /etc/locale.conf
source /etc/locale.conf

echo "Reinstall all the packages"
PKGS=\\\$(pacman -Qq)
pacman -S \\\${PKGS//yay} --noconfirm

echo "Setting console keyboard layout"
loadkeys $KEYMAP

timedatectl set-ntp true

# we can't do this from inside the chroot
if [ -a /link_resolv_conf ] ; then
  echo "Making resolv.conf compatible with networkd"
  rm /link_resolv_conf
  mv "/etc/resolv.conf" "/etc/resolv.conf.bak"
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

echo "First boot script finished"
systemd-notify --ready
END
chmod +x /usr/sbin/nativeSetupTasks.sh

# run mkinitcpio (if it exists, it won't under alarm)
which mkinitcpio >/dev/null && mkinitcpio -p linux || true

# setup & install grub bootloader (if it's been installed)
if pacman -Q grub > /dev/null 2>/dev/null; then
  # disable lvm here because it doesn't do well inside of chroot
  sed -i 's,use_lvmetad = 1,use_lvmetad = 0,g' /etc/lvm/lvm.conf
  
  #if [ "$UEFI_COMPAT_STUB" = true ] ; then
  #  # for grub UEFI (stanalone version)
  #  mkdir -p /boot/EFI/grub-standalone
  #  grub-mkstandalone -d /usr/lib/grub/x86_64-efi/ -O x86_64-efi --modules="part_gpt part_msdos" --fonts="unicode" --locales="en@quot" --themes="" -o "/boot/EFI/grub-standalone/grubx64.efi" "/boot/grub/grub.cfg=/boot/grub/grub.cfg" -v
  #fi
  if efivar --list > /dev/null 2>/dev/null ; then # is this machine UEFI?
    if [ "$UEFI_BOOTLOADER" = "true" ] ; then
      echo "EFI BOOT detected doing EFI grub install..."
      if [ "$PORTABLE" = true ] ; then
        # this puts our entry point at [EFI_PART]/EFI/BOOT/BOOTX64.EFI
        echo "Doing portable UEFI setup"
        grub-install --no-nvram --removable --target=x86_64-efi --efi-directory=/boot
      else # non-portable
        # this puts our entry point at [EFI_PART]/EFI/ArchGRUB/grubx64.efi
        echo "Doing fixed disk UEFI setup"
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ArchGRUB
      fi # portable
    else # if UEFI grub install
      echo "Not doing EFI bootloader install. Set LEGACY_BOOTLOADER=true to install grub"
    fi # end UEFI grub install
  else
    echo "This machine does not support UEFI"
  fi
  
  if [ "$LEGACY_BOOTLOADER" = "true" ] ; then
    # this is for legacy boot:
    grub-install --modules="part_gpt part_msdos" --target=i386-pc --recheck --debug ${TARGET_DEV}
  fi
  
  # don't boot quietly
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet/GRUB_CMDLINE_LINUX_DEFAULT="rootwait/g' /etc/default/grub

  # for LUKS
  if [ "$LUKS_UUID" = "" ]; then
    echo "No encryption"
  else
    sed -i 's,GRUB_CMDLINE_LINUX_DEFAULT="rootwait,GRUB_CMDLINE_LINUX_DEFAULT="rootwait cryptdevice=UUID=${LUKS_UUID}:luks-${LUKS_UUID},g' /etc/default/grub
  fi
  
  # use systemd if we have it
  if pacman -Q systemd > /dev/null 2>/dev/null ; then
    sed -i 's,GRUB_CMDLINE_LINUX_DEFAULT=",GRUB_CMDLINE_LINUX_DEFAULT="init=/usr/lib/systemd/systemd ,g' /etc/default/grub
  fi
  
  # generate the grub configuration file
  grub-mkconfig -o /boot/grub/grub.cfg
  
  if [ "$ROOT_FS_TYPE" = "f2fs" ] ; then
    cat > /usr/sbin/fix-f2fs-grub <<END
#!/usr/bin/env bash
set -eu -o pipefail
echo "Running script to fix bug in grub.config when root is f2fs."
ROOT_DEVICE=\\\$(df | grep -w / | awk {'print \\\$1'})
ROOT_UUID=\\\$(blkid -s UUID -o value \\\${ROOT_DEVICE})
sed -i 's,root=/[^ ]* ,root=UUID='\\\${ROOT_UUID}' ,g' \\\$1
END
    chmod +x /usr/sbin/fix-f2fs-grub
    [ "$LUKS_UUID" = "" ] && fix-f2fs-grub /boot/grub/grub.cfg
  fi
  
  # re-enable lvm
  sed -i 's,use_lvmetad = 0,use_lvmetad = 1,g' /etc/lvm/lvm.conf
fi # end grub section

# if we're on a pi, add some stuff I like to config.txt
if pacman -Q | grep raspberry > /dev/null 2>/dev/null ; then
  echo "lcd_rotate=2" >> /boot/config.txt
  #echo "dtparam=audio=on" >> /boot/config.txt
  #echo "dtparam=device_tree_param=spi=on" >> /boot/config.txt
  #echo "dtparam=i2c_arm=on" >> /boot/config.txt
  echo "dtoverlay=vc4-fkms-v3d" >> /boot/config.txt
  echo "dtoverlay=dtoverlay=rpi-backlight" >> /boot/config.txt
fi
EOF

# run the setup script in th new install's root
chmod +x /tmp/chroot.sh
mv /tmp/chroot.sh ${TMP_ROOT}/root/chroot.sh
arch-chroot ${TMP_ROOT} /root/chroot.sh; REPLY=$? || true

if [ "$REPLY" -eq 0 ] ; then
  # remove the setup script from the install
  rm -rf ${TMP_ROOT}/root/chroot.sh || true
  
  # copy *this* script into the install for installs later
  cp "$THIS" ${TMP_ROOT}/usr/sbin/mkarch.sh
  
  # you might want to know what the install's fstab looks like
  echo "fstab is:"
  cat "${TMP_ROOT}/etc/fstab"
fi

# unmount and clean up everything
umount ${TMP_ROOT}/boot || true
if [ "$ROOT_FS_TYPE" = "btrfs" ] ; then
  umount ${TMP_ROOT}/home || true
fi
umount ${TMP_ROOT} || true
cryptsetup close /dev/mapper/${LUKS_UUID} || true
losetup -D || true
sync

if [ "$REPLY" -eq 0 ] ; then
  echo "Image sucessfully created"
  eject ${TARGET_DEV} || true
  if [ $? -eq 0 ]; then
    echo "It's now safe to remove $TARGET_DEV"
  fi
else
  echo "There was some failure while setting up the operating system."
fi
