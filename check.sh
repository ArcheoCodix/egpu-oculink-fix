#!/bin/bash
# check.sh — Verify if workarounds are still needed on this system.
# Run this before installing, or after a kernel/kwin upgrade.
# Exit 0 = at least one workaround is still needed.
# Exit 1 = all workarounds appear covered by upstream fixes.

set -euo pipefail

KERNEL=$(uname -r)
OK="\e[32m[OK]\e[0m"
WARN="\e[33m[NEEDED]\e[0m"
INFO="\e[34m[INFO]\e[0m"

echo -e "\n=== eGPU OCuLink workaround check — kernel $KERNEL ===\n"

NEEDED=0

# ─── 1. D3cold — kernel quirk for OCuLink slot ───────────────────────────────
echo -e "$INFO Check 1: D3cold quirk for OCuLink PCIe chain"

# The upstream fix is a PCI quirk in drivers/pci/quirks.c marking
# the GPD Win 4 OCuLink slot as PCI_DEV_FLAGS_NO_D3COLD.
# Until that quirk exists, d3cold_allowed defaults to 1 at boot
# and our udev rule is needed.

D3COLD_FIXED=true
for dev in 0000:64:00.0 0000:65:00.0 0000:66:00.0 0000:66:00.1; do
    if [ ! -f /sys/bus/pci/devices/$dev/d3cold_allowed ]; then
        continue  # device not present (eGPU not connected)
    fi
    # Check if the value is 0 BEFORE our udev rule could have set it.
    # We detect our rule's presence to distinguish kernel fix vs our workaround.
    if [ -f /etc/udev/rules.d/99-egpu-no-d3cold.rules ]; then
        # Our rule is installed — can't tell if kernel would default to 0.
        # Check the kernel version as a proxy (no known upstream fix yet).
        D3COLD_FIXED=false
        break
    fi
    val=$(cat /sys/bus/pci/devices/$dev/d3cold_allowed)
    if [ "$val" != "0" ]; then
        D3COLD_FIXED=false
        break
    fi
done

if $D3COLD_FIXED; then
    echo -e "  $OK D3cold appears to be handled upstream (d3cold_allowed=0 without udev rule)"
else
    echo -e "  $WARN D3cold udev rule is needed (no upstream kernel quirk for GPD Win 4 OCuLink)"
    echo -e "       Upstream fix: PCI_DEV_FLAGS_NO_D3COLD quirk in drivers/pci/quirks.c"
    NEEDED=1
fi

# ─── 2. amdgpu.runpm — runtime PM causing Cannot-find-crtc on eGPU resume ────
echo -e "\n$INFO Check 2: amdgpu.runpm=0 (runtime PM resume broken on OCuLink)"

RUNPM_PARAM=$(modinfo amdgpu 2>/dev/null | grep "^parm.*runpm" || true)
if [ -z "$RUNPM_PARAM" ]; then
    echo -e "  $OK amdgpu.runpm parameter no longer exists — runtime PM likely fixed upstream"
else
    CURRENT_KARGS=$(cat /proc/cmdline)
    if echo "$CURRENT_KARGS" | grep -q "amdgpu.runpm=0"; then
        echo -e "  $WARN amdgpu.runpm=0 is active in kernel cmdline"
        echo -e "       Upstream fix: OCuLink runtime PM resume (Cannot find any crtc or sizes)"
        NEEDED=1
    else
        echo -e "  $OK amdgpu.runpm=0 is not set — either fixed upstream or not yet applied"
    fi
fi

# ─── 3. KWIN_DRM_NO_DIRECT_SCANOUT — flip_done hang on RDNA4+OCuLink ─────────
echo -e "\n$INFO Check 3: KWIN_DRM_NO_DIRECT_SCANOUT=1 (direct scanout flip hang)"

KWIN_ENV_FILE="$HOME/.config/plasma-workspace/env/kwin.sh"
if [ ! -f "$KWIN_ENV_FILE" ] || ! grep -q "KWIN_DRM_NO_DIRECT_SCANOUT" "$KWIN_ENV_FILE"; then
    echo -e "  $OK KWIN_DRM_NO_DIRECT_SCANOUT workaround not installed"
else
    # No known upstream kwin version that fixes direct scanout on RDNA4+OCuLink yet.
    # When fixed, this check should compare kwin version against the fix version.
    KWIN_VER=$(kwin_wayland --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    echo -e "  $WARN KWIN_DRM_NO_DIRECT_SCANOUT=1 is active (kwin $KWIN_VER)"
    echo -e "       Upstream fix: kwin direct scanout path for RDNA4 on non-native PCIe"
    NEEDED=1
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ $NEEDED -eq 1 ]; then
    echo -e "Result: \e[33mWorkarounds are still needed on this system.\e[0m"
    exit 0
else
    echo -e "Result: \e[32mAll workarounds appear to be covered by upstream fixes.\e[0m"
    echo -e "        You may remove the installed workarounds."
    exit 1
fi
