# eGPU OCuLink crash investigation — agent context

**Hardware:** GPD Win 4 (Ryzen AI 9 HX 370 / Strix Halo) + Minisforum DEG1 OCuLink dock + Sapphire Nitro+ RX 9070 XT (Navi 48 / RDNA4)  
**OS:** Bazzite 44 (Fedora-based immutable OCI), kernel `6.19.14-ogc5.1.fc44.x86_64`  
**Period:** 2026-05-05 → ongoing | **Crashes captured:** 17+

---

## PCIe chain (eGPU)

```
00:03.1  AMD Strix Halo GPP Bridge  [1022:150b]  (root port, secondary=64-66)
64:00.0  AMD Navi 10 XL Upstream Port Switch     [1002:1478]
65:00.0  AMD Navi 10 XL Downstream Port Switch   [1002:1479]
66:00.0  AMD Navi 48 RX 9070 XT                 [1002:7550] (rev c0)
66:00.1  AMD Navi 48 Audio                       [1002:ab30]
```

DRM card assignment: **`card1` = eGPU** (0000:66:00.0), `card2` = iGPU 890M (0000:67:00.0)

---

## Four root causes

### Cause A — GPU idle wake failure (DS_GFXCLK / GFXOFF)
- **Pattern:** GPU at SCLK 4–60 MHz, Load 0–1% → ring submission → 60 s watchdog timeout
- **Rings:** `gfx_0.0.0` (kwin flip, gap=2), `comp_1.0.1` (VKD3D, gap=1), `sdma1`+`gfx_0.0.0` (DXVK)
- **Recovery:** simple ring reset succeeds, no MES involvement, no MODE1 needed
- **Workaround (partial):** `KWIN_DRM_NO_DIRECT_SCANOUT=1` in `/etc/environment`
- **Upstream issue:** https://gitlab.freedesktop.org/drm/amd/-/work_items/5294
- **Status:** issue filed, comment with workaround test results pending (draft: `~/freedesktop-bug-report/comment-update-5294.md`)
- **Not reliably reproducible on demand** (GPU must be in sufficiently deep idle)

### Cause B — PCIe D3cold bus loss
- **Pattern:** `device lost from bus!` + `SMU: response=0xFFFFFFFF`
- **Root cause:** root port `00:03.1` entering D3cold cuts power to entire OCuLink chain
- **Workaround:** `/etc/udev/rules.d/99-egpu-no-d3cold.rules` — `d3cold_allowed=0` on 5 devices incl. root port
- **Status: RESOLVED** — no device loss since udev rule added
- **Upstream:** PCI quirk `pci_d3cold_disable()` for 0x1478/0x1479 — **soumis** : https://bugzilla.kernel.org/show_bug.cgi?id=221540

### Cause C — MES v12 firmware null pointer dereference
- **Pattern:** `[gfxhub] Page fault @ 0x0`, `regCP_MES_INSTR_PNTR = 0x705c` (fw 0x89) or `0x72c4` (fw 0x8b), MES dead → MODE1 reset
- **Trigger:** sustained GPU load (games via Proton — Enshrouded, PEAK, etc.)
- **Firmware tested:**
  - Base `20260410-1.fc44`: fw 0x89, crash at 0x705c
  - p1 override `bb95ff5c`: fw 0x89 (unchanged), crash at 0x705c — **does not fix**
  - OGC2 base `44.20260511`: fw 0x8b, crash at 0x72c4
  - ogc5 (current): p1 override still active (727680 bytes), fw 0x89
- **Note ogc5:** GFXHUB page fault no longer logged in journal (changed behavior vs ogc1/ogc2), but MES still dies (5× REMOVE_QUEUE timeout)
- **Upstream issue:** https://gitlab.freedesktop.org/drm/amd/-/issues/5274
- **Follow-up comment:** https://gitlab.freedesktop.org/drm/amd/-/issues/5274#note_3467811
- **Status: NO workaround** — AMD firmware fix pending

### Cause D — DCN no-recovery after MODE1
- **Pattern:** after MODE1 reset succeeds, `flip_done timed out` on CRTCs — displays freeze
- **Trigger:** consequence of Cause C or B, not independent
- **Status:** mentioned in #5274 comment, no separate issue filed

---

## Active workarounds

| Workaround | Location | Covers |
|------------|----------|--------|
| `KWIN_DRM_NO_DIRECT_SCANOUT=1` | `/etc/environment` | Cause A (kwin path only) |
| `d3cold_allowed=0` (5 PCIe devices) | `/etc/udev/rules.d/99-egpu-no-d3cold.rules` | Cause B — resolved |
| `amdgpu.runpm=0` | rpm-ostree kargs | Cause D (DC resume) |
| `amd-gpu-firmware p1` local override | rpm-ostree | Cause C — ineffective |

Check active kargs: `rpm-ostree kargs`  
Check udev rule: `cat /etc/udev/rules.d/99-egpu-no-d3cold.rules`

---

## Key directories and files

### Crash dumps (automated service)
```
/var/log/amdgpu-coredumps/
  crash-YYYYMMDD-HHMMSS/
    coredump.bin        — amdgpu devcoredump (binary, GPU state)
    journal-kernel.txt  — kernel journal, 30 min before crash
    pm_info.txt         — GPU power state at crash (SCLK, MCLK, Load, SMC features)
    fence_info.txt      — ring fence signaled/emitted sequences
    ring_gfx.txt        — raw GFX ring buffer
  poll.log              — timestamps of each captured dump
```

Service: `amdgpu-coredump-poll.service` (runs `/usr/local/bin/amdgpu-coredump-poll.sh`)  
The service polls `/sys/class/drm/card1/device/devcoredump/data` every 2 seconds.

### This repo
```
~/egpu-oculink-fix/
  docs/
    topo.md             — executive summary, all 4 causes, status table
    upstream-todo.md    — upstream issues to file / track
    crash-registry.md   — per-crash log (16+ entries)
    crash-analysis.md   — detailed analysis notes
  scripts/
    sclk-monitor.sh     — SCLK/Load/perf_level logger (usage: ./sclk-monitor.sh card1 2)
  udev/
    99-egpu-no-d3cold.rules
  install.sh / check.sh
```

### Bug report drafts
```
~/freedesktop-bug-report/
  issue-gpu-idle-hang.md      — filed as #5294 (Cause A)
  issue-body.md               — filed as #5274 (Cause C — MES)
  comment-update-5274.md      — follow-up comment posted on #5274
  comment-update-5294.md      — DRAFT, not yet posted (awaiting real-world test)
  pm_info-crash-*.txt         — power state snapshots at crash time
  journal-crash-*.txt         — kernel journals for specific crashes
```

---

## Accessing freedesktop GitLab issues

**Project ID:** 4522 (`drm/amd` at `gitlab.freedesktop.org/drm/amd`)  
**Issue vs work_item:** newer issues use `/work_items/NNNN`, older use `/issues/NNNN`. Both IDs are the same number.

### Issue body — REST (no auth) ou GraphQL en fallback
La REST API renvoie le corps sans auth pour les issues classiques. Les **work items** (issues récentes,
URL `/work_items/NNNN`) retournent souvent un corps vide via REST — utiliser GraphQL dans ce cas.

```bash
# REST (essayer en premier)
curl -s "https://gitlab.freedesktop.org/api/v4/projects/4522/issues/NNNN" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('Title:', d['title'])
print('State:', d['state'])
print(d['description'][:3000])
"

# GraphQL (fallback si REST renvoie description vide, ou pour tout récupérer d'un coup)
COOKIE="..." # _gitlab_session + anubis tokens
ISSUE=5298
curl -s "https://gitlab.freedesktop.org/api/graphql" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:150.0) Gecko/20100101 Firefox/150.0" \
  -H "Content-Type: application/json" \
  -H "Cookie: $COOKIE" \
  -d "{\"query\":\"{ project(fullPath: \\\"drm/amd\\\") { issue(iid: \\\"$ISSUE\\\") { title state description notes { nodes { author { username } createdAt body } } } } }\"}" \
  | python3 -c "
import json,sys
issue=json.load(sys.stdin)['data']['project']['issue']
print('Title:', issue['title'])
print(issue['description'][:3000])
print()
for n in issue['notes']['nodes']:
    if not n.get('body') or len(n['body']) < 10: continue
    print(f\"[{n['author']['username']} @ {n['createdAt'][:10]}]\")
    print(n['body'][:1000])
    print()
"
```
**Note :** faire les requêtes GraphQL une par une — le serveur peut bloquer les accès en rafale.

### REST API (recherche par mot-clé — no auth, state=all pour ouvertes+fermées)
```bash
TERM="MES firmware"
curl -s "https://gitlab.freedesktop.org/api/v4/projects/4522/issues?search=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$TERM")&state=all&per_page=20" \
  -H "User-Agent: Mozilla/5.0" | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    state='OPEN' if i['state']=='opened' else 'CLOSED'
    print(f\"[{state}] #{i['iid']} — {i['title']} ({i['created_at'][:10]})\")
"
```
Termes utiles pour nos problèmes : `MES firmware`, `mes_v12`, `uni_mes`, `CP_MES`, `MES null`, `DS_GFXCLK`, `GFXOFF ring timeout`

### GraphQL API (comments/notes — requires session cookie)
La REST API notes retourne 401 même sur les issues publiques (comportement spécifique à ce GitLab).
Utiliser GraphQL à la place, avec le cookie de session Firefox.

Obtenir le cookie : DevTools → Network → n'importe quelle requête gitlab.freedesktop.org → copier le header `Cookie`.
Les cookies nécessaires : `_gitlab_session`, `techaro.lol-anubis-auth`, `techaro.lol-anubis-cookie-verification`.

```bash
COOKIE="_gitlab_session=<value>; techaro.lol-anubis-cookie-verification=<val>; techaro.lol-anubis-auth=<val>"
ISSUE=5194
curl -s "https://gitlab.freedesktop.org/api/graphql" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:150.0) Gecko/20100101 Firefox/150.0" \
  -H "Content-Type: application/json" \
  -H "Cookie: $COOKIE" \
  -d "{\"query\":\"{ project(fullPath: \\\"drm/amd\\\") { issue(iid: \\\"$ISSUE\\\") { title notes { nodes { author { username } createdAt body } } } } }\"}" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
issue=d['data']['project']['issue']
print('Title:', issue['title'])
print()
for n in issue['notes']['nodes']:
    if not n.get('body'): continue
    print(f\"  [{n['author']['username']} @ {n['createdAt'][:10]}]\")
    print(n['body'][:1500])
    print()
"
```

### Extracting data from a HAR file
If a HAR was captured while browsing an issue page, GraphQL responses contain the full comment data:
```bash
python3 -c "
import json
with open('path/to/file.har') as f:
    har = json.load(f)
for e in har['log']['entries']:
    if 'graphql' not in e['request']['url']: continue
    text = e['response']['content'].get('text', '')
    if not text or len(text) < 5000: continue
    data = json.loads(text)
    def find_bodies(obj, d=0):
        if d > 10: return
        if isinstance(obj, dict):
            if 'body' in obj and isinstance(obj['body'], str) and len(obj['body']) > 20:
                name = obj.get('author', {}).get('username', '?') if isinstance(obj.get('author'), dict) else '?'
                print(f'[{name}]:', obj['body'][:800])
            for v in obj.values(): find_bodies(v, d+1)
        elif isinstance(obj, list):
            for i in obj: find_bodies(i, d+1)
    find_bodies(data)
"
```

---

## Related upstream issues

| Issue | Title | Status | Notes |
|-------|-------|--------|-------|
| [#5274](https://gitlab.freedesktop.org/drm/amd/-/issues/5274) | MES v12 null ptr dereference (Cause C) | Open | AMD firmware fix pending |
| [#5294](https://gitlab.freedesktop.org/drm/amd/-/work_items/5294) | GPU idle wake failure, Cause A | Open | Our report — commentaire en attente |
| [#5194](https://gitlab.freedesktop.org/drm/amd/-/issues/5194) | Navi 48 DS_GFXCLK frame drops, native PCIe | Open | Lié à #5178 (clockevents) — même DS_GFXCLK |
| [#4829](https://gitlab.freedesktop.org/drm/amd/-/issues/4829) | RX 9070 XT crashes | Open | Cause B (D3cold bus loss), pas Cause A |
| [#5178](https://gitlab.freedesktop.org/drm/amd/-/work_items/5178) | RX 7900 XTX kernel 7.0 frame drops | Closed | Fix clockevents `d6e152d905`, backporté 7.0.1 |
| [bugzilla #221540](https://bugzilla.kernel.org/show_bug.cgi?id=221540) | PCI quirk D3cold Navi 10 XL switch (Cause B) | Open | Notre report — patch à soumettre linux-pci@vger |

---

## DS_GFXCLK technical notes

- **SMU feature bit 10** = DS_GFXCLK (GFX clock deep-sleep). Distinct from GFXOFF (bit 18).
- Current pp_features on Navi 48: `high: 0x048cf19e low: 0x38fffcfb`
- To disable DS_GFXCLK (bit 10): `printf "0x048cf19e38fff8fb\n" | sudo tee /sys/class/drm/card1/device/pp_features`
- **All userspace workarounds are ineffective:** `performance_level=high`, `manual` DPM, `pp_features` write — PMFW re-enables DS_GFXCLK autonomously at idle regardless.
- Root cause: `smu_v14_0_2_ppt.c` lacks `PP_SCLK_DEEP_SLEEP_MASK` filter (present in navi10, sienna_cichlid, smu_v13_0_0) — ppfeaturemask bit 10 is not honoured.
- GPU wakes normally under real load (32 MHz → 1711 MHz in ~2 s). Bug is that specific ring paths (kwin flip, DXVK SDMA, VKD3D compute) don't signal the GPU to wake before waiting for ring completion.

---

## Useful live commands

```bash
# Power state snapshot
DEV=/sys/class/drm/card1/device
cat $DEV/power_dpm_force_performance_level
cat $DEV/pp_features | grep -E "DS_GFXCLK|GFXOFF|features"
HWMON=$(ls $DEV/hwmon/ | head -1)
echo "SCLK: $(( $(cat $DEV/hwmon/$HWMON/freq1_input) / 1000000 )) MHz"
echo "Load: $(cat $DEV/gpu_busy_percent) %"

# Start SCLK monitor (logs to ~/sclk-monitor-TIMESTAMP.log)
~/egpu-oculink-fix/scripts/sclk-monitor.sh card1 2

# List recent crash dumps
ls -lt /var/log/amdgpu-coredumps/

# Kernel log since last crash
journalctl -b -k --no-pager -g "amdgpu|gfxhub|MES|timeout|wedged|reset|lost from bus" --since "1 hour ago"

# Check active kargs and firmware override
rpm-ostree kargs
rpm-ostree status | grep -A3 "LocalOverrides"
```
