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

# if this is not a block device to install into, then it's an image file that will be created
: ${TARGET:=./bootable_arch.img}
: ${IMG_SIZE:=4GiB}

# these only matter for GRUB installs: set true when the target will be a removable drive, false when the install is only for the machine runnning this script
: ${PORTABLE:=true}
: ${LEGACY_BOOTLOADER:=false}
: ${UEFI_BOOTLOADER:=true}
: ${UEFI_COMPAT_STUB:=false}

: ${TIME_ZONE:=Europe/London}

# possible keymap options can be seen by `localectl list-keymaps`
: ${KEYMAP:=uk}
: ${LOCALE:=en_US.UTF-8}
: ${CHARSET:=UTF-8}
: ${ROOT_PASSWORD:=""}
: ${THIS_HOSTNAME:=archthing}

# empty user name string for no admin user
: ${ADMIN_USER_NAME:="admin"}
: ${ADMIN_USER_PASSWORD:=admin}
: ${ADMIN_SSH_AUTH_KEY:=""}  # a public key that can be used to ssh into the admin account
: ${AUTOLOGIN_ADMIN:=false}

# empty helper string for no aur support
: ${AUR_HELPER:=paru}
: ${AUR_PACKAGE_LIST:=""}

: ${USE_TESTING:=false}
: ${LUKS_KEYFILE:=""}

# for installing into preexisting multi boot setups:
: ${PREEXISTING_BOOT_PARTITION_NUM:=""} # this will not be formatted
: ${PREEXISTING_ROOT_PARTITION_NUM:=""} # this WILL be formatted
# any pre-existing swap partition will just be used via systemd magic

: ${CUSTOM_MIRROR_URL:=""}
# useful with pacoloco on the host with config:
##repos:
##  archlinux:
##    url: http://mirrors.kernel.org/archlinux
##  alarm:
##    url: http://mirror.archlinuxarm.org
# and CUSTOM_MIRROR_URL='http://[ip]:9129/repo/alarm/$arch/$repo' for alarm

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
    echo "and then restart systemd-binfmt.service"
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
  IMG_NAME="${TARGET}.raw"
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
  sgdisk -N ${NEXT_PARTITION} -t ${NEXT_PARTITION}:8304 -c ${NEXT_PARTITION}:"Linux ${ROOT_FS_TYPE} data parition" "${TARGET_DEV}"; ROOT_PARTITION=${NEXT_PARTITION}; ((NEXT_PARTITION++))

  # make hybrid/protective MBR
  #sgdisk -h "1 2" "${TARGET_DEV}"  # this breaks rpi3
  echo -e "r\nh\n1 2\nN\n0c\nN\n\nN\nN\nw\nY\n" | sudo gdisk "${TARGET_DEV}"  # needed for rpi3

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
  btrfs subvolume set-default ${TMP_ROOT}/root
  #btrfs subvolume create ${TMP_ROOT}/home
  umount ${TMP_ROOT}
  mount ${ROOT_DEVICE} -o subvol=root,compress=zstd ${TMP_ROOT}
  #mkdir ${TMP_ROOT}/home
  #mount ${ROOT_DEVICE} -o subvol=home,compress=zstd ${TMP_ROOT}/home
fi
mkdir ${TMP_ROOT}/boot
mount ${TARGET_DEV}${PEE}${BOOT_PARTITION} ${TMP_ROOT}/boot
install -m644 -Dt /tmp /etc/pacman.d/mirrorlist
cat <<EOF > /tmp/pacman.conf
[options]
HoldPkg     = pacman glibc
Architecture = ${TARGET_ARCH}
CheckSpace
Color
SigLevel = Required DatabaseOptional TrustedOnly
LocalFileSigLevel = Optional
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
  sed '1s;^;Server = http://mirror.archlinuxarm.org/$arch/$repo\n;' -i /tmp/mirrorlist
fi

if test ! -z "${CUSTOM_MIRROR_URL}"
then
  sed "1s;^;Server = ${CUSTOM_MIRROR_URL}\n;" -i /tmp/mirrorlist
fi

pacstrap -C /tmp/pacman.conf -M -G "${TMP_ROOT}" ${DEFAULT_PACKAGES} ${PACKAGE_LIST}

if test ! -z "${ADMIN_SSH_AUTH_KEY}"
then
  echo -n "${ADMIN_SSH_AUTH_KEY}" > "${TMP_ROOT}"/var/tmp/auth_pub.key
fi


genfstab -U "${TMP_ROOT}" >> "${TMP_ROOT}"/etc/fstab
sed -i '/swap/d' "${TMP_ROOT}"/etc/fstab


cat > "${TMP_ROOT}/root/setup.sh" <<EOF
#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
set -o verbose
set -o xtrace
touch /var/tmp/phase_one_setup_failed
touch /var/tmp/phase_two_setup_incomplete

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
  sed 's,^#PermitRootLogin prohibit-password,PermitRootLogin yes,g' -i /etc/ssh/sshd_config
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
#echo "LANG=${LOCALE}" > /etc/locale.conf
localectl set-locale LANG=${LOCALE}
unset LANG
set +o nounset
source /etc/profile.d/locale.sh
set -o nounset
#echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
localectl set-keymap --no-convert ${KEYMAP}

# setup gnupg
install -m700 -d /etc/skel/.gnupg
echo "keyserver hkps://hkps.pool.sks-keyservers.net:443" > /tmp/gpg.conf
echo "keyserver-options auto-key-retrieve" >> /tmp/gpg.conf
install -m600 -Dt /etc/skel/.gnupg/ /tmp/gpg.conf
rm /tmp/gpg.conf

# copy over the skel files for the root user
find /etc/skel -maxdepth 1 -mindepth 1 -exec cp -a {} /root \;

pacman-key --init
if [[ \$(uname -m) == *"arm"*  || \$(uname -m) == "aarch64" ]] ; then
  pacman-key --populate archlinuxarm
  echo 'Server = http://mirror.archlinuxarm.org/\$arch/\$repo' > /etc/pacman.d/mirrorlist
else
  pacman-key --populate archlinux
  reflector --protocol https --latest 30 --number 20 --sort rate --save /etc/pacman.d/mirrorlist
  
  # boot with systemd-boot
  bootctl --no-variables --graceful install
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

[DHCPv4]
UseDomains=true

[IPv6AcceptRA]
UseDomains=yes
END

  #sed -i -e 's/hosts: files dns myhostname/hosts: files resolve myhostname/g' /etc/nsswitch.conf

  #ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf  # breaks network inside container
  touch /link_resolv_conf #leave a marker so we can complete this setup later

  systemctl enable systemd-networkd
  systemctl enable systemd-resolved
fi

# if gdm was installed, let's do a few things
if pacman -Q gdm > /dev/null 2>/dev/null; then
  systemctl enable gdm
  #TODO: set keyboard layout for gnome
  if [ ! -z "${ADMIN_USER_NAME}" ] && [ "${AUTOLOGIN_ADMIN}" = true ] ; then
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
  if [ ! -z "${ADMIN_USER_NAME}" ] && [ "${AUTOLOGIN_ADMIN}" = true ] ; then
    echo "# Enable automatic login for user" >> /etc/lxdm/lxdm.conf
    echo "autologin=${ADMIN_USER_NAME}" >> /etc/lxdm/lxdm.conf
  fi
fi

# attempt phase two setup (expected to fail in alarm because https://github.com/systemd/systemd/issues/18643)
if test -f /root/phase_two.sh
then
  echo "Attempting phase two setup"
  set +o errexit
  bash /root/phase_two.sh
  set -o errexit
  if test -f /var/tmp/phase_two_setup_incomplete
  then
    echo "Phase two setup failed"
    echo "Boot into the system natively and run `bash /root/phase_two.sh`"
  else
    echo "Phase two setup complete!"
    rm -f /root/phase_two.sh
  fi
fi

# must do this last because it breaks networking
if test -f /link_resolv_conf
then
  echo "Linking resolv.conf"
  rm /link_resolv_conf
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

# undo changes to service files
sed 's,#PrivateNetwork=yes,PrivateNetwork=yes,g' -i /usr/lib/systemd/system/systemd-localed.service

rm -f /var/tmp/phase_one_setup_failed
exit 0
EOF

cat > "${TMP_ROOT}"/usr/lib/systemd/system/container-boot-setup.service <<END
[Unit]
Description=Initial system setup tasks to be run in a container
ConditionPathExists=/root/setup.sh

[Service]
Type=idle
TimeoutStopSec=10sec
ExecStart=/usr/bin/bash /root/setup.sh
ExecStopPost=/usr/bin/sh -c 'rm -f /root/setup.sh; systemctl disable container-boot-setup; rm -f /usr/lib/systemd/system/container-boot-setup.service; halt'
END
ln -s /usr/lib/systemd/system/container-boot-setup.service "${TMP_ROOT}"/etc/systemd/system/multi-user.target.wants/container-boot-setup.service

cat > "${TMP_ROOT}/root/phase_two.sh" <<EOF
#!/usr/bin/env bash
set -o pipefail
set -o errexit
set -o nounset
set -o verbose
set -o xtrace

# setup admin user
if test ! -z "${ADMIN_USER_NAME}"
then
  pacman -S --needed --noconfirm sudo jq
  # users in the wheel group have password triggered sudo powers
  echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/01_wheel_can_sudo

  systemctl enable systemd-homed
  systemctl start systemd-homed

  STORAGE=directory
  if test "${ROOT_FS_TYPE}" = "btrfs"
  then
    STORAGE=subvolume
  elif test "${ROOT_FS_TYPE}" = "f2fs"
  then
    # STORAGE=fscrypt #TODO: this is broken today with "Failed to install master key in keyring: Operation not permitted"
    STORAGE=directory
  fi

  GRPS=""
  if test ! -z "${AUR_HELPER}"
  then
    pacman -S --needed --noconfirm base-devel
    groupadd aur || true
    MAKEPKG_BACKUP="/var/cache/makepkg/pkg"
    install -d "\${MAKEPKG_BACKUP}" -g aur -m=775
    GRPS="aur,"
  fi
  GRPS="\${GRPS}adm,uucp,wheel"

  if test -f /var/tmp/auth_pub.key
  then
    ADD_KEY_CMD="--ssh-authorized-keys=\$(cat /var/tmp/auth_pub.key)"
  else
    echo "No user key supplied for ssh, generating one for you"
    mkdir -p /root/admin_sshkeys
    if test ! -f /root/admin_sshkeys/id_rsa.pub
    then
      ssh-keygen -q -t rsa -N '' -f /root/admin_sshkeys/id_rsa
    fi
    ADD_KEY_CMD="--ssh-authorized-keys=\$(cat /root/admin_sshkeys/id_rsa.pub)"
  fi

  if ! userdbctl user ${ADMIN_USER_NAME} > /dev/null 2>/dev/null
  then
    # make the user with homectl
    jq -n --arg pw "${ADMIN_USER_PASSWORD}" --arg pwhash "\$(openssl passwd -6 ${ADMIN_USER_PASSWORD})" '{secret:{password:[\$pw]},privileged:{hashedPassword:[\$pwhash]}}' | homectl --identity=- create ${ADMIN_USER_NAME} --member-of=\${GRPS} --storage=\${STORAGE} "\${ADD_KEY_CMD}"
    rm -f /var/tmp/auth_pub.key

    sed "s,^#AuthorizedKeysCommand none,AuthorizedKeysCommand /usr/bin/userdbctl ssh-authorized-keys %u,g" -i /etc/ssh/sshd_config
    sed "s,^#AuthorizedKeysCommandUser nobody,AuthorizedKeysCommandUser root,g" -i /etc/ssh/sshd_config
    grep -qxF 'AuthenticationMethods publickey,password' /etc/ssh/sshd_config || echo "AuthenticationMethods publickey,password" >> /etc/ssh/sshd_config
    sed 's,^PermitRootLogin yes,#PermitRootLogin prohibit-password,g' -i /etc/ssh/sshd_config

    if test -f /root/admin_sshkeys/id_rsa.pub
    then
      PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}
      install -d /home/${ADMIN_USER_NAME}/.ssh -o ${ADMIN_USER_NAME} -g ${ADMIN_USER_NAME} -m=700
      cp -a /root/admin_sshkeys/* /home/${ADMIN_USER_NAME}/.ssh
      chown ${ADMIN_USER_NAME} /home/${ADMIN_USER_NAME}/.ssh/*
      chgrp ${ADMIN_USER_NAME} /home/${ADMIN_USER_NAME}/.ssh/*
      homectl deactivate ${ADMIN_USER_NAME}
    fi
  fi

  if test ! -z "${AUR_HELPER}"
  then
    if ! pacman -Q ${AUR_HELPER} > /dev/null 2>/dev/null; then
      # just for now, admin user is passwordless for pacman
      echo "${ADMIN_USER_NAME} ALL=(ALL) NOPASSWD: /usr/bin/pacman" > "/etc/sudoers.d/allow_${ADMIN_USER_NAME}_to_pacman"
      # let root cd with sudo
      echo "root ALL=(ALL) CWD=* ALL" > /etc/sudoers.d/permissive_root_Chdir_Spec

      # activate admin home
      PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}

      # get helper pkgbuild
      sudo -u ${ADMIN_USER_NAME} -D~ bash -c "curl -s -L https://aur.archlinux.org/cgit/aur.git/snapshot/${AUR_HELPER}.tar.gz | bsdtar -xvf -"

      # make and install helper
      sudo -u ${ADMIN_USER_NAME} -D~/${AUR_HELPER} bash -c "makepkg -si --noprogressbar --noconfirm --needed"

      # clean up
      sudo -u ${ADMIN_USER_NAME} -D~ bash -c "rm -rf ${AUR_HELPER}"
      sudo -u ${ADMIN_USER_NAME} -D~ bash -c "rm -rf .cache/go-build"
      sudo -u ${ADMIN_USER_NAME} -D~ bash -c "rm -rf .cargo"
      pacman -Qtdq | pacman -Rns - --noconfirm

      homectl deactivate ${ADMIN_USER_NAME}
    fi  #get helper
    
    # backup future makepkg built packages
    sed -i "s,^#PKGDEST=.*,PKGDEST=\${MAKEPKG_BACKUP},g" /etc/makepkg.conf

    if test ! -z "${AUR_PACKAGE_LIST}"
    then
      # activate admin home
      PASSWORD="${ADMIN_USER_PASSWORD}" homectl activate ${ADMIN_USER_NAME}
      sudo -u ${ADMIN_USER_NAME} -D~ bash -c "${AUR_HELPER//-bin} -Syu --removemake yes --needed --noconfirm --noprogressbar ${AUR_PACKAGE_LIST}"
      homectl deactivate ${ADMIN_USER_NAME}
    fi
    # take away passwordless sudo for pacman for admin
    rm -rf /etc/sudoers.d/allow_${ADMIN_USER_NAME}_to_pacman
  fi  # add AUR
fi # add admin
rm -f /var/tmp/phase_two_setup_incomplete
EOF

if contains "${TARGET_ARCH}" "arm" || test "${TARGET_ARCH}" = "aarch64"
then
  :
else
  # let pacman update the bootloader
  mkdir -p "${TMP_ROOT}"/etc/pacman.d/hooks
  cat > "${TMP_ROOT}/etc/pacman.d/hooks/100-systemd-boot.hook" <<END
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Updating systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
END
mkdir -p "${TMP_ROOT}"/boot/loader/entries
cp /usr/share/systemd/bootctl/arch.conf "${TMP_ROOT}"/boot/loader/entries
sed "s,root=PARTUUID=XXXX,root=PARTUUID=$(blkid -s PARTUUID -o value ${ROOT_DEVICE})," -i "${TMP_ROOT}"/boot/loader/entries/arch.conf
sed "s,rootfstype=XXXX,rootfstype=${ROOT_FS_TYPE}," -i "${TMP_ROOT}"/boot/loader/entries/arch.conf
sed "s,initrd,initrd  /intel-ucode.img\ninitrd  /amd-ucode.img\ninitrd," -i "${TMP_ROOT}"/boot/loader/entries/arch.conf
fi

# this lets localctl work in the container...
sed 's,PrivateNetwork=yes,#PrivateNetwork=yes,g' -i "${TMP_ROOT}"/usr/lib/systemd/system/systemd-localed.service

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

# boot into newly created system to perform setup tasks
if test -z "${IMG_NAME}"
then
  SPAWN_TARGET=${TARGET_DEV}
else
  SPAWN_TARGET="${IMG_NAME}"
fi
systemd-nspawn --boot --image "${SPAWN_TARGET}"

#eject ${TARGET_DEV} || true

if test ! -z "${ADMIN_SSH_AUTH_KEY}"
then
  echo "If you need to ssh into the system, you can find the keypair you must use in /root/admin_sshkeys"
fi

echo "Done! You could now explore the new system with"
echo "systemd-nspawn --network-macvlan=eno1 --network-veth --boot --image \"${SPAWN_TARGET}\""
