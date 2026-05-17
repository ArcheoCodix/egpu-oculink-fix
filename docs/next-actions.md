# Next actions — investigation à reprendre

Status : on attend des données nouvelles. Deux tests prêts à lancer dès qu'on a
le temps + l'occasion.

---

## 1. Test jeu natif Linux Vulkan (Cause C)

**But :** déterminer si le crash MES null ptr `0x705c` est spécifique au pattern
de soumission de queues compute de VKD3D-Proton, ou s'il survient aussi avec un
moteur Vulkan natif.

**Hypothèse :** tous nos crashs Cause C confirmés sont via Proton (Enshrouded,
PEAK.exe). Si un jeu natif Linux ne déclenche pas le crash en charge soutenue
similaire, le bug MES dépend du pattern VKD3D — workaround possible côté
DXVK/VKD3D plutôt qu'attendre un firmware AMD.

**Candidats jeux natifs Vulkan :**
- Baldur's Gate 3 (Larian, natif Linux/Vulkan)
- DOTA 2 (Source 2 Vulkan natif)
- No Man's Sky (natif Vulkan)
- DXVK pur sans Proton si possible

**Protocole :**
1. Lancer `~/egpu-oculink-fix/scripts/sclk-monitor.sh card1 2` avant le jeu
2. Session de 30-45 min de charge soutenue (équivalent Enshrouded qui crash en <30 min)
3. Si crash : vérifier `/var/log/amdgpu-coredumps/crash-*/` pour signature MES
   (chercher `MES failed to respond` dans `journal-kernel.txt`)
4. Si pas de crash après 45+ min : forte indication que c'est spécifique VKD3D-Proton

**Décision après test :**
- Crash natif identique → fix doit venir d'AMD (firmware), on reste sur #5274
- Pas de crash natif → poster sur #5274 + ouvrir issue côté DXVK/VKD3D-Proton

---

## 2. Bisection firmware MES (Cause C)

**But :** trouver la version de `gc_12_0_0_uni_mes.bin` qui n'a pas le bug null
ptr `0x705c`. Donnée actionnable pour #5274 : "regression introduced between X
and Y".

**Versions à tester** (du plus récent au plus ancien — depuis le repo
`gitlab.com/kernel-firmware/linux-firmware`) :

| SHA | Date | Status |
|-----|------|--------|
| bb95ff5c | 2026-05-07 | Testé (p1) — crash @ 0x705c (fw 0x89) |
| 37e9adcb | 2026-02-25 | Testé via base ogc1 — crash @ 0x705c (fw 0x89) |
| b2fdc1bd | 2025-11-19 | Non testé |
| 98306ae9 | 2025-09-16 | Non testé |
| b53bcd8a | 2025-08-08 | Non testé |
| 0e6cf73e | 2025-06-20 | Non testé |
| 009d751e | 2025-04-19 | Non testé |
| a9e53dc0 | 2025-03-11 | Non testé |
| 95bfb9ef | 2025-01-20 | Non testé |
| 335a3d30 | 2025-01-11 | Non testé |

**Note :** les firmwares antérieurs à ~mi-2025 peuvent ne pas supporter Navi 48
correctement (RDNA4 lancé début 2026 côté hardware). Vérifier que le GPU init
réussit avant de tester la charge.

**Protocole par version :**
1. Télécharger le `.bin` depuis l'historique git de linux-firmware
2. Patcher l'initramfs sur Bazzite (procédure documentée dans
   `upstream-todo.md` section 6) ou via rpm-ostree local override si possible
3. Reboot, vérifier la version MES chargée :
   `sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep MES`
4. Session Enshrouded 30+ min avec sclk-monitor
5. Crash ou pas → noter dans le tableau ci-dessus

**Coût estimé :** ~45 min/version (firmware swap + reboot + gaming + nettoyage).
Bisection log₂(8) ≈ 3 versions à tester en pratique pour cerner la régression.

**Décision après bisection :**
- Si version X ne crashe pas → poster sur #5274 avec la fourchette de régression,
  ce qui aide AMD à identifier le commit fautif dans leur tree firmware interne.
- Si toutes versions historiques crashent → bug présent depuis le support initial
  de Navi 48, AMD doit toujours fournir un fix.

---

## Pas dans cette liste — raisons

- ~~`pcie_aspm=off`~~ : ASPM déjà désactivé hardware-side sur toute la chaîne
  OCuLink (vérifié live). Sans effet. Documenté dans `crash-analysis.md`.
- ~~`echo N > pp_dpm_sclk`~~ : table DPM Navi 48 = `{0: 500MHz, 1: DS_GFXCLK, 2: 2520MHz}`.
  Aucune state intermédiaire qui pinne au-dessus de DS_GFXCLK sans forcer le max.
- ~~Patch `smu_v14_0_2_ppt.c` + `PP_SCLK_DEEP_SLEEP_MASK`~~ : la PMFW ignore
  `DisableSmuFeatures(DS_GFXCLK)` autonomously (#5194 confirme). Patch driver
  seul ne suffirait pas.
- ~~`amdgpu.uni_mes=0`~~ : déjà testé (crash 9), legacy MES crashe plus vite
  (offset 0xa2f, <1 min). Pire que unified.

---

## Maintenance passive

- Vérifier nouvelles versions firmware MES :
  `curl -s 'https://gitlab.com/api/v4/projects/kernel-firmware%2Flinux-firmware/repository/commits?path=amdgpu/gc_12_0_0_uni_mes.bin&per_page=5' | python3 -c "import json,sys; [print(c['short_id'], c['committed_date'][:10], c['title'][:60]) for c in json.load(sys.stdin)]"`
- Vérifier réponse maintainer PCI sur bugzilla #221540
- Vérifier réponses AMD sur #5274 et #5294
