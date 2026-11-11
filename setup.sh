#!/usr/bin/env bash
# Runs INSIDE the new system (chroot) - started by install.sh.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source /etc/handheld-installer.env
trap 'warn "setup.sh failed near line $LINENO"' ERR

put() { install -D -m 0755 "$HERE/files/$1" "$2"; }   # put <file-in-files/> <destination>

# =========================================================================================
# 1. APT: contrib + non-free + backports (gamescope is only in trixie-backports), i386 for Steam
# =========================================================================================
log "Configuring APT..."
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: $DEBIAN_MIRROR
Suites: $SUITE ${SUITE}-updates ${SUITE}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: ${SUITE}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
echo 'Acquire::Languages "none";' > /etc/apt/apt.conf.d/90-no-translations
dpkg --add-architecture i386
apt-get update
apt-get -y full-upgrade

# =========================================================================================
# 2. Locale / time / keyboard
# =========================================================================================
log "Locale, timezone, keyboard..."
sed -i "s/^# *${LOCALE//./\\.} /${LOCALE} /" /etc/locale.gen
grep -q "^${LOCALE} " /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG="$LOCALE"
echo "$TIMEZONE" > /etc/timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KB_LAYOUT"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# =========================================================================================
# 3. Boot tooling first, so the very first kernel install already produces a Limine menu
# =========================================================================================
log "Installing boot tooling (snapper, Limine hooks)..."
install_core snapper inotify-tools
put limine-snapper-sync   /usr/local/sbin/limine-snapper-sync
put handheld-rollback     /usr/local/sbin/handheld-rollback
put apt-snapper           /usr/local/sbin/apt-snapper
put build-cachyos-kernel  /usr/local/sbin/build-cachyos-kernel
put limine-kernel-hook    /etc/kernel/postinst.d/zz-limine-handheld
put limine-kernel-hook    /etc/kernel/postrm.d/zz-limine-handheld

DEFAULT_FLAVOR=lts; [[ $CACHY_MODE != later ]] && DEFAULT_FLAVOR=cachyos
cat > /etc/default/limine-handheld <<EOF
# Used by /usr/local/sbin/limine-snapper-sync
ROOT_UUID=$ROOT_UUID
ROOT_SUBVOL=@
ESP=/boot
TIMEOUT=5
# Extra kernel command line parameters for every entry:
CMDLINE_EXTRA="quiet"
# Which kernel is listed first / booted by default: cachyos | lts
DEFAULT_FLAVOR=$DEFAULT_FLAVOR
EOF

# Limine is not packaged in Debian 13 -> take the upstream binary release (UEFI loader only).
log "Fetching Limine..."
install_core git
tmp=$(mktemp -d)
tag=$(curl -fsSL https://api.github.com/repos/limine-bootloader/limine/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1 || true)
got=0
for br in ${LIMINE_BRANCH:-v12.x-binary} ${tag:+${tag}-binary} binary; do
    if git clone --quiet --depth 1 --branch "$br" https://github.com/limine-bootloader/limine.git "$tmp/limine" 2>/dev/null; then
        got=1; info "Limine from branch/tag: $br"; break
    fi
done
((got)) && [[ -f $tmp/limine/BOOTX64.EFI ]] || die "Could not download Limine (BOOTX64.EFI). Set LIMINE_BRANCH and retry."
install -D -m 0644 "$tmp/limine/BOOTX64.EFI" /usr/local/share/limine/BOOTX64.EFI
rm -rf "$tmp"

# =========================================================================================
# 4. Hardware: microcode + firmware (BEFORE the kernel so the initramfs picks up the firmware)
# =========================================================================================
log "Installing hardware drivers/firmware for the detected hardware..."
# shellcheck disable=SC2086
install_available $HW_PKGS || warn "some hardware packages failed - continuing"

# initramfs: MODULES=most is deliberate. 'dep' mis-detects inside a chroot and would break snapshot boots.
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
grep -q '^COMPRESS=' /etc/initramfs-tools/initramfs.conf \
    && sed -i 's/^COMPRESS=.*/COMPRESS=zstd/' /etc/initramfs-tools/initramfs.conf \
    || echo 'COMPRESS=zstd' >> /etc/initramfs-tools/initramfs.conf

# =========================================================================================
# 5. Kernel #1: Debian LTS (6.12 series in trixie)
# =========================================================================================
log "Installing the Debian LTS kernel..."
install_core linux-image-amd64 linux-headers-amd64

log "Registering Limine in the UEFI boot menu..."
efibootmgr --create --disk "$ESP_DISK" --part "$ESP_PARTNUM" --label "Debian Handheld (Limine)" \
    --loader '\EFI\limine\BOOTX64.EFI' >/dev/null 2>&1 \
    || warn "efibootmgr failed - the fallback loader EFI/BOOT/BOOTX64.EFI will still be found by the firmware"

# =========================================================================================
# 6. Desktop, gaming stack, audio, handheld extras
# =========================================================================================
log "Installing KDE Plasma + SDDM..."
install_core kde-plasma-desktop sddm kwin-wayland
install_available plasma-nm plasma-pa plasma-discover plasma-discover-backend-flatpak kde-config-sddm \
    xdg-desktop-portal-kde xdg-desktop-portal-gtk konsole dolphin kate ark spectacle firefox-esr \
    bluedevil kscreen powerdevil kinfocenter maliit-keyboard qml6-module-qtquick-virtualkeyboard || true

log "Installing the gaming stack (Steam, gamescope, Mesa 32-bit, MangoHud, GameMode)..."
echo "steam steam/question select I AGREE"          | debconf-set-selections
echo "steam steam/license note"                     | debconf-set-selections
echo "steam-installer steam/question select I AGREE" | debconf-set-selections
echo "steam-installer steam/license note"           | debconf-set-selections
install_core steam-installer steam-devices
install_available mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 libasound2-plugins:i386 \
    mangohud gamemode vulkan-tools mesa-utils libva-utils game-devices-udev joystick evtest || true
apt-get install -y -t "${SUITE}-backports" gamescope || warn "gamescope (trixie-backports) failed to install - Gaming Mode will not work"

log "Installing audio (PipeWire + WirePlumber + ALSA), network, power..."
install_core pipewire-audio pipewire-alsa pipewire-pulse wireplumber alsa-utils alsa-ucm-conf
install_available pipewire-jack libspa-0.2-bluetooth || true
install_core network-manager bluez power-profiles-daemon upower
install_available iio-sensor-proxy fwupd systemd-zram-generator lm-sensors smartmontools nvme-cli \
    htop btop usbutils pciutils unzip p7zip-full libfuse2t64 xdg-user-dirs fonts-noto-core fonts-noto-color-emoji || true
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true

log "Installing Flatpak..."
install_core flatpak

# =========================================================================================
# 7. User account
# =========================================================================================
log "Creating user $USERNAME..."
useradd -m -s /bin/bash -c "$USERNAME" "$USERNAME"
usermod -p "$USER_HASH" "$USERNAME"
for g in sudo video audio render input plugdev netdev bluetooth gamemode; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$USERNAME"
done
passwd -l root >/dev/null
sed -i '/^USER_HASH=/d' /etc/handheld-installer.env     # don't leave the hash around longer than needed

# =========================================================================================
# 8. Sessions: SDDM lets you choose Plasma (Wayland) or Steam Gaming Mode (gamescope)
# =========================================================================================
log "Configuring SDDM sessions..."
put gamescope-session-steam /usr/local/bin/gamescope-session-steam
put steamos-session-select  /usr/local/bin/steamos-session-select
put steamos-update          /usr/local/bin/steamos-update
put handheld-session-set    /usr/local/sbin/handheld-session-set
put return-to-gamemode      /usr/local/bin/return-to-gamemode
mkdir -p /etc/handheld
cat > /etc/handheld/gamescope.conf <<'EOF'
# Options for Steam Gaming Mode (sourced by /usr/local/bin/gamescope-session-steam)
# Portrait-native panel that comes up rotated?  Try:  GAMESCOPE_ARGS="--force-orientation left"   (or right / inverted)
GAMESCOPE_ARGS=""
# Steam launch flags:
#STEAM_ARGS="-steamos3 -steampal -steamdeck -gamepadui"
EOF
cat > /usr/share/wayland-sessions/steam-gamescope.desktop <<'EOF'
[Desktop Entry]
Name=Steam (Gaming Mode)
Comment=Steam Big Picture inside gamescope
Exec=/usr/local/bin/gamescope-session-steam
Type=Application
DesktopNames=gamescope
EOF
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-handheld.conf <<'EOF'
# Wayland greeter: respects the panel's DRM orientation quirks (portrait-native handheld screens)
[General]
DisplayServer=wayland
InputMethod=qtvirtualkeyboard

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
EOF
# only keep the on-screen keyboard option when the plugin really got installed
dpkg -s qml6-module-qtquick-virtualkeyboard >/dev/null 2>&1 || sed -i '/^InputMethod=/d' /etc/sddm.conf.d/10-handheld.conf

cat > "/etc/sudoers.d/handheld-session" <<EOF
$USERNAME ALL=(root) NOPASSWD: /usr/local/sbin/handheld-session-set
EOF
chmod 440 /etc/sudoers.d/handheld-session
if [[ $AUTOLOGIN == yes ]]; then
    cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$USERNAME
Session=steam-gamescope.desktop
Relogin=true
EOF
    cat > /usr/share/applications/return-to-gamemode.desktop <<'EOF'
[Desktop Entry]
Name=Return to Gaming Mode
Exec=/usr/local/bin/return-to-gamemode
Icon=steam
Type=Application
Categories=Game;
EOF
fi

# =========================================================================================
# 9. Handheld Daemon (controller emulation, TDP, gyro, RGB) - best effort
# =========================================================================================
if [[ $INSTALL_HHD == yes ]]; then
    log "Installing Handheld Daemon (hhd)..."
    bash "$HERE/chroot/hhd.sh" "$USERNAME" \
        || warn "hhd installation failed - install it later, see https://github.com/hhd-dev/hhd"
fi

# =========================================================================================
# 10. System tuning
# =========================================================================================
log "Applying gaming tweaks (zram, sysctl)..."
cat > /etc/sysctl.d/99-handheld-gaming.conf <<'EOF'
vm.swappiness = 100
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.max_map_count = 2147483642
kernel.split_lock_mitigate = 0
EOF
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF

# =========================================================================================
# 11. Snapper (3-4 snapshots max) - configured by hand so it works inside the chroot
# =========================================================================================
log "Configuring snapper..."
mkdir -p /etc/snapper/configs
cat > /etc/snapper/configs/root <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
# Keep at most 4 snapshots (apt pre+post count as two)
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="0"
NUMBER_LIMIT="4"
NUMBER_LIMIT_IMPORTANT="4"
# No timeline snapshots - only apt transactions and the baseline
TIMELINE_CREATE="no"
TIMELINE_CLEANUP="no"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="0"
TIMELINE_LIMIT_DAILY="0"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF
if [[ -f /etc/default/snapper ]]; then
    sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' /etc/default/snapper
else
    echo 'SNAPPER_CONFIGS="root"' > /etc/default/snapper
fi
chmod 750 /.snapshots

# =========================================================================================
# 12. Services
# =========================================================================================
log "Enabling services..."
systemctl enable sddm NetworkManager bluetooth power-profiles-daemon fstrim.timer snapper-cleanup.timer
systemctl disable snapper-timeline.timer 2>/dev/null || true
systemctl enable systemd-timesyncd 2>/dev/null || true
if has_candidate thermald && [[ $HW_CPU_VENDOR == intel ]]; then systemctl enable thermald 2>/dev/null || true; fi

# =========================================================================================
# 13. Flathub + Bazaar + ProtonPlus (falls back to a first-boot service when the chroot can't do it)
# =========================================================================================
log "Setting up Flathub, Bazaar and ProtonPlus..."
put handheld-flatpak-setup /usr/local/sbin/handheld-flatpak-setup
cat > /etc/systemd/system/handheld-flatpak.service <<'EOF'
[Unit]
Description=Install Flathub apps (Bazaar, ProtonPlus)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/handheld/flatpak-pending

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/handheld-flatpak-setup
Restart=on-failure
RestartSec=120

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /var/lib/handheld
if ! /usr/local/sbin/handheld-flatpak-setup; then
    warn "Flatpak install inside the chroot failed - it will be finished on first boot (needs network)."
    touch /var/lib/handheld/flatpak-pending
    systemctl enable handheld-flatpak.service
fi

# =========================================================================================
# 14. Kernel #2: CachyOS (latest stable + CachyOS patchset). A failure here is not fatal.
# =========================================================================================
case $CACHY_MODE in
    build)
        log "Building the CachyOS kernel - grab a coffee..."
        X86_LEVEL=$HW_X86_LEVEL /usr/local/sbin/build-cachyos-kernel \
            || warn "CachyOS kernel build failed. The system boots the Debian LTS kernel; retry later with: sudo build-cachyos-kernel"
        ;;
    prebuilt)
        log "Installing prebuilt CachyOS kernel packages..."
        mkdir -p /var/cache/handheld-kernels
        cp "$HERE"/prebuilt/linux-image-*cachyos*.deb "$HERE"/prebuilt/linux-headers-*cachyos*.deb /var/cache/handheld-kernels/ 2>/dev/null || true
        apt-get install -y /var/cache/handheld-kernels/linux-image-*cachyos*.deb $(ls /var/cache/handheld-kernels/linux-headers-*cachyos*.deb 2>/dev/null) \
            || warn "Installing the prebuilt kernel failed - booting Debian LTS only."
        ;;
    later)
        info "CachyOS kernel skipped. Run 'sudo build-cachyos-kernel' after first boot."
        ;;
esac

# =========================================================================================
# 15. Baseline snapshot + apt hook (installed LAST so the install itself doesn't spam snapshots)
# =========================================================================================
log "Creating the baseline snapshot and enabling apt snapshots..."
update-initramfs -u -k all || true
/usr/local/sbin/limine-snapper-sync || true
snapper --no-dbus -c root create -c number -d "Fresh install" || warn "could not create the baseline snapshot"
/usr/local/sbin/limine-snapper-sync || true
cat > /etc/apt/apt.conf.d/80-snapper-limine <<'EOF'
// Snapshot before/after every dpkg run and refresh the Limine menu (see /usr/local/sbin/apt-snapper)
DPkg::Pre-Invoke  { "[ -x /usr/local/sbin/apt-snapper ] && /usr/local/sbin/apt-snapper pre  || true"; };
DPkg::Post-Invoke { "[ -x /usr/local/sbin/apt-snapper ] && /usr/local/sbin/apt-snapper post || true"; };
EOF

apt-get clean
rm -rf /var/lib/apt/lists/*
log "Chroot stage complete."
