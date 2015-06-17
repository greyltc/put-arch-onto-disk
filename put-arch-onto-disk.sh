#!/usr/bin/env bash
set -e #break on error
set -vx #echo on

if [[ $EUID -ne 0 ]]; then
  echo "Please run with root permissions"
  exit
fi
THIS="$( cd "$(dirname "$0")" ; pwd -P )"/$(basename $0)

: ${ROOT_FS_TYPE:=f2fs}
: ${MAKE_SWAP_PARTITION:=false}
: ${SWAP_SIZE_IS_RAM_SIZE:=false}
: ${SWAP_SIZE:=100MiB}
: ${TARGET:=./bootable_arch.img}
: ${IMG_SIZE:=2GiB}
: ${TIME_ZONE:=Europe/Copenhagen}
: ${LANGUAGE:=en_US}
: ${TEXT_ENCODING:=UTF-8}
: ${ROOT_PASSWORD:=toor}
: ${MAKE_ADMIN_USER:=false}
: ${ADMIN_USER_NAME:=l3iggs}
: ${ADMIN_USER_PASSWORD:=sggi3l}
: ${THIS_HOSTNAME:=bootdisk}
: ${PACKAGE_LIST:=""}
: ${ENABLE_AUR:=true}
: ${AUR_PACKAGE_LIST:=""}
: ${GDM_AUTOLOGIN_ADMIN:=false}
: ${FIRST_BOOT_SCRIPT:=""}
: ${DD_TO_DISK:=false}
: ${TARGET_IS_REMOVABLE:=false}
: ${CLEAN_UP:=false}

DEFAULT_PACKAGES="base grub efibootmgr btrfs-progs dosfstools exfat-utils f2fs-tools gpart parted jfsutils mtools nilfs-utils ntfs-3g hfsprogs gdisk arch-install-scripts bash-completion"

if [ -b $TARGET ] ; then
  TARGET_DEV=$TARGET
  for n in ${TARGET_DEV}* ; do umount $n || true; done
else
  IMG_NAME=$TARGET
  rm -f "${IMG_NAME}"
  su -c "fallocate -l $IMG_SIZE ${IMG_NAME}" $SUDO_USER
  TARGET_DEV=$(losetup --find)
  losetup -P ${TARGET_DEV} "${IMG_NAME}"
  PEE=p
fi

wipefs -a -f "${TARGET_DEV}"

NEXT_PARTITION=1
sgdisk -n 0:+0:+1MiB -t 0:ef02 -c 0:biosGrub "${TARGET_DEV}" && ((NEXT_PARTITION++))
sgdisk -n 0:+0:+512MiB -t 0:ef00 -c 0:boot "${TARGET_DEV}"; BOOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
if [ "$MAKE_SWAP_PARTITION" = true ] ; then
  if [ "$SWAP_SIZE_IS_RAM_SIZE" = true ] ; then
    SWAP_SIZE=`free -b | grep Mem: | awk '{print $2}' | numfmt --to-unit=K`KiB
  fi
  sgdisk -n 0:+0:+${SWAP_SIZE} -t 0:8200 -c 0:swap "${TARGET_DEV}"; SWAP_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
fi
#sgdisk -N 0 -t 0:8300 -c 0:${ROOT_FS_TYPE}Root "${TARGET_DEV}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))
sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8300 -c ${NEXT_PARTITION}:${ROOT_FS_TYPE}Root "${TARGET_DEV}"; ROOT_PARTITION=$NEXT_PARTITION; ((NEXT_PARTITION++))


wipefs -a -f ${TARGET_DEV}${PEE}${BOOT_PARTITION}
mkfs.fat -F32 -n BOOT ${TARGET_DEV}${PEE}${BOOT_PARTITION}
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
pacstrap ${TMP_ROOT} base grub efibootmgr btrfs-progs dosfstools exfat-utils f2fs-tools gpart parted jfsutils mtools nilfs-utils ntfs-3g hfsprogs ${PACKAGE_LIST}
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
set -e #break on error
#set -vx #echo on
set -x

echo ${THIS_HOSTNAME} > /etc/hostname
ln -sf /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime
echo "${LANGUAGE}.${TEXT_ENCODING} ${TEXT_ENCODING}" >> /etc/locale.gen
locale-gen
echo LANG="${LANGUAGE}.${TEXT_ENCODING}" > /etc/locale.conf
echo "root:${ROOT_PASSWORD}"|chpasswd
if [ "$MAKE_ADMIN_USER" = true ] ; then
  useradd -m -G wheel -s /bin/bash ${ADMIN_USER_NAME}
  echo "${ADMIN_USER_NAME}:${ADMIN_USER_PASSWORD}"|chpasswd
  pacman -S --needed --noconfirm sudo
  sed -i 's/# %wheel ALL=(ALL) NOPASSWD: ALL/## %wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
  sed -i 's/# %wheel ALL=(ALL)/%wheel ALL=(ALL)/g' /etc/sudoers
fi
if [ "$ENABLE_AUR" = true ] ; then
  pacman -S --needed --noconfirm jshon base-devel
  mkdir /apacman
  cd /apacman
  curl -O https://raw.githubusercontent.com/oshazard/apacman/master/apacman
  chmod +x apacman
  ./apacman -S --noconfirm apacman
  cd /
  rm -rf /apacman
  apacman -S --noconfirm --needed --skipinteg pacaur
  apacman -S --noconfirm --needed yaourt packer aura-bin ${AUR_PACKAGE_LIST}
  sed -i 's/EXPORT=./EXPORT=2/g' /etc/yaourtrc
fi
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet/GRUB_CMDLINE_LINUX_DEFAULT="rootwait/g' /etc/default/grub
if pacman -Q openssh > /dev/null 2>/dev/null; then
  systemctl enable sshd.service
fi
if pacman -Q networkmanager > /dev/null 2>/dev/null; then
  systemctl enable NetworkManager.service
fi
if pacman -Q bcache-tools > /dev/null 2>/dev/null; then
  sed -i 's/MODULES="/MODULES="bcache /g' /etc/mkinitcpio.conf
  sed -i 's/HOOKS="base udev autodetect modconf block/HOOKS="base udev autodetect modconf block bcache/g' /etc/mkinitcpio.conf
fi
if pacman -Q gdm > /dev/null 2>/dev/null; then
  systemctl enable gdm
  if [ "$MAKE_ADMIN_USER" = true ] && [ "$GDM_AUTOLOGIN_ADMIN" = true ] ; then
    echo "# Enable automatic login for user" >> /etc/gdm/custom.conf
    echo "[daemon]" >> /etc/gdm/custom.conf
    echo "AutomaticLogin=$ADMIN_USER_NAME" >> /etc/gdm/custom.conf
    echo "AutomaticLoginEnable=True" >> /etc/gdm/custom.conf
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
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
END
systemctl enable firstBootScript.service
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
grub-install --modules=part_gpt --target=i386-pc --recheck --debug ${TARGET_DEV}
EOF
if [ -b $DD_TO_DISK ] ; then
  for n in ${DD_TO_DISK}* ; do umount $n || true; done
  wipefs -a ${DD_TO_DISK}
fi
chmod +x /tmp/chroot.sh
mv /tmp/chroot.sh ${TMP_ROOT}/root/chroot.sh
arch-chroot ${TMP_ROOT} /root/chroot.sh
rm ${TMP_ROOT}/root/chroot.sh
cp "$THIS" /usr/sbin/mkarch.sh
sync
umount ${TMP_ROOT}/boot
[ "$ROOT_FS_TYPE" = "btrfs" ] && umount ${TMP_ROOT}/home
umount ${TMP_ROOT}
losetup -D
sync
echo "Image sucessfully created"
if [ -b $DD_TO_DISK ] ; then
  TARGET_DEV=$DD_TO_DISK
  echo "Writing image to disk..."
  dd if="${IMG_NAME}" of=${TARGET_DEV} bs=4M
  sync
  sgdisk -e ${TARGET_DEV}
  sgdisk -v ${TARGET_DEV}
  echo "Image sucessfully written."
fi

if [ "$TARGET_IS_REMOVABLE" = true ] ; then
  eject ${TARGET_DEV} && echo "It's now safe to remove $TARGET_DEV"
fi

if [ "$CLEAN_UP" = true ] ; then
  rm -f "${IMG_NAME}"
fi
