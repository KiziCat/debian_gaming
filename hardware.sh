#!/usr/bin/env bash
# shellcheck shell=bash
# Hardware detection. Runs on the live system BEFORE installation; the result is written into the
# target as /etc/handheld-installer.env and consumed by chroot/setup.sh.
#
# Exports: HW_CPU_VENDOR HW_X86_LEVEL HW_GPU_AMD HW_GPU_INTEL HW_SYS_VENDOR HW_PRODUCT
#          HW_HANDHELD HW_PKGS (space separated Debian packages: firmware, microcode, VA-API ...)

_dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null || true; }

detect_hardware() {
    local pci usb flags
    pci=$(lspci -nn 2>/dev/null || true)
    usb=$(lsusb 2>/dev/null || true)
    flags=$(grep -m1 '^flags' /proc/cpuinfo || true)
    _has_flag() { grep -qw -- "$1" <<<"$flags"; }

    HW_SYS_VENDOR=$(_dmi sys_vendor)
    HW_PRODUCT=$(_dmi product_name)

    # ---- CPU ----
    case "$(grep -m1 -o 'GenuineIntel\|AuthenticAMD' /proc/cpuinfo || true)" in
        GenuineIntel) HW_CPU_VENDOR=intel ;;
        AuthenticAMD) HW_CPU_VENDOR=amd ;;
        *)            HW_CPU_VENDOR=unknown ;;
    esac
    # x86-64 micro-architecture level used for the CachyOS kernel build (v3 = Haswell/Zen1 and newer)
    if _has_flag avx2 && _has_flag bmi1 && _has_flag bmi2 && _has_flag fma && _has_flag movbe && _has_flag f16c && _has_flag abm; then
        HW_X86_LEVEL=3
    else
        HW_X86_LEVEL=2
    fi

    # ---- GPU (no NVIDIA support on purpose) ----
    HW_GPU_AMD=0; HW_GPU_INTEL=0
    grep -Ei 'vga|3d|display' <<<"$pci" | grep -q '\[1002:' && HW_GPU_AMD=1
    grep -Ei 'vga|3d|display' <<<"$pci" | grep -q '\[8086:' && HW_GPU_INTEL=1
    grep -Ei 'vga|3d|display' <<<"$pci" | grep -q '\[10de:' && warn "NVIDIA GPU detected - this installer ships no NVIDIA driver (nouveau only)."

    # ---- package selection ----
    local -a pkgs=(firmware-linux-free firmware-misc-nonfree)

    case $HW_CPU_VENDOR in
        intel) pkgs+=(intel-microcode thermald) ;;
        amd)   pkgs+=(amd64-microcode) ;;
    esac

    if ((HW_GPU_AMD)); then
        pkgs+=(firmware-amd-graphics libdrm-amdgpu1 mesa-va-drivers mesa-vulkan-drivers radeontop)
    fi
    if ((HW_GPU_INTEL)); then
        pkgs+=(firmware-intel-graphics intel-media-va-driver-non-free mesa-vulkan-drivers intel-gpu-tools)
    fi
    # Unknown GPU (VM, exotic hardware): install the generic Mesa stack
    ((HW_GPU_AMD || HW_GPU_INTEL)) || pkgs+=(mesa-vulkan-drivers mesa-va-drivers)

    # Wi-Fi / Bluetooth by PCI/USB vendor id
    local net; net=$(grep -Ei 'network|wireless|bluetooth' <<<"$pci")$'\n'"$usb"
    grep -q '8086:'        <<<"$net" && pkgs+=(firmware-iwlwifi firmware-intel-misc)
    grep -q '10ec:\|0bda:' <<<"$net" && pkgs+=(firmware-realtek)
    grep -q '14c3:\|0e8d:' <<<"$net" && pkgs+=(firmware-mediatek)
    grep -q '168c:\|0cf3:' <<<"$net" && pkgs+=(firmware-atheros)
    grep -q '17cb:'        <<<"$net" && pkgs+=(firmware-atheros firmware-qcom-soc)
    grep -q '14e4:'        <<<"$net" && pkgs+=(firmware-brcm80211)

    # Audio: Sound Open Firmware covers Intel (Tiger/Alder Lake...) and AMD ACP (Rembrandt/Phoenix...)
    pkgs+=(firmware-sof-signed alsa-ucm-conf)
    grep -qi 'audio' <<<"$pci" && grep -q '8086:' <<<"$(grep -i audio <<<"$pci")" && pkgs+=(firmware-intel-sound)

    # No PCI hits at all (virtual machine?) -> fall back to the full firmware set
    [[ -z $pci ]] && pkgs+=(firmware-linux)

    HW_PKGS=$(printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' ')

    # ---- handheld model ----
    HW_HANDHELD=none
    case "$HW_SYS_VENDOR" in
        ONE-NETBOOK*)  HW_HANDHELD=onexplayer ;;
        AYANEO*)       HW_HANDHELD=ayaneo ;;
        AYN*)          HW_HANDHELD=ayn ;;
        GPD*)          HW_HANDHELD=gpd ;;
        AOKZOE*)       HW_HANDHELD=aokzoe ;;
        Valve*)        HW_HANDHELD=steamdeck ;;
        ASUSTeK*)      [[ $HW_PRODUCT == *Ally* || $HW_PRODUCT == RC7[12]* ]] && HW_HANDHELD=rog-ally ;;
        LENOVO*)       [[ $HW_PRODUCT =~ ^83(E1|L3|N6|N7)$ ]] && HW_HANDHELD=legion-go ;;
        Micro-Star*)   [[ $HW_PRODUCT == Claw* ]] && HW_HANDHELD=msi-claw ;;
    esac

    export HW_CPU_VENDOR HW_X86_LEVEL HW_GPU_AMD HW_GPU_INTEL HW_SYS_VENDOR HW_PRODUCT HW_HANDHELD HW_PKGS
}

print_hardware() {
    info "Machine   : ${HW_SYS_VENDOR:-?} ${HW_PRODUCT:-?}  (handheld profile: $HW_HANDHELD)"
    info "CPU       : $HW_CPU_VENDOR, x86-64-v$HW_X86_LEVEL"
    info "GPU       : AMD=$HW_GPU_AMD Intel=$HW_GPU_INTEL"
    info "Drivers   : $HW_PKGS"
}
