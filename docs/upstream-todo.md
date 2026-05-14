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

## 5. [FIRMWARE] MES v12 null pointer dereference at offset 0x705c (RDNA4)

**Status:** Submitted — https://gitlab.freedesktop.org/drm/amd/-/issues/5274
**Priority:** Critical — root cause of all Type C crashes; causes GPU hang + occasional CPU hard lockup
**Workaround:** None. Requires firmware fix from AMD.

### Root cause — confirmed

The Unified MES firmware (`gc_12_0_0_uni_mes.bin`, **version 0x89**) crashes at a
fixed instruction under sustained GPU load, always at the same point:

```
[gfxhub] Page fault observed
Faulty page starting at address: 0x0000000000000000
Protection fault status register: 0x0
regCP_MES_INSTR_PNTR  0x0000705c   ← always the same instruction offset
regCP_MES_HEADER_DUMP 0xdef0def0   ← repeated 8× with incrementing low nibble
```

The MES firmware dereferences a null pointer (GPU VA 0x0) at code offset 0x705c.
This triggers a GFXHUB page fault that permanently halts the MES microcontroller.
All driver messages to MES (RESET, REMOVE_QUEUE) subsequently time out.

**Confirmed in 3 independent crashes across 2 kernel boots, 3 different offenders
(Enshrouded, PEAK.exe, kwin_wayland), always the same register state.**

### Observed crashes

| Crash | Offender | Recovery |
|-------|----------|----------|
| 20260507-001329 | enshrouded.exe | Failed (MODE1 incomplete) |
| 20260507-221258 | PEAK.exe | Failed (CPU hard lockup) |
| 20260508-014526 | kwin_wayland* | Succeeded (MODE1 reset) |

*kwin_wayland appeared as offender while GPU was at 100% load from a game session —
the logged offender is not the cause of the MES crash.

### Failure sequence

```
[gfxhub] Page fault at 0x0 → MES microcontroller halts at offset 0x705c
60s later: ring gfx_0.0.0 timeout (watchdog fires, logs whatever process last submitted)
amdgpu: MES(1) failed to respond to msg=RESET
amdgpu: Ring gfx_0.0.0 reset failed
amdgpu: GPU reset begin!
amdgpu: MES(1) failed to respond to msg=REMOVE_QUEUE  (×5–6)
→ sometimes: CPU hard lockup in reset ioctl spin loop
→ sometimes: MODE1 reset succeeds and GPU recovers
```

### Key data for bug report

- Firmware file: `gc_12_0_0_uni_mes.bin` (also symlinked as `gc_12_0_1_uni_mes.bin`)
- Firmware version: `MES feature version: 1, fw version: 0x00000089`
- MES instruction pointer at crash: `regCP_MES_INSTR_PNTR = 0x0000705c` (consistent)
- Faulting GPU address: `0x0000000000000000` (null pointer dereference)
- Header dump FIFO: `0xdef0def0..0xdef7def7` (8 values, consistent)
- linux-firmware: `20260410-1.fc44` (latest available)
- `amdgpu.mes_log_enable=1` is active but MES log is not dumped to journal or coredump
  text — log buffer exists in VRAM but extraction mechanism not implemented in this
  kernel version's coredump path.

### Where to file

- freedesktop drm/amd: **Filed — https://gitlab.freedesktop.org/drm/amd/-/issues/5274**
- Attached: coredump.bin from crash-20260507-221258 + journal sections from crashes 1 and 2
- Update comment (2026-05-14): https://gitlab.freedesktop.org/drm/amd/-/issues/5274#note_3467811
  (firmware bb95ff5c NOT fixing the crash; D3cold root port finding; DCN no-recovery; mes_dead suggestion)

### Firmware update — fix NOT confirmed

`amd-gpu-firmware 20260410-1.fc44.p1` installed 2026-05-10 via rpm-ostree local override.
`gc_12_0_0_uni_mes.bin` updated to 727,680 bytes (upstream commit `bb95ff5c`, 2026-05-06).
**Status: le fix ne fonctionne pas sur ce hardware.**
Le firmware p1 rapporte `fw version: 0x89` en interne et crashe à l'offset `0x705c` —
identique aux crashs ogc1. Le test FurMark 30 min était insuffisant ; Enshrouded déclenche
le crash en moins de 30 min. Signalé sur freedesktop#5274.

### Workarounds tested (all ineffective for Type C)

- `amdgpu.uni_mes=0` — legacy MES crashes at 0xa2f within ~1 min. Worse than uni_mes.
- `amdgpu.pg_mask=0` — prevents GPU init, system unbootable. Too aggressive.

---

## 6. [NOTE] Patch chirurgical d'un initramfs sur Bazzite immutable

Pour modifier un seul fichier dans l'initramfs sans rebuild dracut complet (évite les modules manquants) :

```bash
# 1. Extraire
lsinitrd --unpack --directory /tmp/initrd-extract /boot/initramfs-backup.img

# 2. Modifier le fichier voulu (ex: firmware)
cp nouveau_firmware.bin.xz /tmp/initrd-extract/usr/lib/firmware/amdgpu/gc_12_0_0_uni_mes.bin.xz

# 3. Détecter le format de compression de l'original
file /boot/initramfs-backup.img  # zstd ou xz

# 4. Recompresser (zstd = format Bazzite)
cd /tmp/initrd-extract
find . | cpio --create --format=newc | zstd > /boot/ostree/.../initramfs-new.img
```

Avantage : on part de l'image fonctionnelle connue → zéro risque de module manquant.

---

## 7. [INVESTIGATE] Correctable PCIe errors on OCuLink chain

`DevSta: CorrErr+` on 00:03.1 (root port) and 64:00.0 (PCIe switch).
`DevSta: UnsupReq+` on 64:00.0.

These persistent errors suggest signal integrity issues on the OCuLink link.
The link uses retimers (`Retimer+ 2Retimers+` on 00:03.1). If the retimers
are not locking correctly at 16GT/s, correctable errors accumulate and may
eventually trigger link resets. Worth monitoring with `rasdaemon` or AER logging.
