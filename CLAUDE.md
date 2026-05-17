# eGPU OCuLink crash investigation — agent context

Hardware: GPD Win 4 (Ryzen AI 9 HX 370 / Strix Halo) + Minisforum DEG1 OCuLink dock + Sapphire Nitro+ RX 9070 XT (Navi 48 / RDNA4). Bazzite 44.

Full picture in `docs/topo.md`. Next planned tests in `docs/next-actions.md`. This file is the agent quick-start.

## PCIe chain

```
00:03.1  AMD Strix Halo GPP Bridge       [1022:150b]  (root port)
64:00.0  AMD Navi 10 XL Upstream Port    [1002:1478]
65:00.0  AMD Navi 10 XL Downstream Port  [1002:1479]
66:00.0  AMD Navi 48 RX 9070 XT          [1002:7550] (rev c0)
66:00.1  AMD Navi 48 Audio               [1002:ab30]
```

DRM card assignment is probe-order dependent. Verify with:
```bash
for d in /sys/class/drm/card?/device; do
  printf '%s -> %s\n' "$(basename $(dirname $d))" "$(cat $d/vendor):$(cat $d/device)"
done
# eGPU = vendor 0x1002 device 0x7550; iGPU 890M = 0x1002 0x150e
```

## Four root causes

Detailed crash-by-crash log in `docs/crash-registry.md`. Cause/workaround tables
in `docs/topo.md`. Per-cause status table here is the quick reference.

| Cause | Pattern | Recovery | Workaround | Repro |
|-------|---------|----------|------------|-------|
| **A** — GPU idle wake (DS_GFXCLK) | SCLK 4–60 MHz + Load 0–1% → ring submit → 60s timeout. Rings: `gfx_0.0.0` (kwin flip, gap=2), `comp_1.0.1` (VKD3D, gap=1), `sdma1`+`gfx` (DXVK) | simple ring reset (no MES, no MODE1) | `KWIN_DRM_NO_DIRECT_SCANOUT=1` (kwin path only — DXVK/VKD3D still exposed) | **Opportunistic only.** GPU must reach deep idle. Not forceable. |
| **B** — PCIe D3cold bus loss | `device lost from bus!` + `SMU: response=0xFFFFFFFF`. Root port `00:03.1` enters D3cold, cuts whole chain | udev rule sets `d3cold_allowed=0` | `/etc/udev/rules.d/99-egpu-no-d3cold.rules` (5 devs incl. root port) | **Opportunistic only.** Triggered by PM idle. |
| **C** — MES v12 firmware null ptr | `[gfxhub] Page fault @ 0x0`, `regCP_MES_INSTR_PNTR = 0x705c` (fw 0x89) / `0x72c4` (fw 0x8b). MES dies → `MES failed to respond` → MODE1 reset | MODE1 PCIe reset (sometimes CPU hard lockup) | **None efficace.** | Sustained GPU load via Proton (Enshrouded, PEAK reproducibly trigger it). |
| **D** — DCN no-recovery post-MODE1 | After MODE1 succeeds, `flip_done timed out` on CRTCs, displays freeze | Reboot (system stays SSH-reachable) | `amdgpu.runpm=0` reduces frequency | **Follow-on only** — only after Cause B or C. |

### Cause B note: status nuance

- **Local: RESOLVED** — no `device lost from bus` since the udev rule added the
  root port (`00:03.1`) on 2026-05-11. Crashes 12–17 confirm.
- **Upstream: PENDING** — bugzilla #221540 filed, no kernel quirk merged yet.
- A reader running `install.sh` is fully covered.

## Issues and reports

| Tracker | ID | Subject | Status |
|---------|----|---------|--------|
| freedesktop drm/amd | [#5274](https://gitlab.freedesktop.org/drm/amd/-/issues/5274) | MES v12 null ptr (Cause C) | Open — awaiting AMD firmware fix |
| freedesktop drm/amd | [#5294](https://gitlab.freedesktop.org/drm/amd/-/work_items/5294) | GPU idle wake failure (Cause A) | Open — comment draft pending real-world test result |
| freedesktop drm/amd | [#5194](https://gitlab.freedesktop.org/drm/amd/-/issues/5194) | Navi 48 DS_GFXCLK frame drops, native PCIe | Open — related to #5178 (clockevents fix in 7.0.1) |
| freedesktop drm/amd | [#4829](https://gitlab.freedesktop.org/drm/amd/-/issues/4829) | RX 9070 XT crashes (D3cold bus loss) | Open — same as our Cause B |
| freedesktop drm/amd | [#5178](https://gitlab.freedesktop.org/drm/amd/-/work_items/5178) | RX 7900 XTX kernel 7.0 frame drops | Closed — fixed by clockevents `d6e152d905` revert in 7.0.1 |
| bugzilla.kernel.org | [#221540](https://bugzilla.kernel.org/show_bug.cgi?id=221540) | PCI quirk D3cold Navi 10 XL switch (Cause B) | Open — patch to submit to linux-pci@vger |

Draft reports in `~/freedesktop-bug-report/`:
- `issue-gpu-idle-hang.md` — filed as #5294
- `issue-body.md` — filed as #5274
- `comment-update-5274.md` — posted on #5274 (note_3467811)
- `comment-update-5294.md` — DRAFT, awaiting reproducible crash
- `bugzilla-d3cold-oculink.txt` — filed as #221540

## Key directories

```
/var/log/amdgpu-coredumps/         — auto-captured by amdgpu-coredump-poll.service
  crash-YYYYMMDD-HHMMSS/
    coredump.bin                   — devcoredump (GPU register state)
    journal-kernel.txt             — kernel journal, 30 min before crash
    pm_info.txt                    — SCLK/MCLK/Load/SMC features at crash
    fence_info.txt                 — ring fence signaled/emitted
    ring_gfx.txt                   — raw GFX ring buffer
  poll.log                         — timestamps of captured dumps

~/egpu-oculink-fix/                — this repo
  docs/topo.md                     — executive summary, source of truth
  docs/crash-registry.md           — per-crash log (17 entries)
  docs/crash-analysis.md           — detailed analysis & rejected workarounds
  docs/upstream-todo.md            — upstream items to file/track
  docs/next-actions.md             — pending tests (native game, fw bisection)
  docs/gitlab-api.md               — how to query freedesktop GitLab
  scripts/sclk-monitor.sh          — SCLK/Load logger (./sclk-monitor.sh card1 2)
  udev/99-egpu-no-d3cold.rules     — D3cold workaround rule
  install.sh / check.sh            — installer + upstream-status checker

~/freedesktop-bug-report/          — issue drafts, coredumps, logs
```

The poll service hardcodes `card1` for the devcoredump path. If the eGPU is
not card1 (see DRM verification command above), the service won't capture
crashes — edit `/usr/local/bin/amdgpu-coredump-poll.sh`.

## DS_GFXCLK technical notes

- SMU feature bit 10 = DS_GFXCLK (GFX deep-sleep). Distinct from GFXOFF (bit 18).
- Disabling DS_GFXCLK via `pp_features` write: driver accepts it but PMFW re-enables it autonomously at idle. No userspace workaround works.
- Root cause: `smu_v14_0_2_ppt.c` lacks the `PP_SCLK_DEEP_SLEEP_MASK` filter present in navi10, sienna_cichlid, smu_v13_0_0 — `ppfeaturemask` bit 10 is not honoured by the driver.
- GPU does wake normally under real load (32 MHz → 1711 MHz in ~2 s). Bug is that specific ring paths (kwin flip, DXVK SDMA, VKD3D compute) don't signal the GPU to wake before waiting for ring completion.

## Useful live commands

```bash
# Current state (kernel, firmware override, kargs)
uname -r
rpm-ostree status | grep -E "Version|LocalOverrides"
rpm-ostree kargs

# Active MES firmware version (eGPU = drm minor for card1)
sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep MES

# GPU live state
DEV=/sys/class/drm/card1/device
cat $DEV/power_dpm_force_performance_level
cat $DEV/pp_features | grep -E "DS_GFXCLK|GFXOFF|features"
HWMON=$(ls $DEV/hwmon/ | head -1)
echo "SCLK: $(( $(cat $DEV/hwmon/$HWMON/freq1_input) / 1000000 )) MHz, Load: $(cat $DEV/gpu_busy_percent)%"

# Watch SCLK/Load over time (for crash investigation)
~/egpu-oculink-fix/scripts/sclk-monitor.sh card1 2

# Recent crash dumps
ls -lt /var/log/amdgpu-coredumps/ | head

# Kernel log around recent amdgpu events
journalctl -b -k --no-pager -g "amdgpu|gfxhub|MES|timeout|wedged|reset|lost from bus" --since "1 hour ago"
```

## Querying freedesktop GitLab

See `docs/gitlab-api.md` for REST/GraphQL recipes, the cookie requirement,
and how to extract data from a HAR file.
