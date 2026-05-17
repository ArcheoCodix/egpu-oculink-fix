# Topo — eGPU OCuLink crash investigation

**Hardware:** GPD Win 4 (Ryzen AI 9 HX 370 / Strix Halo) + Minisforum DEG1 (OCuLink) + Sapphire RX 9070 XT (Navi 48 / RDNA4)  
**Connection:** PCIe 4.0 x4 via OCuLink  
**OS:** Bazzite 44, kernel 6.19.14-ogc5.1.fc44  
**Period:** 2026-05-05 → 2026-05-17 | **Crashes captured:** 17+

---

## Résumé exécutif

Quatre causes racines distinctes ont été identifiées. L'une est résolue côté workaround
(D3cold), une est en attente de fix AMD (MES firmware), et deux n'ont pas encore de
workaround complet (GPU idle wake, DCN no-recovery).

| Cause | Status workaround | Status upstream |
|-------|-------------------|-----------------|
| A — GPU idle wake failure | Partiel (kwin couvert, DXVK/VKD3D non) | **Issue non déposée** |
| B — PCIe D3cold bus loss | Résolu via udev (00:03.1 inclus) | Patch noyau non soumis |
| C — MES firmware null ptr | Aucun | Issue déposée (#5274) — fix AMD attendu |
| D — DCN no-recovery post-reset | Aucun | Mentionné dans #5274 — non déposé séparément |

---

## Cause A — GPU idle wake failure

**Crashs concernés :** 1–4, 11, 15–16 (8 crashs sur 16)

### Symptôme

Le GPU est en veille profonde (SCLK 4–60 MHz, Load 0–1%) quand une soumission ring arrive.
Le GPU ne se réveille pas avant le timeout du watchdog (60s). Aucune page fault, aucune perte
de bus PCIe. La récupération par ring reset réussit systématiquement.

### Chemins affectés

| Chemin | Ring | Gap | Offender typique | Crashs |
|--------|------|-----|-----------------|--------|
| kwin flip direct | gfx_0.0.0 | 2 | kwin_wayland | 1, 2, 3, 4 |
| VKD3D compute | comp_1.0.1 | 1 | vkd3d_queue | 11 |
| DXVK (sdma + gfx) | sdma1 + gfx_0.0.0 | 1 + 2 | dxvk-submit | 15, 16 |

### Workaround

`KWIN_DRM_NO_DIRECT_SCANOUT=1` dans `/etc/environment` — élimine le chemin kwin flip.
**Ne couvre pas DXVK ni VKD3D.**

### Fix upstream attendu

Driver amdgpu : s'assurer que le GPU sort de GFXOFF avant d'attendre la completion d'un ring.
**Issue à déposer** → freedesktop drm/amd.

---

## Cause B — PCIe D3cold bus loss

**Crashs concernés :** 5, 10

### Symptôme

```
amdgpu 0000:66:00.0: device lost from bus!
amdgpu 0000:66:00.0: SMU: response:0xFFFFFFFF
```

Le GPU disparaît du bus PCIe. OCuLink ne supporte pas la Surprise Removal (`Surprise-` dans
`lspci`). Si le bus loss survient pendant une session active, le ring timeout suit
immédiatement ; la récupération échoue.

### Cause racine

Le bridge parent (`00:03.1` — AMD Strix Halo GPP Bridge, root port de la chaîne OCuLink)
entrait en D3cold avec `d3cold_allowed=1`. Quand le root port entre en D3cold, il coupe
l'alimentation de l'ensemble de la chaîne aval, indépendamment des réglages des devices enfants.

### Chaîne PCIe

```
00:03.1  AMD Strix Halo GPP Bridge  (root port, parent de la chaîne OCuLink)
64:00.0  AMD Navi 10 XL Upstream Port  (0x1478)
65:00.0  AMD Navi 10 XL Downstream Port  (0x1479)
66:00.0  AMD Navi 48 RX 9070 XT  (0x7550)
66:00.1  AMD Navi 48 Audio
```

### Workaround actif — confirmé résolu

`/etc/udev/rules.d/99-egpu-no-d3cold.rules` couvre les 5 devices dont `00:03.1`.
Aucun `device lost` depuis l'ajout du root port (crashs 12–16, 3 sessions gaming).

### Fix upstream attendu

Quirk PCI dans `drivers/pci/quirks.c` : `PCI_DEV_FLAGS_NO_D3COLD` pour 0x1478/0x1479
(Navi 10 XL PCIe switch) — similaire aux quirks Thunderbolt eGPU existants.
À soumettre à `linux-pci@vger.kernel.org`.

---

## Cause C — MES firmware null pointer dereference

**Crashs concernés :** 6, 7, 8, 12, 13, 14 (6 crashs sur 16)

### Symptôme

```
[gfxhub] Page fault observed
Faulty page starting at address: 0x0000000000000000
regCP_MES_INSTR_PNTR    0x0000705c   (fw v0x89)
regCP_MES_INSTR_PNTR    0x000072c4   (fw v0x8b)
regCP_MES_HEADER_DUMP   0xdef0def0 … 0xdef7def7
```

Le microcontrôleur MES déréférence un pointeur nul à un offset fixe sous charge GPU soutenue.
Le GFXHUB page fault stoppe définitivement le MES. Tous les messages driver vers le MES
(`RESET`, `REMOVE_QUEUE`) expirent ensuite. Peut provoquer un CPU hard lockup (crash 7).

### Firmware testé

| Firmware | Version interne | INSTR_PNTR | Résultat |
|----------|-----------------|------------|---------|
| ogc1 base (`20260410-1.fc44`) | 0x89 | 0x705c | Crash confirmé |
| p1 (`bb95ff5c`, 727 680 bytes) | 0x89 (inchangé) | 0x705c | **Ne corrige pas** |
| ogc2 base (`44.20260511`) | 0x8b | 0x72c4 | Crash confirmé |

FurMark 30 min ne reproduit pas le crash. Les jeux via Proton (Enshrouded) le déclenchent
en moins de 30 minutes.

### Issue upstream

**Déposée :** https://gitlab.freedesktop.org/drm/amd/-/issues/5274  
**Commentaire de suivi (2026-05-14) :** https://gitlab.freedesktop.org/drm/amd/-/issues/5274#note_3467811  
**Status :** EN ATTENTE d'un firmware fix AMD. Aucun workaround efficace.

---

## Cause D — DCN no-recovery après MODE1

**Crashs concernés :** 6, 10, 12

### Symptôme

Après un ring reset (MODE1) réussi, le pipeline d'affichage DCN ne se réinitialise pas :

```
amdgpu 0000:66:00.0: [drm] *ERROR* [CRTC:416:crtc-0] flip_done timed out
amdgpu 0000:66:00.0: [drm] *ERROR* [CRTC:420:crtc-1] flip_done timed out
```

Les écrans externes se figent. Le système reste réactif en SSH. Un deuxième crash MES
suit ~2 minutes plus tard (le MES n'a pas été rechargé par le premier MODE1 reset).

### Status

Mentionné dans le commentaire #5274 (note_3467811). Aucune issue séparée déposée.
Secondaire — conséquence des causes B et C, pas une cause primaire indépendante.

---

## Workarounds actifs

| Workaround | Fichier | Cible | Status |
|------------|---------|-------|--------|
| `KWIN_DRM_NO_DIRECT_SCANOUT=1` | `/etc/environment` | Cause A (kwin) | Actif — partiel |
| `d3cold_allowed=0` (5 devices) | `/etc/udev/rules.d/99-egpu-no-d3cold.rules` | Cause B | Actif — résolu |
| `amdgpu.runpm=0` | rpm-ostree kargs | Cause D (DC resume) | Actif |
| ~~`amd-gpu-firmware p1`~~ | rpm-ostree local override | Cause C | **Retiré** — inefficace |

---

## Issues upstream

| Sujet | Repo | Status | Référence |
|-------|------|--------|-----------|
| MES v12 null ptr dereference | freedesktop drm/amd | Déposée | [#5274](https://gitlab.freedesktop.org/drm/amd/-/issues/5274) |
| Update firmware bb95ff5c inefficace + D3cold + DCN | freedesktop drm/amd | Commentaire posté | [note_3467811](https://gitlab.freedesktop.org/drm/amd/-/issues/5274#note_3467811) |
| GPU idle wake failure (GFXOFF) | freedesktop drm/amd | **Déposée** | [#5294](https://gitlab.freedesktop.org/drm/amd/-/work_items/5294) |
| PCI quirk D3cold OCuLink | bugzilla.kernel.org | **Déposée** | [#221540](https://bugzilla.kernel.org/show_bug.cgi?id=221540) |
| runtime PM resume CRTC | freedesktop drm/amd | À déposer | — |
