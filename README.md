# Debian Handheld Gaming Installer - WIP

Installs Debian 13 (trixie) on a handheld gaming PC (older Intel / AMD, no NVIDIA) from a Debian Live ISO:
Btrfs root, Limine + snapper snapshots, two kernels (Debian LTS + CachyOS), KDE Plasma with SDDM, Steam installed
with a "Steam Big Picture" desktop shortcut, Flatpak with Flathub / Bazaar / ProtonPlus, PipeWire + ALSA.

> **Status: untested on real hardware.** The shell syntax is checked and the Limine/snapper sync logic was
> exercised against a fake ESP, but the full install has not been run end to end. **Test in a UEFI VM first**
> (QEMU + OVMF, 40 GB+ disk), then on the handheld. Expect to fix a few things.

## Usage

1. Boot a Debian 13 Live ISO **in UEFI mode**, connect to the network.
2. ```sh
   git clone https://github.com/KiziCat/debian_gaming && cd debian_gaming
   tar -xf debian-handheld-installer.tar.gz && cd debian-handheld-installer
   chmod +x install.sh chroot/*.sh files/*
   sudo ./install.sh
   ```
3. Answer the prompts: pick the disk by number, hostname, user + password, timezone (type `Warsaw`, `europe/berlin`, `new york`...),
   locale, keyboard, autologin, hhd, CachyOS kernel mode.

Non-interactive (VM testing): `DISK=/dev/vda USERNAME=deck USERPASS=deck ASSUME_YES=1 CACHY_MODE=later ./install.sh`

## What it does, in order

| Stage | Details |
|---|---|
| Detect hardware (before touching the disk) | CPU vendor + x86-64 level, AMD/Intel GPU, Wi-Fi/BT/audio chips, handheld model (OneXPlayer, AYANEO, AYN, GPD, ROG Ally, Legion Go, MSI Claw, Steam Deck). Selects microcode, firmware, Mesa/VA-API packages. |
| Partition | GPT: 3 GiB FAT32 ESP (mounted at `/boot`) + Btrfs. |
| Btrfs layout | `@` `@home` `@snapshots` `@rescue` `@var_log` `@var_cache` `@flatpak` (zstd:1, noatime, async discard). Home, logs, caches and Flatpak are **not** rolled back with the system. |
| Base | `debootstrap` trixie with contrib/non-free/non-free-firmware, i386 multiarch, trixie-backports. |
| Limine | Upstream binary (not packaged in Debian 13; the newest existing `vN.x-binary` branch is auto-detected) -> `EFI/limine/` + `EFI/BOOT/` fallback + efibootmgr entry. |
| Kernels | `linux-image-amd64` (Debian LTS, 6.12 series) and a CachyOS-patched latest stable (see below). Both in the Limine menu. |
| Desktop | KDE Plasma, SDDM (Wayland greeter, on-screen keyboard), optional autologin. |
| Gaming/handheld | Steam (+ "Steam Big Picture" launcher in the menu and on the desktop), MangoHud, GameMode, 32-bit Mesa, Steam udev rules, power-profiles-daemon, iio-sensor-proxy, zram, optional hhd. |
| Audio / Flatpak | PipeWire + WirePlumber + pipewire-alsa/-pulse, alsa-utils, ucm; Flatpak + Flathub + Bazaar + ProtonPlus (finishes on first boot if the chroot can't). |
| Snapper | `NUMBER_LIMIT=4`, no timeline snapshots, pre/post snapshot around every apt/dpkg run, baseline "Fresh install". |

## How Limine + snapper work together (important)

Limine can only read FAT, **not Btrfs**. So the kernels live on the ESP (`/boot`), and a small tool,
`/usr/local/sbin/limine-snapper-sync`, does the glue every time a kernel or snapshot changes:

* writes `/boot/limine.conf` (newest kernel per flavour, "Older kernels", "Snapshots (rescue)")
* for each snapper snapshot N: makes a writable clone `@rescue/N` (the snapshot stays pristine) and copies the
  matching kernel + initramfs to `/boot/snapshots/N/` so the modules always match
* prunes clones/kernel copies when snapper deletes a snapshot

Roll back: boot a "Snapshot N" entry to try it, then `sudo handheld-rollback N` and reboot. The previous root is
kept as `@.before-rollback-<time>` until you delete it.

## The CachyOS kernel

There is no CachyOS kernel package for Debian, so `build-cachyos-kernel` builds one: latest stable from kernel.org +
CachyOS `base` and `BORE` patches + CachyOS config, x86-64-v2/v3 chosen from your CPU, packaged with `make bindeb-pkg`.
It falls back to the newest patch series CachyOS provides if the very latest kernel has none yet.

* **Build at install**: 30-120+ min on a handheld APU. Debug info/BTF is dropped by default (`FAST_BUILD=1`: ~12 GB temp space, fewer ways to fail);
  `FAST_BUILD=0` keeps them for sched_ext/scx but needs ~28 GB.
* **If it fails**: everything is logged to `/var/log/cachyos-kernel-build.log`, the last 40 lines are printed, and the source tree is kept in
  `/var/tmp/cachyos-build`. Retry any time with `sudo build-cachyos-kernel`.
* **Prebuilt**: drop `linux-image-*cachyos*.deb` + `linux-headers-*cachyos*.deb` into `prebuilt/` and pick option 2. Building these
  once in CI (a Debian 13 container) and hosting them in your repo is the practical long-term route.
* **Later**: pick option 3, then `sudo build-cachyos-kernel` after first boot (also how you update it).
* If the build fails the install still completes with the LTS kernel.

## Known limitations / things to verify

* UEFI only. No Secure Boot, no LUKS (neither was requested; both are doable additions).
* Limine: override the auto-detected branch with `LIMINE_BRANCH=v11.x-binary` if a future major changes the config syntax.
* Steam: the Debian `steam-installer` package and all its 32-bit dependencies are installed, but Valve's client downloads its own
  updates on the first launch (needs network, a few minutes). That step cannot be done offline during install.
* hhd is installed from PyPI with udev rules fetched from its GitHub repo; handheld-specific out-of-tree drivers
  (IMU, etc.) are not installed automatically - check hhd's docs for your model.

## Layout

```
install.sh              host-side installer (live ISO)
lib/common.sh           helpers
lib/hardware.sh         hardware detection
chroot/setup.sh         everything that happens inside the new system
chroot/hhd.sh           Handheld Daemon install
files/                  scripts installed into the target (limine-snapper-sync, handheld-rollback, build-cachyos-kernel, ...)
prebuilt/               optional CachyOS kernel .deb files
```
