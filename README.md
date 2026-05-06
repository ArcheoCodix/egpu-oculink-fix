# eGPU OCuLink workarounds for Linux

Workarounds for eGPU instability on GPD Win 4 + Minisforum DEG1 (OCuLink) running
Bazzite/Fedora. Likely applicable to other OCuLink eGPU setups on Linux.

**Hardware tested:**
- GPD Win 4 (Ryzen AI 9 HX 370 / Strix Halo)
- Minisforum DEG1 OCuLink dock
- Sapphire RX 9070 XT (Navi 48 / RDNA4)

**Note:** PCIe power management issues on OCuLink causing instability have also
been observed on this system with an Nvidia eGPU, suggesting the D3cold/power
state problem is not specific to the AMD driver.

**Symptoms fixed:**
1. `ring gfx_0.0.0 timeout` / kwin_wayland freeze during desktop use
2. `device lost from bus` / eGPU disappearing from PCIe bus at idle

**Not fixed here:**
- GPU hang at full load during gaming (separate issue, possibly Proton/RDNA4 driver)

## Quick start

```bash
# Check if workarounds are still needed on your system
bash check.sh

# Install everything
bash install.sh

# Then reboot and log out/in
```

## What gets installed

| Workaround | File | Effect |
|-----------|------|--------|
| D3cold disabled | `/etc/udev/rules.d/99-egpu-no-d3cold.rules` | Prevents eGPU from vanishing off PCIe bus |
| kwin direct scanout disabled | `~/.config/plasma-workspace/env/kwin.sh` | Fixes kwin_wayland ring timeout |
| amdgpu runtime PM disabled | rpm-ostree kargs (`amdgpu.runpm=0`) | Prevents broken DC resume after GPU idle |

## Documentation

- [Full crash analysis and methodology](docs/crash-analysis.md) — detailed logs,
  what was observed, what was ruled out, open questions
- [Upstream fixes to track/submit](docs/upstream-todo.md) — proper kernel/kwin
  fixes, where to file issues, proposed patches

## Checking if workarounds are obsolete

Run `bash check.sh` after a kernel or kwin upgrade. The script verifies whether
each workaround is still needed or has been superseded by an upstream fix.

## Uninstalling

```bash
# Remove D3cold rule
sudo rm /etc/udev/rules.d/99-egpu-no-d3cold.rules
sudo udevadm control --reload-rules

# Remove kwin env
rm ~/.config/plasma-workspace/env/kwin.sh

# Remove kernel arg
rpm-ostree kargs --delete=amdgpu.runpm=0
```
