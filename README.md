# Debian Handheld Gaming Installer - WIP

Installs Debian 13 (trixie) on a handheld gaming PC (older Intel / AMD, no NVIDIA) from a Debian Live ISO:
Btrfs root, Limine + snapper snapshots, two kernels (Debian LTS + XanMod), KDE Plasma with SDDM, Steam installed
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
   locale, keyboard, autologin, hhd, XanMod yes/no and branch.

Non-interactive (VM testing): `DISK=/dev/vda USERNAME=deck USERPASS=deck ASSUME_YES=1 CACHY_MODE=later ./install.sh`

## What it does, in order

| Stage | Details |
|---|---|
| Detect hardware (before touching the disk) | CPU vendor + x86-64 level, AMD/Intel GPU, Wi-Fi/BT/audio chips, handheld model (OneXPlayer, AYANEO, AYN, GPD, ROG Ally, Legion Go, MSI Claw, Steam Deck). Selects microcode, firmware, Mesa/VA-API packages. |
| Partition | GPT: 3 GiB FAT32 ESP (mounted at `/boot`) + Btrfs. |
| Btrfs layout | `@` `@home` `@snapshots` `@rescue` `@var_log` `@var_cache` `@flatpak` (zstd:1, noatime, async discard). Home, logs, caches and Flatpak are **not** rolled back with the system. |
| Base | `debootstrap` trixie with contrib/non-free/non-free-firmware, i386 multiarch, trixie-backports. |
| Limine | Upstream binary (not packaged in Debian 13; the newest existing `vN.x-binary` branch is auto-detected) -> `EFI/limine/` + `EFI/BOOT/` fallback + efibootmgr entry. |
| Kernels | `linux-image-amd64` (Debian LTS, 6.12 series) and a prebuilt XanMod kernel for your CPU level (see below). Both in the Limine menu, XanMod first. |
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

## The XanMod kernel

Nothing is compiled on the handheld. `install-xanmod` adds the official XanMod apt repository (`deb.xanmod.org`, signed key from
`dl.xanmod.org`) and installs the prebuilt package for your CPU level: x64v3 on Haswell/Zen1 and newer, x64v2 otherwise
(`XANMOD_LEVEL=4` opts into AVX-512 builds). XanMod kernels are built with LLVM ThinLTO and have sched_ext and MGLRU enabled.

* **Branches**: `main` = latest stable (default), `lts` = long-term support, `edge` = newest mainline. Chosen at install time or via `XANMOD_BRANCH`.
* **scx_lavd**: the `scx-scheds` package comes from the same repository. A small `scx-lavd.service` starts it, but only while a
  XanMod kernel is running (`ConditionKernelVersion=*xanmod*`). Arguments go in `/etc/default/scx-lavd`. If a sched_ext scheduler
  misbehaves the kernel falls back to its default scheduler; `systemctl disable --now scx-lavd` turns it off for good.
* **Repository pinning**: the repo also ships dkms/llvm/NVIDIA packages. `/etc/apt/preferences.d/50-xanmod` limits it to the kernel
  packages and scx so it can never replace Debian's versions of those.
* **Default boot entry**: XanMod when installed. To make Debian LTS the default, set `DEFAULT_FLAVOR=lts` in `/etc/default/limine-handheld`
  and run `sudo limine-snapper-sync`.
* **Update / retry / add later**: kernels update through normal `apt upgrade`; `sudo install-xanmod` installs it after the fact.
* **DKMS**: XanMod kernels are built with Clang, so out-of-tree modules need `clang lld llvm` installed. Nothing in this installer needs that.
* Not included: ADIOS I/O scheduler, zram-ir and re-swappiness - these are CachyOS patches, not part of XanMod.

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
files/                  scripts installed into the target (limine-snapper-sync, handheld-rollback, install-xanmod, ...)
```
