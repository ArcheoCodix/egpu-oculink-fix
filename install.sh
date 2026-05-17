#!/bin/bash
# install.sh — Apply eGPU OCuLink workarounds for GPD Win 4 + Minisforum DEG1.
# Safe on Bazzite/rpm-ostree: only touches /etc and rpm-ostree kargs.
# Run check.sh first to verify these workarounds are still needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== eGPU OCuLink workaround installer ==="
echo ""

# ─── Pre-flight checks ────────────────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
    echo "Do not run as root. sudo will be used where needed." >&2
    exit 1
fi

echo "[*] Checking if workarounds are still needed..."
if bash "$SCRIPT_DIR/check.sh"; then
    NEEDED=true
else
    echo ""
    echo "All workarounds appear to be covered upstream. Aborting installation."
    echo "If you still want to install, run the steps manually."
    exit 0
fi

echo ""
echo "[*] Applying workarounds..."
echo ""

# ─── 1. D3cold udev rule ──────────────────────────────────────────────────────
UDEV_DEST="/etc/udev/rules.d/99-egpu-no-d3cold.rules"
echo "[1/3] D3cold udev rule -> $UDEV_DEST"

if [ -f "$UDEV_DEST" ]; then
    echo "      Already installed — skipping"
else
    sudo install -m 644 "$SCRIPT_DIR/udev/99-egpu-no-d3cold.rules" "$UDEV_DEST"
    sudo udevadm control --reload-rules
    # Apply immediately to running system (root port first, then downstream chain)
    for dev in 0000:00:03.1 0000:64:00.0 0000:65:00.0 0000:66:00.0 0000:66:00.1; do
        if [ -f /sys/bus/pci/devices/$dev/d3cold_allowed ]; then
            echo 0 | sudo tee /sys/bus/pci/devices/$dev/d3cold_allowed > /dev/null
        fi
    done
    echo "      Installed and applied immediately"
fi

# ─── 2. amdgpu.runpm=0 kernel argument ───────────────────────────────────────
echo "[2/3] amdgpu.runpm=0 kernel argument"

if cat /proc/cmdline | grep -q "amdgpu.runpm=0"; then
    echo "      Already active in current boot"
elif rpm-ostree kargs 2>/dev/null | grep -q "amdgpu.runpm=0"; then
    echo "      Already staged for next boot"
else
    if command -v rpm-ostree &>/dev/null; then
        rpm-ostree kargs --append=amdgpu.runpm=0
        echo "      Staged for next boot (rpm-ostree)"
    else
        echo "      WARNING: rpm-ostree not found — add amdgpu.runpm=0 to kernel cmdline manually"
    fi
fi

# ─── 3. KWIN_DRM_NO_DIRECT_SCANOUT ───────────────────────────────────────────
KWIN_ENV_DIR="$HOME/.config/plasma-workspace/env"
KWIN_ENV_FILE="$KWIN_ENV_DIR/kwin.sh"
echo "[3/3] KWIN_DRM_NO_DIRECT_SCANOUT=1 -> $KWIN_ENV_FILE"

if [ -f "$KWIN_ENV_FILE" ] && grep -q "KWIN_DRM_NO_DIRECT_SCANOUT" "$KWIN_ENV_FILE"; then
    echo "      Already installed — skipping"
else
    mkdir -p "$KWIN_ENV_DIR"
    echo 'export KWIN_DRM_NO_DIRECT_SCANOUT=1' > "$KWIN_ENV_FILE"
    chmod +x "$KWIN_ENV_FILE"
    echo "      Installed (effective after session restart)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  - Reboot to fully apply amdgpu.runpm=0"
echo "  - Log out and back in to activate KWIN_DRM_NO_DIRECT_SCANOUT=1"
echo "  - Run check.sh after a kernel upgrade to see if workarounds can be removed"
echo ""
echo "See docs/upstream-todo.md for the proper upstream fixes to track."
