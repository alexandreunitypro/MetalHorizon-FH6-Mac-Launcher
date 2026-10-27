# Passation complète : Forza Horizon 6 (édition Microsoft Store) sous Wine sur macOS

Ce document permet à une autre IA de reprendre le travail **comme si elle avait suivi toute la conversation**.
Il est écrit à partir de ce qui s'est réellement passé et prouvé (logs collés par l'utilisateur, fichiers du
dépôt). Quand quelque chose est une **hypothèse**, c'est écrit « hypothèse ». Quand c'est **vérifié sur le Mac**,
c'est écrit « prouvé ».

- Dépôt : `alexandreunitypro/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT`
- Branche de travail : `claude/clever-fermat-0kxfc1` (ne pas pousser ailleurs sans accord)
- Dates : 19 au 21 octobre 2026 (les logs et dossiers de l'utilisateur sont datés du 2026-10-19)
- Documents liés : `docs/ANALYSE-FH6-STORE-MACOS.md` (preuves techniques, section 7 = résultats sur le Mac),
  `docs/TUTORIEL-TEST-MAC.md` (tutoriel de départ, partiellement dépassé : ce document fait foi)

---

## 0. L'essentiel en une page

**Où on en est (21 octobre 2026, fin de session).**

| Question | Réponse |
|---|---|
| Le jeu démarre ? | **Oui.** Le jeu se lance. On voit la scène du jeu (autoroute) derrière une boîte de dialogue. |
| Licence, protection, Xbox runtime ? | Prouvé : « Package license accepted », `xgameruntime.dll` chargée, fichier déchiffré servi (`image served: 4`), aucun arrêt volontaire du jeu. |
| Contrôle de compatibilité matérielle (FH205 / FH206) ? | **Passé.** La boîte « Avertissement de compatibilité » a disparu avec le shim DirectX 12 de Highball (voir §7). |
| Sauvegardes cloud (compte Microsoft) ? | **Synchro PlayFab fonctionnelle** (`hr 0`). Pas encore vérifié : progression téléchargée, remontée à la fermeture normale, stabilité longue durée. [icex/ferestre](https://github.com/icex/ferestre) donne FH6 « playable » avec la synchro PlayFab native validée, même paquet 3.461.691.0. |
| Ce qui s'affiche maintenant | **La boîte « Game Saves » a disparu** (21 octobre 2026, soir). Run de 360 s : `work_complete PlayFab operation 0 completed, hr 0`, aucune ligne `ui_failed`, aucun texte de boîte, pas d'arrêt anormal.. Causes trouvées et corrigées : voir la phase 13 (§5). |
| Polices / boîtes illisibles ? | **Corrigé** (FreeType activé, `GetDialogBaseUnits` 0 → `00100008`, 968 familles de polices). **Pas encore revérifié en jeu** : l'utilisateur n'a pas encore relancé le jeu pour voir les trois boutons lisibles. |
| Connexion Xbox / compte Microsoft ? | **Oui, prouvé** : `xodus-service` (lancé par le lanceur) donne les jetons XSTS ; `xsts_token_once got a 2111-character token … (gamertag "<pseudo>")` ; le jeu affiche « Bienvenue, <pseudo> » ; login PlayFab réussi (`POST /Client/LoginWithXbox`, réponse 200). |
| Le jeu atteint le menu ? / ses sauvegardes cloud sont-elles là ? | **À confirmer par l'utilisateur** (ce qu'il voit après la boîte, bouton « Continuer » avec la progression du compte). Les journaux disent seulement que la synchro PlayFab se termine sans erreur. |

**Première chose à faire à la reprise :** demander à l'utilisateur ce qu'il voit en jeu après le démarrage (menu ? « Continuer » avec
sa progression ? plantage ?) et le laisser **jouer** avec la commande « mode jeu » du `README.md`. **Fermeture** : quitter par le menu du
jeu et attendre environ 30 s (envoi final des sauvegardes) ; ne pas tuer le Terminal. Si une boîte propose de choisir entre sauvegarde
locale et cloud, choisir **Cloud**.

**Ce qu'il ne faut pas refaire :** tout ce qui est en §5 est réglé et documenté ; ne pas re-diagnostiquer la
relecture de l'exe, le déroulé SEH, le crash D3DMetal, le chemin long, les polices.

---

## 1. Cadre de travail, règles, et l'utilisateur

### 1.1 Règles posées par l'utilisateur (dans l'ordre où elles sont apparues)

- **Pas de sous-agents.**
- **Ne pas modifier le binaire du jeu.** Rien dans ce projet ne le modifie : xodus déchiffre le paquet MSIXVC
  que l'utilisateur possède, Wine l'exécute tel quel.
- Au début : « ne pas contourner la protection, la licence ou l'anti-triche ». Plus tard, l'utilisateur a dit
  qu'il ne se fixe pas de règle sur le contrôle de compatibilité et a demandé d'**aligner exactement la
  configuration sur Highball** (« je veux me présenter exactement comme Highball a fait, aucune différence »).
  Rien de ce qui a été fait ne touche à la licence ni à l'anti-triche : la licence est acceptée par le jeu lui-même.
- **Pas de partage de jetons ni de secrets.** Au début, l'utilisateur a collé par erreur un jeton GitHub dans le
  chat ; on lui a conseillé de le **révoquer**. Ne jamais le redemander, l'afficher ni le stocker.
- **Ne rien présenter comme un fait sans preuve.**
- **Modifications réversibles :** une sauvegarde `.bak` avant chaque remplacement et un `--undo` dans les scripts.
- **Ne pas détruire le travail existant** (Ferestre, FHTRACE de l'utilisateur, etc.).
- Ne pas créer de pull request sans demande explicite. Aucune PR n'a été créée.

### 1.2 Pratique

- Réponses en français, simples, une commande à la fois, prête à coller, en disant où mettre le résultat.
- Chaque nouvel onglet de Terminal démarre dans `~` : commencer par `cd ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT`.
- `zsh` peut ajouter `[200~` au collage (« bracketed paste »). Remède : `unset zle_bracketed_paste`.
- Pas de balise parasite (`</parameter>`) à la fin d'un bloc de code : ça casse le collage.
- Préférer les tests rapides sans le jeu (`d3d12probe`, `fontprobe`, `gpuprobe`) aux lancements de 10 minutes.

### 1.3 Environnement de l'IA

- La session tourne dans un **conteneur cloud Linux**. **Aucun accès au Mac** de l'utilisateur : tout passe par
  des commandes qu'il colle et des logs qu'il renvoie.
- Le mingw Linux du conteneur est **trop vieux** (en-têtes `d3d12.h` anciens) : le shim `d3d12.c` n'y compile
  pas. Il compile sur le Mac avec **llvm-mingw 20260908** (prouvé : « marked builtin: d3d12.dll »).
- Les commits portent l'attribution fournie par le rappel de session de l'IA qui les crée
  (`Co-Authored-By:` + `Claude-Session:`). La session a changé de modèle trois fois (Opus 5.5, Opus 4.8,
  Sonnet 5.5) : les commits portent donc des signatures différentes. Sans importance.
- Un résumé de réponse a été **interrompu par un classifieur de sécurité** quand la discussion portait sur le
  choix d'identifiants matériels (voir §5, phase 11). Ce n'est pas une erreur technique.

---

## 2. La machine de l'utilisateur

| Élément | Valeur |
|---|---|
| Mac | Apple M5 Pro, 18 cœurs, 48 Go, **macOS 27.0.1**.  |
| Clone du dépôt | `~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT` |
| `WORK` | `/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work` |
| Sources Wine (base CrossOver) | `$WORK/crossover-source/sources/wine` |
| Build Wine | `$WORK/crossover-source/build-x64-cross` |
| Wine installé (« engine ») | `$WORK/crossover-source/out-x64/engine` (Wine x86_64 sous Rosetta ; **le moteur est un build maison**, pas CrossOver.app) |
| Compilateur PE | `$WORK/toolchains/llvm-mingw-20260908-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang`. Le build l'appelle `x86_64-w64-mingw32-gcc`. Les scripts créent un lien dans `out/cross-bin` |
| xodus (déchiffrement MSIXVC) | `$WORK/xodus` ; binaire `target/release/xodus-cli` (arm64). **Il résout les liens symboliques** du dossier du jeu |
| **Dossier du jeu** | **`~/FH6`** (renommé par `tools/mac_move_short.sh`). L'ancien `$WORK/audit/gamefarm-audit` est un **lien symbolique** vers `~/FH6` |
| Préfixe Wine | `~/FH6/.blackwell-wine` |
| CrossOver.app | `/Applications/CrossOver.app` : fournit les d3d12 (`lib64/apple_gptk/wine`), D3DMetal 3.0 (`lib64/apple_gptk/external`), `libfreetype.6.dylib` x86_64 (`lib64`), les polices Wine (`share/wine/fonts`) |
| D3DMetal 4.0b3 | dans `…/Blackwell FH6 Final.app/Contents/Resources/GPTK4/external` (seulement `D3DMetal.framework` et `libd3dshared.dylib`). Chemin complet dans `tools/mac_launch_fh6.sh` |
| Homebrew | présent ; `bison 3.8.2` installé mais non lié (inutile : on n'utilise pas `configure`). Aucun en-tête FreeType n'a été trouvé sur le Mac, d'où le téléchargement des en-têtes |
| Outils | Python 3, `cmake`/`protoc` trouvés dans `$WORK/cmake-python` et `$WORK/protoc`, Xcode Command Line Tools (`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) |

**Tous les chemins sont codés en dur dans `tools/mac_*.sh`.** Ne pas les « généraliser » sans demander.

**Ce que l'utilisateur possède :** l'édition **Microsoft Store / Xbox (MSIXVC)** de FH6. Pas la version Steam.

---

## 3. Comment ça marche (architecture)

1. **xodus** (`xodus-cli run <dossier> <wine> --exe forzahorizon6.exe`) déchiffre le paquet MSIXVC et lance Wine.
   L'exe reste chiffré sur disque. La version déchiffrée est passée à Wine par un descripteur nommé dans
   `WINE_DLL_FILE_MAP="fd:\??\Z:\…"` (une entrée pour l'exe, une deuxième malformée `15:\??\Z:\??\Z:\…`,
   préfixe en double ajouté par le xodus de l'utilisateur ; sans effet constaté).
2. **Wine** (build maison, base **CrossOver 26.3 sources**) + patches **Ferestre** (0006, 0009, 0010, 0013 et
   retrait de GlobalRoot de Proton, déjà présents dans l'arbre de l'utilisateur) servent l'image déchiffrée quand
   le jeu ouvre son propre `.exe` (y compris sous la forme `\??\GLOBALROOT\??\Z:\…`).
3. Le jeu fait une **vérification d'empreinte de son propre exe** (trois relectures), puis charge
   `xgameruntime.dll` (couche Xbox), les modules NVIDIA Streamline (`sl.*.dll`), l'audio, DirectX 12.
4. **DirectX 12 → Metal** via **D3DMetal** (Apple, Game Porting Toolkit) : le d3d12 de Wine charge un
   `d3d12.so` (macOS) qui parle à `D3DMetal.framework`.
5. Un **shim DirectX 12** (celui de Highball) se place devant le d3d12 de CrossOver. Le vrai d3d12 est copié sous
   le nom `apd12.dll` (nom d'export interne changé pour que Wine ne confonde pas les deux).
6. Les identifiants GPU présentés au jeu viennent des variables `D3DM_VENDOR_ID`, `D3DM_DEVICE_ID`,
   `D3DM_DEVICE_DESCRIPTION` lues par D3DMetal.

Schéma de la pile (de haut en bas) :

```
forzahorizon6.exe (déchiffré par xodus)
  └─ Wine 11 (CrossOver 26.3 + Ferestre + correctifs de ce dépôt + patches Highball)
       ├─ d3d12.dll  = SHIM Highball (tools/tsshim/d3d12.c)
       │     └─ apd12.dll = d3d12 de CrossOver.app (nom d'export renommé) + apd12.so (lien)
       │           └─ D3DMetal 4.0b3 (GPTK4) → Metal
       └─ win32u.so (FreeType activé) → polices macOS
```

---

## 4. Lancer, options, lire un rapport

### 4.0 Jouer au quotidien (sans journal)

`bash ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT/tools/jouer.sh` : `FH6_QUICK=1` dans `mac_launch_fh6.sh` (pas de traces, pas de journal, pas de vérifications,
service Xbox démarré, `FH6_CX_GPTK=1 FH6_D3DM4=1` par défaut, ne tue que son propre wineserver). Fermer **par le menu du jeu** puis attendre ~30 s. Un plantage ne laisse
aucun journal dans ce mode : pour diagnostiquer, utiliser `mac_all.sh` / `mac_launch_fh6.sh` avec `FH6_DEBUG="err+all,+loaddll"`, puis `tools/mac_crash_report.sh`.

**Expérience de vitesse `FH6_AVX=1` (`ROSETTA_ADVERTISE_AVX=1`) : ÉCHEC, À NE PAS UTILISER.** Résultat de l'utilisateur (22 octobre 2026) : **le jeu plante avec AVX annoncé, et ne plante pas sans**. Cause non analysée (journal à lire avec `FH6_DEBUG="err+all,+loaddll"` puis `tools/mac_crash_report.sh` si on veut y revenir). L'option reste dans le lanceur, désactivée par défaut. **MetalFX : refusé par l'utilisateur, ne pas le proposer ni l'ajouter.** Mesuré avec `tools/mac_cpuid_probe.sh` (macOS 27.0.1, M5 Pro) : **sans** le réglage Rosetta annonce `AVX: no / AVX2: no / OSXSAVE: no` ;
**avec** : `AVX, AVX2, FMA, BMI2: yes`. Utilisation : `FH6_AVX=1 bash tools/jouer.sh`. Comparer le compteur d'images au même endroit.
**Metal HUD : ACTIF PAR DÉFAUT depuis le 22 octobre 2026 (demande de l'utilisateur)** ; `FH6_HUD=0` pour le couper. Pas encore vérifié qu'il s'affiche avec FH6. Autres outils Apple (options) : `FH6_METAL_DEBUG=1` (validation Metal, **très lent**, chasse aux plantages seulement), `FH6_METAL_CAPTURE=1` (captures GPU Xcode/xctrace), `tools/mac_metal_trace.sh` (Metal System Trace via `xctrace`, **exige Xcode complet**, à lancer pendant que le jeu tourne). Je n'ai trouvé aucune documentation fiable pour un journal du HUD (`MTL_HUD_LOG_ENABLED` non vérifié : ne pas l'utiliser).
Highball propose aussi un moteur FEX (ARM64EC) mais son README le donne « à moins de 20 % de Rosetta » : préparation à la fin de Rosetta (macOS 28), pas un gain.

### 4.1 La commande de référence

```sh
pkill -f xodus-cli; pkill -f wineserver; sleep 2; cd ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT && git pull -q && FH6_CX_GPTK=1 FH6_D3DM4=1 FH6_DEBUG="-all" bash tools/mac_all.sh 3600
```

(`FH6_DEBUG="-all"` = pas de traces, jeu plus rapide ; le rapport sera pauvre. Pour diagnostiquer, retirer
`FH6_DEBUG` ou mettre `+loaddll,warn+process,err+all`, et ajouter `HB_TSSHIM_DEBUG=1` pour que le shim écrive
dans `C:\highball\logs`.)

`tools/mac_all.sh` : applique ce qui manque (shim, patches Forza, chemin court, déroulé leaf, polices, traces de
diagnostic), lance le jeu, fabrique un rapport (`out/report.txt`) et **le copie dans le presse-papiers**
(« == RAPPORT COPIE »). L'utilisateur colle ensuite ce rapport **dans le chat**.

**FreeType n'est pas dans `mac_all.sh`** (opération longue, une seule fois) : `bash tools/mac_enable_freetype.sh`
(déjà fait avec succès).

### 4.2 Variables d'environnement reconnues par `tools/mac_launch_fh6.sh`

| Variable | Effet |
|---|---|
| `FH6_CX_GPTK=1` | Utilise les d3d12 de CrossOver.app. **Obligatoire** : sans, la copie GPTK4 plante dans `D3D12CreateDevice` (§5 phase 5) |
| `FH6_D3DM4=1` | Utilise **D3DMetal 4.0b3** (shader model 6.8) au lieu du 3.0 de CrossOver (6.6 max). **Obligatoire** pour FH6 (barrières DX12 améliorées) |
| `FH6_GPU=nvidia\|amd\|intel` | Carte présentée au jeu. **Défaut : `nvidia`** = recette actuelle de Highball (0x10de / 0x2786, « NVIDIA GeForce RTX 4070 »). `intel` = ancien Reddit (0x8086 / 0x56a1, Arc A750) ; `amd` = 0x1002 / 0x73bf (à éviter : chemin AMD du jeu qui plante) |
| `FH6_NO_SHIM=1` | Pas de shim Highball (alors FH205/FH206 reviennent) |
| `FH6_NO_TSSHIM=1` | Ne pas utiliser l'ancien shim `renderers/d3dmetal-tsshim` de l'utilisateur |
| `FH6_LONG_PATH=1` | Garde l'ancien chemin long (le jeu quitte alors sur « Installation path is too long ») |
| `FH6_DEBUG=…` | Remplace `WINEDEBUG`. Défaut de `mac_all.sh` : `+timestamp,+loaddll,warn+process,warn+seh,+seh,+unwind,+win,+dialog,err+all` (**très lourd** : 18 à 93 millions de lignes, 15 000 000 de pièges `c000001d`). `-all` = aucune trace |
| `HB_TSSHIM_DEBUG=1` | Le shim écrit un journal dans `~/FH6/.blackwell-wine/drive_c/highball/logs/tsshim-*.log` (pipelines, formats de cibles ; `=2` ajoute chaque ressource, lent). Le lanceur range les anciens dans `logs/old` |
| `HB_TSSHIM_DEPTHRESOLVE=1` | Laisse passer le `ResolveSubresource` multisample que le shim saute (inutile avec D3DMetal 4.0b3 ?) |
| `HB_TSSHIM_APPEND_OFFSETS=0` | Désactive la correction des offsets `APPEND_ALIGNED_ELEMENT` |
| `HB_TSSHIM_SHADINGRATE=0` | Désactive la correction des pixel shaders qui lisent `SV_ShadingRate` (§10, « Rendu ») |
| `HB_TSSHIM_UNUSED_BLEND=0` | Désactive l'arrêt du mélange double source inutilisé des pipelines sans cible de couleur (§10, « Rendu ») |
| `HB_TSSHIM_REPLACE=fix[,dossier]` | Shaders de remplacement `C:\highball\replace\<dossier>` (le lanceur met `fix` par défaut, `none` coupe ; §10 « Rendu ») |
| `HB_TSSHIM_DUMP=1` | Le shim copie les vertex/pixel shaders de chaque pipeline dans `C:\highball\shaders` (`<empreinte>.vs/.ps`, `pairs-<pid>.txt`), pour `tools/dxilbench` (≈ 100 Mo par run) |
| `HB_SPATIAL=0\|speakers\|headphones\|external` | Patch Highball 0023 (son surround) |

### 4.3 Lire les résultats : repères

- **Log complet :** `out/fh6-after.log` (peut dépasser 90 millions de lignes). **Copie réduite :**
  `out/fh6-small.log` (sans les lignes seh/unwind par piège), produite en **un seul passage** par le lanceur ;
  `mac_all.sh` travaille sur cette copie.
- Les **traces de diagnostic locales** (`FHTRACE …`, `FH6 null call`, `FH6 message box …`) sont **ajoutées par ce
  projet ou par l'utilisateur** dans Wine. Elles ne sont pas du Wine standard.
- Le **texte des boîtes de dialogue** est dans le log (`FH6 message box text[0] …`) même quand la boîte est
  illisible à l'écran.
- `i` dans le résumé = secondes d'exécution. Un run **qui s'arrête à 77 s** peut être arrêté **par
  l'utilisateur** : demander avant de conclure à un plantage.

---

## 5. Chronologie complète, de A à Z

Chaque phase : **problème → cause → preuve → correctif (fichier)**.

### Phase 1 : mission et premier diagnostic

- Mission initiale : faire démarrer FH6 Store sur macOS ; symptômes : `SIGILL`, `xgameruntime.dll` jamais
  chargée, `GLOBALROOT`, tuer le jeu à 14 s (`diag-codebytes.sh` de l'utilisateur).
- Cahier des charges détaillé, règles du §1.1. Un dépôt a été cloné, des docs écrites
  (`README.md`, `docs/ANALYSE-FH6-STORE-MACOS.md`, `docs/TUTORIEL-TEST-MAC.md`).
- **Établi** : les `SIGILL` (valeur de retour `ffffffff` du gestionnaire VEH = `EXCEPTION_CONTINUE_EXECUTION`)
  sont le **mécanisme normal de la protection** (sonde : `ud2`, `hlt`, `int3` sont livrés correctement sur le
  Mac, 20 µs par piège). Pas la cause du blocage.

### Phase 2 : le vrai blocage initial, la relecture de l'exe

- **Problème** : sur macOS, xodus utilise `tempfile()` (fichier supprimé aussitôt créé), Ferestre 0009 rouvre le
  descripteur via `/proc/self/fd` **qui n'existe pas sur macOS**. Toutes les ouvertures partagent **une seule
  position de lecture**. Forza relit trois fois son propre `.exe` pour en vérifier l'empreinte : dès la
  deuxième relecture il lit **0 octet**, l'empreinte est fausse, le jeu s'arrête lui-même avant de charger
  `xgameruntime.dll`.
- **Preuve** : `tools/selfread/selfread.c` (sonde Windows qui rejoue le contrôle) lancée par
  `tools/mapfd_run.py` : **4 échecs avant correctif, 0 après**.
- **Correctifs** :
  - `patches/wine/0001-ntdll-macos-reopen-mapped-image-by-path.patch` : sur macOS, rouvrir le fichier par son
    nom (`fcntl(F_GETPATH)`) en vérifiant `st_dev`/`st_ino`. Appliqué sur le Mac par
    `tools/mac_apply_wine_fix.sh` (+ `tools/mac_replace_mapped_fd.py`, remplacement par nom de fonction car
    `patch` échouait sur son `loader.c`). Sauvegardes `.pre-fh6-reopen.bak` ; `--undo` disponible.
  - `patches/xodus-cli/0001-macos-keep-decrypted-image-named-on-ramdisk.patch` : xodus garde le fichier déchiffré
    nommé jusqu'à la fin de Wine, puis le supprime. Appliqué par `tools/mac_apply_xodus_fix.sh`
    (+ `tools/mac_replace_make_temp_file.py`, **deux variantes** de `run.rs` gérées). Sauvegarde
    `.pre-fh6-named.bak`.
- **Obstacles rencontrés** (à connaître) : macOS efface `DYLD_*` au lancement de `/usr/bin/python3` (le script
  passe `DYLD_LIBRARY_PATH` lui-même) ; fenêtre Mono/Gecko invisible qui bloque la création du préfixe
  (`WINEDLLOVERRIDES=mscoree,mshtml=` + `pkill`) ; `assert.h` introuvable (**`SDKROOT` via `xcrun`**) ; aucun
  `BlackwellLauncher.app` (on corrige directement le `xodus-cli` du dossier de travail) ; `cmake`/`protoc`
  absents du PATH.
- **Inventaire** (`tools/check_runtime.py`) : 0006, 0009, 0010, 0013, retrait GlobalRoot de Proton, concrt140 0015
  présents ; empreintes concrt `f9aff5d6…`, `xgameruntime.so` `9028b263…`.

### Phase 3 : première fois que le jeu va loin, et une trace qui plante Wine

- Le jeu charge, puis « Unhandled page fault on read access to 0000000003260000 (thread 0114) » : **c'est la trace
  locale `FHTRACE` de `call_vectored_handlers`** (`dlls/ntdll/exception.c`, pas du code Wine) qui lisait
  **24 cases de pile au-delà de `Tib.StackBase`**.
- **Correctif** : `tools/mac_fix_vectored_trace.py` / `.sh` : trace bornée, active seulement avec `+seh`, et
  tolère un `RIP` bas (`< 0x10000`). Reconstruit **`ntdll.dll`** (PE). Sauvegarde `.pre-fh6-trace.bak`.
  (Premier essai : `x86_64-w64-mingw32-gcc` introuvable → le script trouve `llvm-mingw` dans `$WORK`.)

### Phase 4 : un gestionnaire d'exceptions absurde

- « Unhandled page fault on execute access to `0020019008070C10` » ; message
  « calling personality routine in system library not supported yet ».
- **Cause** : pour une **frame sans module** (code généré à l'exécution), l'unwinder de macOS inventait une
  personality routine ; Wine gardait le contexte bidon.
- **Correctif** : `tools/mac_fix_leaf_unwind.py` / `.sh` (marqueur `fh6: leaf unwind`) : dérouler la frame comme
  une fonction feuille (`rip = [rsp]`, `rsp += 8`), comme Windows. Le patch 0017 de Highball est un **autre** sujet.
- **Preuve** : le saut absurde a disparu du log.

### Phase 5 : appel à l'adresse 0 dans D3DMetal ; la matrice GPTK

- **Symptôme** : `Unhandled page fault on read access to 0000000000000000`, thread principal, `rip=0`.
- **Diagnostic en entonnoir** :
  - `tools/mac_trace_null_call.py` / `.sh` : `dladdr()` dans le `segv_handler` unix → l'appel vient de
    `lib64/apple_gptk/wine/x86_64-unix/d3d12.so`, fonction **`WineMonitor::Init()`** (puis
    `WineMonitor::QueryDescription`), appelée par `WineOS::Init()`. Sauvegarde `.pre-fh6-nullcall.bak`.
  - `tools/mac_symbolize_null.sh`, `tools/mac_check_gptk_symbols.sh`, `tools/mac_gptk_slot*.sh`,
    `tools/mac_gptk_dispatch.sh`, `tools/mac_gptk_flow*.sh`, `tools/mac_cx_d3dm_hook.sh` : **la table interne
    `gWin32Dispatch` de D3DMetal est vide**, donc `WineMonitor::Init` appelle un pointeur NULL
    (`NtUserEnumDisplayMonitors` n'est pas résolu). Tous les symboles attendus (`macdrv_functions`,
    `NtUser*`, `ntdll_get_*`) **existent** dans le Wine de l'utilisateur comme dans celui de CrossOver : ce n'est
    pas un symbole manquant. Hypothèses écartées par le test : shim de l'utilisateur, `D3DM_WINE_UNIX_CALL`.
  - **Reproduction sans le jeu** : `tools/d3d12probe/` (+ `tools/mac_d3d12_probe.sh`) appelle
    `CreateDXGIFactory2`, `D3D12CreateDevice`, `D3D12GetInterface` un par processus. Résultat prouvé :
    `CreateDXGIFactory2` OK (adaptateur vu) ; **`D3D12CreateDevice` plante** avec la copie GPTK4 du moteur.
  - **Matrice** `tools/mac_d3d12_matrix.sh` : (1) comme le jeu ❌, (2) sans shim ❌, (3) **ton Wine + le d3d12 de
    CrossOver.app ✅ `D3D12CreateDevice` réussit**, (4) tout CrossOver.app ✅.
- **Conclusion prouvée** : la copie GPTK4 des d3d12 du moteur ne va pas avec ce Wine ; ceux de CrossOver.app
  oui. → `FH6_CX_GPTK=1` dans le lanceur.
- `tools/mac_d3d12_features.sh`, `tools/mac_d3d12_mix.sh`, `tools/mac_gptk4_inventory.sh` : D3DMetal **3.0 =
  shader model 6.6 max** ; les d3d12 de CrossOver + D3DMetal **4.0b3 = 6.8** (`FH6_D3DM4=1`).

### Phase 6 : l'écran de démarrage, et le message « Installation path is too long »

- Le jeu affiche son image de démarrage (voiture rouge) et une **mini fenêtre en forme de pilule** (point rouge,
  trait blanc). Le menu « Window » la nomme **« Forza Horizon »** (la grande : « Forza Horizon 6 »).
- Pour lire son texte sans la voir : `tools/mac_trace_msgbox.py` / `.sh` (ajoute un `ERR` dans
  `MSGBOX_OnInit`, `dlls/user32/msgbox.c`, reconstruit **`user32.dll`**, sauvegarde `.pre-fh6-msgbox.bak`).
  Les traces `+win` et `+dialog` donnent aussi la création des fenêtres.
- **Texte lu** : *« Installation path is too long. Forza Horizon is currently installed at: Z:\…\gamefarm-audit.
  Please move your Forza Horizon installation to a shorter path. … Forza Horizon will now quit. »*
- **Cause** : dossier d'installation de plus d'une centaine de caractères.
- **Premier essai** : lien symbolique `~/FH6` → **échec** (le log montre toujours le chemin long) car
  **xodus résout les liens**. **Correctif réel** : `tools/mac_move_short.sh` **renomme** le dossier en `~/FH6`
  (même disque, aucune copie, vérifié par `stat -f %d`) et laisse un **lien à l'ancien emplacement** (pour tous
  les anciens scripts). `--undo` fourni. Le jeu voit `Z:\Users\alexandre\FH6\forzahorizon6.exe`.

### Phase 7 : boîtes de dialogue illisibles (« pilules », boutons vides)

- Cause en deux temps :
  1. `share/wine/fonts` était **vide** dans le moteur → `tools/mac_fix_fonts.sh` copie les 67 polices Wine de
     CrossOver.app (`--undo` : retire seulement ce qui a été copié). **Insuffisant.**
  2. `tools/fontprobe/` + `tools/mac_font_probe.sh` : `GetDialogBaseUnits = 0`, métriques à 0, **0 famille de
     polices** → Wine compilé **sans FreeType** (`config.h` : `/* #undef HAVE_FT2BUILD_H */`).
- **Correctif final (prouvé)** : `tools/mac_enable_freetype.sh`.
  - **Pourquoi pas `configure`** : il échoue sur ce Mac (« Your bison version is too old », bison 2.3 de macOS).
    Le script **modifie donc `config.h` et le `Makefile` à la main** (trois réglages exacts de configure) :
    `#define HAVE_FT2BUILD_H 1`, `#define SONAME_LIBFREETYPE "libfreetype.6.dylib"`, et
    `FREETYPE_CFLAGS = -I<en-têtes>` (+ les `HAVE_FREETYPE_*_H` optionnels dont l'en-tête existe).
  - **En-têtes** : pas de Homebrew requis. Le script télécharge le **tarball officiel FreeType 2.13.3**
    (`download.savannah.gnu.org`, repli SourceForge), **vérifie le SHA-256**
    `0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289`, et ne garde que le dossier `include`
    dans `$WORK/freetype-headers/freetype-2.13.3/include`.
  - **Bibliothèque** : celle de CrossOver.app (`lib64/libfreetype.6.dylib`, **x86_64** comme le Wine ; Wine la
    charge par `dlopen`, sans édition de liens).
  - **Recompilation** : `win32u.so` seulement. Il faut **`SDKROOT`** (sinon `math.h` introuvable) **et `CPATH`**
    (le `Makefile` de cet arbre n'applique pas `FREETYPE_CFLAGS` à `freetype.c` : « ft2build.h not found »).
  - **Piège de script déjà corrigé** : « already enabled » signifie maintenant « le `win32u.so` **installé**
    contient `libfreetype` », pas « `config.h` est modifié » (un essai raté avait laissé `config.h` modifié).
  - **Preuve** : `GetDialogBaseUnits = 00100008`, `SYSTEM_FONT … height=16`, `message font … height=13
    avewidth=5`, **`font families seen by GDI: 968`** (Wine charge les polices macOS, ex. Tahoma).
  - Sauvegardes : `config.h`, `Makefile`, `config.status`, `win32u.so` en `.pre-freetype.bak`. `--undo` fourni.

### Phase 8 : l'avertissement de compatibilité FH205 / FH206 (le blocage principal)

- Boîte **« Avertissement de compatibilité de Forza Horizon 6 »** : *« Votre carte graphique n'est pas prise en
  charge (code : FH205). »* ; plus tard FH206 ; en plus *« Impossible de détecter la version du pilote
  graphique. Vous pouvez continuer, mais… »* (celle-là n'est qu'un avertissement). Boutons : **Quitter** et
  **En savoir plus** (pas de « Continuer » quand FH205/FH206 est présent).
- **Chronologie** : FH205 avec D3DMetal 3.0 (Intel Arc A750 présentée) ; FH206 avec D3DMetal 4.0b3.
- `tools/gpuprobe/` + `tools/mac_gpu_probe.sh` : ce que Windows expose. Résultat prouvé : DXGI montre la carte
  présentée (NVIDIA) avec une version de pilote illisible (`65535.65535.65535.65535`), mais
  `EnumDisplayDevices` montre **« Apple M5 Pro »** et le registre/WMI gardent `PCI\VEN_106B&DEV_03F2` (Apple).
- Changer seulement le nom de la carte (Intel → NVIDIA) **n'a pas suffi** : il faut le **shim** (phase 10).

### Phase 9 : l'examen de Highball (l'élément clé)

À la demande de l'utilisateur, lecture de **https://github.com/gauthierpiarrette/highball-engine** (patches
Wine), **highball** (`spike/tsshim/d3d12.c`) et **highball-db** (recette `forza-horizon-6.json`), plus un zip
fourni (`highball-engine-main.zip`, **identique** au clone : `diff -rq` vide). Voir §7 pour le détail.

Faits établis :
- **Highball lance l'édition Steam**, sur un Mac mini M4 de base, **macOS 27 obligatoire** (D3DMetal 4 beta).
  Performances annoncées : 28 fps (Élevé natif) → 50 fps (Très bas + FSR Équilibré), 1080p.
- Le blocage FH205/FH206 est dû à un **écart de shader model** : le jeu demande un modèle que D3DMetal ne
  connaît pas, `CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL)` renvoie `E_INVALIDARG`. Le **shim** redemande
  avec des valeurs plus basses et renvoie le plus haut modèle supporté (comportement du runtime Windows).
- Le même shim **saute un `ResolveSubresource` depuis une texture de profondeur multisample** (assertion Metal
  qui figeait le jeu à la sélection du personnage) et **écrit explicitement les offsets
  `D3D12_APPEND_ALIGNED_ELEMENT`** (correction du 2026-10-20).
- **Le GPU présenté** : le Reddit (Highball 0.10.10) dit **Intel Arc A750** (`0x8086`/`0x56a1`) ; la
  **recette actuelle** dit **NVIDIA GeForce RTX 4070** (`0x10de`/`0x2786`), avec cette explication : « D3DMetal se
  présente comme une carte AMD par défaut, le jeu prend alors un chemin réservé AMD et plante (dialogue FHE21) ;
  on présente donc une NVIDIA, ce qui débloque aussi Reflex et DLSS via MetalFX ». Les deux évitent le crash ;
  **NVIDIA est la plus récente**. Défaut du lanceur : NVIDIA (`FH6_GPU=intel` pour l'autre).
- Patches de Highball **étiquetés FH6** : 0017, 0018, 0019, 0022, 0023.

### Phase 10 : application de la solution de Highball

- **Bug trouvé** : avec `FH6_CX_GPTK=1`, le lanceur faisait `unset HB_D3D12_REAL` et pointait vers le d3d12
  de CrossOver **sans shim** : le shim n'était donc **jamais chargé**. Corrigé dans `mac_launch_fh6.sh`.
- **Shim** : `tools/tsshim/d3d12.c` + `d3d12.def` (copiés **tels quels** de Highball, GPL-3.0,
  `tools/tsshim/ORIGIN.md`). `tools/mac_setup_tsshim.sh` le compile (llvm-mingw), le marque « Wine builtin DLL »,
  copie le d3d12 de CrossOver en **`apd12.dll`** (nom d'export interne changé à `apd12.dll`), crée le lien
  `apd12.so` → `d3d12.so` de CrossOver, dans `$ENGINE/renderers/d3dmetal-tsshim-hb/wine`
  (dossier neuf ; `--undo` le supprime). `tools/pe_tools.py` (port de `mark-builtin.py` et de
  `PEExportName.swift`) : `mark-builtin` (octets `Wine builtin DLL\0` à l'offset 0x40) et `rename-export`
  (testé sur une vraie DLL mingw).
- **Patches Wine** (`tools/forza-patches/`, GPL-3.0, `ORIGIN.md`) appliqués par `tools/mac_apply_forza_patches.sh` :
  0017, 0018, 0019 (obligatoires) ; 0020, 0022, 0023, 0024, 0025 (au mieux). **Restauration par patch** : un
  `.rej` ou un échec de build annule **seulement les fichiers de ce patch**. **Détection « déjà présent »** par
  marqueur dans la source.
- **Surprise sur 0024** : « 5 out of 5 hunks ignored » ne voulait **pas** dire « refusé » : le code de 0024 était
  **déjà dans l'arbre CrossOver** de l'utilisateur (`packages_key_name`, `GetPackagesByPackageFamily` qui lit
  le registre, `PackageFullNameFromId`, `GetPackagePath`). On l'a gardé (demande de l'utilisateur) ; le script
  détecte maintenant la présence.
- **Résultat prouvé** : après ces changements, **la boîte FH205/FH206 a disparu**, 0 piège `c000001d`, le jeu
  charge `sl.reflex.dll` (NVIDIA Reflex, activé **parce que** la carte présentée est NVIDIA), l'audio, puis tourne
  sans arrêt volontaire. Un premier run de 541 s a été **arrêté par l'utilisateur** (« rien ne bouge »), un
  second de 77 s dont la cause de fin n'a pas été confirmée (l'utilisateur interrompait souvent). **Puis le jeu s'est lancé.**

### Phase 11 : épisode « identifiants matériels » (à connaître pour le cadre)

Quand l'utilisateur a demandé de contourner l'avertissement de compatibilité **avant** d'avoir montré Highball,
l'IA de l'époque a **refusé de fabriquer de fausses informations matérielles** (identifiants de carte, version
de pilote) et a proposé Xbox Cloud Gaming ; un résumé de réponse a été coupé par le classifieur de sécurité. La
position de l'utilisateur était qu'il autorisait ce travail. Ensuite, l'utilisateur a fourni le dépôt et la
recette **publiés** par l'auteur de Highball et demandé d'**aligner exactement** la configuration dessus ; c'est ce
qui a été fait (identifiants GPU de la recette + shim + patches). **Chaque IA décide pour elle-même** de ce
qu'elle accepte de faire sur ce point. Le projet **ne modifie pas le binaire du jeu, la licence ni l'anti-triche**.

### Phase 12 : le jeu se lance, la boîte « Game Saves »

- Capture de l'utilisateur : une scène d'autoroute derrière une boîte **« Game Saves »** avec une icône
  d'avertissement et **trois boutons blancs vides** (police absente à ce moment-là).
- **Texte lu dans le log** : *« Cloud save synchronization failed. Retry? / Yes: retry. No: play with local saves
  offline. Cancel: stop. »* (légende de 102 caractères). C'est un `MessageBox` **Oui / Non / Annuler**.
  **Ordre Windows** : gauche = Oui, **milieu = Non (jouer hors ligne)**, droite = Annuler (arrête le jeu).
- La boîte apparaît **48 fois** dans un log, par **plusieurs threads** (0170, 0174, 017c, 0178, 0184, 018c, …) :
  c'est **une boucle**, pas un nombre fini.
- Aucune ligne de connexion Xbox (`microsoft.com/link`, `device code`, `XSTS`, `xbl`…) dans ce log.
- **L'utilisateur a signalé que la boîte « réapparaît »** après un clic. Il n'a **pas encore dit** si, en
  recliquant sur « No », il arrive au menu.
- Ensuite FreeType a été activé (phase 7).

### Phase 13 : la boîte « Game Saves » est résolue (synchro cloud PlayFab fonctionnelle)

**But de l'utilisateur** : « faire fonctionner ça avec ma sauvegarde que j'ai dans mon compte Microsoft ».

**Résultat prouvé** (run de 360 s, `FH6_DEBUG="err+all,+pfxgamesave,warn+gdkc"`) : `work_complete PlayFab operation 0 completed, hr 0`,
aucune ligne `ui_failed`, la section « MESSAGE BOX TEXT » du rapport est vide, aucun arrêt anormal. Auparavant la même opération finissait en
`0x80004005` (puis `0x800704c7` après un clic sur Cancel).

**Piste décisive** : la fiche `titles/9NR1R1XWLCNB.toml` du dépôt public `icex/ferestre` (commit `9ab17d7`, cloné pour lecture) dit FH6
« playable » et « Native PlayFab cloud synchronization … passed » avec **le même paquet 3.461.691.0** sous Linux. Donc ce n'était pas une limite
du jeu, mais une différence d'environnement. Le code de synchro (`dlls/xgameruntime/pfxgamesave.c`, patch Ferestre 0028) fait tourner une copie
privée du `PlayFabGameSave.dll` du jeu dans le processus du jeu.

**Chaîne de causes, dans l'ordre où elles ont été trouvées (toutes corrigées) :**

1. **`xodus-service`** doit tourner pour donner les jetons Xbox : `tools/mac_xodus_service.sh` (lancé par `mac_launch_fh6.sh`, sauf
   `FH6_NO_XODUS_SERVICE=1`). Preuve : `tools/mac_xodus_token_probe.py` (jeton de 2111 caractères, non affiché).
2. **D'où vient la boîte** : une seule fonction, `ui_failed()` de `pfxgamesave.c`, appelée par la bibliothèque PlayFab du jeu avec `state 1`,
   `hr 0x80004005` (E_FAIL). Même « No » (mode hors ligne) échouait : l'échec était donc local au login/à la lib, pas au compte.
   Outil : `tools/mac_trace_cloudsave.sh` (ajoute une ligne `WARN` dans `ui_failed`, réversible).
3. **GnuTLS absent du Wine maison** : `err:bcrypt:key_asymmetric_create no encryption support` (45 fois) ; `config.h` avait
   `/* #undef SONAME_LIBGNUTLS */`. Correction : `tools/mac_enable_gnutls.sh` (même méthode que FreeType : en-têtes de Homebrew
   `brew install gnutls`, `libgnutls.30.dylib` x86_64 de CrossOver.app chargée au lancement ; `bcrypt.so`, `secur32.so`, `crypt32.so` recompilés).
   Effet : 0 erreur `bcrypt`, connexions TLS établies.
4. **Le prefix garde des copies complètes des DLL builtin** (pas des « placeholders ») et **le jeu charge la copie du prefix**. Le prefix
   contenait l'ancienne `xgameruntime.dll` (707 535 octets) : toutes les modifications faites dans le moteur étaient ignorées. Correction :
   `tools/mac_sync_prefix_dll.sh --apply xgameruntime` (sauvegarde `.pre-sync.bak`, retour : `--undo`).
5. **`winhttp.dll` périmée** (moteur et prefix, 1 122 304 octets, ne correspondait pas à la source). Symptôme isolé avec `tools/httpprobe` :
   `WinHttpQueryHeaders(RAW_HEADERS_CRLF, buffer=NULL)` rendait FALSE avec `GetLastError() == 0` au lieu de `ERROR_INSUFFICIENT_BUFFER (122)`.
   libHttpClient (PlayFab) teste exactement 122, abandonne la requête au `HEADERS_AVAILABLE` sans lire le corps, et renvoie E_FAIL.
   Une **recompilation de la source non modifiée** corrige tout (sonde : `err=122` partout). Outil : `tools/mac_fix_winhttp_headers.sh`
   (sauvegardes `.pre-qh.bak`, `--undo`). Il a aussi laissé dans `dlls/winhttp/request.c` une garde inoffensive conforme à Windows.

**Outils ajoutés (lecture seule sauf indication)** : `mac_trace_cloudsave.sh` (modifie, réversible), `mac_enable_gnutls.sh` (modifie, réversible),
`mac_sync_prefix_dll.sh` (modifie le prefix, réversible), `mac_fix_winhttp_headers.sh` (modifie, réversible), `httpprobe/` + `mac_http_probe.sh`
(compare les DLL du prefix au moteur et rejoue la séquence WinHTTP du jeu), `mac_cloud_window.sh`, `mac_cloud_http.sh`, `mac_cloud_files.sh`,
`mac_cloud_debugstr.sh`, `mac_cloud_logins.sh` (extraits de journal avec jetons masqués).

**Pistes écartées (preuves)** : problème de fichiers (`fs_usage` : la bibliothèque ne crée aucun fichier sous `PFXGameSave/data`, elle charge
seulement sa copie `pgs-….dll` ; la trace `+file` rend le jeu trop lent), messages de diagnostic de la bibliothèque (`+debugstr` : 6 lignes sans rapport),
jetons ou réseau en général (TLS et login fonctionnaient ; c'était le code d'erreur de `winhttp`).

**Points ouverts découverts en route** (voir aussi §10) :
- 9 DLL du prefix diffèrent encore du moteur (`tools/mac_http_probe.sh`) : `advapi32`, `kernelbase`, `ntdll`, `user32` (moteur plus récent : les patches
  0019 / 0024 / 0025 ne sont peut-être pas actifs à l'exécution) ; `concrt140`, `msvcp140`, `msvcp140_atomic_wait`, `vcruntime140`, `vcruntime140_1`
  (natives voulues par `WINEDLLOVERRIDES`, normal).
- `xodus-service` journalise `Failed to read magic: early eof` toutes les quelques secondes pendant que le jeu tourne (connexions qui raccrochent
  sans rien envoyer). Origine inconnue, sans effet visible.
- Le crash `page fault` / erreurs Metal `sv_shadingrate0` vu plus tôt et l'avertissement FH302 (« version du pilote graphique ») n'ont pas été revus
  depuis. Le dernier run de 360 s n'a pas planté.

---

## 6. Inventaire complet des outils du dépôt

**Pipeline principal**

| Fichier | Rôle |
|---|---|
| `tools/mac_all.sh` | Tout-en-un : correctifs + lancement + rapport + presse-papiers |
| `tools/mac_launch_fh6.sh` | Lancement (variables §4.2), résumé en un passage (`out/fh6-small.log`, `out/fh6-counts.txt`) |
| `tools/mac_exit_report.sh` | Pourquoi le jeu a quitté (messages Xbox, boîtes, 50 dernières lignes du thread) |
| `tools/mac_collect_crash_info.sh` | Extraits de code Wine et de log pour un plantage |
| `tools/mac_winlist.sh`, `tools/winlist/` | Liste les fenêtres du jeu (**n'a rien affiché** pendant la session : ne pas s'y fier) |

**Correctifs fonctionnels (à garder)**

| Fichier | Contenu | Cible installée |
|---|---|---|
| `tools/mac_apply_wine_fix.sh`, `mac_replace_mapped_fd.py`, `patches/wine/0001-…` | Relecture de l'image par `F_GETPATH` | `ntdll.so` |
| `tools/mac_apply_xodus_fix.sh`, `mac_replace_make_temp_file.py`, `patches/xodus-cli/0001-…` | Fichier déchiffré nommé | `xodus-cli` |
| `tools/mac_fix_leaf_unwind.*` | Déroulé « leaf » | `ntdll.dll` (PE) |
| `tools/mac_fix_vectored_trace.*` | Trace de pile bornée | `ntdll.dll` (PE) |
| `tools/mac_move_short.sh` | Dossier du jeu → `~/FH6` | — |
| `tools/mac_fix_fonts.sh` | Copie les polices Wine de CrossOver.app | `share/wine/fonts` |
| `tools/mac_enable_freetype.sh` | FreeType dans `win32u.so` | `win32u.so` |
| `tools/mac_setup_tsshim.sh`, `tools/tsshim/`, `tools/pe_tools.py` | Shim DX12 de Highball + apd12 | `renderers/d3dmetal-tsshim-hb` |
| `tools/mac_apply_forza_patches.sh`, `tools/forza-patches/*.patch` | Patches Highball 0017–0020, 0022–0025 | `kernelbase.dll`, `ntdll.so`, `advapi32.dll`, `winemac.so`, `mmdevapi.dll`, `winecoreaudio.so`, `kernel32.dll`, `ntdll.dll` |

**Diagnostics (retirables ; chacun a un `--undo`)**

| Fichier | Ajoute dans Wine |
|---|---|
| `tools/mac_trace_msgbox.*` | `FH6 message box caption/text` dans `user32.dll` (utile : **à garder** tant qu'on lit des boîtes) |
| `tools/mac_trace_null_call.*` | `FH6 null call: stack[n]=…` dans `ntdll.so` (unix `segv_handler`) |

**Sondes sans le jeu**

`tools/d3d12probe/` (+ `mac_d3d12_probe.sh`, `mac_d3d12_matrix.sh`, `mac_d3d12_features.sh`, `mac_d3d12_mix.sh`) ;
`tools/fontprobe/` (+ `mac_font_probe.sh`) ; `tools/gpuprobe/` (+ `mac_gpu_probe.sh`) ;
`tools/selfread/` (+ `mapfd_run.py`) ; `tools/check_runtime.py`.

**Analyses de D3DMetal (lecture seule)** : `mac_gptk_slot.sh`, `mac_gptk_slot2.sh`, `mac_gptk_dispatch.sh`,
`mac_gptk_flow.sh/.py`, `mac_gptk_flow2.sh/.py`, `mac_check_gptk_symbols.sh`, `mac_cx_d3dm_hook.sh`,
`mac_symbolize_null.sh`, `mac_gptk4_inventory.sh`, `mac_bad_handler_report.py`, `mac_null_call_report.py`,
`mac_msgbox_text.sh`.

**Phase 13 (synchro cloud)** : voir la liste à la fin de la phase 13 (§5) : `mac_trace_cloudsave.sh`, `mac_enable_gnutls.sh`, `mac_sync_prefix_dll.sh`, `mac_fix_winhttp_headers.sh`, `mac_http_probe.sh` + `httpprobe/`, `mac_cloud_*.sh`, `mac_xodus_service.sh`, `mac_xodus_token_probe.py`.

---

## 7. Highball : ce qui a été pris, et ce qui ne l'a pas été

### 7.1 Sources (toutes publiques)

- `https://github.com/gauthierpiarrette/highball-engine` : moteur Wine 11 = **sources CrossOver 26.3.0**
  (CodeWeavers, LGPL) + 24 patches (`patches/`). Moteur Intel nommé `x64-crossover26.3-r*` ; la recette FH6
  demande **r18**.
- `https://github.com/gauthierpiarrette/highball` : `spike/tsshim/d3d12.c` (shim), `Scripts/build-tsshim.sh`,
  `Scripts/mark-builtin.py`, `Sources/HighballKit/PEExportName.swift`.
- `https://github.com/gauthierpiarrette/highball-db` : `recipes/games/forza-horizon-6.json`
  (`lastVerified` 2026-10-05, M4, macOS 27.0, D3DMetal 4.0b2 ; **le shim du 2026-10-20** gère aussi 4.0b3).
- **Licence : GPL-3.0.** Les fichiers copiés gardent cette licence et l'attribution (`ORIGIN.md`).

### 7.2 Recette Highball (valeurs exactes)

`sync = msync` (`WINEMSYNC=1`), `D3DM_VENDOR_ID=0x10de`, `D3DM_DEVICE_ID=0x2786`,
`D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 4070"`, moteur r18, D3DMetal 4, shim. Notes de la recette : macOS 27
requis ; la copie protégée ouvre des fichiers par `\\.\GLOBALROOT\` ; premier démarrage ≈ **3 minutes** à
« Optimizing for your PC » ; connexion Xbox **une fois** par code sur microsoft.com/link ; en jeu
28 fps (Élevé) à 50 fps (Très bas + FSR).

### 7.3 Liste du Reddit (« ce qu'il a fallu ») : état chez l'utilisateur

| Élément | État |
|---|---|
| Protection via `\\.\GLOBALROOT\` | ✅ Ferestre 0009/0013 + correctif `F_GETPATH` |
| GPU AMD par défaut → crash | ✅ GPU présenté NVIDIA (recette) |
| Barrières DX12 améliorées (D3DMetal 4, macOS 27) | ✅ D3DMetal 4.0b3, macOS 27.0.1 |
| `GetIntegratedDisplaySize` manquant | ✅ patch 0017 |
| « 87 Go / 32 Go » mémoire | ✅ patch 0018 |
| Gel à la sélection du personnage | ✅ shim (`ResolveSubresource`) |
| FH206 / shader model inconnu | ✅ shim (`CheckFeatureSupport`) |
| Code Xbox redemandé à chaque lancement | ✅ patch 0019 (mais voir « Game Saves » : la connexion n'est pas faite du tout) |
| msync | ✅ |
| **Steam dans le même préfixe** (« sans ça, le jeu se ferme après ~12 s ») | ⚠️ **Sans objet** : l'utilisateur a la version **Store** (xodus), le jeu ne se ferme pas à 12 s |

### 7.4 Les patches de `highball-engine/patches/` (numérotés 0001 à 0025, 24 fichiers) : classement

**Appliqués** (tous « FH6 » + ceux qui aident la version Store) : **0017, 0018, 0019, 0022, 0023** (FH6),
**0020** (Retina, recadrage plein écran), **0024** (app packages ; **déjà dans l'arbre**), **0025**
(crash E/S asynchrones).

**Non appliqués, et pourquoi :**
- 0001, 0002, 0006, 0007, 0010, 0021 : autres jeux/lanceurs (Warframe, Rockstar, Steam, Unity, OpenGL ES 2).
- 0003, 0005, 0008, 0009, 0011, 0012, 0013, 0014, 0016 : modifient `ntdll/loader.c`, `signal_x86_64.c` et
  `msync.c`, **où sont les patches Ferestre et les diagnostics** nécessaires à la version Store → risque de
  conflit ; et aucun n'est étiqueté FH6.
- 0015 : réglage audio CS2.

### 7.5 Différences restantes avec Highball (à ne pas masquer)

1. **Édition Store (xodus) vs Steam** : le jeu, la protection et l'identité Xbox diffèrent.
2. **Moteur** : Highball livre un moteur construit par leur CI (CrossOver 26.3 + 24 patches + **FreeType**). Celui de
   l'utilisateur est **construit à la main** (patches Ferestre + correctifs de ce dépôt + 8 patches Highball). Les
   patches 0003/0005/0008… ne sont **pas** dedans.
3. **Compilateur PE** : Highball note que **llvm-mingw « casse la connexion Steam »** (frankea, 2026-08-04) et
   utilise **mingw-w64 gcc** ; l'utilisateur utilise llvm-mingw. Non démontré comme gênant pour la version Store.
4. **D3DMetal 4.0 bêta 3** chez l'utilisateur, **bêta 2** chez Highball (le shim 20 oct couvre les deux).

---

## 8. Fichiers modifiés, sauvegardes, retours arrière

Toute modification crée `<fichier>.pre-<nom>.bak` **une seule fois** (la sauvegarde d'origine n'est jamais
écrasée) :

| Suffixe | Fichiers |
|---|---|
| `.pre-fh6-reopen.bak` | `dlls/ntdll/unix/loader.c`, `ntdll.so` installé |
| `.pre-fh6-named.bak` | `crates/xodus-cli/src/commands/run.rs`, `xodus-cli` |
| `.pre-fh6-trace.bak` | `dlls/ntdll/exception.c`, `ntdll.dll` installé |
| `.pre-fh6-leaf.bak` | fichier source ntdll du déroulé, `ntdll.dll` |
| `.pre-fh6-nullcall.bak` | `dlls/ntdll/unix/signal_x86_64.c`, `ntdll.so` |
| `.pre-fh6-msgbox.bak` | `dlls/user32/msgbox.c`, `user32.dll` |
| `.pre-forza.bak` | sources et DLLs des patches 0017–0025 |
| `.pre-freetype.bak` | `include/config.h`, `Makefile`, `config.status`, `win32u.so` |

**Attention au retour arrière :** plusieurs scripts reconstruisent **le même `ntdll.so` / `ntdll.dll`**. Annuler un
ancien `.bak` écrase aussi les changements **plus récents** de ce fichier. Pour un retour complet, annuler dans
l'ordre inverse (`freetype`, `forza`, `msgbox`, `nullcall`, `leaf`, `trace`, `reopen`).

Autres retours arrière : `tools/mac_move_short.sh --undo`, `tools/mac_fix_fonts.sh --undo`,
`tools/mac_setup_tsshim.sh --undo`, `tools/mac_enable_freetype.sh --undo`,
`tools/mac_apply_forza_patches.sh --undo`.

---

## 9. Leçons, pièges opérationnels (à ne pas reproduire)

- **`git pull -q` silencieux** : plusieurs fois, l'utilisateur a lancé l'**ancienne** version d'un script car le pull
  n'avait pas encore récupéré le dernier commit. Vérifier avec `git pull 2>&1 | tail -4; git log --oneline -1`
  et un `grep -c <marqueur> tools/<script>`.
- **Une commande collée plusieurs fois à la suite** s'exécute plusieurs fois : demander `Ctrl+C` d'abord.
- **Deux lancements en parallèle** (deux onglets) : le second **tue le Wine du premier et vide son log**
  (`lines: 0`). Dire : un seul onglet, `pkill` d'abord.
- **Ne pas utiliser `head` sur la sortie du test de polices** : l'ancien script y mélangeait des lignes `FHTRACE`.
  Filtrer par mots-clés.
- **Ne pas lancer un « grep » trop large** sur `out/fontprobe.log` : le niveau `+font` produit des milliers de
  lignes ; chercher `GetDialogBaseUnits|families seen|ok=`.
- Le rapport relisait le log 15 fois (35 millions de lignes) : corrigé, un seul passage.
- **Run court ≠ plantage** : l'utilisateur coupe souvent lui-même. Demander.
- **`mac_all.sh` redirige tout vers `out/report.txt`** et copie dans le presse-papiers : **ne pas le coller dans
  le Terminal**.
- **`bison`/`configure`** : ne pas relancer `configure` (bison 2.3). Le script FreeType n'en a pas besoin.
- Les « pilules » ne sont **pas** un bug du jeu : c'est un symptôme de police absente.
- La **sortie de `mac_apply_forza_patches.sh` dans `mac_all.sh` est filtrée** par un `grep` qui masque les lignes
  `installed …` : pour voir ce qui est réellement installé, lire `out/forza-patches.log`.

- **Le prefix garde des copies complètes des DLL builtin** et le jeu charge celles-là. Toute DLL PE recompilée dans le moteur doit être
  recopiée dans `~/FH6/.blackwell-wine/drive_c/windows/system32` (comparer avec `tools/mac_http_probe.sh` / `mac_sync_prefix_dll.sh`). Les `.so`
  (partie Unix) sont, eux, chargés depuis le moteur.
- **Canaux de debug Wine** : `trace+canal` n'active **pas** `warn` (niveaux indépendants). Pour tout voir d'un canal : `+canal`. Un `WARN` invisible
  a coûté un tour.
- **`+file` est trop lourd** : le jeu devient si lent que 7 minutes n'atteignent pas la synchro. Préférer `fs_usage` (macOS, sudo) ou des sondes.
- **Une sonde vaut mieux que 5 minutes de jeu** pour tester une hypothèse sur une API Windows (`tools/httpprobe`). **Tester la logique du verdict sur un
  cas connu bon et un cas connu mauvais** : un script a affiché « PAS CORRIGÉ » parce que le code 122 (la bonne valeur) était compté comme mauvais.
- **Ne pas coller l'historique du Terminal** : utiliser `open -e fichier` ou `pbcopy` puis Cmd+V dans le chat. Les scripts `mac_cloud_*` masquent
  les jetons (`Authorization`, `Signature`, JWT) ; un fragment de jeton tronqué a pourtant été collé une fois (expiré, inutilisable).
- **Une commande longue = une seule fenêtre**, sans mot de passe si possible ; ne pas fermer le Terminal avant `== RAPPORT COPIE`.

---

## 10. Questions ouvertes et hypothèses (non prouvées)

1. **« Game Saves » en boucle** : **RÉSOLU** (phase 13). Reste à confirmer en jeu que la progression du compte est bien téléchargée et que la fermeture normale envoie les sauvegardes (Ferestre : envoi final jusqu'à 30 s ; pas d'envoi après un crash).
2. **Les patches 0017–0019 sont-ils vraiment installés ?** Le jeu a dépassé l'ouverture de fenêtre (indice fort pour
   0017), mais les lignes `installed …` ont été filtrées. À vérifier : `out/forza-patches.log` et les trois
   marqueurs :
   ```sh
   W=/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/sources/wine
   grep -c "stdcall GetIntegratedDisplaySize" $W/dlls/kernelbase/kernelbase.spec
   grep -c phys_footprint $W/dlls/ntdll/unix/process.c
   grep -c "ERROR_NOT_FOUND) ret = ERROR_SUCCESS" $W/dlls/advapi32/cred.c
   ```
3. **Reflex activé ≠ DLSS** : les modules `sl.*.dll` se chargent ; la recette dit que DLSS Super Resolution
   exige « Enable DLSS (MetalFX) » côté Highball. Non exploré.
4. **Performance** : jamais mesurée sur le Mac de l'utilisateur. Les traces lourdes la ruinent ; mesurer avec
   `FH6_DEBUG="-all"`.
5. **Shaders** : la première exécution compile des shaders (« ~3 minutes » chez Highball sur M4) ; chez
   l'utilisateur, avec traces et Rosetta, c'est bien plus long. Le journal du shim (`HB_TSSHIM_DEBUG=1`) dit si
   ça progresse.
6. **Les « Skipping this font. »** (une douzaine) au chargement du préfixe : polices système que FreeType ne retient pas, sans gravité.
7. **`winebth` : « failed to create driver » (`c00000e5`)** : bruit habituel, sans lien.

8. **Plantage en enregistrant les réglages du jeu** (21 octobre 2026, soir, après être arrivé en monde ouvert). Écran en fond : « Modifications non
   sauvegardées » (le jeu demande s'il enregistre les options changées). Puis, dans l'ordre : boîte Wine « Exception raised : Unhandled page fault on
   **write** access to `0000000000000000` at address `00006FFFFFD459F2` » (adresse dans la zone des DLL de Wine, `0x6FFF…`, **pas** dans le code du jeu en
   `0x1400…`), boîte du jeu « Forza Horizon 6 a rencontré une erreur… **FHE11** Plantage du jeu, Contexte 461691 \ baf465ae » (accents illisibles :
   UTF-8 lu comme Windows-1252, cosmétique), puis **la boîte « Game Saves » revient** : c'est la conséquence (l'envoi final après un plantage est impossible,
   Ferestre le dit), pas l'ancien défaut. **Réglage modifié juste avant : les options de ray tracing (RT) du jeu** (dit par l'utilisateur, 21 octobre 2026 ; le crash survient quand les réglages
   sont enregistrés). Cause exacte non analysée (pas de journal : lancement avec `jouer.sh`) ; probable : DXR via D3DMetal. **Conseil : garder le RT désactivé** (meilleur aussi pour les
   images/s). Si le jeu replante à l'enregistrement, redescendre l'option RT. Pistes si on veut un jour l'étudier : `FH6_DEBUG="err+all,+loaddll"` puis `bash tools/mac_crash_report.sh`. Le run du plantage a été lancé sans journal : rien à lire. Ne pas
   répondre « Yes » à « Game Saves » après un plantage (ne pas envoyer un état possiblement interrompu) : **Cancel**. Copie locale conseillée :
   `cp -R …/SystemAppData ~/FH6-sauvegardes-DATE`.
9. **Interface coupée à gauche** : « /OUS », « /lei », « aison » (première lettre manquante) en monde ouvert. Fenêtre qui dépasse de l'écran ou image
   décalée ; patch Highball 0020 (winemac, retina HORZRES/VERTRES) installé. Non diagnostiqué.
10. **Lecture de la performance** : le compteur du jeu affiche « 79 » (probablement les images/s) et « GPU : 0 % » (**faux** : le jeu ne lit pas le GPU
   Apple). L'« Historique du processeur graphique » d'Activity Monitor (M5 Pro) montrait, pendant le jeu, des barres à ~75-100 % avec des creux : GPU **très
   utilisé** (l'utilisateur avait compris « sous-utilisé » : corrigé). Une capture, à confirmer en roulant. Pour gagner des images : alléger le rendu
   (résolution interne, mise à l'échelle, effets), mais **éviter de changer les réglages tant que le plantage ci-dessus n'est pas compris**.

**Décision de l'utilisateur (22 octobre 2026) : le multijoueur est mis de côté** (le mode en ligne « ne fonctionne pas de base » ; entrer dans le salon fait planter le jeu ; Ferestre le donne
« non vérifié » pour FH6). Ne pas y revenir sans demande. **Priorité : fluidité et retard des commandes en solo.** Ordre prévu : (1) test iCloud (`bird`/`cloudd`/`fileprovider` en CPU ;
le jeu de 159 Go et `.xodus-streaming.msixvc` sont sur le Bureau, donc dans iCloud) ; (2) lire le HUD Metal (actif par défaut) ; (3) `tools/mac_metal_trace.sh` (Xcode installé et sélectionné) ;
(4) sortir le jeu du Bureau vers `~/Games` en re-pointant les 55 liens de `~/FH6` (+ le lien caché `.xodus-streaming.msixvc`), avec retour en arrière. **Ne jamais déplacer ni supprimer** le dossier
`~/Desktop/FORZA HORIZON 6` ni `~/Desktop/.xodus-streaming.msixvc` avant ce re-pointage. AVX (`FH6_AVX`) : plantage, abandonné. MetalFX : refusé.

**Mesures du 22 octobre 2026 (trace Metal System Trace de 25 s, `tools/mac_trace_stats.sh`)** : 911 images affichées, 35,8 images/s ; médiane **25,0 ms** (71,5 % des images à
3 rafraîchissements d'un écran 120 Hz) ; p99 141,7 ms, **max 299,9 ms** ; **6 gels de 175 à 300 ms en 25 s** (à 5,6 / 10,6 / 15,5 / 18,2 / 20,6 / 23,1 s) : ce sont les saccades. Compilation
de shaders Metal : **16,5 ms au total** (65 événements, plus long 2,7 ms), donc **pas la cause** (limite : la table ne voit que le compilateur Metal). HUD (D3D12 / Metal 4, 3456x2234, `Composited`
en rouge) : 14,55 FPS, GPU 14,28 ms contre 68,7 ms d'intervalle, 7168 draws, `App` 27,9 Go ; RAM 48 Go, 41 % libre, swap 2,1 Go : mémoire écartée. Le plafond d'images n'est pas le remède
principal. **Piste en cours** : savoir ce que fait le jeu pendant un gel (`tools/mac_sample_hitch.sh`, `sample` macOS, sans Xcode). Hypothèses non prouvées : chargement disque (jeu sur le Bureau, iCloud),
traduction Rosetta de code exécuté pour la première fois, attente de synchronisation.

**Multijoueur repris à la demande de l'utilisateur (23 octobre 2026).** Symptôme réel (capture de l'utilisateur, pas un plantage) : « Fonctionnalité
indisponible — Le serveur Forza Horizon 6 n'est pas disponible pour l'heure ». Cause prouvée : le serveur du jeu est
`https://gameservices.fh6.forzamotorsport.net/Services/o.xtsw` (chaîne de l'exe déchiffré). Sa NSAL de titre
(`https://title.mgt.xboxlive.com/titles/2079757188/endpoints`, **sans** `?type=1`, qui donne 414) dit `*.forzamotorsport.net` → relying party
`http://xboxliveauth.forzamotorsport.net/`. `xodus-service` ne lisait que `titles/default`, se rabattait sur `http://xboxlive.com` et fabriquait des XSTS
**utilisateur seul** (sans revendication de titre : la NSAL du titre leur répondait 403). Correctif `patches/xodus-cli/0002-…` : le jeu envoie déjà
`TitleId` + `TitleClientId` (MSAAppId `000000004CE146F7`), le service fait maintenant le SISU du titre (`xodus::auth::do_sisu`), lit sa NSAL, et
signe des XSTS appareil + titre + utilisateur avec la clé SISU (repli sur l'ancien jeton en cas d'échec). Vérifié hors jeu : NSAL du titre 200, profil
Xbox signé 200, jeton Forza délivré. **Non vérifié en jeu au moment d'écrire.** Ancien binaire : `work/xodus/target/release/xodus-service.pre-title.bak`.
Aussi installé (correction de fond, pas la cause) : `patches/wine/0002-winhttp-…` (connexion WebSocket exclusive, lecture bloquante qui attend),
anciennes DLL en `winhttp.dll.pre-ws.bak`. Diagnostic : `tools/mac_multi_diag.sh`. Piège : la boucle `recv error 10035` vue avec `warn+winhttp`
n'existe pas sans journal (wineserver à 4 % en jeu normal).

**Matchmaking débloqué (24 octobre 2026).** Après les jetons de titre, la recherche Horizon Play tournait sans fin. Cause (journal `udpreq`) :
le socket de jeu est un **AF_INET6 double pile** (`IPV6_V6ONLY=0`, `FIONBIO`, `SO_REUSEADDR`, bind `[::]:3074`, `SIO_UDP_CONNRESET/NETRESET`), puis
`setsockopt(IPPROTO_IP, IP_DONTFRAGMENT=1)` et `IP_TTL=255`. Windows applique ces options IPv4 au trafic IPv4 du socket double pile ; macOS les
refuse sur un socket IPv6 (WSAEINVAL 10022) → le jeu **ferme le socket** et réessaie 5250 puis 5002 → aucun socket UDP → aucun ping QoS → le ticket
(`LspMatchmakingService` via le serveur Forza, pas PlayFab Match) n'aboutit jamais. Correctif `patches/wine/0006-ws2_32-dual-stack-ipv4-options.patch`
(équivalent IPv6 puis succès). Vérifié en jeu : socket 3074 gardé, pings QoS vers les 15 régions avec réponses (nettop : 30 Ko/30 Ko sur 5002), puis
session UDP avec un serveur dédié Azure `:30029` (plage 30000-30050 du `networkmanifest.xml`), centaines de Ko/s. Restant, non bloquant :
`IPPROTO_IP 76 = IP_USER_MTU` refusé (10042). Aussi : `ws2_32` accepte `SIO_UDP_NETRESET` (0003), `xgameruntime` image de joueur, `nsiproxy`/`SendARP`
(0004 ; macOS 27 cache la table ARP aux processus non-plateforme, Wine compris), canaux de diagnostic `httpreq`/`udpreq` (0005).
Pièges : lancer le diagnostic **dans le Terminal de l'utilisateur** (le bac à sable de l'agent bloque le réseau local) ; le `c0000409` des runs tracés
vient d'un blocage passager de 5 s (chien de garde du jeu), pas du réseau ; PlayFab Multiplayer appelle WinHTTP lui-même (invisible dans `hctrace`).

**Son du moteur absent (24 octobre 2026).** Cause prouvée : le jeu envoie le moteur et les voix dans un flux float 7.1 (`0x63f`, mastering
XAudio2) et 7.1.4 (`0x2d63f`, audio spatial) ; sur la sortie 2 canaux du Mac, Core Audio ne joue que avant gauche/droite. Les patches Highball
0022/0023 (AUSpatialMixer) le corrigent et étaient **dans le source depuis le 21 octobre mais jamais compilés** : `mac_apply_forza_patches.sh`
lance `make dlls/<dossier>` (cible toujours « à jour »), puis prend le marqueur du source pour une preuve d'installation (et son chemin
`winecoreaudio.drv/x86_64-unix/` n'existe pas dans cet arbre). Les `.o` dataient du 20 octobre. Correctif : `tools/mac_fix_audio_surround.sh`
(cibles explicites, sauvegardes `.pre-audio.bak`, `--undo`) + sonde `tools/audioprobe` (un bip par haut-parleur). Avant : aucune ligne
`rendered by AUSpatialMixer` ; après : la ligne apparaît pour 8 et 12 canaux. **Vérifié en jeu (24 octobre 2026)** : le journal du jeu
montre les deux flux (12 canaux `0x2d63f`, 8 canaux `0x63f`) rendus par AUSpatialMixer, et l'utilisateur entend le moteur. Même défaut de
compilation possible pour les autres patches de ce script (0017–0020, 0024, 0025) : non vérifié.

**Rendu : 221 pipelines « no-op » (arbres/objets sans texture ou noirs), 24-25 octobre 2026.** Le journal montrait 221
`marking PSO(N) as no-op` (D3DMetal saute tous les dessins de ces pipelines) : 148 `Fragment input(s) user(sv_shadingrate0) mismatching
vertex shader output…` et 73 `Failed to compile fragment function`. Deux causes, prouvées, corrigées dans le shim (`tools/tsshim/d3d12.c`) :
1. **`SV_ShadingRate`** : la piste « VRS annoncé » est **fausse** : D3DMetal répond déjà `VariableShadingRateTier 0` (`tools/mac_vrs_probe.sh`).
   Des pixel shaders lisent quand même `SV_ShadingRate` ; le convertisseur Metal de D3DMetal (`libmetalirconverter.dylib`, « Unsupported:
   shadingrate ») en fait une variable `user(sv_shadingrate0)` que le vertex shader n'écrit pas, Metal refuse le pipeline. Correctif
   (`tools/tsshim/dxil_shadingrate.c`) : l'entrée est relabellisée `SV_ViewportArrayIndex` (Metal la fournit, 0 = taux 1×1, la valeur sans
   VRS) dans la métadonnée du bitcode DXIL (constante i8 29 → 5 réécrite sur place, même largeur), `ISG1`, `PSV0` ; empreinte du conteneur
   recalculée. **Piège : D3DMetal garde ses traductions sur disque** (`$(getconf DARWIN_USER_CACHE_DIR)d3dm/<exe>/shaders.cache`, 540 Mo pour
   le jeu) **sous l'empreinte de la partie `HASH`** du shader (`vs=8<deux u64>…` dans ses erreurs), pas sous les octets : le correctif modifie
   donc aussi `HASH`, sinon l'ancienne traduction cassée revient du cache. Résultat en jeu : refus `sv_shadingrate0` **148 → 0**, 1 592 pipelines
   corrigés par le shim.
2. **Mélange double source** : D3DMetal (`IsDualSourceBlendingEnabled`) impose le double source au pixel shader dès que la cible 0 a `BlendEnable`
   et un facteur `SRC1_*`, **même sans cible de couleur** ; le convertisseur n'accepte le double source que d'un shader qui écrit exactement
   `SV_Target0` et `SV_Target1` (« Unable to force-enable dual-source blending »). Les passes d'ombre du verre, de l'eau, de l'océan et des
   matériaux en fondu tramé (`…ShadowDepthLightScenario`, 0 cible) gardent le mélange du matériau : 65 des 73 échecs. Correctif : sans cible 0,
   le shim coupe ce mélange (sans effet sous D3D12). Vérifié par la sonde avec un vrai shader du jeu (1 échec → 0). **Pas encore vérifié en jeu**
   (installé le 25 octobre, après le run). Restent 8 pipelines `skidmarksDeferredDecalsLightScenario` (traces de pneus) : vrai double source sur
   1 cible avec un shader qui écrit 3 sorties ; il faudrait retirer une sortie du bitcode, non fait.
3. **Traces de pneus (8 derniers pipelines, 25 octobre)** : `skidmarksDeferredDecalsLightScenario` mélange vraiment en double source sur
   1 cible, avec un pixel shader qui écrit `SV_Target0..2` ; le convertisseur exige exactement 0 et 1. Le **même** shader sert aussi à un
   pipeline à 3 cibles (décalcomanies du GBuffer) qui a besoin de la 3e sortie : la version sans sortie 2 n'est donc donnée qu'aux pipelines
   en double source. Mécanisme : `HB_TSSHIM_REPLACE=<dossiers>` (le lanceur met `fix` par défaut ; `none` coupe), shaders de remplacement
   `C:\highball\replace\<dossier>\<empreinte>.ps`, sous-dossier `dualsrc\` = seulement si la cible 0 mélange avec un facteur `SRC1`
   (la règle de D3DMetal). `tools/mac_shader_fixes.sh` les reconstruit depuis la copie `HB_TSSHIM_DUMP` (désassemblage/réassemblage avec la
   DXC de D3DMetal, `tools/dxilbench/replace_output.py … drop`) et ne garde un correctif que si le banc montre qu'il compile en double source.
   Vérifié au banc avec la vraie paire du jeu (VS `ca0ae82f…` + PS) : original refusé, corrigé → pipeline Metal créé. Une mise à jour du jeu
   change les empreintes : le correctif ne s'applique plus (8 « no-op » reviennent), sans autre effet.
**Sapins noirs (non résolu au 25 octobre)** : présents aussi avec le shim d'origine, donc sans lien avec ces correctifs ; ils ne viennent pas
des pipelines « no-op ». Le feuillage = `uber_foliage*` (les branches `uber_branch*` sont correctes). Pistes **écartées par mesure** :
VRS annoncé (tier 0 déjà) ; `saturate(NaN)` (Metal donne 0 comme D3D, `dxilbench nantest` ; un premier test faux venait de DXC qui
simplifie `x/x` à la compilation) ; cible non écrite (le feuillage n'écrit pas `SV_Target0` sur 8 cibles, mais Metal la laisse intacte,
`dxilbench unwritten`) ; avertissements du convertisseur (aucun sur les 4 368 shaders, sauf « shadingrate »). Le pixel shader principal du
feuillage écrit `SV_Target1..4` (vitesse, 2 cibles entières, albedo en cible 4 = `mix(texture, DISTANT_COLOUR_BLEND.rgb, .a)` ; la couleur
lointaine vient d'une texture-tableau lue dans le vertex shader). Expérience prévue : `HB_TSSHIM_REPLACE=fix,albedo` (albedo du feuillage
forcé magenta) pour séparer « albedo noir » de « éclairage/matériau ». `HB_TSSHIM_DEBUG=1` journalise maintenant les 8 formats de cibles,
le mélange et le masque de chaque pipeline ; `=2` ajoute les ressources (500 Mo, lent).
**Plantages vus le 25 octobre** : (a) `0x143217541` lecture `0x8` = code réseau du jeu (`network_session/coordinator`, `CrashReport.xml`),
déjà vu le 23 octobre ; (b) trois `c0000409` au chargement (après lecture de `media\shadersdxil.zip`), avec et sans les correctifs, puis plus
rien avec le même shim : cause inconnue (peut-être le traitement du rapport de plantage précédent au démarrage).
**Résultat « albedo magenta » (25 octobre)** : les arbres `uber_foliage` deviennent magenta **et éclairés** (l'éclairage marche) ; les
sapins noirs restent noirs, donc **ils ne sont pas dessinés par ces shaders**. Toutes les familles du GBuffer écrivent l'albedo en
`SV_Target4` (`T1:f T2:u T3:u T4:f`). Essai suivant : `HB_TSSHIM_REPLACE=fix,colors` (dossier `replace/colors` : magenta `uber_foliage`,
cyan `projection_lod`, jaune `environment`, vert `uberlod`, bleu `uber_branch`) avec `HB_TSSHIM_DUMP=1` pour copier les shaders encore
inconnus. **Attention : la trace PE ci-dessous est RETIRÉE** (elle faisait planter le démarrage, voir plus bas) ; la trace utilisée est
`tools/mac_trace_faults.sh` (côté macOS, `ntdll.so`, canal `fh6fault`, lecture mémoire par `mach_vm_read_overwrite`), vérifiée avec `tools/excprobe`.
**Résultat « couleurs » et essai de profondeur (25 octobre)** : les couleurs ne servent qu'à savoir quel shader dessine quoi (ce ne sont pas
des correctifs). Grands arbres magenta (`uber_foliage`), troncs bleus (`uber_branch`), rails jaunes ; les feuilles proches restent **noires**,
et des arbres magenta de loin deviennent noirs en s'approchant. Le feuillage proche passe deux fois : une pré-passe de profondeur (shaders
`ShadowDepth`, test GREATER_EQUAL, écrit la profondeur), puis le GBuffer `uber_foliageTrackFPlusPlus` (test EQUAL, sans écriture), qui ne
produit **aucun pixel**. Essai `HB_TSSHIM_DEPTH_EQUAL=1` (EQUAL sans écriture → « égal ou plus près » + biais de 8) : 3 592 pipelines touchés,
rendu cassé (blocs gris), feuilles toujours noires. **Ce n'est donc pas un petit écart de profondeur ; ne pas utiliser cette option.** Le
feuillage n'utilise ni tessellation (seulement l'océan et la neige `terr_mega`) ni geometry shader. Pistes restantes : vertex shader du
GBuffer proche (positions dégénérées ou NaN), dessins sautés (ExecuteIndirect, instances), test de stencil.
**Inspecteur (25 octobre, à la place des codes couleur)** : `HB_TSSHIM_INSPECT=1` (shim, `tools/tsshim/inspect.c`) journalise tout ce que
le jeu crée (chaque pipeline avec le nom de ses shaders lu dans la partie ILDN, sa profondeur, son stencil, son culling, la réponse de
D3DMetal ; ressources, tas, root/command signatures, listes : réussites et échecs détaillés) dans `C:\highball\logs\inspect-<pid>.log`.
Pendant 100 ms toutes les 5 s (`HB_TSSHIM_INSPECT_PERIOD`/`_WINDOW`), chaque dessin d'une liste directe est entouré d'une requête
d'occlusion (pixels écrits). Un pipeline qui n'écrit rien, ou dont un shader contient un mot de `HB_TSSHIM_INSPECT_WATCH` (ex. `foliage`),
reçoit 4 « jumeaux » invisibles (aucune écriture) créés sur un fil à part : sans pixel shader ni profondeur ; idem sans culling ; avec le
pixel shader du jeu sans profondeur ; avec sa profondeur sans stencil. Chaque dessin mesuré passe d'abord par les jumeaux : le journal dit
où les pixels se perdent (rien à l'écran, culling, discard, profondeur, stencil). Max 400 pipelines (`HB_TSSHIM_INSPECT_MAX`). Création des
pipelines sérialisée (numéros = « PSO(N) » de D3DMetal ; les jumeaux prennent des numéros, journalisés). Rapport en français :
`bash tools/mac_fh6_inspect.sh` (`tools/mac_fh6_inspect.py`, joint le journal Wine `out/fh6-after.log` : no-op, plantages, DLL), écrit
`out/inspect-report.txt`. Vérifié sans le jeu : `bash tools/mac_vrs_probe.sh inspect` (`tools/inspectprobe` : 8 triangles qui perdent
leurs pixels à une étape connue, dont un pipeline en stream et un ExecuteIndirect) → 8/8. Sans `HB_TSSHIM_INSPECT` le shim fait exactement
la même chose qu'avant. Le shim remplacé est gardé à chaque reconstruction (`d3dmetal-tsshim-hb.d3d12.dll.last.bak`, `--last`).
**Premier résultat de l'inspecteur (25 octobre, 6 min de jeu, `out/inspect-crash-1603.log` + partie de 16 h 05)** : 22 875 pipelines,
0 refusé, 0 no-op, aucun échec de ressource. Feuilles proches noires = **test de profondeur EQUAL** : `uber_foliageTrackFPlusPlusLightScenario_I`
(GBuffer du feuillage, EQUAL sans écriture) a 569 dessins sur 2 521 mesurés où le pixel shader produit des pixels (jumeau 2) mais où EQUAL
les refuse tous (jumeau 3), et un pipeline (6750) toujours refusé. Même défaut sur `environmentTrackFPlusPlus*` et `characterskin*` (EQUAL).
La pré-passe (`uber_foliage*ShadowDepth*`, GREATER_EQUAL, Z inversé) écrit une profondeur que la passe couleur, autre vertex shader, ne
retrouve pas au bit près. L'ancien essai `HB_TSSHIM_DEPTH_EQUAL` avait bien choisi GREATER_EQUAL + biais 8, mais sur les 3 592 pipelines
EQUAL dont les passes plein écran (composite, classement de pixels) qui se servent d'EQUAL pour trier : d'où les blocs gris ; et 8 unités ne
suffisaient peut-être pas. `D3DM_POSITION_INVARIANCE` vaut 1 par défaut (drapeau 1<<4 de `IRCompilerSetCompatibilityFlags`, lu dans
`D3DMCompiler::CreateIRCompiler`) : ce n'est pas le levier. **Mesure suivante** : les pipelines EQUAL étudiés ont 4 jumeaux de plus
(GREATER_EQUAL ; LESS_EQUAL ; GREATER_EQUAL + biais 64 ; GREATER_EQUAL + biais 4096 et pente 1), lignes `equal` du journal, section 3b du
rapport : quelle correction rendrait quels pixels, sans rien changer à l'image. Sonde : 9/9 (dont un cas « juste devant » : LESS_EQUAL et
biais 64 passent, GREATER_EQUAL non → D3DMetal applique bien le DepthBias). Fenêtre par défaut ramenée à 40 ms (avec 100 ms, 45 % des
dessins n'avaient pas de place dans le tas de requêtes). Comptage des ressources étendu à `ID3D12Device10` (CreateCommittedResource3…).
Sauvegarde du shim d'avant l'inspecteur : `d3dmetal-tsshim-hb.d3d12.dll.pre-inspect.bak`.
**Plantage du 25 octobre 15 h 22** : faute volontaire `0x1434b9f6f` (écriture à 0) avec `rax = 0x800705AA`
(`ERROR_NO_SYSTEM_RESOURCES`, « ressources système insuffisantes ») : le jeu s'arrête sur ce code d'erreur. À relier à l'appel qui le
renvoie (l'inspecteur journalise les échecs de création D3D12).
**Plantage du 25 octobre 16 h 03 (1re partie avec l'inspecteur)** : au chargement de la carte (2 965 → 17 033 pipelines en 25 s),
juste après « AGX: exceeded compiled variants footprint limit » (message présent dans presque toutes les parties, même normales),
faute en lecture à `0xd90f` dans libdispatch (`_dispatch_set_priority_and_voucher_slow+90`, appelé par `_dispatch_block_invoke_direct`)
depuis le pilote `AGXMetalG17X` (`Metal4To3ConversionUtility::createFunction` → `createLinkedFunctions`), puis fautes en boucle
dans ntdll. Jamais vu dans les 16 parties d'avant (rapports `fh6fault`). Adresses retrouvées avec `vmmap` sur un processus x86_64
Metal (même décalage du cache partagé) et `atos`. Hypothèse : les requêtes d'occlusion de l'inspecteur font compiler au pilote des
variantes de plus ; à confirmer en relançant (si ça revient, ne pas mesurer pendant les chargements).
**Revenu à 16 h 39** (même adresse, même fil 0148, même moment : ~14 000 pipelines en 10 s, après le même « footprint limit »). Dans les
deux parties plantées, l'inspecteur avait fait des jumeaux du pipeline 2829 `ForzaUIMaterialScreenShadow` (VS + **GS** + PS ; jumeaux 0/1
sans pixel shader) ; la partie qui a passé le chargement avait étudié un autre pipeline. Metal émule GS/HS/DS (fonctions liées, d'où
`createLinkedFunctions`) : l'inspecteur ne fait plus de jumeaux pour les pipelines avec GS, HS, DS, AS ou MS (`emulated`, pas de copie).
**Revenu à 16 h 44 sans aucun jumeau** : ce n'était donc pas (seulement) les jumeaux. L'instruction fautive lit `gs:[0xe0]`, le
« voucher » de libdispatch dans le TSD macOS (sur Mac, `%gs` = TSD pthread, partagé avec le TEB que voit le code PE ; ce Wine échange
déjà les cases 0x20 et 0x68 à chaque passage) ; le voucher du bloc (rax) vaut 0xd903/0xd43f/0xdacb, pas une adresse. Le fil 0148
fait d'ordinaire du réseau. Hypothèse retenue : la création des pipelines un par un (verrou `pso_lock`, pour suivre les numéros de
D3DMetal) ralentit le chargement et fait compiler des shaders par des fils qui n'en compilent pas d'habitude. Désormais, par défaut,
l'inspecteur ne sérialise plus (`HB_TSSHIM_INSPECT_SERIAL=1` pour l'ancien mode ; numéros propres sinon, le rapport ne relie plus les
« no-op » aux pipelines) et ne mesure ni ne fait de jumeaux tant que le jeu a créé un pipeline dans les 2 dernières secondes.
**Revenu le 26 octobre 15 h 12 sans sérialisation ni jumeau** (4 plantages sur 5 chargements avec l'inspecteur ; 0 sur 4 sans lui depuis
que le rapport `fh6fault` existe). Restent : les requêtes d'occlusion faites dans les menus avant le chargement, et le travail de
l'inspecteur à chaque création (copie, journal). Essai suivant : `HB_TSSHIM_INSPECT_AFTER=16500` (aucune mesure avant 16 500 pipelines,
la carte chargée en compte ~16 900) : si ça plante encore, les requêtes ne sont pas en cause.
**Plantage « exécution de 0x1 » (25 octobre, trace `fh6fault`)** : deux fils sur **un même objet libéré**. Fil principal : faute en
`exe+3217541` en copiant un `std::function` d'un objet en `0x4cd233a80` (pointeur lu = 1). Fil de pool : `invoke_async_completion`
(`xgameruntime`, `xthreading.c:1249`) appelle la routine de fin d'un `XAsyncBlock` en `0x4cd233a90` (dans le même objet), routine = 1.
Le crash « exécution en 0x4CE7FEE00 » du 24 octobre (fil d'un appel HTTP Xbox) a la même forme. Correctif `tools/mac_fix_xasync_inline.sh`
(xgameruntime, moteur + préfixe, `.pre-fh6-xasyncdefer.bak`, `--undo`) : (1) les appels que Wine réalise lui-même (`xgr_async_complete_ex` :
`XNetworkingQuerySecurityInformationForUrlAsync` que libHttpClient demande avant chaque requête, XStore, XGameUI, XGameSave, XUser) ne finissent
plus dans l'appel mais sur le pool après le retour, comme sous Windows (`XGR_INLINE_COMPLETIONS=1` = ancien comportement) ; (2) une routine
de fin qui n'est pas du code (adresse 1, tas) n'est plus appelée : `ERR` « not calling completion routine … (block begun or completed from
<adresse>) », qui nomme la fonction responsable. Sonde `tools/asyncprobe` (12 000 appels sur 4 fils) : ancien = 18 fins avant le retour,
12 000 tâches déjà finies au retour ; corrigé = 17 et 141 ; jamais de double livraison. **Le correctif ne prouve pas la cause** : la prochaine
ligne « not calling completion routine » le dira.
**Trace des exceptions (25 octobre)** : le jeu attrape lui-même ses fautes (il écrit `CrashReport.xml`, puis s'arrête par une 2e faute
volontaire : écriture à 0 en `0x1434B9F6F`, ou lecture dans son rapporteur en `0x143217541`) ; la boîte « Unhandled page fault » ne montre donc
jamais la cause. `tools/mac_trace_exceptions.sh` ajoute à `ntdll` (`exception.c`, `dispatch_exception`) une trace de chaque **première**
exception sur le canal `fh6exc` (niveau ERR, visible avec `FH6_DEBUG="err+all,+loaddll"`) : code, module+décalage, paramètres, pile de
16 niveaux ; sans les pièges de la protection ; 3 lignes max par pile, 3000 en tout. Vérifiée avec `tools/excprobe` (erreur mémoire et
exception logicielle rattrapées, piles exactes). Sauvegardes `.pre-fh6-exctrace.bak`, `--undo`. **Retirée le 25 octobre (`--undo`) : avec elle,
3 démarrages sur 3 ont planté en moins de 3 min (`forzahorizon6.exe+3217544`, lecture de `D8560258C0AEDCC6`, valeur fixe d'un essai à l'autre) ;
sans elle, mêmes réglages, le jeu tourne. La protection n'accepte pas de changement dans le chemin d'exception de `ntdll.dll` : ne pas la
réinstaller.** Ce qu'elle a montré : la fonction `exe+3217541/4` est appelée par un fil de travail `exe+34d0806 → 34d6c2e → 34d7cc2 → 323cd8e →
321c7a3`. Plantages connus à expliquer (désormais avec `tools/mac_trace_faults.sh`) :
`0x143217541` (lecture 0x8), `0x1434B9F6F` (« Fatal Error », écriture 0), exécution en `0x4CE7FEE00` (fil d'un appel HTTP Xbox), `c0000409`
au chargement ; les trois premiers pendant `network_session/coordinator` (jeu en ligne).
Outils : `tools/mac_vrs_probe.sh` (sonde Wine sans le jeu, préfixe à part `out/probe-prefix`, ne gêne pas un jeu lancé : `features`,
`pipeline`, `targets <ps> <n> [dual]`, `--new-shim` pour tester les sources avant installation), `tools/dxilbench/dxilbench.mm` (banc natif
macOS x86_64 avec la `libdxcompiler` et le convertisseur de D3DMetal : `selftest`, `variants`, `settings`, `dualtest`, `dis`, `scan`, `pair`),
`tools/mac_pso_report.sh` (compte avant/après par raison, relie les PSO de D3DMetal aux shaders du shim). Journaux d'avant :
`out/fh6-after.avant-shadingrate.log`. Shim d'avant : `renderers/d3dmetal-tsshim-hb.d3d12.dll.pre-shadingrate.bak` (`tools/mac_setup_tsshim.sh --previous`).

---

## 11. Plan pour la suite (dans l'ordre)

1. **Faire jouer l'utilisateur** (commande « mode jeu » du README) et noter : menu ? « Continuer » avec la progression du compte ? plantage ?
   Fermer par le menu du jeu (attendre ~30 s). Boîte de conflit local / cloud : choisir **Cloud**. Sauvegarder le dossier
   `…/SystemAppData` du prefix avant de s'amuser (`cp -R`).
2. Si le jeu plante : reprendre le `page fault` / erreurs Metal `sv_shadingrate0` et l'avertissement FH302 (§10).
3. **Performance** (demandée par l'utilisateur) : un vrai pilote GPU n'est pas écrivable (pilote Apple fermé). Plan réaliste : mesurer
   (Metal HUD), supprimer les saccades de compilation (cache de shaders persistant), réduire le coût CPU de notre couche (traces désactivées,
   shim), régler D3DMetal (résolution interne + mise à l'échelle). Chaque étape mesurable et réversible.
4. **Vérifier l'état réel des patches** (§10, point 2) et corriger le filtre de `mac_all.sh` pour afficher
   `installed …`.
5. **Nettoyer les diagnostics** (quand tout marche) : `tools/mac_trace_null_call.sh --undo`, retirer les `FHTRACE`
   de l'utilisateur si souhaité (ils sont à lui), garder `mac_trace_msgbox` tant qu'on lit des boîtes.
6. **Documentation** : garder `README.md`, `docs/ANALYSE-FH6-STORE-MACOS.md` (section 7) et ce fichier à jour.
7. Éventuellement : comparer avec la config Highball sur un point jamais vérifié (version exacte de CrossOver du
   moteur, `compiler gcc vs llvm-mingw`).

---

## 12. Annexes

### 12.1 Textes exacts des boîtes du jeu

- *« Installation path is too long. Forza Horizon is currently installed at: Z:\…\gamefarm-audit  Please move
  your Forza Horizon installation to a shorter path. Click Help for more details. Forza Horizon will now
  quit. »* (310 caractères, légende « Forza Horizon »).
- *« Nous avons détecté les problèmes matériels suivants : - Votre carte graphique n'est pas prise en charge
  (code : FH205). [- Impossible de détecter la version du pilote graphique. Vous pouvez continuer, mais les
  performances et la stabilité du jeu pourraient…] Cliquez sur En savoir plus ci-dessous pour avoir plus
  d'infos sur ces codes d'erreur et la configuration requise pour ce jeu. »* Boutons : **Quitter**,
  **En savoir plus**. Titre : « Avertissement de compatibilité de Forza Horizon 6 ». Codes vus : FH205 (D3DMetal 3),
  FH206 (D3DMetal 4).
- *« Cloud save synchronization failed. Retry? / Yes: retry. No: play with local saves offline. Cancel: stop. »*
  Légende : « Game Saves ».
- Autre code cité par la recette : **FHE21** (plantage du chemin AMD-only quand D3DMetal se dit AMD).

### 12.2 Résultats chiffrés utiles

- `selfread` : 4 échecs → 0 (relecture de l'exe).
- `D3D12CreateDevice` : plante avec GPTK4 du moteur ; réussit avec les d3d12 de CrossOver (adaptateur
  « Intel Arc A750 » puis « NVIDIA GeForce RTX 4070 » selon `FH6_GPU`, VRAM déclarée ≈ 38 Go).
- Shader model : D3DMetal 3.0 → 6.6 ; 4.0b3 → 6.8.
- `fontprobe` : avant `GetDialogBaseUnits=0`, 0 famille ; après `00100008`, **968 familles**.
- Logs : 18 à 93 millions de lignes avec `+seh,+unwind` ; 80 000 à 175 000 lignes sans.
- Un run de **689 s** (arrêt par l'utilisateur après la boîte « Installation path ») et un de **900 s** (limite du
  script) ont eu lieu avec le chemin long puis le chemin court.

### 12.3 Commande de vérification rapide de l'état de l'installation

```sh
cd ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT && git log --oneline -3 \
 && ls ~/FH6 | head -3 && ls -ld /Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/audit/gamefarm-audit \
 && E=/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine \
 && ls $E/renderers/d3dmetal-tsshim-hb/wine/x86_64-windows $E/share/wine/fonts | head -8 \
 && strings -a $E/lib/wine/x86_64-unix/win32u.so | grep -m1 libfreetype
```

### 12.4 Sécurité et confidentialité

- Aucun jeton, mot de passe ni identifiant n'est dans le dépôt ni dans ce document.
- Le jeton GitHub collé par erreur au début n'a pas été conservé ; l'utilisateur a été invité à le révoquer.
- Les logs (`out/`) restent sur le Mac de l'utilisateur et **ne sont pas** dans le dépôt (ils contiennent des
  chemins personnels).

---

## 13. Blackwell Engine : le jeu sans CrossOver.app (26 octobre 2026)

**Prouvé** : le jeu tourne sur **Blackwell Engine** (moteur reconstruit par `engine/build.sh`) + le `redist/lib` du
Game Porting Toolkit 4.0b3 d'Apple + le shim Highball, **sans aucun fichier de CrossOver.app** (`vmmap` du processus du
jeu : 0 chemin CrossOver). Essai tracé : `LoginWithXbox` 200, `GameSave/ListManifests` 200, `gameservices.fh6.forzamotorsport.net`
200 ; il a fini sur le plantage connu `gs:[0xe0]` (voucher libdispatch) au chargement de la carte, favorisé par les traces.
Essai sans traces (`WINEDEBUG=-all`, comme Play) : plus de 10 minutes de jeu, 6,9 Go, sans plantage.

- **La vraie cause de « GPTK4 ne marche pas avec ce Wine »** (phase 5) : dans le kit d'Apple, `wine/x86_64-unix/*.so`
  (`d3d12.so`, `dxgi.so`, `d3d12core.so`…) sont des **liens** vers `external/libd3dshared.dylib`. L'ancien moteur en avait
  des **copies** : dyld chargeait plusieurs images séparées, et seule celle de `d3d12.so` recevait la table de Wine
  (`Win32DispatchInit`, appelée par le `d3d12.dll` PE via l'unix call n° 1). `WineMonitor::Init` tournait dans une autre
  copie : appel à l'adresse 0. Avec les liens (et `apd12.so` lien vers `d3d12.so`), tout marche.
- Le shim charge le vrai `d3d12.dll` d'Apple sous le nom `apd12.dll` : la copie doit avoir son **nom d'export** changé
  (sinon Wine rend le shim et `d3d12=0`). L'app le fait sur le Mac de l'utilisateur (`app/Sources/MetalHorizon/PEFile.swift`),
  comme Highball : on ne distribue jamais de fichier Apple modifié.
- GnuTLS (Nettle intégré, ne dépend que de GMP), GMP, FreeType, MoltenVK : construits en x86_64 par `engine/build-deps.sh`
  et rangés dans `lib/` du moteur (`@loader_path`).
- La licence d'Apple autorise la redistribution séparée du Framework et des Redistributables à des fins **non commerciales**
  (2A(iii), 2C). `engine/package-d3dmetal.sh` emballe le `redist/lib` intact ; l'app l'installe après acceptation.
- Release GitHub `blackwell-engine-1.0` : `blackwell-engine-1.0.tar.xz` et `d3dmetal-4.0b3-redist.tar.xz`, épinglés dans
  `app/components.json`. Tant que le dépôt est privé, le téléchargement anonyme répond 404 ; l'app prend alors
  `~/Library/Application Support/MetalHorizon/Downloads/`.
- `tools/jouer.sh` et `tools/mac_launch_fh6.sh` (outils de développement) utilisent encore CrossOver.app ; l'app non.
