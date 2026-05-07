# Crash analysis: eGPU OCuLink on Linux (GPD Win 4 + Minisforum DEG1 + RX 9070 XT)

## Hardware context

| Component | Detail |
|-----------|--------|
| Host | GPD Win 4 |
| APU | AMD Ryzen AI 9 HX 370 (Strix Halo) |
| iGPU | AMD Radeon 780M (Navi 33 / RDNA3, PCI 0000:67:00.0, device 150e) |
| eGPU | Sapphire RX 9070 XT (Navi 48 / RDNA4, PCI 0000:66:00.0, device 7550) |
| Dock | Minisforum DEG1 (OCuLink) |
| Connection | OCuLink → PCIe 4.0 x4 (16GT/s, with retimers) |
| OS (test) | Bazzite 44 desktop, kernel 6.19.14-ogc1.1.fc44 (external NVMe) |
| OS (main) | Bazzite deck stable, kernel 6.17.7-ba29 (internal SSD) |

**Key note:** PCIe power management issues causing eGPU instability on this
OCuLink setup were also observed with an Nvidia eGPU. The specific symptoms
differed, but both involved power reduction triggering connectivity problems.
This suggests the OCuLink power state handling is a platform-level issue,
not specific to the amdgpu driver.

**Key note:** The problem does not occur on Windows on the same hardware.

---

## PCIe topology

```
CPU (00:03.1 — AMD Strix Halo GPP Bridge, PCIe 4.0 x4, ASPM not supported)
  └── 64:00.0 — AMD Navi 10 XL Upstream Port   [vendor 1002, device 1478]
                 PCIe switch in DEG1 dock
                 LnkCap: 32GT/s x16 | LnkSta: 16GT/s x4 (downgraded, expected for OCuLink)
                 LnkCtl: ASPM Disabled
                 DevSta: CorrErr+ UnsupReq+  ← persistent PCIe errors
        └── 65:00.0 — AMD Navi 10 XL Downstream Port  [vendor 1002, device 1479]
                      LnkCap: ASPM L1 | LnkCtl: ASPM Disabled
                      Surprise- (no surprise removal support)
               └── 66:00.0 — Navi 48 RX 9070 XT  (eGPU, VGA)
                   66:00.1 — Navi 48 Audio
```

ASPM is **already disabled** on all links in this chain. The `CorrErr+` and
`UnsupReq+` on 64:00.0 are historical flags (persistent across boots) suggesting
accumulated signal integrity events on the OCuLink link.

---

## Crash taxonomy

Five crashes were captured across multiple boots. They fall into two distinct types.

---

### Type A — GFX ring timeout via kwin_wayland (crashes 1–4)

**Observed in:** crashes 20260505-233258, 20260506-002444, 20260506-212420, 20260506-224307

#### Signature

```
amdgpu 0000:66:00.0: ring gfx_0.0.0 timeout, signaled seq=N, emitted seq=N+2
amdgpu 0000:66:00.0:  Process kwin_wayland pid XXXX thread kwin_wayla:cs0 pid YYYY
amdgpu 0000:66:00.0: Starting gfx_0.0.0 ring reset
amdgpu 0000:66:00.0: Ring gfx_0.0.0 reset succeeded
amdgpu 0000:66:00.0: [drm] device wedged, but recovered through reset
amdgpu 0000:66:00.0: Fence fallback timer expired on ring sdma1  (×2)
```

- Offender: always `kwin_wayland` (Wayland compositor)
- Fence gap: always exactly **2** (one render command + one flip/present command)
- Recovery: always succeeded (no full freeze)
- Timing: 7–19 minutes after boot, while desktop is in use (no game running)

#### GPU power state at crash time

| Crash | SCLK | VDDGFX | Notes |
|-------|------|--------|-------|
| #1 (23:32) | — | — | pm_info not sampled |
| #2 (00:24) | — | — | pm_info not sampled |
| #3 (21:24) | 60 MHz | 220 mV | gfxoff=0 (invalid param, ignored) |
| #4 (22:43) | 14 MHz | 110 mV | gfxoff=0 still ignored |

The GPU is effectively at minimum or zero clock when the ring timeout fires.
The GFX block appears to be in a deep idle state (GFXOFF or equivalent) and
does not wake up when kwin_wayland submits its flip commands.

#### fence_info analysis

Captured after ring reset — all rings show signaled=emitted (synced post-reset).
At crash time, the journal records:
- gfx_0.0.0: gap of 2 (render + flip commands submitted, neither completed)
- sdma1: also shows gap in crash #3 (secondary effect of ring hang)
- mes_3.1.0: gap of 1 in crash #3 (MES firmware scheduler also stalled)

The MES (Micro Engine Scheduler) stalling alongside the GFX ring suggests the
problem is deeper than just the display flip path — the GPU's internal command
scheduler may not be waking from idle correctly.

#### Display pipeline errors at boot (crash #2 only — after runtime PM resume)

```
amdgpu 0000:66:00.0: [drm] Cannot find any crtc or sizes  (×2)
amdgpu 0000:66:00.0: [drm] Failed to setup vendor infoframe on connector HDMI-A-2: -22
```

In crash #2, the journal shows the GPU performing a runtime PM resume (`PSP is resuming`)
rather than a cold boot. The DC (Display Core) fails to re-enumerate CRTCs during
this resume. Despite this, kwin_wayland continues running and submitting render jobs,
which leads to the ring timeout 13 minutes later.

These display errors are absent from crashes #1, #3, #4 (cold boots).

#### MST/DSC event at boot (consistent across all crashes)

```
[drm] pre_validate_dsc:1742 MST_DSC crtc[1] needs mode_change
```

Present in every crash journal at boot time. The DEG1 dock exposes a DisplayPort
MST hub, and DSC (Display Stream Compression) is being negotiated at init.
This may add complexity to the flip/present path but has not been confirmed
as a direct cause.

#### Hypothesis for Type A crashes

kwin_wayland submits a render command and a flip/present command to the GFX ring.
The flip completion requires the DCN (Display Core Next) to signal `flip_done`
via a vblank interrupt. If the GPU's GFX block is in deep idle (GFXOFF) when the
flip is submitted, and the wakeup from idle does not complete correctly before
the flip command executes, the command blocks indefinitely waiting for resources
that are unavailable. The 60-second GFX ring watchdog then fires.

The exact mechanism may be:
- GFXOFF not waking on flip submission (power state management bug)
- DC/DCN not signaling vblank correctly via OCuLink (interrupt delivery issue)
- A race in the vblank_control_worker that incorrectly allows idle optimizations
  at the wrong time (pre-f377ea0561c9, but this commit is already in 6.19.14)

**What we ruled out:**
- `f377ea0561c9` (Revert "drm/amd/display: pause the workload setting in dm") —
  initially suspected as the root cause. Confirmed present in OGC kernel 6.19.14
  by inspecting source at tag v6.19.14-ogc1: `amdgpu_dm_crtc.c` does NOT contain
  `pause_power_profile` calls. The 5 occurrences found via `strings amdgpu.ko`
  are the function definition and other call sites, not the CRTC file.
- Bus_lock CPU traps from Steam — 71,000+ callbacks suppressed in crash #1.
  Adding `split_lock_detect=off` (later found invalid for this kernel) did not
  prevent subsequent crashes.
- Runtime PM (`amdgpu.runpm=0`) — helped with the CRTC resume error but did not
  prevent Type A crashes.
- GFXOFF (`amdgpu.gfxoff=0`) — parameter does not exist in this kernel
  (confirmed: `amdgpu: unknown parameter 'gfxoff' ignored`). `amdgpu.pg_mask=0`
  exists but caused GPU initialization failure and unbootable system.

**Effective mitigation:** `KWIN_DRM_NO_DIRECT_SCANOUT=1` bypasses the direct
scanout / flip path in kwin, routing presentation through an intermediate buffer.
After enabling this, kwin_wayland no longer appears as the crash offender.

---

### Type B — eGPU lost from PCIe bus (crash 5)

**Observed in:** crash 20260506-232111

#### Signature

```
amdgpu 0000:66:00.0: device lost from bus!
amdgpu 0000:66:00.0: SMU: response:0xFFFFFFFF for index:18 param:0x00000005 message:TransferTableSmu2Dram
amdgpu 0000:66:00.0: Failed to export SMU metrics table!
amdgpu 0000:66:00.0: device lost from bus!   (repeated)
amdgpu 0000:66:00.0: ring gfx_0.0.0 timeout, signaled seq=46803, emitted seq=46805
amdgpu 0000:66:00.0: Ring gfx_0.0.0 reset succeeded
amdgpu 0000:66:00.0: [drm] device wedged, but recovered through reset
```

- Offender: `enshrouded.exe` (game via Proton/Wine), not kwin_wayland
- GPU state at crash: **SCLK=0 MHz, VDDGFX=40 mV** — essentially powered off
- `SMU: response=0xFFFFFFFF` — the SMU (System Management Unit) is unreachable,
  indicating the PCIe link to the GPU is fully down
- The `device lost from bus` precedes the ring timeout by ~2 seconds

#### Context

This crash occurred with `KWIN_DRM_NO_DIRECT_SCANOUT=1` active (Type A mitigated)
and while a game was running but idle (user not interacting). The GPU was at
minimum power state, and the PCIe link dropped instead of just the ring hanging.

#### Root cause: D3cold over OCuLink

`d3cold_allowed` was confirmed as `1` (enabled) for all four devices in the OCuLink
chain (64:00.0, 65:00.0, 66:00.0, 66:00.1). D3cold is a complete power-off state
for PCIe devices. When a device enters D3cold, it is removed from the PCIe bus.

OCuLink does not support Surprise removal (`Surprise-` confirmed via lspci on
65:00.0). Without Surprise removal support, the kernel has no safe mechanism to
recover a device that has vanished from the bus due to power cycling.

On Windows, D3cold is not permitted for this OCuLink slot (either via driver
policy or platform ACPI tables). Linux does not have a quirk for this hardware
combination and allows D3cold by default.

The `SMU: response=0xFFFFFFFF` is definitive: all-ones response means no PCIe
transaction completed — the device is physically absent from the bus at that point.

**Note:** `amdgpu.runpm=0` was active during this crash. Runtime PM (`runpm`)
controls the amdgpu driver's own power state transitions, but D3cold can also
be triggered by the parent PCIe bridge power management, independently of the
device driver. This explains why runpm=0 did not prevent the bus loss.

**Note:** ASPM is already disabled on all links in the chain (`LnkCtl: ASPM Disabled`
on 64:00.0 and 65:00.0). Disabling ASPM globally (`pcie_aspm=off`) would therefore
have no effect and was removed from the staged kargs.

**Effective mitigation:** Setting `d3cold_allowed=0` via udev rules on all four
devices in the OCuLink PCIe chain. This prevents any of them from entering D3cold.

---

### Type C — MES firmware lockup under full load (crashes 6–7)

**Observed in:** crashes 20260507-001329 (Enshrouded), 20260507-221258 (PEAK.exe)

#### Signature

```
amdgpu 0000:66:00.0: ring gfx_0.0.0 timeout, signaled seq=N, emitted seq=N+2
amdgpu 0000:66:00.0:  Process <game>.exe pid XXXX thread Vulkan Submissi pid YYYY
amdgpu 0000:66:00.0: Starting gfx_0.0.0 ring reset
amdgpu 0000:66:00.0: MES(1) failed to respond to msg=RESET
amdgpu 0000:66:00.0: failed to reset legacy queue
amdgpu 0000:66:00.0: reset via MES failed and try pipe reset -110
amdgpu 0000:66:00.0: The CPFW hasn't support pipe reset yet.
amdgpu 0000:66:00.0: Ring gfx_0.0.0 reset failed
amdgpu 0000:66:00.0: GPU reset begin!. Source:  1
amdgpu 0000:66:00.0: MES(1) failed to respond to msg=REMOVE_QUEUE  (×6)
amdgpu 0000:66:00.0: failed to unmap legacy queue  (×6)
watchdog: CPU10: Watchdog detected hard LOCKUP on cpu 10
watchdog: BUG: soft lockup - CPU#0 stuck for 22s! [Thread (pooled):YYYY]
```

- Offenders: `enshrouded.exe` (crash 6), `PEAK.exe` (crash 7) — two different games
- Offending thread: `Vulkan Submissi` in crash 7 — a Vulkan submission thread
- GPU state at crash: **SCLK ~3333–3342 MHz, VDDGFX=1174 mV, GPU Load=100%**
- Fence gap: always exactly **2** (same as Type A)
- MES ring (mes_3.1.0): gap of 1 (signaled=0x35, emitted=0x36 in crash 7)
- No `device lost from bus` — OCuLink link stable (D3cold fix effective)
- **Recovery failed** in both cases

#### Failure cascade

1. `ring gfx_0.0.0` fires the 60-second watchdog
2. Ring reset attempts to use MES firmware (mes_v12, RDNA4's Unified MES) → MES does not respond
3. Pipe reset attempted as fallback → `The CPFW hasn't support pipe reset yet` (no CPFW pipe reset on RDNA4)
4. Ring reset fails → full GPU reset (MODE1) initiated
5. GPU reset attempts to unmap all queues via MES (REMOVE_QUEUE) → 6 consecutive timeouts
6. GPU reset code spins waiting for MES → CPU thread stuck in `ioctl()` for >20s
7. **CPU hard lockup** (CPU 10) and **CPU soft lockup** (CPU 0) — system completely frozen
8. Forced power-off required

The crash in the kernel is not the ring hang itself but the subsequent GPU reset code
spinning in an ioctl with no way out. The MES firmware (mes_v12_0) is completely
unresponsive and blocks both the ring reset and the MODE1 GPU reset.

#### Steam bus_lock precursor

Both Type C crashes are preceded by a Steam `CHTTPClientThre` / `CJobMgr` bus_lock storm:

| Crash | Duration | Callbacks suppressed | Gap before crash |
|-------|----------|---------------------|-----------------|
| #6 (Enshrouded) | ~6 min | ~71,000 | 7 min |
| #7 (PEAK.exe) | ~7 min (21:59–22:06) | 169,226 | 6 min |

The bus_lock storm ends several minutes before the ring hang — the traps are not the
direct cause. Whether they contribute to MES instability (e.g., via CPU scheduling
pressure) is unclear.

#### MES firmware context

The Unified MES (`uni_mes`) is RDNA4's hardware command scheduler firmware, loaded by
amdgpu as `mes_v12_0_0` IP block. It is enabled by default (`amdgpu.uni_mes=1`) on
RDNA4 and cannot be easily bypassed at runtime. The `amdgpu.reset_method` parameter
controls the GPU reset strategy:

```
reset_method: GPU reset method (-1=auto(default), 0=legacy, 1=mode0, 2=mode1, 3=mode2, 4=baco)
```

The current auto reset path attempts MES-based ring reset before falling back to
MODE1. If MES is dead, both fail and the reset code loops indefinitely.

#### Assessment

This is **not game-specific** — two different games (Enshrouded, PEAK.exe) produce the
identical failure. The common factor is: Vulkan command submission under 100% GPU load
via OCuLink (PCIe 4.0 x4).

Root cause candidates:
1. **MES v12 firmware bug** triggered by specific Vulkan command patterns under load
2. **OCuLink bandwidth/latency** causing MES firmware memory access failures (MES
   firmware reads its work queue from VRAM; high PCIe traffic on x4 link may cause
   access latency exceeding MES timeouts)
3. **Mesa/VKD3D-Proton** generating commands that trigger the MES bug

`linux-firmware-20260410-1.fc44.noarch` is the latest available — no newer MES
firmware is currently available.

**Potential mitigation to test:** `amdgpu.reset_method=2` (force mode1 reset) may
bypass the MES REMOVE_QUEUE loop during GPU reset, allowing the MODE1 reset to
complete and preventing the CPU lockup. The initial ring hang would still occur, but
the system would recover instead of requiring a forced reboot.

---

## Workaround summary

| Workaround | Mechanism | Target crash | Persistence |
|------------|-----------|--------------|-------------|
| `KWIN_DRM_NO_DIRECT_SCANOUT=1` | Avoids direct scanout flip path in kwin | Type A | `~/.config/plasma-workspace/env/kwin.sh` |
| `amdgpu.runpm=0` | Disables amdgpu runtime PM (prevents broken DC resume) | Type A (partial) | rpm-ostree kargs |
| `d3cold_allowed=0` on OCuLink chain | Prevents D3cold entry on OCuLink devices | Type B | `/etc/udev/rules.d/99-egpu-no-d3cold.rules` |

### Workarounds tested but found ineffective or invalid

| Attempted | Outcome |
|-----------|---------|
| `split_lock_detect=off` | Kernel treats it as userspace param (not a kernel boot param in 6.19.x). Steam bus_lock traps were noise, not the crash cause. |
| `amdgpu.gfxoff=0` | `amdgpu: unknown parameter 'gfxoff' ignored` — does not exist in this kernel version. |
| `amdgpu.pg_mask=0` | Valid parameter but caused GPU initialization failure → unbootable system. Too aggressive. |
| `pcie_aspm=off` | ASPM already disabled on all OCuLink chain links — no effect. Removed. |
| f377ea0561c9 patch | Already present in kernel 6.19.14-ogc1.1. Initial diagnosis was incorrect. |

### Candidate mitigation for Type C (untested)

`amdgpu.reset_method=2` — forces mode1 GPU reset instead of auto. Mode1 is a full
hardware bus reset; it may bypass the MES REMOVE_QUEUE teardown that currently deadlocks
during GPU reset, allowing the system to recover from ring hangs instead of CPU-locking.
The initial ring hang would still occur, but recovery would be automatic.

Parameter exists and is valid (confirmed via `modinfo amdgpu`). To test:
```bash
rpm-ostree kargs --append=amdgpu.reset_method=2
```

---

## Open questions

1. **What exactly prevents the GFX ring from waking from idle when a flip is submitted?**
   The fence gap is always 2, always kwin_wayland, always at minimum clock. The MES
   also stalls in some crashes. Is this a GFXOFF wakeup race specific to RDNA4, or
   a DC/DCN interrupt delivery issue on non-native PCIe (OCuLink)?

2. **Why does `KWIN_DRM_NO_DIRECT_SCANOUT=1` fix Type A crashes?**
   With direct scanout disabled, kwin composites through an intermediate buffer and
   submits a blit instead of a hardware flip. This avoids the DCN pageflip path.
   If the fix is in the flip path, the bug may be in `amdgpu_dm_crtc_vblank_control_worker`
   or the DCN flip interrupt handling on RDNA4.

3. **Are the persistent PCIe errors (`CorrErr+`, `UnsupReq+`) on 64:00.0 contributing?**
   These errors predate our testing and may be an artifact of previous crashes or
   a permanent signal integrity issue on the OCuLink link. Clearing and monitoring
   them with `rasdaemon` or `setpci` would clarify whether they accumulate during
   operation and could eventually trigger a link reset.

4. **Does the ACPI table for the GPD Win 4 incorrectly advertise D3cold support
   for the OCuLink slot?** Windows not allowing D3cold suggests either the Windows
   driver overrides it or the ACPI _PR3/_S0W objects are being interpreted differently.
   Inspecting the DSDT for the root port (00:03.1) would clarify this.

5. **Why does MES v12 firmware become unresponsive under full Vulkan load on OCuLink?**
   Two different games (Enshrouded, PEAK.exe) trigger the same failure: MES completely
   stops responding to all messages (RESET, REMOVE_QUEUE), causing a GPU reset deadlock
   and CPU lockup. Is this a MES firmware bug with specific command patterns, an OCuLink
   bandwidth issue causing VRAM access latency for MES, or a combination?

6. **Would `amdgpu.reset_method=2` (mode1) prevent the CPU lockup cascade?**
   Mode1 is a full hardware bus reset that does not rely on MES for queue teardown.
   If it bypasses the REMOVE_QUEUE loop, the system could recover from the ring hang
   instead of requiring forced reboot. To be tested with the next Type C crash.
