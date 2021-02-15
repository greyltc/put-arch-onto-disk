#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
set -o verbose
set -o xtrace
shopt -s extglob

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
: ${PACKAGE_LIST:=""}

: ${ROOT_FS_TYPE:=btrfs}
: ${MAKE_SWAP_PARTITION:=false}
: ${SWAP_SIZE_IS_RAM_SIZE:=false}
: ${SWAP_SIZE:=100MiB}
: ${TARGET:=./bootable_arch.img}

# these only matter for GRUB installs: set true when the target will be a removable drive, false when the install is only for the machine runnning this script
: ${PORTABLE:=true}
: ${LEGACY_BOOTLOADER:=false}
: ${UEFI_BOOTLOADER:=true}
: ${UEFI_COMPAT_STUB:=false}

: ${IMG_SIZE:=4GiB}
: ${TIME_ZONE:=Europe/London}

# possible keymap options can be seen by `localectl list-keymaps`
: ${KEYMAP:=uk}
: ${LOCALE:=en_US.UTF-8}
: ${CHARSET:=UTF-8}
: ${ROOT_PASSWORD:=""}
: ${THIS_HOSTNAME:=archthing}

# empty user name string for no admin user
: ${ADMIN_USER_NAME:=admin}
: ${ADMIN_USER_PASSWORD:=admin}
: ${AUTOLOGIN_ADMIN:=false}

# empty helper string for no aur support
#: ${AUR_HELPER:=paru}
: ${AUR_HELPER:=""}
: ${AUR_PACKAGE_LIST:=""}

: ${USE_TESTING:=false}
: ${LUKS_KEYFILE:=""}

# for installing into preexisting multi boot setups:
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
  if pacman -Q qemu-user-static > /dev/null 2>/dev/null && pacman -Q binfmt-qemu-static > /dev/null 2>/dev/null 
  then
    ARCH_SPECIFIC_PKGS="archlinuxarm-keyring"
  else
    echo "Please install qemu-user-static and binfmt-qemu-static from the AUR"
    echo "so that we can chroot into the ARM install"
    exit 1
  fi
else
  # alarm does not like/need these
  ARCH_SPECIFIC_PKGS="linux grub efibootmgr reflector os-prober amd-ucode intel-ucode"
fi

# here are a baseline set of packages for the new install
DEFAULT_PACKAGES="base ${ARCH_SPECIFIC_PKGS} mkinitcpio haveged btrfs-progs dosfstools exfat-utils f2fs-tools openssh gpart parted mtools nilfs-utils ntfs-3g gdisk arch-install-scripts bash-completion rsync dialog ifplugd cpupower vi openssl ufw crda linux-firmware wireguard-tools"

# if this is a pi then let's make sure we have the packages listed here
if contains "${PACKAGE_LIST}" "raspberry"
then
  PACKAGE_LIST="${PACKAGE_LIST} iw wireless-regdb wireless_tools wpa_supplicant"
fi

# install these packages on the host now. they're needed for the install process
pacman -S --needed --noconfirm efibootmgr btrfs-progs dosfstools f2fs-tools gpart parted gdisk arch-install-scripts

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
else  # installing to image file
  IMG_NAME="${TARGET}"
  rm -f "${IMG_NAME}"
  fallocate -l $IMG_SIZE "${IMG_NAME}"
  TARGET_DEV=$(losetup --find)
  losetup -P ${TARGET_DEV} "${IMG_NAME}"
fi

if test ! -b "${TARGET_DEV}"
then
  echo "ERROR: Install target device ${TARGET_DEV} is not a block device."
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
    echo "LUKS encryption with keyfile: $(readlink -f \"${LUKS_KEYFILE}\")"
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

if test "${ROOT_FS_TYPE}" = "f2fs"
then
  ELL=l
  ENCR="-O encrypt"
else
  ELL=L
  ENCR=""
fi
mkfs.${ROOT_FS_TYPE} ${ENCR} -${ELL} ${ROOT_FS_TYPE}Root ${ROOT_DEVICE}

echo "Current partition table:"
sgdisk -p "${TARGET_DEV}"  # print the current partition table

TMP_ROOT=/tmp/diskRootTarget
mkdir -p ${TMP_ROOT}
mount -t${ROOT_FS_TYPE} ${ROOT_DEVICE} ${TMP_ROOT}
if test "${ROOT_FS_TYPE}" = "btrfs"
then
  btrfs subvolume create ${TMP_ROOT}/root
  #btrfs subvolume create ${TMP_ROOT}/home
  umount ${TMP_ROOT}
  mount ${ROOT_DEVICE} -o subvol=root,compress=zstd ${TMP_ROOT}
  #mkdir ${TMP_ROOT}/home
  #mount ${ROOT_DEVICE} -o subvol=home,compress=zstd ${TMP_ROOT}/home
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
if test "${USE_TESTING}" = "true"
then
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

if contains "${TARGET_ARCH}" "arm" || test "${TARGET_ARCH}" = "aarch64"
then
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

pacstrap -C /tmp/pacman.conf -M -G "${TMP_ROOT}" ${DEFAULT_PACKAGES} ${PACKAGE_LIST}

genfstab -U "${TMP_ROOT}" >> "${TMP_ROOT}"/etc/fstab
sed -i '/swap/d' "${TMP_ROOT}"/etc/fstab
#if test -f "${FIRST_BOOT_SCRIPT}" 
#then
#  cp "$FIRST_BOOT_SCRIPT" ${TMP_ROOT}/usr/sbin/runOnFirstBoot.sh
#  chmod +x ${TMP_ROOT}/usr/sbin/runOnFirstBoot.sh
#fi

# make the reflector service
#cat > ${TMP_ROOT}/etc/systemd/system/reflector.service <<EOF
#[Unit]
#Description=Pacman mirrorlist update
#Wants=network-online.target
#After=network-online.target
#
#[Service]
#Type=oneshot
#ExecStart=/usr/bin/reflector --protocol https --latest 30 --number 20 --sort rate --save /etc/pacman.d/mirrorlist
#
#[Install]
#RequiredBy=multi-user.target
#EOF

cat > "${TMP_ROOT}/root/setup.sh" <<EOF
#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
set -o verbose
set -o xtrace

# ONLY FOR TESTING:
#rm /usr/share/factory/etc/securetty
#rm /etc/securetty

# change password for root
if test -z "$ROOT_PASSWORD"
then
  echo "password locked for root user"
  passwd -l root
else
  echo "root:${ROOT_PASSWORD}"|chpasswd
fi

# enable magic sysrq
echo "kernel.sysrq = 1" > /etc/sysctl.d/99-sysctl.conf

# set hostname
echo ${THIS_HOSTNAME} > /etc/hostname

# set timezone
ln -sf /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime

# generate adjtime (this is probably forbidden)
hwclock --systohc || :
timedatectl set-ntp true

# do locale things
sed -i "s,^#${LOCALE} ${CHARSET},${LOCALE} ${CHARSET},g" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
unset LANG
set +o nounset
source /etc/profile.d/locale.sh
set -o nounset
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# setup gnupg
install -m700 -d /etc/skel/.gnupg
echo "keyserver hkps://hkps.pool.sks-keyservers.net:443" > /tmp/gpg.conf
echo "keyserver-options auto-key-retrieve" >> /tmp/gpg.conf
install -m600 -Dt /etc/skel/.gnupg/ -m644 /tmp/gpg.conf
rm /tmp/gpg.conf

# copy over the skel files for the root user
find /etc/skel -exec cp -a {} /root \;

echo "ENTROPY I HAVE="
cat /proc/sys/kernel/random/entropy_avail

pacman-key --init
if [[ \$(uname -m) == *"arm"*  || \$(uname -m) == "aarch64" ]] ; then
  pacman-key --populate archlinuxarm
else
  pacman-key --populate archlinux
  reflector --protocol https --latest 30 --number 20 --sort rate --save /etc/pacman.d/mirrorlist
fi

# make pacman color
sed -i 's/#Color/Color/g' /etc/pacman.conf

# if cpupower is installed, enable the service
if pacman -Q cpupower > /dev/null 2>/dev/null; then
  systemctl enable cpupower.service
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
  echo "Setting up systemd-networkd service"

  cat > /etc/systemd/network/DHCPany.network << END
[Match]
Name=*

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
END

  #sed -i -e 's/hosts: files dns myhostname/hosts: files resolve myhostname/g' /etc/nsswitch.conf

  #ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf  # breaks network inside container
  touch /link_resolv_conf #leave a marker so we can complete this setup later

  systemctl enable systemd-networkd
  systemctl enable systemd-resolved
fi

# setup admin user
if test ! -z "${ADMIN_USER_NAME}"
then
  systemctl enable systemd-homed
  systemctl start systemd-homed

  pacman -S --needed --noconfirm sudo jq

  STORAGE="directory"
  if test "${ROOT_FS_TYPE}" = "btrfs"
  then
    STORAGE="subvolume"
  elif test "${ROOT_FS_TYPE}" = "f2fs"
  then
    STORAGE="fscrypt"
  fi

  GRPS=""
  if test ! -z "${AUR_HELPER}"
  then
    pacman -S --needed --noconfirm base-devel
    groupadd aur
    MAKEPKG_BACKUP="/var/cache/makepkg/pkg"
    install -d "\${MAKEPKG_BACKUP}" -g aur -m=775
    GRPS="aur,"
  fi
  GRPS="\${GRPS}adm,uucp,wheel"

  echo "AuthenticationMethods publickey,password" >> /etc/ssh/sshd_config
  echo "AuthorizedKeysCommand /usr/bin/userdbctl ssh-authorized-keys %u" >> /etc/ssh/sshd_config
  echo "AuthorizedKeysCommandUser root" >> /etc/ssh/sshd_config

  # make the user with homectl
  echo '{"secret":{"password":"'${ADMIN_USER_PASSWORD}'"},"privileged":{"hashedPassword":["'\$(openssl passwd -6 "${ADMIN_USER_PASSWORD}")'"]}}' | homectl --identity=- create ${ADMIN_USER_NAME} --member-of=\${GRPS} --storage=\${STORAGE}

  if test ! -z "${AUR_HELPER}"
  then
    # just for now, users in the wheel group have passwordless sudo powers
    sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
    # fakeroot needs to use tcp IPC here because the non-tcp IPC isn't supported by qemu
    # so now we need to bootstrap fakeroot-tcp so that making packages with makepkg works
    if pacman -Q | grep raspberry > /dev/null 2>/dev/null
    then
      # bootstrap fakeroot-tcp
      su -c '(git clone https://aur.archlinux.org/fakeroot-tcp.git /var/tmp/fakeroot-tcp && cd /var/tmp/fakeroot-tcp && makepkg --skippgpcheck --nobuild && cd src && cd */ && ./bootstrap ; ./configure --prefix=/usr --libdir=/usr/lib/libfakeroot --disable-static --with-ipc=tcp ; make )' -s /bin/bash nobody
      pushd /var/tmp/fakeroot-tcp/src
      cd */
      make DESTDIR="/" install
      popd
      mkdir -p /etc/ld.so.conf.d
      echo '/usr/lib/libfakeroot' > /etc/ld.so.conf.d/fakeroot.conf
      libtool --finish /usr/lib/libfakeroot
      pushd /
      sbin/ldconfig -r .
      popd
    
      # now build the fakeroot-tcp package using our bootstrapped fakeroot-tcp build
      su -c '(git clone https://aur.archlinux.org/fakeroot-tcp.git /var/tmp/fakeroot-tcp2 && cd /var/tmp/fakeroot-tcp2 ; makepkg --skippgpcheck )' -s /bin/bash nobody

      # remove the bootstrapped fakeroot-tcp
      pushd /var/tmp/fakeroot-tcp/src
      cd */
      make DESTDIR="/" uninstall
      popd
      rm -rf /etc/ld.so.conf.d/fakeroot.conf

      # reinstall the bad fakeroot because we just butchered it (avoids install errors later)
      #pacman -Syu --noconfirm fakeroot || true

      # install the replacement fakeroot-tcp package
      pushd /var/tmp/fakeroot-tcp2
      yes | LC_ALL=en_US.UTF-8 pacman -U *.pkg.tar.zst || true
      mv *.pkg.tar.zst "\${MAKEPKG_BACKUP}/."
      popd
      rm -rf /var/tmp/fakeroot-tcp
      rm -rf /var/tmp/fakeroot-tcp2
    fi
    # get the helper
    cd /tmp
    su -c "(curl -s -L https://aur.archlinux.org/cgit/aur.git/snapshot/${AUR_HELPER}.tar.gz | bsdtar -xvf -)" -s /bin/bash nobody
    su -c "(cd /tmp/${AUR_HELPER}; )" -s /bin/bash nobody
    # TODO: test without skipping pgp check
  
    #su -c "(git clone https://aur.archlinux.org/aurutils.git /var/tmp/aurutils && cd /var/tmp/aurutils && makepkg --skippgpcheck)" -s /bin/bash nobody

    chgrp -R aur \${MAKEPKG_BACKUP}
    # backup future makepkg built packages
    sed -i "s,^#PKGDEST=.*,PKGDEST=\${MAKEPKG_BACKUP},g" /etc/makepkg.conf

    # take away passwordless sudo powers for wheel group
    sed -i 's/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
  fi  # add AUR

  # users in the wheel group have password triggered sudo powers
  sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/g' /etc/sudoers

fi # add admin

# must do this last because it breaks networking
if test -f /link_resolv_conf
then
  echo "Linking resolv.conf"
  rm /link_resolv_conf
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

touch /var/tmp/setup_complete
halt  # exit the namespace
EOF

cat > "${TMP_ROOT}"/usr/lib/systemd/system/container-boot-setup.service <<END
[Unit]
Description=Initial system setup tasks to be run in a container
ConditionPathExists=/root/setup.sh

[Service]
Type=idle
TimeoutStopSec=5sec
ExecStart=/usr/bin/bash /root/setup.sh
ExecStop=/usr/bin/echo "container-boot-setup.service is exiting now"
END
ln -s /usr/lib/systemd/system/container-boot-setup.service "${TMP_ROOT}"/etc/systemd/system/multi-user.target.wants/container-boot-setup.service

cat > "${TMP_ROOT}/root/setup2.sh" <<EOF
#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
set -o verbose
set -o xtrace

# if gdm was installed, let's do a few things
if pacman -Q gdm > /dev/null 2>/dev/null; then
  systemctl enable gdm
  #TODO: set keyboard layout for gnome
  if [ ! -z "$ADMIN_USER_NAME" ] && [ "$AUTOLOGIN_ADMIN" = true ] ; then
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
  if [ ! -z "$ADMIN_USER_NAME" ] && [ "$AUTOLOGIN_ADMIN" = true ] ; then
    echo "# Enable automatic login for user" >> /etc/lxdm/lxdm.conf
    echo "autologin=$ADMIN_USER_NAME" >> /etc/lxdm/lxdm.conf
  fi
fi

#if test -f /usr/sbin/runOnFirstBoot.sh
#then
#  cat > /etc/systemd/system/firstBootScript.service <<END
#[Unit]
#Description=Runs a user defined script on first boot
#ConditionPathExists=/usr/sbin/runOnFirstBoot.sh
#
#[Service]
#Type=forking
#ExecStart=/usr/sbin/runOnFirstBoot.sh
#ExecStopPost=/usr/bin/systemctl disable firstBootScript.service
#TimeoutSec=0
#RemainAfterExit=yes
#SysVStartPriority=99
#
#[Install]
#WantedBy=multi-user.target
#END
#  systemctl enable firstBootScript.service
#fi

cat > /etc/systemd/system/nativeSetupTasks.service <<END
[Unit]
Description=Some system setup tasks to be run once at first boot
ConditionPathExists=/usr/sbin/nativeSetupTasks.sh
Before=multi-user.target

[Service]
Type=notify
TimeoutSec=0
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

# run mkinitcpio
# ignore exit code here because of https://bugs.archlinux.org/task/65725
mkinitcpio -P || true

# setup & install grub bootloader (if it's been installed)
if pacman -Q grub > /dev/null 2>/dev/null; then
  # disable lvm here because it doesn't do well inside of chroot
  if test -f "/etc/lvm/lvm.conf"
  then
    sed -i 's,use_lvmetad = 1,use_lvmetad = 0,g' /etc/lvm/lvm.conf
  fi

  #if [ "${UEFI_COMPAT_STUB}" = true ] ; then
  #  # for grub UEFI (stanalone version)
  #  mkdir -p /boot/EFI/grub-standalone
  #  grub-mkstandalone -d /usr/lib/grub/x86_64-efi/ -O x86_64-efi --modules="part_gpt part_msdos" --fonts="unicode" --locales="en@quot" --themes="" -o "/boot/EFI/grub-standalone/grubx64.efi" "/boot/grub/grub.cfg=/boot/grub/grub.cfg" -v
  #fi
  if efivar --list > /dev/null 2>/dev/null  # is this machine UEFI?
  then
    if test "${UEFI_BOOTLOADER}" = "true"
    then
      echo "EFI BOOT detected doing EFI grub install..."
      if test "${PORTABLE}" = "true"
      then
        # this puts our entry point at [EFI_PART]/EFI/BOOT/BOOTX64.EFI
        echo "Doing portable UEFI setup"
        grub-install --no-nvram --removable --target=x86_64-efi --efi-directory=/boot --bootloader-id="GRUB_ARCH_REMOVABLE"
      else # non-portable
        # this puts our entry point at [EFI_PART]/EFI/ArchGRUB/grubx64.efi
        echo "Doing fixed disk UEFI setup"
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="GRUB_ARCH_FIXED"
      fi # portable
    else # if UEFI grub install
      echo "Not doing EFI bootloader install. Set LEGACY_BOOTLOADER=true to install grub"
    fi # end UEFI grub install
  else
    echo "This machine does not support UEFI"
  fi
  
  # make sure never to put a legacy bootloader into a preformatted disk
  if test "${TO_EXISTING}" = "false"
  then
    if test "${LEGACY_BOOTLOADER}" = "true"
    then
      # this is for legacy boot:
      grub-install --modules="part_gpt part_msdos" --target=i386-pc --recheck --debug ${TARGET_DEV}
    fi
  fi
  
  # don't boot quietly
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet/GRUB_CMDLINE_LINUX_DEFAULT="rootwait/g' /etc/default/grub

  # for LUKS
  if test -z "${LUKS_UUID}"
  then
    echo "No encryption"
  else
    sed -i 's,GRUB_CMDLINE_LINUX_DEFAULT="rootwait,GRUB_CMDLINE_LINUX_DEFAULT="rootwait cryptdevice=UUID=${LUKS_UUID}:luks-${LUKS_UUID},g' /etc/default/grub
  fi
  
  # use systemd if we have it
  if pacman -Q systemd > /dev/null 2>/dev/null
  then
    sed -i 's,GRUB_CMDLINE_LINUX_DEFAULT=",GRUB_CMDLINE_LINUX_DEFAULT="init=/usr/lib/systemd/systemd ,g' /etc/default/grub
  fi
 
  # generate the grub configuration file
  sync
  partprobe
  if pacman -Q lvm2 > /dev/null 2>/dev/null
  then
    pvscan --cache -aay
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
  #cat /boot/grub/grub.cfg
  
 # re-enable lvm
 if test -f "/etc/lvm/lvm.conf"
 then
    sed -i 's,use_lvmetad = 0,use_lvmetad = 1,g' /etc/lvm/lvm.conf
  fi
fi # end grub section

# if we're on a pi, add some stuff ( mostly to config.txt)
if pacman -Q | grep raspberry > /dev/null 2>/dev/null
then

  sed -i 's|^gpu_mem=64.*|gpu_mem=128|g' /boot/config.txt

  if test "${TARGET_ARCH}" = "aarch64"
  then
    echo "arm_64bit=1" >> /boot/config.txt
  fi
  #echo "initramfs initramfs-linux.img followkernel" >> /boot/config.txt
  #echo "lcd_rotate=2" >> /boot/config.txt
  #echo "dtparam=audio=on" >> /boot/config.txt
  #echo "dtparam=device_tree_param=spi=on" >> /boot/config.txt
  #echo "dtparam=i2c_arm=on" >> /boot/config.txt
  #echo "dtoverlay=vc4-fkms-v3d" >> /boot/config.txt
  #echo "dtoverlay=rpi-backlight" >> /boot/config.txt
  if pacman -Q | grep raspberrypi-bootloader > /dev/null 2>/dev/null
  then
    echo "start_x=1" >> /boot/config.txt
  fi
  
  echo "bcm2835-v4l2" > /etc/modules-load.d/rpi-camera.conf
fi
EOF

cat > "${TMP_ROOT}/usr/sbin/nativeSetupTasks.sh" <<END
#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
echo "Running first boot script."

# don't know why setting locale in the chroot doesn't work so we'll do it here again
localectl set-locale LANG=${LOCALE}
unset LANG
set +o nounset
source /etc/profile.d/locale.sh
set -o nounset
localectl set-keymap ${KEYMAP} 
localectl status

if [[ \$(uname -m) == *"arm"*  || \$(uname -m) == "aarch64" ]] ; then
  echo "Doing arm only setup things"
else
  echo "Doing non-arm only setup things"
  hwclock --systohc # probably the arm thing doesn't have a rtc
fi

echo "Reinstall all native packages"
pacman -Qqn | pacman -S --noconfirm -

# make sure everything is up to date
pacman -Syyuu --needed --noconfirm || true # requires internet

if test ! -z "${AUR_HELPER}"
then
  echo "Reinstall all foreign packages"
  pushd /var/cache/makepkg/pkg
  pacman --noconfirm -U *
  popd
fi

echo "First boot script finished"
systemd-notify --ready
END
chmod +x "${TMP_ROOT}/usr/sbin/nativeSetupTasks.sh"

# run the setup script in the new install's root
#chmod +x /tmp/chroot.sh
#mv /tmp/chroot.sh "${TMP_ROOT}/root/chroot.sh"
set +o errexit
#systemd-nspawn -D "${TMP_ROOT}" /usr/bin/bash /root/setup.sh; CHROOT_RESULT=$? || true
#arch-chroot "${TMP_ROOT}" /usr/bin/bash /root/chroot.sh; CHROOT_RESULT=$? || true
set -o errexit

#ln -s "${TMP_ROOT}" /var/lib/machines/newsys
#exit 43

#systemd-nspawn --directory "${TMP_ROOT}" /usr/bin/bash -c '/usr/bin/echo "root:root"|/usr/bin/chpasswd'
#systemd-nspawn --directory "${TMP_ROOT}" /usr/bin/systemctl enable container-boot-setup.service
systemd-nspawn --boot --directory "${TMP_ROOT}" || true

if test -f "${TMP_ROOT}/var/tmp/setup_complete"
then
  rm -rf "${TMP_ROOT}/var/tmp/setup_complete"
  export SETUP_WORKED=true
  # remove setup files
  rm -f "${TMP_ROOT}"/etc/systemd/system/multi-user.target.wants/container-boot-setup.service
  rm -f "${TMP_ROOT}"/usr/lib/systemd/system/container-boot-setup.service
  rm -f "${TMP_ROOT}/root/setup.sh"

  # don't need the emulator binaries any more
  rm -f "${TMP_ROOT}/usr/bin/qemu-arm-static"
  rm -f "${TMP_ROOT}/usr/bin/qemu-aarch64-static"

  # copy *this* script into the install for installs later
  cp "$THIS" "${TMP_ROOT}/usr/sbin/mkarch.sh"
  
  # you might want to know what the install's fstab looks like
  echo "fstab is:"
  cat "${TMP_ROOT}/etc/fstab"
else
  echo "Internal setup failure!"
fi

# unmount and clean up everything
umount "${TMP_ROOT}/boot" || true
umount -d "${TMP_ROOT}/boot" || true
if test "${ROOT_FS_TYPE}" = "btrfs"
then
  for n in "${TMP_ROOT}"/home/* ; do umount $n || true; done
  for n in "${TMP_ROOT}"/home/* ; do umount -d $n || true; done
  umount "${TMP_ROOT}/home" || true
  umount -d "${TMP_ROOT}/home" || true
fi
umount "${TMP_ROOT}" || true
umount -d "${TMP_ROOT}" || true
cryptsetup close /dev/mapper/${LUKS_UUID} || true
losetup -D || true
sync
if pacman -Q lvm2 > /dev/null 2>/dev/null
then
  pvscan --cache -aay
fi
rm -r "${TMP_ROOT}" || true

if [ -z ${SETUP_WORKED+x} ]
then 
  echo "There was some failure while setting up the operating system."
else 
  echo "Image sucessfully created"
  if eject ${TARGET_DEV}
  then
    echo "It's now safe to remove $TARGET_DEV"
  fi
fi