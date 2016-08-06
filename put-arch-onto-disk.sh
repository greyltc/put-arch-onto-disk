#!/usr/bin/env bash
set -eu -o pipefail
set -vx #echo on

# put-arch-onto-disk.sh
# This script installs Arch Linux onto media (making it bootable)
# or into a disk image which can later be dd'd onto some media to make it bootable

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
: ${IMG_SIZE:=2GiB}
: ${TIME_ZONE:=Europe/London}
: ${KEYMAP:=uk}
: ${LANGUAGE:=en_US}
: ${TEXT_ENCODING:=UTF-8}
: ${LEGACY_BOOTLOADER:=true}
: ${UEFI_COMPAT_STUB:=true}
: ${ROOT_PASSWORD:=toor}
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


if [[ $TARGET_ARCH == *"arm"* ]]; then
  su ${SUDO_USER} -c 'pacaur -Sy --needed --noconfirm qemu-user-static binfmt-support'
  update-binfmts --enable qemu-arm
  NON_ARM_PKGS=""
else
  # alarm does not like/need these
  NON_ARM_PKGS="grub efibootmgr reflector jfsutils"
fi

# here are a baseline set of packages for the new install
DEFAULT_PACKAGES="base ${NON_ARM_PKGS} haveged btrfs-progs dosfstools exfat-utils f2fs-tools openssh gpart parted mtools nilfs-utils ntfs-3g hfsprogs gdisk arch-install-scripts bash-completion rsync dialog wpa_actiond ifplugd cpupower ntp"

# install these packages on the host now. they're needed for the install process
pacman -Sy --needed --noconfirm efibootmgr btrfs-progs dosfstools f2fs-tools gpart parted gdisk arch-install-scripts

if [ -b $TARGET ] ; then
  TARGET_DEV=$TARGET
  for n in ${TARGET_DEV}* ; do umount $n || true; done
  PEE=""
  IMG_NAME=""
else
  IMG_NAME=$TARGET
  rm -f "${IMG_NAME}"
  su -c "fallocate -l $IMG_SIZE ${IMG_NAME}" $SUDO_USER
  TARGET_DEV=$(losetup --find)
  losetup -P ${TARGET_DEV} "${IMG_NAME}"
  PEE=p
fi

wipefs -a -f "${TARGET_DEV}"
sgdisk -Z "${TARGET_DEV}"  || true # zap (destroy) all partition tables

NEXT_PARTITION=1
if [[ $TARGET_ARCH == *"arm"* ]]; then
  echo "No bios grub for arm"
  BOOT_P_TYPE=0700
else
  sgdisk -n 0:+0:+1MiB -t 0:ef02 -c 0:biosGrub "${TARGET_DEV}" && ((NEXT_PARTITION++))
  BOOT_P_TYPE=ef00
fi
BOOT_P_SIZE_MB=100
sgdisk -n 0:+0:+${BOOT_P_SIZE_MB}MiB -t 0:${BOOT_P_TYPE} -c 0:boot "${TARGET_DEV}"; BOOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  if [ "$SWAP_SIZE_IS_RAM_SIZE" = true ] ; then
    SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
  fi
  sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:swap "${TARGET_DEV}"; SWAP_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
fi
#sgdisk -N 0 -t 0:8300 -c 0:${ROOT_FS_TYPE}Root "${TARGET_DEV}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8300 -c ${NEXT_PARTITION}:${ROOT_FS_TYPE}Root "${TARGET_DEV}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))

# make hybrid/protective MBR
#sgdisk -h "1 2" "${TARGET_DEV}"
echo -e "r\nh\n1 2\nN\n0c\nN\n\nN\nN\nw\nY\n" | sudo gdisk "${TARGET_DEV}"

wipefs -a -f ${TARGET_DEV}${PEE}${BOOT_PARTITION}
mkfs.fat -n BOOT ${TARGET_DEV}${PEE}${BOOT_PARTITION}
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  wipefs -a -f ${TARGET_DEV}${PEE}${SWAP_PARTITION}
  mkswap -L swap ${TARGET_DEV}${PEE}${SWAP_PARTITION}
fi
wipefs -a -f ${TARGET_DEV}${PEE}${ROOT_PARTITION}
ELL=L
[ "$ROOT_FS_TYPE" = "f2fs" ] && ELL=l
mkfs.${ROOT_FS_TYPE} -${ELL} ${ROOT_FS_TYPE}Root ${TARGET_DEV}${PEE}${ROOT_PARTITION}
sgdisk -p "${TARGET_DEV}"
TMP_ROOT=/tmp/diskRootTarget
mkdir -p ${TMP_ROOT}
mount -t${ROOT_FS_TYPE} ${TARGET_DEV}${PEE}${ROOT_PARTITION} ${TMP_ROOT}
if [ "$ROOT_FS_TYPE" = "btrfs" ] ; then
  btrfs subvolume create ${TMP_ROOT}/root
  btrfs subvolume create ${TMP_ROOT}/home
  umount ${TMP_ROOT}
  mount ${TARGET_DEV}${PEE}${ROOT_PARTITION} -o subvol=root,compress=lzo ${TMP_ROOT}
  mkdir ${TMP_ROOT}/home
  mount ${TARGET_DEV}${PEE}${ROOT_PARTITION} -o subvol=home,compress=lzo ${TMP_ROOT}/home
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

if [[ $TARGET_ARCH == *"arm"* ]]; then
  cat <<EOF >> /tmp/pacman.conf

[alarm]
Include = /tmp/mirrorlist

[aur]
Include = /tmp/mirrorlist
EOF
  mkdir -p ${TMP_ROOT}/usr/bin
  cp /usr/bin/qemu-arm-static ${TMP_ROOT}/usr/bin
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

# set text encoding
echo "${LANGUAGE}.${TEXT_ENCODING} ${TEXT_ENCODING}" >> /etc/locale.gen

# set locale
locale-gen
locale > /etc/locale.conf
source /etc/locale.conf

# setup gnupg
echo "keyserver hkp://keys.gnupg.net" >> /usr/share/gnupg/gpg-conf.skel
sed -i "s,#keyserver-options auto-key-retrieve,keyserver-options auto-key-retrieve,g" /usr/share/gnupg/gpg-conf.skel
mkdir -p /etc/skel/.gnupg
cp /usr/share/gnupg/gpg-conf.skel /etc/skel/.gnupg/gpg.conf
cp /usr/share/gnupg/dirmngr-conf.skel /etc/skel/.gnupg/dirmngr.conf

# change password for root
echo "root:${ROOT_PASSWORD}"|chpasswd

# copy over the skel files for the root user
cp -r \$(find /etc/skel -name ".*") /root

# update pacman keys
haveged -w 1024
pacman-key --init
pkill haveged || true
pacman -Rs --noconfirm haveged
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
if [[ \$(uname -m) == *"arm"* ]] ; then
  pacman -S --noconfirm --needed archlinuxarm-keyring
  pacman-key --populate archlinuxarm
else
  pacman-key --populate archlinux
  reflector -l 200 -p http --sort rate --save /etc/pacman.d/mirrorlist
fi
pkill gpg-agent || true

# setup admin user
if [ "$MAKE_ADMIN_USER" = true ] ; then
  useradd -m -G wheel -s /bin/bash ${ADMIN_USER_NAME}
  echo "${ADMIN_USER_NAME}:${ADMIN_USER_PASSWORD}"|chpasswd
  pacman -S --needed --noconfirm sudo
  sed -i 's/# %wheel ALL=(ALL)/%wheel ALL=(ALL)/g' /etc/sudoers
  
  # AUR can only be enabled if a non-root user exists, so we'll do it in here
  if [ "$ENABLE_AUR" = true ] ; then
    pacman -S --needed --noconfirm base-devel # needed to build aur packages
    # bootstrap pacaur
    su -c "(cd; bash <(curl aur.sh) -si --noconfirm --needed cower pacaur)" -s /bin/bash ${ADMIN_USER_NAME}
    su -c "(cd; rm -rf cower pacaur)" -s /bin/bash ${ADMIN_USER_NAME}
  fi
  # make sudo prompt for password
  sed -i 's/%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
fi

# if cpupower is installed, enable the service
if pacman -Q cpupower > /dev/null 2>/dev/null; then
  systemctl enable cpupower.service
  if [[ \$(uname -m) == *"arm"* ]] ; then
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

# add crc modules to initcpio (needed for f2fs)
sed -i 's/MODULES="/MODULES="crc32 libcrc32c crc32c_generic crc32c-intel crc32-pclmul /g' /etc/mkinitcpio.conf

# if bcache is installed, make sure its module is loaded super early in case / is bcache
if pacman -Q bcache-tools > /dev/null 2>/dev/null; then
  sed -i 's/MODULES="/MODULES="bcache /g' /etc/mkinitcpio.conf
  sed -i 's/HOOKS="base udev autodetect modconf block/HOOKS="base udev autodetect modconf block bcache/g' /etc/mkinitcpio.conf
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

echo "Reinstall all the packages"
pacman -S $(pacman -Qq) --noconfirm

echo "Setting console keyboard layout"
loadkeys $KEYMAP

if [ -a /link_reslov_conf ] ; then
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
which mkinitcpio >/dev/null && mkinitcpio -p linux

# setup & install grub bootloader (if it's been installed)
if pacman -Q grub > /dev/null 2>/dev/null; then
  # we always want os-prober if we have grub
  pacman -S --noconfirm --needed os-prober
  
  # don't boot quietly
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet/GRUB_CMDLINE_LINUX_DEFAULT="rootwait/g' /etc/default/grub
  
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
    fix-f2fs-grub /boot/grub/grub.cfg
  fi
  
  # for grub UEFI (stanalone version)
  mkdir -p /boot/EFI/grub-standalone
  grub-mkstandalone -d /usr/lib/grub/x86_64-efi/ -O x86_64-efi --modules="part_gpt part_msdos" --fonts="unicode" --locales="en@quot" --themes="" -o "/boot/EFI/grub-standalone/grubx64.efi" "/boot/grub/grub.cfg=/boot/grub/grub.cfg" -v
  
  # attempt normal grub UEFI install
  grub-install --modules="part_gpt part_msdos" --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch_grub;  REPLY=\$? || true
  
  # some retarded bioses are hardcoded to only boot from /boot/EFI/Boot/BOOTX64.EFI (looking at you Sony)
  #TODO, make this check case insensative
  if [ "$UEFI_COMPAT_STUB" = true ] ; then
    if [ -d "/boot/EFI/Boot" ] ; then 
      cp /boot/EFI/Boot /boot/EFI/Boot.bak
    else
      mkdir -p /boot/EFI/Boot
    fi
    cp -a /boot/EFI/arch_grub/grubx64.efi  /boot/EFI/Boot/BOOTX64.EFI
  fi
  
  # do these things if the normal UEFI grub install failed
  if [ "\$REPLY" -eq 0 ] ; then
    cat > /etc/systemd/system/fix-efi.service <<END
[Unit]
Description=Re-Installs Grub-efi bootloader
ConditionPathExists=/usr/sbin/fix-efi.sh

[Service]
Type=forking
ExecStart=/usr/sbin/fix-efi.sh
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
END

    cat > /usr/sbin/fix-efi.sh <<END
#!/usr/bin/env bash
set -eu -o pipefail
if efivar --list > /dev/null 2>/dev/null ; then
  echo "Re-installing grub when efi boot."
  grub-install --modules="part_gpt part_msdos" --target=x86_64-efi --efi-directory=/boot --bootloader-id=arch_grub && systemctl disable fix-efi.service
else
  echo "No efi: don't need to fix grub-efi"
fi
END
    chmod +x /usr/sbin/fix-efi.sh
    systemctl enable fix-efi.service
  fi
  
  if [ "$LEGACY_BOOTLOADER" = "true" ] ; then
    # this is for legacy boot:
    grub-install --modules="part_gpt part_msdos" --target=i386-pc --recheck --debug ${TARGET_DEV}
  fi
fi

# if we're on a pi, maybe the display is upside down, fix it
if pacman -Q raspberrypi-firmware > /dev/null 2>/dev/null ; then
  echo "lcd_rotate=2" >> /boot/config.txt
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
