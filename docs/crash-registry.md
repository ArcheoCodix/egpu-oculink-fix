# Crash Registry — eGPU OCuLink (GPD Win 4 + RX 9070 XT)

**Hardware:** GPD Win 4 (Ryzen AI 9 HX 370 / Strix Halo) + Minisforum DEG1 (OCuLink) + Sapphire RX 9070 XT (Navi 48 / RDNA4)  
**Connexion:** PCIe 4.0 x4 via OCuLink  
**OS:** Bazzite 44, kernel 6.19.14-ogc{1,2}.1.fc44  
**Captures:** `/var/log/amdgpu-coredumps/crash-*/` (service `amdgpu-coredump-poll`)

---

## Causes racines identifiées

Quatre causes racines distinctes ont été identifiées. Elles peuvent se produire indépendamment ou
s'enchaîner (ex : bus loss → flip_done timeout).

### 1. GFX ring hang (GPU idle / flip path)

**Symptôme :** timeout du ring `gfx_0.0.0`, gap toujours = 2, offender `kwin_wayland`. GPU à
très basse fréquence (14–60 MHz SCLK) au moment du crash. Aucune perte de bus, aucun crash MES.
Reprise par ring reset (MODE1 non nécessaire).

**Cause probable :** le GPU est en état de veille profonde (GFXOFF ou équivalent) quand
kwin_wayland soumet une commande de flip. La commande ne réveille pas le GPU → timeout 60s.

**Workaround actif :** `KWIN_DRM_NO_DIRECT_SCANOUT=1` — redirige le chemin de présentation kwin
via un buffer intermédiaire, évite le flip direct sur le GFX ring.  
**Status : workaround en place, cause racine non corrigée upstream.**

---

### 2. PCIe bus loss (D3cold ou erreur de lien)

**Symptôme :** `device lost from bus!` + `SMU: response:0xFFFFFFFF` — le GPU a disparu du bus
PCIe. Ring timeout consécutif. Peut s'accompagner d'un `flip_done timed out` si le pipeline DCN
ne se réinitialise pas correctement après recovery.

**Cause probable :** entrée en D3cold par le bridge parent (00:03.1, non couvert par notre règle
udev) ou erreur de lien PCIe. OCuLink ne supporte pas la Surprise Removal.

**Workaround actif :** `d3cold_allowed=0` via udev sur les devices `64:00.0`, `65:00.0`,
`66:00.0`, `66:00.1`. La règle ne couvre pas le root port `00:03.1`.  
**Status : partiel — crash 10 montre que le bus loss se produit encore malgré la règle.**

---

### 3. MES firmware null pointer dereference

**Symptôme :** `[gfxhub] Page fault` à l'adresse GPU VA `0x0`, `regCP_MES_INSTR_PNTR = 0x705c`
(v0x89) ou `0x72c4` (v0x8b), suivi d'un ring timeout avec `MES(1) failed to respond`. Peut
provoquer un CPU hard lockup si la boucle REMOVE_QUEUE ne se termine pas.

**Cause confirmée :** bug dans le firmware unifié MES (`gc_12_0_0_uni_mes.bin`). Le microcontrôleur
MES déréférence un pointeur nul à un offset fixe lors d'une charge GPU soutenue.

**Fix :** firmware `amd-gpu-firmware 20260410-1.fc44.p1` (linux-firmware commit `bb95ff5c`,
2026-05-06, 727 680 bytes, version 0x00). 30 min FurMark sans crash observé.  
**Bug report :** https://gitlab.freedesktop.org/drm/amd/-/issues/5274  
**Status : fix firmware installé, en attente de confirmation sur session gaming prolongée.**

---

### 4. Compute ring hang (GPU idle / compute path)

**Symptôme :** timeout du ring `comp_1.0.1` (compute, pas GFX), offender `vkd3d_queue`. GPU à
4 MHz SCLK, Load=0%. Reprise par ring reset.

**Cause probable :** même origine que la cause 1 — GPU en veille profonde lors d'une soumission
compute VKD3D. `KWIN_DRM_NO_DIRECT_SCANOUT=1` ne couvre pas ce chemin.

**Status : aucun workaround. Non reproduit de façon fiable. À surveiller.**

---

## Registre des crashs

11 crashs capturés par le service `amdgpu-coredump-poll`.

| # | Timestamp | Kernel | MES fw | Workarounds actifs | Cause racine | Offender | Ring | Recovery | Outcome |
|---|-----------|--------|--------|--------------------|--------------|----------|------|----------|---------|
| 1 | 2026-05-05 23:32 | ogc1 | v0x89 | — | GFX ring hang (idle) | kwin_wayland | gfx_0.0.0 (gap=2) | Ring reset | Récupéré |
| 2 | 2026-05-06 00:24 | ogc1 | v0x89 | — | GFX ring hang (idle) | kwin_wayland | gfx_0.0.0 (gap=2) | Ring reset | Récupéré |
| 3 | 2026-05-06 21:24 | ogc1 | v0x89 | — | GFX ring hang (idle) | kwin_wayland | gfx_0.0.0 (gap=2) | Ring reset | Récupéré |
| 4 | 2026-05-06 22:43 | ogc1 | v0x89 | — | GFX ring hang (idle) | kwin_wayland | gfx_0.0.0 (gap=2) | Ring reset | Récupéré |
| 5 | 2026-05-06 23:21 | ogc1 | v0x89 | NO_DIRECT_SCANOUT | PCIe bus loss | enshrouded.exe | gfx_0.0.0 (gap=2) | Ring reset | Récupéré (DCN OK) |
| 6 | 2026-05-07 00:13 | ogc1 | v0x89 | NO_DIRECT_SCANOUT + D3cold rule | MES null ptr (0x705c) | enshrouded.exe | gfx_0.0.0 (gap=2) | MODE1 | Récupéré partiellement |
| 7 | 2026-05-07 22:12 | ogc1 | v0x89 | NO_DIRECT_SCANOUT + D3cold rule | MES null ptr (0x705c) | PEAK.exe | gfx_0.0.0 (gap=2) | MODE1 échoué | **CPU hard lockup** |
| 8 | 2026-05-08 01:45 | ogc1 | v0x89 | NO_DIRECT_SCANOUT + D3cold rule + runpm=0 | MES null ptr (0x705c) | kwin_wayland¹ | gfx_0.0.0 (gap=2) | MODE1 | Récupéré |
| 9 | 2026-05-10 15:26 | ogc2 | legacy v0x55² | NO_DIRECT_SCANOUT + D3cold rule + runpm=0 | Legacy MES crash (0xa2f) | kwin_wayland | gfx_0.0.0 (gap=2) | — | Test avorté |
| 10 | 2026-05-10 17:43 | ogc2 | p1 v0x00 | NO_DIRECT_SCANOUT + D3cold rule + runpm=0 | PCIe bus loss + DCN no-recovery | enshrouded.exe | gfx_0.0.0 (gap=2) | Ring reset + flip_done timeout | Écrans gelés, système OK |
| 11 | 2026-05-10 19:17 | ogc2 | p1 v0x89² | NO_DIRECT_SCANOUT + D3cold rule + runpm=0 | Compute ring hang (idle) | vkd3d_queue (AoE4) | comp_1.0.1 (gap=1) | Ring reset | Récupéré |
| 12 | 2026-05-11 22:42 | ogc2 | v0x8b³ | NO_DIRECT_SCANOUT + D3cold rule (00:03.1 inclus) + runpm=0 | MES null ptr (0x72c4, v0x8b) | kwin_wayland | gfx_0.0.0 (gap=2) | Ring reset failed → MODE1 | Écrans gelés (flip_done timeout) |
| 13 | 2026-05-11 22:44 | ogc2 | v0x8b³ | idem | MES mort (suite crash 12) | kwin_wayland | gfx_0.0.0 (gap=2) | MODE1 → 5× REMOVE_QUEUE sans réponse | Reboot forcé |
| 14 | 2026-05-11 23:13 | ogc2 | p1 v0x89² | NO_DIRECT_SCANOUT + D3cold rule (00:03.1 inclus) + runpm=0 | MES null ptr (**0x705c**, v0x89) | enshrouded.exe | gfx_0.0.0 (gap=2) | Ring reset (×2) | Reboot |

¹ kwin_wayland loggé comme offender car dernier soumetteur — GPU était à 100% charge de jeu au
moment du crash MES. Le jeu était la vraie charge, kwin n'est pas la cause.  
² Le firmware p1 (`amd-gpu-firmware 20260410-1.fc44.p1`, 727 680 bytes, linux-firmware bb95ff5c)
rapporte `fw version: 0x00000089` en interne malgré `ucode_version = 0x00` dans le header kernel.
Il crashe à 0x705c — **le même offset que l'ogc1**. Le p1 ne corrige pas le bug sur ce hardware.  
³ Crash 12/13 : boot sur le déploiement OCI 44.20260511 — le firmware chargé était v0x8b (ogc2
base) malgré l'override p1 listé. Incohérence de déploiement entre les deux layers rpm-ostree.  
⁴ Crash 9 est un test volontaire de `amdgpu.uni_mes=0`. Le firmware legacy MES v0x55 crashe à
l'offset 0xa2f en moins d'une minute. Testé et supprimé immédiatement.

---

## État actuel des workarounds

| Workaround | Fichier | Cible | Status |
|------------|---------|-------|--------|
| `KWIN_DRM_NO_DIRECT_SCANOUT=1` | `/etc/environment` | GFX ring hang (cause 1) | Actif — couvre kwin, pas VKD3D compute |
| `d3cold_allowed=0` | `/etc/udev/rules.d/99-egpu-no-d3cold.rules` | PCIe bus loss (cause 2) | Actif — couvre toute la chaîne dont `00:03.1` |
| `amdgpu.runpm=0` | rpm-ostree kargs | DC resume CRTC cassé | Actif |
| `amd-gpu-firmware p1` | rpm-ostree local override | MES null ptr (cause 3) | Actif — **ne corrige pas le bug** (crash 14 : v0x89 → 0x705c) |

---

## Dossiers de captures (`/var/log/amdgpu-coredumps/`)

Chaque dossier contient : `coredump.bin`, `journal-kernel.txt`, `fence_info.txt`,
`ring_gfx.txt`, `pm_info.txt` (capturés au moment du crash par le service poll).

| Dossier | Crash # | Cause racine | Fichiers utiles |
|---------|---------|--------------|-----------------|
| `crash-20260505-233258` | 1 | GFX ring hang (idle / kwin) | `pm_info.txt` (SCLK post-reset), `fence_info.txt` |
| `crash-20260506-002444` | 2 | GFX ring hang (idle / kwin) + DC resume cassé | `journal-kernel.txt` (Cannot find crtc or sizes) |
| `crash-20260506-212420` | 3 | GFX ring hang (idle / kwin) | `pm_info.txt` (SCLK=60 MHz au crash) |
| `crash-20260506-224307` | 4 | GFX ring hang (idle / kwin) | `pm_info.txt` (SCLK=14 MHz au crash) |
| `crash-20260506-232111` | 5 | PCIe bus loss (D3cold) | `pm_info.txt` (SCLK=0, VDDGFX=40 mV), `journal-kernel.txt` |
| `crash-20260507-001329` | 6 | MES null ptr (0x705c, v0x89) | `coredump.bin` (gfxhub + INSTR_PNTR confirmé), `journal-kernel.txt` |
| `crash-20260507-221258` | 7 | MES null ptr (0x705c, v0x89) — CPU lockup | `coredump.bin` (**meilleur dump**, copié dans `/var/home/archeo/freedesktop-bug-report/`), `journal-kernel.txt` |
| `crash-20260508-014526` | 8 | MES null ptr (0x705c, v0x89) — recovery OK | `coredump.bin` (INSTR_PNTR confirmé), `journal-kernel.txt` |
| `crash-20260510-152602` | 9 | Legacy MES crash (0xa2f, v0x55) — test uni_mes=0 | `coredump.bin`, `journal-kernel.txt` |
| `crash-20260510-174347` | 10 | PCIe bus loss + DCN no-recovery (p1 fw) | `journal-kernel.txt` (device lost + flip_done timeout), `pm_info.txt` (SCLK=63 MHz) |
| `crash-20260510-191734` | 11 | Compute ring hang (idle / vkd3d) | `pm_info.txt` (SCLK=4 MHz, Load=0%), `journal-kernel.txt` |
| `crash-20260511-224207` | 12 | MES null ptr (0x72c4, v0x8b) + DCN no-recovery | `coredump.bin` (INSTR_PNTR=0x72c4, fw=0x8b), `journal-kernel.txt` |
| `crash-20260511-224409` | 13 | MES mort (suite crash 12), REMOVE_QUEUE loop | `journal-kernel.txt` (5× MES failed) |
| `crash-20260511-231307` | 14 | MES null ptr (**0x705c**, **v0x89** p1 firmware) | `coredump.bin` (INSTR_PNTR=0x705c, fw=0x89 — **p1 non corrigé**) |

**Note :** les coredumps des crashs 6, 7, 8 contiennent les registres MES
(`regCP_MES_INSTR_PNTR = 0x705c`) et le page fault GFXHUB. Le coredump du crash 7 a été
joint au bug report freedesktop#5274.

---

## Questions ouvertes

1. **Crash 10 : pourquoi le bus loss se produit-il malgré la règle D3cold ?**  
   Le root port `00:03.1` n'est pas dans la règle udev. Si lui entre en D3cold, toute la chaîne
   en aval est coupée. À vérifier : `cat /sys/bus/pci/devices/0000:00:03.1/d3cold_allowed`.
   Alternative : le bus loss pourrait être dû à une erreur PCIe (CorrErr+/UnsupReq+ déjà présents
   sur 64:00.0) et non à D3cold.

2. **Crash 10 : pourquoi le DCN ne récupère pas après le ring reset ?**  
   Le ring reset (MODE1) a réussi mais les écrans sont restés gelés (flip_done timeout persistant).
   Même pattern que crash #2 (resume runtime PM → DC ne ré-énumère pas les CRTCs).

3. **Crash 11 : le compute ring hang est-il la même cause que les crashs 1-4 ?**  
   Même GPU à veille profonde, même pattern. `KWIN_DRM_NO_DIRECT_SCANOUT=1` couvre le chemin
   kwin flip mais pas le chemin compute VKD3D. Workaround potentiel : forcer le GPU hors GFXOFF
   pendant les sessions gaming (non confirmé).

4. **Le firmware p1 ne corrige pas le bug MES.**  
   Crash 14 confirme : `fw version: 0x89`, `INSTR_PNTR = 0x705c` — même signature que les crashs
   ogc1 originaux. Le FurMark 30 min ne reproduit pas le crash aussi vite que les jeux (Enshrouded
   déclenche le bug en moins de 30 min). Le fix upstream n'est pas encore disponible.

5. **Incohérence de version firmware entre les boots (v0x8b vs v0x89).**  
   Les crashs 12/13 (OCI 44.20260511) ont chargé v0x8b malgré l'override p1. Le crash 14 (boot
   suivant) a chargé v0x89 (p1). Origine probable : switch de déploiement ostree entre deux layers
   ayant des bases différentes pour `amd-gpu-firmware`. À investiguer.
