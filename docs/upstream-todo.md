# Upstream fixes to track / submit

Hardware: GPD Win 4 (Ryzen AI 9 HX 370, Strix Halo) + Minisforum DEG1 OCuLink dock + Sapphire RX 9070 XT (Navi48/RDNA4)
OS tested: Bazzite 44 desktop, kernel 6.19.14-ogc1.1.fc44
Bug confirmed also with Nvidia eGPU on Bazzite → not driver-specific, kernel-level issue.

---

## 1. [KERNEL] PCI quirk: disable D3cold for GPD Win 4 OCuLink slot

**Status:** Not submitted  
**Priority:** High — root cause of `device lost from bus` crashes  
**Workaround:** `/etc/udev/rules.d/99-egpu-no-d3cold.rules`

### Problem

When the eGPU (or PCIe switch in the DEG1 dock) enters D3cold, the PCIe link drops
and the device disappears from the bus. On resume, the driver fails to recover:

```
amdgpu 0000:66:00.0: device lost from bus!
amdgpu 0000:66:00.0: SMU: response:0xFFFFFFFF for index:18 ...
amdgpu 0000:66:00.0: Failed to export SMU metrics table!
```

OCuLink does not support Surprise removal (`Surprise-` in lspci). The kernel should
not allow D3cold on slots without this capability unless the firmware explicitly
guarantees safe power cycling. Windows does not allow D3cold on this slot.

### PCIe chain concerned

```
00:03.1  AMD Strix Halo GPP Bridge           (root port, ASPM not supported)
64:00.0  AMD Navi 10 XL Upstream Port        vendor=0x1002 device=0x1478
65:00.0  AMD Navi 10 XL Downstream Port      vendor=0x1002 device=0x1479
66:00.0  AMD Navi 48 RX 9070 XT             vendor=0x1002 device=0x7550
66:00.1  AMD Navi 48 Audio                  vendor=0x1002 device=...
```

Link runs at PCIe 4.0 x4 (16GT/s, downgraded from switch's 32GT/s x16 capability).

### Proposed fix

Add a quirk in `drivers/pci/quirks.c` using `PCI_DEV_FLAGS_NO_D3COLD` for the
PCIe switch upstream/downstream port device IDs (0x1478/0x1479), similar to
existing eGPU Thunderbolt quirks.

Alternatively, the GPD Win 4 ACPI tables should set `_PR3` absence or `_S0W`
appropriately for the OCuLink slot to prevent the kernel from enabling D3cold.

### Where to file

- Linux kernel: `drivers/pci/quirks.c` — submit to `linux-pci@vger.kernel.org`
- OGC kernel: https://github.com/OpenGamingCollective/linux/issues

---

## 2. [KERNEL] amdgpu runtime PM resume: "Cannot find any crtc or sizes" on OCuLink

**Status:** Not submitted  
**Priority:** Medium — causes display pipeline failure after GPU runtime PM resume  
**Workaround:** `amdgpu.runpm=0` kernel parameter

### Problem

When the amdgpu driver resumes the eGPU from runtime PM suspend, the Display Core
fails to re-enumerate CRTCs:

```
amdgpu 0000:66:00.0: [drm] Cannot find any crtc or sizes
amdgpu 0000:66:00.0: [drm] Failed to setup vendor infoframe on connector HDMI-A-2: -22
```

This leaves the display pipeline in a broken state. The GPU ring then times out
13 minutes later as kwin_wayland submits flip commands to a broken display pipeline.

### Where to file

- freedesktop drm/amd: https://gitlab.freedesktop.org/drm/amd/-/issues
- Search for: RDNA4 OCuLink runtime PM resume CRTC

---

## 3. [KWIN] Direct scanout flip hang on RDNA4 + non-native PCIe (OCuLink)

**Status:** Not submitted  
**Priority:** Medium — causes ring gfx_0.0.0 timeout via kwin_wayland  
**Workaround:** `KWIN_DRM_NO_DIRECT_SCANOUT=1`

### Problem

With direct scanout enabled (default), kwin_wayland submits exactly 2 GFX ring
commands (render + flip) that never complete. The flip_done signal from the display
engine is never received, causing the GFX ring watchdog to fire after 60 seconds.

Signature in all observed crashes:
```
amdgpu: ring gfx_0.0.0 timeout, signaled seq=N, emitted seq=N+2
amdgpu:  Process kwin_wayland pid XXXX thread kwin_wayla:cs0 pid YYYY
```

The gap is always exactly 2. The GPU is always at minimal clock (14-60 MHz SCLK)
when the watchdog fires, suggesting the flip path does not properly wake the GFX
block before waiting for flip completion.

Disabling direct scanout (`KWIN_DRM_NO_DIRECT_SCANOUT=1`) routes presentation
through an intermediate buffer, bypassing the problematic flip path.

### Where to file

- KWin: https://bugs.kde.org — component: kwin, keyword: direct scanout RDNA4
- freedesktop drm/amd: may also be an amdgpu DC flip path issue on OCuLink

---

## 4. [REFERENCE] Related upstream issues and commits

- freedesktop drm/amd flip_done timeout tracking issues:
  - #4894, #4717, #4725, #4517, #4806 (closed by f377ea0561c9 — already in 6.19.14)
- commit f377ea0561c9: `Revert "drm/amd/display: pause the workload setting in dm"`
  — **already present in kernel 6.19.14** (confirmed in OGC tree)
  — was initially suspected but not the root cause for OCuLink-specific crashes

## 5. [KERNEL/FIRMWARE] MES v12 firmware lockup under full Vulkan load on OCuLink

**Status:** Not submitted
**Priority:** High — causes CPU hard lockup requiring forced reboot
**Workaround:** None confirmed. `amdgpu.reset_method=2` is a candidate to prevent CPU lockup.

### Problem

Under full Vulkan load (100% GPU, ~3333 MHz SCLK), the RDNA4 Unified MES firmware
(`mes_v12_0_0`) becomes completely unresponsive. All subsequent attempts to reset the
GPU (ring reset, full MODE1 reset) stall waiting for MES to respond to RESET and
REMOVE_QUEUE messages. The GPU reset code spins in a kernel ioctl with no timeout,
causing CPU hard lockup and requiring forced reboot.

Observed twice with two different games (Enshrouded, PEAK.exe) both running via Proton.

### Failure sequence

```
amdgpu: ring gfx_0.0.0 timeout (Vulkan submission thread, 100% GPU load)
amdgpu: MES(1) failed to respond to msg=RESET
amdgpu: Ring gfx_0.0.0 reset failed
amdgpu: GPU reset begin!
amdgpu: MES(1) failed to respond to msg=REMOVE_QUEUE  (×6)
watchdog: CPU10: Watchdog detected hard LOCKUP
watchdog: BUG: soft lockup - CPU#0 stuck for 22s!
```

### Key parameters

- `amdgpu.uni_mes=1` is the default for RDNA4 (Unified MES enabled)
- `amdgpu.reset_method=-1` (auto) tries MES-based reset first, deadlocks if MES is dead
- `amdgpu.reset_method=2` (mode1) is a hardware bus reset that may bypass MES teardown
- `linux-firmware-20260410-1.fc44.noarch` is installed (latest available)

### Where to file

- freedesktop drm/amd: https://gitlab.freedesktop.org/drm/amd/-/issues
  Search for: RDNA4 MES firmware lockup OCuLink hard lockup REMOVE_QUEUE
- Include: full journal from 22:12:56 to 22:14:11 from crash 20260507-221258

---

## 6. [INVESTIGATE] Correctable PCIe errors on OCuLink chain

`DevSta: CorrErr+` on 00:03.1 (root port) and 64:00.0 (PCIe switch).
`DevSta: UnsupReq+` on 64:00.0.

These persistent errors suggest signal integrity issues on the OCuLink link.
The link uses retimers (`Retimer+ 2Retimers+` on 00:03.1). If the retimers
are not locking correctly at 16GT/s, correctable errors accumulate and may
eventually trigger link resets. Worth monitoring with `rasdaemon` or AER logging.
