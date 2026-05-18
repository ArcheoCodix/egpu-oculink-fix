# Next actions — investigation à reprendre

Mise à jour : 2026-05-18. Deux sessions de test depuis la dernière version.

---

## PRIORITÉ 1 — Audit kernel : wake-signal path Navi 48 (Cause A)

**Statut : À FAIRE — seule voie viable restante pour Cause A**

Tous les workarounds userspace ont été testés et rejetés (voir section "Pas dans cette
liste"). PMFW Navi 48 a une autonomie complète sur DS_GFXCLK — aucun message driver
(DisableSmuFeatures, SetSoftMinByFreq, SetSoftFreqLimitedRange, GFXOFF karg) n'y change
quoi que ce soit.

**But :** identifier pourquoi les soumissions ring (kwin flip, DXVK SDMA, VKD3D compute,
CS2 VKRenderThread) ne réveillent pas le GPU depuis DS_GFXCLK, alors qu'une charge
continue le maintient éveillé.

**Reproducteur fiable disponible :** CS2 → charger shaders (100% GPU) → aller au menu
→ GPU entre DS_GFXCLK en <2 s → kwin flip ou CS2 VKRenderThread timeout en ~60 s.

**Hypothèse révisée :** ce n'est pas un message PM manquant (tous testés, tous ignorés
par PMFW). C'est soit :
- (a) un signal de réveil dans le chemin de soumission ring qui existait sur Navi 21/31
  et est absent/cassé sur gfx_v12/sdma_v7 pour RDNA4
- (b) PMFW Navi 48 a supprimé la réponse au réveil driver — dans ce cas c'est un bug
  firmware pur, et Cause A est non fixable sans AMD

**Protocole (analyse code, pas test runtime) :**
1. Cloner les sources du kernel actif (`linux-6.19.14`, branche ogc5)
2. Dans `drivers/gpu/drm/amd/amdgpu/` : grep `amdgpu_ring_commit`,
   `amdgpu_job_run`, `amdgpu_fence_emit` — chercher tout appel à
   `amdgpu_dpm_*` / `amdgpu_gfx_off_ctrl` / messages SMU avant submission
3. Comparer le path GFX vs SDMA/compute
4. Comparer gfx_v12/sdma_v7 (Navi 48) vs gfx_v10/v11 (Navi 21/31) — diff des
   callbacks ring init et submit

**Décision après analyse :**
- Wake-call manquant identifié → patch kernel + test avec CS2 reproducer → soumettre upstream
- Aucun wake explicite dans le driver → bug firmware pur → mettre à jour #5294 avec
  cette conclusion pour orienter AMD

---

## PRIORITÉ 2 — Test Cause C sur jeu natif (Cause C)

**Statut : BLOQUÉ par Cause A**

CS2 a crashé en Cause A avant d'atteindre 30 min de charge soutenue — le test Cause C
n'a pas pu avoir lieu. Tant que Cause A n'est pas workaroundée, tout jeu qui passe par
le menu avant la partie risque de crasher en Cause A d'abord.

**Alternatives :**
- Lancer BG3 ou Dota2 **directement en partie** (skip menu si possible) pour 30-45 min
- Ou attendre le patch Cause A (action 1) avant de retester

**Protocole (inchangé) :**
1. `~/egpu-oculink-fix/scripts/sclk-monitor.sh card1 2` avant le jeu
2. Session 30-45 min de charge soutenue (jeu actif, pas menu)
3. Si crash Cause C → `MES failed to respond` dans journal → fix doit venir d'AMD
4. Si pas de crash Cause C → bug MES spécifique VKD3D-Proton → issue côté DXVK/VKD3D

---

## PRIORITÉ 3 — Bisection firmware MES (Cause C)

**Statut : À FAIRE — en attente d'une occasion**

**But :** trouver la version de `gc_12_0_0_uni_mes.bin` sans le bug null ptr `0x705c`.
Donnée actionnable pour #5274 : "régression introduite entre X et Y".

**Versions à tester** (du plus récent au plus ancien) :

| SHA | Date | Status |
|-----|------|--------|
| bb95ff5c | 2026-05-07 | Crash @ 0x705c (fw 0x89) — p1 firmware |
| 37e9adcb | 2026-02-25 | Crash @ 0x705c (fw 0x89) — base ogc1 |
| b2fdc1bd | 2025-11-19 | Non testé |
| 98306ae9 | 2025-09-16 | Non testé |
| b53bcd8a | 2025-08-08 | Non testé |
| 0e6cf73e | 2025-06-20 | Non testé |
| 009d751e | 2025-04-19 | Non testé |
| a9e53dc0 | 2025-03-11 | Non testé |
| 95bfb9ef | 2025-01-20 | Non testé |
| 335a3d30 | 2025-01-11 | Non testé |

**Note :** firmwares antérieurs à ~mi-2025 peuvent ne pas supporter Navi 48 (RDNA4
lancé début 2026). Vérifier que le GPU init réussit avant de tester la charge.

**Protocole par version :**
1. Télécharger le `.bin` depuis l'historique git de linux-firmware
2. Override via rpm-ostree local (procédure dans `upstream-todo.md` section 6)
3. Reboot, vérifier : `sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep MES`
4. Session Enshrouded 30+ min avec sclk-monitor
5. Crash ou pas → noter dans le tableau

**Décision :**
- Version X sans crash → poster fourchette de régression sur #5274
- Toutes versions crashent → bug présent depuis support initial Navi 48, AMD doit fixer

---

## Pas dans cette liste — tout ce qui a été testé et rejeté

### Workarounds Cause A — tous testés 2026-05-18, tous inefficaces

PMFW Navi 48 a une autonomie totale sur DS_GFXCLK. Aucune de ces commandes ne
maintient SCLK au-dessus de 60 MHz à l'idle.

| Méthode | Mécanisme SMU | Résultat |
|---------|--------------|---------|
| `pp_features` write (bit 10) | DisableSmuFeatures | PMFW réactive DS_GFXCLK autonomously |
| `ppfeaturemask` | PP_SCLK_DEEP_SLEEP_MASK | Absent de smu_v14_0_2_ppt.c |
| `force_performance_level=high` | SetSoftMinByFreq | PMFW ignore, état 1 reste actif |
| `amdgpu_force_sclk 500/2520` | SetSoftFreqLimitedRange | Write OK, PMFW ignore |
| `amdgpu_gfxoff 0` | PP_GFXOFF_MASK | EINVAL (runpm=0 verrouille) |
| `amdgpu.gfxoff=0` karg | PP_GFXOFF_MASK init | GFXOFF reste enabled, DS_GFXCLK actif |
| `KWIN_DRM_NO_DIRECT_SCANOUT=1` | — | Couvre scanout direct, pas composition |

### Autres — hors scope ou déjà testés

- `pcie_aspm=off` : ASPM déjà désactivé hardware-side sur toute la chaîne OCuLink.
- `echo N > pp_dpm_sclk` : état 1 = DS_GFXCLK lui-même. Masquer état 1 ne fait qu'exclure
  un état entre 500 MHz et 2520 MHz.
- Patch `smu_v14_0_2_ppt.c` + `PP_SCLK_DEEP_SLEEP_MASK` : PMFW ignore DisableSmuFeatures,
  un patch driver seul ne suffirait pas.
- `amdgpu.uni_mes=0` : legacy MES crashe en <1 min (crash 9, offset 0xa2f). Pire.

---

## Maintenance passive

- Nouvelles versions firmware MES :
  ```
  curl -s 'https://gitlab.com/api/v4/projects/kernel-firmware%2Flinux-firmware/repository/commits?path=amdgpu/gc_12_0_0_uni_mes.bin&per_page=5' | python3 -c "import json,sys; [print(c['short_id'], c['committed_date'][:10], c['title'][:60]) for c in json.load(sys.stdin)]"
  ```
- Réponse maintainer PCI sur bugzilla #221540
- Réponses AMD sur #5274 et #5294
