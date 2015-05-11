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
: ${GET_SIZE_FROM_TARGET:=false}
: ${TARGET_DISK:=/dev/sdX}
: ${IMG_SIZE:=2GiB}
: ${IMG_NAME:=bootable_arch.img}
: ${TIME_ZONE:=Europe/Copenhagen}
: ${LANGUAGE:=en_US}
: ${TEXT_ENCODING:=UTF-8}
: ${ROOT_PASSWORD:=toor}
: ${MAKE_ADMIN_USER:=true}
: ${ADMIN_USER_NAME:=admin}
: ${ADMIN_USER_PASSWORD:=admin}
: ${THIS_HOSTNAME:=archthing}
: ${PACKAGE_LIST:=""}
: ${ENABLE_AUR:=true}
: ${TARGET_IS_REMOVABLE:=false}

rm -f "${IMG_NAME}"
if [ "$GET_SIZE_FROM_TARGET" = true ] ; then
  DISK_INFO=$(lsblk -n -b -o SIZE,PHY-SEC ${TARGET_DISK})
  IFS=' ' read -a DISK_INFO_A <<< "$DISK_INFO"
  IMG_SIZE=$(numfmt --to-unit=K ${DISK_INFO_A[0]})KiB
  PHY_SEC_BYTES=${DISK_INFO_A[1]}
fi
fallocate -l $IMG_SIZE "${IMG_NAME}"
wipefs -a -f "${IMG_NAME}"

NEXT_PARTITION=1
sgdisk -n 0:+0:+1MiB -t 0:ef02 -c 0:biosGrub "${IMG_NAME}" && ((NEXT_PARTITION++))
sgdisk -n 0:+0:+512MiB -t 0:ef00 -c 0:boot "${IMG_NAME}"; BOOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  if [ "$SWAP_SIZE_IS_RAM_SIZE" = true ] ; then
    SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
  fi
  sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:swap "${IMG_NAME}"; SWAP_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
fi
#sgdisk -N 0 -t 0:8300 -c 0:${ROOT_FS_TYPE}Root "${IMG_NAME}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8300 -c ${NEXT_PARTITION}:${ROOT_FS_TYPE}Root "${IMG_NAME}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))

LOOPDEV=$(sudo losetup --find)
sudo losetup -P ${LOOPDEV} "${IMG_NAME}"
sudo wipefs -a -f ${LOOPDEV}p${BOOT_PARTITION}
sudo mkfs.fat -F32 -n BOOT ${LOOPDEV}p${BOOT_PARTITION}
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  sudo wipefs -a -f ${LOOPDEV}p${SWAP_PARTITION}
  sudo mkswap -L swap ${LOOPDEV}p${SWAP_PARTITION}
fi
sudo wipefs -a -f ${LOOPDEV}p${ROOT_PARTITION}
ELL=L
[ "$ROOT_FS_TYPE" = "f2fs" ] && ELL=l
sudo mkfs.${ROOT_FS_TYPE} -${ELL} ${ROOT_FS_TYPE}Root ${LOOPDEV}p${ROOT_PARTITION}
sgdisk -p "${IMG_NAME}"
TMP_ROOT=/tmp/diskRootTarget
mkdir -p ${TMP_ROOT}
sudo mount -t${ROOT_FS_TYPE} ${LOOPDEV}p${ROOT_PARTITION} ${TMP_ROOT}
sudo mkdir ${TMP_ROOT}/boot
sudo mount ${LOOPDEV}p${BOOT_PARTITION} ${TMP_ROOT}/boot
sudo pacstrap ${TMP_ROOT} base grub efibootmgr btrfs-progs dosfstools exfat-utils f2fs-tools gpart parted jfsutils mtools nilfs-utils ntfs-3g hfsprogs ${PACKAGE_LIST}
sudo sh -c "genfstab -U ${TMP_ROOT} >> ${TMP_ROOT}/etc/fstab"
sudo sed -i '/swap/d' ${TMP_ROOT}/etc/fstab
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  SWAP_UUID=$(lsblk -n -b -o UUID ${LOOPDEV}p${SWAP_PARTITION})
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
  sed -i 's/# %wheel ALL=(ALL) NOPASSWD: ALL/## %wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
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
if [ "$ENABLE_AUR" = true ] ; then
  echo "[archlinuxfr]" >> /etc/pacman.conf
  echo "SigLevel = Never" >> /etc/pacman.conf
  echo 'Server = http://repo.archlinux.fr/\$arch' >> /etc/pacman.conf
  pacman -Sy --needed --noconfirm yaourt
  sed -i '$ d' /etc/pacman.conf
  sed -i '$ d' /etc/pacman.conf
  sed -i '$ d' /etc/pacman.conf
  pacman -Sy
fi
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet/GRUB_CMDLINE_LINUX_DEFAULT="rootwait/g' /etc/default/grub
INSTALLED_PACKAGES=\$(pacman -Qe)
if [[ \$INSTALLED_PACKAGES == *"openssh"* ]] ; then
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
if [[ \$INSTALLED_PACKAGES == *"bcache-tools"* ]] ; then
  sed -i 's/MODULES="/MODULES="bcache /g' /etc/mkinitcpio.conf
  sed -i 's/HOOKS="base udev autodetect modconf block/HOOKS="base udev autodetect modconf block bcache/g' /etc/mkinitcpio.conf
fi
mkinitcpio -p linux
grub-mkconfig -o /boot/grub/grub.cfg
if [ "$ROOT_FS_TYPE" = "f2fs" ] ; then
  cat > /usr/sbin/fix-f2fs-grub.sh <<END
#!/usr/bin/env bash
ROOT_DEVICE=\\\$(df | grep -w / | awk {'print \\\$1'})
ROOT_UUID=\\\$(blkid -s UUID -o value \\\${ROOT_DEVICE})
sed -i 's,root=/[^ ]* ,root=UUID='\\\${ROOT_UUID}' ,g' \\\$1
END
  chmod +x /usr/sbin/fix-f2fs-grub.sh
  fix-f2fs-grub.sh /boot/grub/grub.cfg
fi
mkdir -p /boot/EFI/BOOT
grub-mkstandalone -d /usr/lib/grub/x86_64-efi/ -O x86_64-efi --modules="part_gpt part_msdos" --fonts="unicode" --locales="en@quot" --themes="" -o "/boot/EFI/BOOT/BOOTX64.EFI" /boot/grub/grub.cfg=/boot/grub/grub.cfg  -v
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
if efivar --list > /dev/null ; then
  grub-install --removable --target=x86_64-efi --efi-directory=/boot --recheck && systemctl disable fix-efi.service
  grub-mkconfig -o /boot/grub/grub.cfg
  ROOT_DEVICE=\\\$(df | grep -w / | awk {'print \\\$1'})
  ROOT_FS_TYPE=\\\$(lsblk \\\${ROOT_DEVICE} -n -o FSTYPE)
  if [ "\\\$ROOT_FS_TYPE" = "f2fs" ] ; then
    fix-f2fs-grub.sh /boot/grub/grub.cfg
  fi
fi
END
chmod +x /usr/sbin/fix-efi.sh
systemctl enable fix-efi.service
grub-install --modules=part_gpt --target=i386-pc --recheck --debug ${LOOPDEV}
EOF
if [ "$DD_TO_TARGET" = true ] ; then
  for n in ${TARGET_DISK}* ; do sudo umount $n || true; done
  sudo wipefs -a ${TARGET_DISK}
fi
chmod +x /tmp/chroot.sh
mv /tmp/chroot.sh "${TMP_ROOT}/root/chroot.sh"
set +o errexit
arch-chroot "${TMP_ROOT}" /root/chroot.sh; CHROOT_RESULT=$? || true
set -o errexit

sync && sudo umount ${TMP_ROOT}/boot && sudo umount ${TMP_ROOT} && sudo losetup -D && sync && echo "Image sucessfully created"
if [ "$DD_TO_TARGET" = true ] ; then
  echo "Writing image to disk..."
  sudo -E bash -c 'dd if='"${IMG_NAME}"' of='${TARGET_DISK}' bs=4M && sync && sgdisk -e '${TARGET_DISK}' && sgdisk -v '${TARGET_DISK}' && [ '"$TARGET_IS_REMOVABLE"' = true ] && eject '${TARGET_DISK} && echo "Image sucessfully written. It's now safe to remove ${TARGET_DISK}"
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
