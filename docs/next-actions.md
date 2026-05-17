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

## 3. Audit kernel : wake-signal path Navi 48 (Cause A)

**But :** identifier pourquoi certains rings (kwin flip `gfx_0.0.0`, DXVK `sdma1`,
VKD3D `comp_1.0.1`) ne réveillent pas le GPU avant d'attendre la complétion du
job, alors qu'une charge continue le maintient éveillé sans souci.

**Hypothèse :** un appel de wake (vers PMFW ou message SMU type
`WakeFromGfxoff`/`SetSoftMinByFreq`) présent dans certains chemins de soumission
est manquant pour SDMA et compute sur RDNA4 (gfx_v12/sdma_v7/mes_v12). Si vrai,
Cause A est un bug driver (omission RDNA4) et non un bug firmware — c'est-à-dire
fixable côté kernel, contrairement à ce qu'on a écrit jusqu'ici.

**Protocole (analyse code, pas test runtime) :**
1. Cloner les sources du kernel actif (`linux-6.19.14`, branche ogc5)
2. Dans `drivers/gpu/drm/amd/amdgpu/` : grep `amdgpu_ring_commit`,
   `amdgpu_job_run`, `amdgpu_fence_emit`, chercher tout appel à
   `amdgpu_dpm_*` / `amdgpu_device_ip_set_powergating_state` / messages SMU
   avant submission
3. Comparer le path GFX (semble OK sous charge continue) vs SDMA/compute paths
4. Comparer Navi 48 (gfx_v12, sdma_v7) vs Navi 21/31 (gfx_v10/v11) où Cause A
   n'est pas rapportée. Diff entre les init ring callbacks est la cible

**Output attendu :** un patch testable (ajouter le wake-call manquant dans le
path SDMA/compute) ou la confirmation que le wake est entièrement délégué à PMFW
côté firmware — auquel cas on recadre #5294 avec cette donnée.

**Décision après analyse :**
- Wake-call manquant identifié → build kernel custom + patch, valider en
  reproduisant Cause A (déjà difficile, voir crash-registry), soumettre upstream
- Aucun wake explicite quelque part dans amdgpu → preuve que c'est purement
  firmware, mettre à jour #5294 avec l'analyse pour orienter AMD

---

## 4. Test SMU SetHardMinByFreq sur GFXCLK (Cause A)

**But :** vérifier si le message SMU `SetHardMinByFreq(PPCLK_GFXCLK, N)` est
honoré par PMFW, là où `DisableSmuFeatures(DS_GFXCLK)` et `force_performance_level=high`
sont ignorés. C'est un plancher dur côté firmware, mécaniquement distinct des
masques de features.

**Hypothèse :** PMFW pourrait respecter un HardMin alors qu'elle ignore les
masques. Si oui, plancher à 500 MHz (DPM state 0) empêche l'entrée DS_GFXCLK et
masque Cause A jusqu'au fix firmware réel.

**À distinguer du patch déjà rejeté :** le patch `PP_SCLK_DEEP_SLEEP_MASK` rejeté
plus bas porte sur le message `DisableSmuFeatures` à l'init. `SetHardMinByFreq`
est un message SMU différent — même si la PMFW ignore le premier, elle peut
respecter le second (utilisé par AMD pour pin display clock par exemple).

**Vérification préalable (code) :**
1. Grep `SetHardMinByFreq` / `set_hard_min_freq` dans
   `drivers/gpu/drm/amd/pm/swsmu/smu14/smu_v14_0_2_ppt.c`
2. Vérifier que `PPCLK_GFXCLK` est dans la table des clocks autorisés pour ce
   message sur smu_v14_0_2

**Protocole de test :**
1. Si exposé via debugfs : `echo` la valeur directement, mesurer SCLK live
2. Sinon : patch driver appelant `smu_set_hard_min_freq(SMU_GFXCLK, 500)` à
   l'init, rebuild kernel
3. `sclk-monitor.sh card1 2` : SCLK doit rester ≥ 500 MHz idle compris
4. Si plancher tenu : usage normal 2–3 h, vérifier absence ring timeout Cause A

**Risque connu :** plancher 500 MHz idle = ~+5–10 W consommation continue. Pas
un problème en eGPU desktop ; à noter si on porte la solution à un setup mobile.

**Décision après test :**
- HardMin tenu et Cause A absent → workaround driver-side viable, patch soumis
  upstream + commentaire #5294
- HardMin tenu mais Cause A persiste → bug n'est pas dans la profondeur d'idle
  mais bien dans la séquence wake (renvoi vers action 3)
- HardMin ignoré comme les masques → confirmation que tout pilotage SCLK passe
  par PMFW autonome, escalade #5294 avec cette preuve

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
