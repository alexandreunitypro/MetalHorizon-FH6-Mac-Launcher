# Forza Horizon 6 (Microsoft Store / MSIXVC) sur macOS : analyse du blocage de démarrage

Session cloud du 2026-10-21. Rien ici n'a été exécuté sur un Mac, et le jeu n'a jamais été lancé dans
cette session. Chaque point indique ce qui a été vu, compilé ou exécuté, et où.

## 0. Ce qui était disponible (et ce qui ne l'était pas)

- Ce dépôt ne contenait qu'un `README.md` d'une ligne (commit `2fb1bdc`). L'audit
  `work/audit/2026-10-20-phase0/findings-2026-10-20-denuvo.md` est absent. Une recherche
  sur tout le disque du conteneur ne trouve pas non plus de logs, de
  `xsts_probe.py`, de sources Xodus ou Ferestre modifiées, de `xgameruntime.so`, de
  `concrt140` ou de sauvegardes `.pre-runtime-dir`. Ton compte GitHub ne donne accès qu'à ce dépôt.
- Conséquence : les empreintes `9028b263…`, `012ab467…`, `f9aff5d6…` et les adresses SIGILL n'ont pas pu
  être vérifiées ici. `tools/check_runtime.py` sert à le faire sur le Mac.
- Sources réellement lues dans cette session (clones publics) :
  - `icex/ferestre` @ `9ab17d7` (patches Wine/xgameruntime/xodus, recettes de jeux, `capabilities.toml`) ;
  - `xodus-gaming/xodus` @ `95f482f` (HEAD) et `3e75c9f` (commit épinglé par Ferestre) ;
  - `xodus-gaming/wine` branche `bleeding-edge` @ `eab6973` (base Wine 11.0 du runtime Ferestre) ;
  - `wine-mirror/wine` tags `wine-10.0` à `wine-11.20` et `master` ;
  - `gauthierpiarrette/highball`, `highball-engine`, `highball-db` (HEAD du jour).
- Inaccessibles : les sources CrossOver 26.3 (`media.codeweavers.com` refusé par le proxy,
  aucun miroir trouvé) et `gitlab.winehq.org` (refusé ; le miroir GitHub de Wine fonctionne).

## 1. Ce qui différencie l'édition Store de l'édition Steam (faits lus dans le code)

| | Steam (Highball) | Store/MSIXVC (Xodus/Ferestre) |
|---|---|---|
| Exécutable sur disque | en clair | **chiffré** ; la copie déchiffrée n'existe que derrière un descripteur |
| Lancement | `wine game.exe` | `WINE_DLL_FILE_MAP="<fd>:\??\Z:\...\forzahorizon6.exe" wine '\??\Z:\...'` (`xodus-cli/src/commands/run.rs`) |
| Le jeu relit son .exe | lit le fichier sur disque | doit lire le descripteur ; sinon il lit du chiffré |
| Descripteur | — | Linux : `memfd_create` ; **macOS : `tempfile_in()` sur un disque RAM HFS, nom supprimé tout de suite** |

Ferestre décrit en clair le contrôle que fait Forza (`patches/wine/0013`, commentaire) :
> Forza Horizon 5 opens its own executable that way three times, read only, hashes what it reads and stops the
> process when the answer is wrong.

« That way » désigne la forme `\??\GlobalRoot\??\Z:\…` du nom renvoyé par
`NtQueryVirtualMemory(MemoryMappedFilenameInformation)` sur la base de l'image (`patches/wine/0010`).
Ferestre marque FH6 Store « playable » sous Linux (`titles/9NR1R1XWLCNB.toml`, vérifié le 2026-10-17,
paquet 3.461.691.0). La capacité exigée pour **tous** les titres MSIXVC est `loader.memfd-main-image`.

Pour que ce contrôle réussisse, il faut quatre choses à la fois :

1. le nom de l'image doit être renvoyé (Ferestre 0010, repli via le PEB) ;
2. `\??\GlobalRoot\??\Z:\…\forzahorizon6.exe` doit être reconnu comme l'image mappée (Ferestre 0013) ;
3. `NtCreateFile` sur ce nom doit renvoyer le **descripteur déchiffré**, pas le fichier chiffré (Ferestre 0009) ;
4. **chaque handle doit avoir sa propre position de lecture**. Ferestre 0009 l'obtient en rouvrant
   le descripteur par `/proc/self/fd/N`. Son commentaire cite le cas où la position est partagée :
   l'EAC de Halo lit les 83 Mo, et la réouverture suivante démarre en fin de fichier.

## 2. Le défaut propre à macOS

Les deux constats suivants viennent de la lecture du code (faits) :

- `/proc` n'existe pas sur macOS. Dans `mapped_fd_to_handle()` (Ferestre 0009), `open("/proc/self/fd/N")`
  échoue toujours. Le code se replie alors sur `wine_server_fd_to_handle(fd, …)`, donc sur **une seule
  description de fichier partagée** par tous les handles ouverts sur l'image.
- `NtReadFile` sans offset fait un `read()` sur la position du noyau (`dlls/ntdll/unix/file.c` du fork,
  branche `virtual_locked_read`). Avec offset, il fait un `pread` puis un `lseek(offset + n)` qui
  déplace lui aussi cette position partagée.

D'où une inférence forte : sur macOS, avec les patches Ferestre tels quels, la 2e et la 3e lecture du
contrôle d'intégrité partent de la fin du fichier, l'empreinte est fausse, et le jeu se termine
volontairement **avant** d'atteindre `XGameRuntimeInitialize`. `xgameruntime.dll` n'est alors jamais
chargée, ce qui correspond à l'observation des essais précédents. Les correctifs `concrt140` n'y changent
rien : d'après `capabilities.toml`, 0015 n'intervient qu'« after compiling shaders », bien plus tard.

Ce qui reste une hypothèse : que FH6 Store lise sans offset explicite, ou avec des `SetFilePointer`
mêlés à d'autres handles. L'expérience de la section 4 montre le mécanisme sur une sonde. Seul le Mac
peut montrer l'effet sur le jeu.

Il y a aussi une seconde différence macOS, indépendante : sur macOS, xodus **supprime le nom** du fichier
déchiffré (`tempfile_in`). Sans nom, et sans `/proc`, aucune réouverture n'est possible.

## 3. Ce que disent les autres pistes

### SIGILL (`0x14539BEA8`, `…BEB6`, `0x145399EE8`, `…BE3B`, VEH `0x145364498` → `ffffffff`)

- `ffffffff` vaut `-1`, c'est-à-dire `EXCEPTION_CONTINUE_EXECUTION` : le gestionnaire du jeu a **accepté**
  l'exception et demandé à reprendre. Quatre adresses distinctes et proches : ce motif évoque une émulation
  qui progresse, pas un blocage sur une adresse. Inférence forte, mais sans log je ne peux pas compter les
  traps ni voir le RIP après coup.
- Le chiffre d'environ 2 000 vient de Highball (`spike/rosetta-trap-cost/README.md`, rapport Apple
  FB25100017). Ils l'ont **mesuré sur FH6 Steam** : la protection exécute environ 2 000 instructions qui
  piègent volontairement, émulées par le gestionnaire du jeu, toutes les ~1,1 s, à ~57 µs chacune sous
  Rosetta. C'est un nombre par tâche périodique, pas un total. Cela décrit un mécanisme qui **fonctionne**
  sous Wine 11 + Rosetta : la version Steam joue.
- Dans `signal_x86_64.c` de Wine 11, SIGILL est routé vers `segv_handler`. `TRAP_x86_PRIVINFLT` y devient
  `EXCEPTION_ILLEGAL_INSTRUCTION`, et les instructions privilégiées sont reconnues via `is_privileged_instr`
  sur une faute de protection générale (`TRAP_x86_PROTFLT`). Si Rosetta livrait `hlt`/`cli` comme SIGILL
  au lieu d'une faute de protection générale, Wine rapporterait `ILLEGAL_INSTRUCTION` au lieu de
  `PRIV_INSTRUCTION`. C'est une hypothèse. La sonde la teste (`trap-hlt`).
- Conclusion : les SIGILL passent au second plan. La sonde vérifie la livraison (code, adresse, RIP,
  reprise) et mesure le coût par trap. Une divergence sur ce point ferait remonter la piste.

### GLOBALROOT

- Wine amont, de 10.0 à 11.20/master, ne retire **pas** `\??\GlobalRoot`. Dans `get_dos_prefix_len()`,
  le nom tombe en `STATUS_BAD_DEVICE_TYPE` ; ensuite le serveur s'arrête sur l'objet
  `\Device\HarddiskVolumeN` de mountmgr (`no_lookup_name`), d'où `STATUS_OBJECT_NAME_NOT_FOUND`.
  `git log -S GlobalRoot` sur `dlls/ntdll/unix/file.c` ne renvoie aucun commit.
- `xodus-gaming/wine` (lignée Proton) retire ce préfixe dans `get_dos_prefix_len()` (« Stripping off
  GlobalRoot prefix »). Pour l'exe lui-même, Ferestre 0013 le traite avant même la résolution du nom.
- Highball dit que la protection de FH6 Steam « opens files in a way the Wine 10 engine does not handle »
  et que leur Wine 11 (CrossOver 26.3) passe. Je n'ai pas pu lire CrossOver 26.3. Cela suggère que
  CrossOver porte un traitement équivalent, mais ce n'est pas vérifié. Si ton Wine macOS est basé sur
  CrossOver ou sur Wine amont plutôt que sur le fork Proton, la sonde (`globalroot-unmapped-file`) le dira.

### Xodus 0001 (XSTS)

`scripts/check-patches.sh` de Ferestre **saute** `xodus-cli/0001-xsts-token-ipc-endpoint.patch` (« earlier
export of work that 0002 already contains »). Le reconstruire seul sur un Xodus propre donne donc un
Xodus différent de celui de Ferestre. Ce n'est pas lié au démarrage (le jeu ne va pas jusque-là), mais il
faut le savoir avant d'étudier XSTS dans le jeu.

### Highball : ce qui s'applique et ce qui ne s'applique pas

- 0017 (`GetIntegratedDisplaySize`), 0018 (mémoire), 0019 (`CredEnumerateW`), tsshim D3D12, variables
  `D3DM_*` : ils interviennent **après** l'ouverture de la fenêtre ou au sign-in. Utiles plus tard, ils ne
  peuvent pas agir sur un arrêt antérieur à `xgameruntime`.
- Écart avec ton dossier : la recette Highball actuelle présente le GPU comme **NVIDIA**
  (`D3DM_VENDOR_ID=0x10de`, `D3DM_DEVICE_ID=0x2786`, « RTX 4070 »), pas Intel `0x8086`. La note de la
  recette explique que sans cela le jeu plante dans son code AMD (FHE21) ou refuse D3DMetal 3 (FH205).

## 4. Correctifs écrits dans ce dépôt

- `patches/wine/0001-ntdll-macos-reopen-mapped-image-by-path.patch`, à appliquer après Ferestre 0001-0018 :
  sur macOS, rouvre le descripteur par `fcntl(F_GETPATH)` et contrôle `st_dev`/`st_ino`. Sur Linux, il
  garde `/proc` avec le même contrôle. Sinon, il garde l'ancien repli et écrit **une** ligne `ERR` qui le
  signale.
- `patches/xodus-cli/0001-macos-keep-decrypted-image-named-on-ramdisk.patch`, à appliquer après Ferestre
  0002-0027 sur xodus `3e75c9f` : sur macOS, le fichier déchiffré garde son nom **sur le disque RAM
  privé** (monté `nobrowse`, détaché à la sortie). Le texte en clair ne touche toujours pas de disque
  persistant.
- `tools/selfread/selfread.c` (+ `selfread.exe` compilé) : reproduit le contrôle de Forza sans le jeu,
  et teste la livraison de `ud2`/`hlt`/`int3`.
- `tools/mapfd_run.py` : lance la sonde exactement comme xodus lance un titre (copie illisible sur
  disque, vraie image derrière le descripteur, `WINE_DLL_FILE_MAP`).
- `tools/check_runtime.py` : liste les patches réellement compilés dans un Wine installé et donne les
  SHA-256 complets.

Aucun de ces correctifs ne touche le binaire du jeu ni sa protection. Ils rendent seulement à Wine le
comportement de Windows : chaque ouverture d'un fichier a sa propre position.

## 5. Résultats des tests (Linux, cloud)

Environnement : conteneur Linux x86_64 (pas de Rosetta, pas de macOS). Wine compilé ici à partir de
`xodus-gaming/wine` `bleeding-edge` `eab6973` + Ferestre `patches/wine` 0001-0018 (les 18 s'appliquent) +
le patch de ce dépôt. Configuration : `--enable-archs=x86_64 --disable-tests`, sans X ; le module Proton
`amd_ags_x64` a été retiré de la copie de build, car sa génération de Makefile échoue hors de Proton.
Sonde : `tools/selfread/selfread.exe`, sha256 `f62db538f0b352e1b1ff326e62860b41f2ec6660a0d33f820d544f77864d5806`
(mingw-w64 GCC 13). Les trois variantes de test ne diffèrent que par `reopen_mapped_fd()` ; les deux
variantes d'émulation n'existent que dans la copie de travail et ne sont pas livrées.

| # | ntdll.so | descripteur | résultat |
|---|---|---|---|
| E1 | patch livré, branche Linux `/proc` (`5bd78116…`) | memfd | **0 échec** : 3 relectures GLOBALROOT de 310 265 octets, même FNV `f80038ee5a64a459`, offsets indépendants, ud2/hlt/int3 corrects |
| E2 | « Ferestre sur macOS » : réouverture impossible (`3e546bc1…`) | memfd / unlinked / named | **4 échecs** chaque fois : relecture 1 = 310 265 octets, **relectures 2 et 3 = 0 octet** (FNV du vide `cbf29ce484222325`), `independent-offsets` et `plain-path-read` = 0 octet |
| E3a | logique macOS du patch, F_GETPATH émulé par `readlink` (`3ae5cc87…`) | unlinked (xodus macOS actuel) | **4 échecs** + la ligne `err:module:mapped_fd_to_handle … cannot be reopened` |
| E3b | idem | named (xodus corrigé) | **0 échec** |

Ce que ces tests établissent :
- le lanceur reproduit fidèlement la situation xodus : le processus ne peut tourner que depuis le
  descripteur, puisque le fichier sur disque est du bruit ;
- sans réouverture possible, une 2e lecture complète de l'image ne lit **rien**. C'est le cas sur macOS
  avec le code Ferestre actuel, quel que soit le type de descripteur ;
- le correctif ne marche **qu'avec ses deux moitiés** (Wine + xodus).

Ce qu'ils n'établissent pas :
- que FH6 Store lit son image de cette manière : c'est ce que dit Ferestre pour FH5, pas une mesure sur FH6 ;
- que la branche `#ifdef F_GETPATH` compile et se comporte pareil sur macOS (non compilée ici) ;
- que ton Wine macOS contient Ferestre 0009/0010/0013. Sans ces patches, l'échec se produit encore plus
  tôt (voir `tools/check_runtime.py`) ;
- quoi que ce soit au-delà du démarrage : D3DMetal, sign-in, saves.

Mesure annexe : un aller-retour `ud2` → VEH → reprise coûte 10,9 µs ici (Linux natif). Highball mesure
14,8 à 57 µs sous Rosetta. Sur 2 000 traps, cela fait 20 à 110 ms : un à-coup, pas un blocage.

## 6. État et prochaine étape

État : **cause très probable, correctif préparé et validé sur une reproduction minimale, pas encore testé
dans le jeu ni compilé sur macOS.**

Prochaine étape, la plus informative : sur le Mac, `tools/check_runtime.py`, puis `tools/mapfd_run.py`
avec le Wine actuel, sans patch. En une minute et sans le jeu, ces deux commandes disent :

- si ton runtime a bien les patches 0009/0010/0013 ;
- si la deuxième relecture lit 0 octet chez toi.

Si c'est le cas, appliquer les deux moitiés du patch et relancer le jeu. Commandes exactes dans le
[README](../README.md).

Si la sonde passe déjà sur le Mac sans correctif, cette piste est réfutée pour ton environnement.
L'inconnue décisive devient alors ce que fait le jeu entre ses callbacks TLS et la fin du processus.
Pour l'éclairer : `WINE_TRACE_TLS=1` (Ferestre 0001), `WINEDEBUG=warn+process` (code de sortie, Ferestre
0012), et `trace+file` limité au démarrage, pour voir quel fichier le jeu ouvre en dernier.

## 7. Résultats sur le Mac (21 octobre 2026)

Chaque étape a été vérifiée sur le Mac de l'utilisateur. Les logs sont dans `out/` sur ce Mac, ils ne sont pas dans le dépôt.

| Étape | Constat | Correctif |
|---|---|---|
| Relecture de l'exe | Sonde : 0 échec après le correctif Wine 0001 et le correctif xodus | `patches/wine/0001`, `patches/xodus-cli/0001` |
| Trace locale `FHTRACE` dans `call_vectored_handlers` | Lisait 24 cases de pile au-delà de `StackBase` (fault à `0x3260000`, thread 0114) | `tools/mac_fix_vectored_trace.*` (bornée, seulement avec `+seh`) |
| `virtual_unwind`, frame sans module | L'unwinder macOS inventait un handler (`0020019008070C10`) | `tools/mac_fix_leaf_unwind.*` : déroulé « leaf » comme Windows |
| Appel à l'adresse 0 dans `d3d12.so` (`WineMonitor::Init`, `QueryDescription`) | `gWin32Dispatch` vide. Reproduit **sans le jeu** par `tools/d3d12probe` (`D3D12CreateDevice`) | Aucun dans Wine : la copie GPTK4 de D3DMetal ne va pas avec ce Wine |
| Matrice `tools/mac_d3d12_matrix.sh` | GPTK4 : plante, avec ou sans tsshim. **GPTK de CrossOver.app sur ce Wine : `D3D12CreateDevice` réussit** | `FH6_CX_GPTK=1` dans `tools/mac_launch_fh6.sh` |
| Jeu avec `FH6_CX_GPTK=1` | Écran de démarrage affiché, image servie 4 fois, **`xgameruntime.dll` chargée**, pas d'arrêt de lui-même en 150 s | — |

| Boîte de message « Forza Horizon » affichée juste après `xgameruntime.dll` | Texte lu dans le log via `tools/mac_trace_msgbox.*` : *« Installation path is too long… Please move your Forza Horizon installation to a shorter path… Forza Horizon will now quit. »* Le dossier `Z:\Users\alexandre\Documents\Codex\…\gamefarm-audit` dépasse 100 caractères | Chemin court par lien symbolique `~/FH6` (par défaut dans `tools/mac_launch_fh6.sh`, `FH6_LONG_PATH=1` pour l'ancien) |
| Boîte dessinée comme une fine pilule | `share/wine/fonts` vide dans le moteur compilé, puis `DIALOG_CreateIndirect units = 0,0` même après copie des polices | `tools/mac_fix_fonts.sh`. La cause restante des unités nulles est encore à trouver |

| Chemin court pris (`Z:\Users\alexandre\FH6`, dossier renommé par `tools/mac_move_short.sh`) | Le jeu va plus loin : il ouvre `media\ui\fonts.zip`, puis affiche « Avertissement de compatibilité de Forza Horizon 6 » : *« Votre carte graphique n'est pas prise en charge (code : FH205) »*, avec les boutons Quitter et En savoir plus | Changer la carte présentée n'y change rien (essai NVIDIA retiré, réglages d'origine remis). D'après les notes de Highball 0.10.9, ce message vient d'un écart de *shader model* dans la couche DirectX 12 : voir `tools/d3d12probe features` |
| Unités de dialogue 0,0 | `tools/fontprobe` : GDI voit 0 famille de polices, et toutes les métriques sont à 0 | En cours : FreeType absent du `win32u.so` compilé ? |

| Shader model annoncé (`tools/mac_d3d12_features.sh`, `tools/mac_d3d12_mix.sh`) | D3DMetal 3.0 (CrossOver.app) : 6.6 au plus. **D3DMetal 4.0b3 avec les d3d12 de CrossOver : 6.8**, conforme à la règle (min de la demande et du support). Les d3d12 du moteur avec 4.0b3 plantent toujours | `FH6_D3DM4=1` (avec `FH6_CX_GPTK=1`) |

| Jeu avec `FH6_CX_GPTK=1 FH6_D3DM4=1` | Même avertissement, avec le code **FH206** au lieu de FH205 : *« Votre carte graphique n'est pas prise en charge »* | Aucun : c'est le contrôle de compatibilité matérielle du jeu lui-même, et ce projet ne le contourne pas |

| Boîtes de dialogue en « pilule » / boutons vides (cause : Wine compilé sans FreeType) | `tools/mac_enable_freetype.sh` : `config.h` et `Makefile` modifiés directement (HAVE_FT2BUILD_H, SONAME_LIBFREETYPE, FREETYPE_CFLAGS), en-têtes FreeType 2.13.3 téléchargés avec vérification SHA-256, bibliothèque x86_64 de CrossOver.app, `win32u.so` recompilé (SDKROOT et CPATH nécessaires). Test `tools/fontprobe` : `GetDialogBaseUnits` 0 → `00100008`, métriques 0 → 13×5, familles de polices 0 → 968 | Corrigé. Retour arrière : `--undo` |

| Examen de Highball (highball-engine, highball, highball-db ; GPL-3.0) | Highball fait tourner la version **Steam** de FH6 sur Mac. Cause de FH205/FH206 : écart de **shader model** (`CheckFeatureSupport(SHADER_MODEL)` → `E_INVALIDARG` avec D3DMetal). Solution : shim DX12 devant D3DMetal + patches Wine 0017–0019 (+ 0022/0023) + carte NVIDIA RTX 4070 présentée (recette actuelle ; Intel Arc A750 dans l'ancien Reddit) | `tools/tsshim/`, `tools/mac_setup_tsshim.sh`, `tools/forza-patches/`, `tools/mac_apply_forza_patches.sh` |
| Bug du lanceur : `unset HB_D3D12_REAL` avec `FH6_CX_GPTK=1` | Le shim n'était jamais chargé | Corrigé : le shim passe devant le d3d12 de CrossOver |
| Avec shim + patches | **La boîte FH205/FH206 disparaît**, 0 piège `c000001d`, `sl.reflex.dll` chargée (Reflex), le jeu tourne. L'utilisateur : « le jeux se lance » | — |
| Boîte « Game Saves » (Yes/No/Cancel) | *« Cloud save synchronization failed. Retry? … No: play with local saves offline »*, **48 apparitions** (boucle), aucune connexion Xbox dans le log | **Résolu** : voir les lignes suivantes |
| Origine de la boîte | `ui_failed()` (`dlls/xgameruntime/pfxgamesave.c`) : `cloud save sync failed: state 1, hr 0x80004005` ; « No » (hors ligne) échoue aussi | Cause locale, pas le compte |
| Chiffrement | `err:bcrypt:key_asymmetric_create no encryption support` ×45 ; `SONAME_LIBGNUTLS` non défini | `tools/mac_enable_gnutls.sh` : 0 erreur, TLS établi |
| DLL du prefix | `xgameruntime.dll` du prefix = ancienne copie (707 535 o) ; le jeu charge la copie du prefix | `tools/mac_sync_prefix_dll.sh --apply xgameruntime` |
| `winhttp.dll` | `WinHttpQueryHeaders(RAW_HEADERS_CRLF, NULL)` : FALSE avec `GetLastError()==0` (Windows : 122) ; libHttpClient abandonne et renvoie E_FAIL | Recompilation de la source non modifiée (`tools/mac_fix_winhttp_headers.sh`) ; sonde `tools/httpprobe` : `err=122` partout |
| Run de 360 s après correction | `work_complete PlayFab operation 0 completed, hr 0`, aucun `ui_failed`, aucune boîte, pas d'arrêt anormal | Reste à confirmer en jeu : progression du compte téléchargée |

Le blocage décrit dans la mission (`xgameruntime.dll` jamais chargée) est levé. L'édition Store de FH6 démarre, sa licence est acceptée, elle charge son runtime Xbox, puis s'arrête sur son propre contrôle de compatibilité matérielle (FH205 avec D3DMetal 3.0, FH206 avec D3DMetal 4.0b3). Ce projet s'arrête là : il ne contourne ni la protection, ni la licence, ni ce contrôle.

### Pistes légitimes restantes
- Polices : recompiler `win32u.so` avec FreeType (`config.h` : `/* #undef HAVE_FT2BUILD_H */`), pour que les boîtes Windows s'affichent normalement.
- Jouer à FH6 sur ce Mac : Xbox Cloud Gaming, ou bien la version Steam via Highball (macOS 27, D3DMetal 4, testée par son auteur sur un Mac mini M4). Voir les [notes de version de Highball 0.10.9](https://github.com/gauthierpiarrette/highball/releases/tag/v0.10.9).
