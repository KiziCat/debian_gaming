#!/usr/bin/env bash
# Debian Handheld Gaming Installer
# Run as root from a Debian 13 (trixie) Live ISO with network access:
#     git clone <your-repo> && cd debian-handheld-installer && sudo ./install.sh
#
# Non-interactive example (VM testing):
#     DISK=/dev/vda USERNAME=deck USERPASS=deck TARGET_HOSTNAME=handheld ASSUME_YES=1 CACHY_MODE=later ./install.sh
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/hardware.sh
source "$SCRIPT_DIR/lib/hardware.sh"

SUITE=${SUITE:-trixie}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
TARGET=${TARGET:-/target}
ESP_SIZE_MIB=${ESP_SIZE_MIB:-3072}     # kernels + per-snapshot kernel copies live here (Limine reads FAT only)
BTRFS_OPTS="noatime,compress=zstd:1,discard=async"

[[ $EUID -eq 0 ]] || exec sudo -E "$0" "$@"

cleanup() {
    set +e
    if mountpoint -q "$TARGET"; then
        umount -R "$TARGET" 2>/dev/null || umount -R -l "$TARGET" 2>/dev/null
    fi
    if mountpoint -q /mnt/btrfs-top; then umount /mnt/btrfs-top; fi
    return 0    # must never return non-zero: the ERR trap would turn a clean exit into "Installer failed"
}
trap cleanup EXIT
trap 'die "Installer failed near line $LINENO - see the message above. A re-run after wiping the disk is safe."' ERR

part_of() { [[ $1 =~ [0-9]$ ]] && echo "${1}p$2" || echo "${1}$2"; }

# ------------------------------------------------------------------------------------------
# 0. Sanity checks + host tooling
# ------------------------------------------------------------------------------------------
[[ -d /sys/firmware/efi ]] || die "Booted in legacy BIOS mode. Handhelds are UEFI - boot the live ISO in UEFI mode."
curl -fsI --max-time 10 "$DEBIAN_MIRROR/dists/$SUITE/Release" >/dev/null || die "No network / mirror unreachable: $DEBIAN_MIRROR"

log "Installing host tools in the live environment..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends debootstrap btrfs-progs gdisk parted dosfstools efibootmgr \
    pciutils usbutils dmidecode openssl curl ca-certificates util-linux >/dev/null

# ------------------------------------------------------------------------------------------
# 1. Hardware detection (before anything is touched)
# ------------------------------------------------------------------------------------------
log "Detecting hardware..."
detect_hardware
print_hardware

# ------------------------------------------------------------------------------------------
# 2. Questions
# ------------------------------------------------------------------------------------------
# Find the disk the live system booted from so it can be hidden from the list (never fails the script).
find_live_disk() {
    local mnt src parent
    for mnt in /run/live/medium /usr/lib/live/mount/medium /lib/live/mount/medium; do
        src=$(findmnt -no SOURCE "$mnt" 2>/dev/null) || continue
        src=${src%%[*}
        [[ -b $src ]] || continue
        parent=$(lsblk -ndo PKNAME "$src" 2>/dev/null | head -n1) || true
        if [[ -n $parent ]]; then echo "/dev/$parent"; else echo "$src"; fi
        return 0
    done
    return 0
}
LIVE_DISK=$(find_live_disk) || LIVE_DISK=""

[[ -n ${DISK:-} ]] || pick_disk "$LIVE_DISK"
[[ -b $DISK ]] || die "$DISK is not a block device"
[[ -z $LIVE_DISK || $DISK != "$LIVE_DISK" ]] || die "$DISK is the live medium"

prompt_var TARGET_HOSTNAME "Hostname" "handheld"
prompt_var USERNAME "Username"
[[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username (lowercase letters, digits, _ and - only)"
if [[ -z ${USERPASS:-} ]]; then
    while :; do
        read -rsp "Password for $USERNAME: " p1 </dev/tty; echo
        read -rsp "Repeat password: " p2 </dev/tty; echo
        [[ -n $p1 && $p1 == "$p2" ]] && break
        warn "Empty or mismatching, try again."
    done
    USERPASS=$p1
fi
default_tz=$(cat /etc/timezone 2>/dev/null || echo UTC)
if [[ -n ${TIMEZONE:-} ]]; then
    [[ -e /usr/share/zoneinfo/$TIMEZONE ]] || die "Unknown timezone $TIMEZONE"
else
    pick_timezone "$default_tz"
fi
prompt_var LOCALE "Locale" "en_US.UTF-8"
prompt_var KB_LAYOUT "Keyboard layout (XKB, e.g. us, pl, de)" "us"

if [[ -z ${AUTOLOGIN:-} ]]; then
    ask_yn "Log in automatically (skip the SDDM login screen)?" n && AUTOLOGIN=yes || AUTOLOGIN=no
fi
if [[ -z ${INSTALL_HHD:-} ]]; then
    d=n; [[ $HW_HANDHELD != none ]] && d=y
    ask_yn "Install Handheld Daemon (hhd) for controller/TDP/gyro support?" "$d" && INSTALL_HHD=yes || INSTALL_HHD=no
fi

shopt -s nullglob
prebuilt=("$SCRIPT_DIR"/prebuilt/linux-image-*cachyos*.deb)
shopt -u nullglob
if [[ -z ${CACHY_MODE:-} ]]; then
    echo
    info "CachyOS kernel (BORE scheduler etc.) - Debian has no package, so it is built into .deb files:"
    echo "   1) build    - compile on this machine during install (30-120+ min, ~20 GB temp space)"
    echo "   2) prebuilt - use .deb files from ./prebuilt (${#prebuilt[@]} image package(s) found)"
    echo "   3) later    - skip now; run 'sudo build-cachyos-kernel' after first boot"
    def=1; ((${#prebuilt[@]})) && def=2
    case "$(ask "Choice" "$def")" in 1) CACHY_MODE=build ;; 2) CACHY_MODE=prebuilt ;; 3) CACHY_MODE=later ;; *) die "Invalid choice" ;; esac
fi
[[ $CACHY_MODE != prebuilt || ${#prebuilt[@]} -gt 0 ]] || die "CACHY_MODE=prebuilt but no linux-image-*cachyos*.deb in $SCRIPT_DIR/prebuilt"

echo
warn "ALL DATA ON $DISK WILL BE ERASED:"
lsblk "$DISK"
if [[ -z ${ASSUME_YES:-} ]]; then
    [[ $(ask "Type YES to continue") == YES ]] || die "Aborted."
fi

# ------------------------------------------------------------------------------------------
# 3. Partition + Btrfs
# ------------------------------------------------------------------------------------------
log "Partitioning $DISK (GPT: ${ESP_SIZE_MIB} MiB ESP + Btrfs)..."
swapoff -a || true
umount -R "$TARGET" 2>/dev/null || true
wipefs -af "$DISK" >/dev/null
sgdisk --zap-all "$DISK" >/dev/null
sgdisk -n "1:0:+${ESP_SIZE_MIB}MiB" -t 1:ef00 -c 1:ESP \
       -n "2:0:0"                   -t 2:8300 -c 2:debian-btrfs "$DISK" >/dev/null
partprobe "$DISK"; udevadm settle; sleep 1
ESP_PART=$(part_of "$DISK" 1)
ROOT_PART=$(part_of "$DISK" 2)

log "Creating filesystems..."
mkfs.vfat -F32 -n ESP "$ESP_PART" >/dev/null
mkfs.btrfs -f -L debian "$ROOT_PART" >/dev/null
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")

log "Creating subvolumes..."
mkdir -p /mnt/btrfs-top "$TARGET"
mount "$ROOT_PART" /mnt/btrfs-top
for sv in @ @home @snapshots @rescue @var_log @var_cache @flatpak; do
    btrfs subvolume create "/mnt/btrfs-top/$sv" >/dev/null
done
umount /mnt/btrfs-top

mount -o "$BTRFS_OPTS,subvol=@" "$ROOT_PART" "$TARGET"
mkdir -p "$TARGET"/{home,.snapshots,.rescue,var/log,var/cache,var/lib/flatpak,boot}
mount -o "$BTRFS_OPTS,subvol=@home"      "$ROOT_PART" "$TARGET/home"
mount -o "$BTRFS_OPTS,subvol=@snapshots" "$ROOT_PART" "$TARGET/.snapshots"
mount -o "$BTRFS_OPTS,subvol=@rescue"    "$ROOT_PART" "$TARGET/.rescue"
mount -o "$BTRFS_OPTS,subvol=@var_log"   "$ROOT_PART" "$TARGET/var/log"
mount -o "$BTRFS_OPTS,subvol=@var_cache" "$ROOT_PART" "$TARGET/var/cache"
mount -o "$BTRFS_OPTS,subvol=@flatpak"   "$ROOT_PART" "$TARGET/var/lib/flatpak"
mount -o umask=0077,quiet,noatime "$ESP_PART" "$TARGET/boot"
chmod 750 "$TARGET/.snapshots"

# ------------------------------------------------------------------------------------------
# 4. Base system
# ------------------------------------------------------------------------------------------
log "Running debootstrap ($SUITE) - this takes a few minutes..."
debootstrap --arch=amd64 --components=main,contrib,non-free,non-free-firmware \
    --include=locales,sudo,curl,wget,ca-certificates,git,gnupg,initramfs-tools,btrfs-progs,dosfstools,efibootmgr,console-setup,keyboard-configuration,kmod,linux-base,dbus,python3,openssl,xz-utils,zstd,cpio,rsync,nano,less,iproute2,iputils-ping \
    "$SUITE" "$TARGET" "$DEBIAN_MIRROR"

log "Writing fstab / hostname..."
# NOTE: no subvol= on the "/" line on purpose. The kernel command line (rootflags=subvol=...) decides which
# subvolume is root, so the very same fstab works for the normal entries and for snapshot entries.
cat > "$TARGET/etc/fstab" <<EOF
# <device>        <mountpoint>      <type> <options>
UUID=$ROOT_UUID  /                 btrfs  $BTRFS_OPTS 0 0
UUID=$ROOT_UUID  /home             btrfs  $BTRFS_OPTS,subvol=@home 0 0
UUID=$ROOT_UUID  /.snapshots       btrfs  $BTRFS_OPTS,subvol=@snapshots 0 0
UUID=$ROOT_UUID  /.rescue          btrfs  $BTRFS_OPTS,subvol=@rescue 0 0
UUID=$ROOT_UUID  /var/log          btrfs  $BTRFS_OPTS,subvol=@var_log 0 0
UUID=$ROOT_UUID  /var/cache        btrfs  $BTRFS_OPTS,subvol=@var_cache 0 0
UUID=$ROOT_UUID  /var/lib/flatpak  btrfs  $BTRFS_OPTS,subvol=@flatpak 0 0
UUID=$ESP_UUID   /boot             vfat   umask=0077,quiet,noatime 0 2
EOF
echo "$TARGET_HOSTNAME" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $TARGET_HOSTNAME
::1       localhost ip6-localhost ip6-loopback
EOF

# ------------------------------------------------------------------------------------------
# 5. Hand over to the chroot stage
# ------------------------------------------------------------------------------------------
log "Preparing chroot..."
mkdir -p "$TARGET/opt/handheld-installer"
tar -C "$SCRIPT_DIR" --exclude=.git -cf - . | tar -C "$TARGET/opt/handheld-installer" -xf -

USER_HASH=$(printf '%s' "$USERPASS" | openssl passwd -6 -stdin)
umask 077
{
    for v in SUITE DEBIAN_MIRROR TARGET_HOSTNAME USERNAME USER_HASH TIMEZONE LOCALE KB_LAYOUT AUTOLOGIN INSTALL_HHD \
             CACHY_MODE ROOT_UUID ESP_UUID HW_CPU_VENDOR HW_X86_LEVEL HW_GPU_AMD HW_GPU_INTEL HW_SYS_VENDOR HW_PRODUCT HW_HANDHELD HW_PKGS; do
        printf '%s=%q\n' "$v" "${!v}"
    done
    printf 'ESP_DISK=%q\nESP_PARTNUM=%q\n' "$DISK" 1
} > "$TARGET/etc/handheld-installer.env"
umask 022

mount --rbind /dev "$TARGET/dev";   mount --make-rslave "$TARGET/dev"
mount -t proc proc "$TARGET/proc"
mount --rbind /sys "$TARGET/sys";   mount --make-rslave "$TARGET/sys"
mount -t tmpfs tmpfs "$TARGET/run"
cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"

log "Configuring the system inside the chroot (packages, kernels, Limine, desktop...)"
chroot "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /opt/handheld-installer/chroot/setup.sh

# ------------------------------------------------------------------------------------------
# 6. Finish
# ------------------------------------------------------------------------------------------
rm -rf "$TARGET/opt/handheld-installer" "$TARGET/etc/handheld-installer.env"
rm -f  "$TARGET/etc/resolv.conf"        # NetworkManager recreates it on first boot
sync
log "Installation finished."
info "Remove the live medium and reboot. Choose your kernel in the Limine menu."
if [[ -z ${ASSUME_YES:-} ]] && ask_yn "Reboot now?" y; then
    trap - ERR EXIT
    cleanup
    sync
    systemctl reboot || reboot -f
fi
