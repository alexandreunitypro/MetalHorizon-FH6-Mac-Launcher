# Notes de développement (ancien README)

Faire démarrer **Forza Horizon 6, édition Microsoft Store / Xbox (MSIXVC)**, sur macOS avec Wine +
Xodus + les patches Ferestre.

- **Tutoriel pas à pas pour tester sur le Mac : [`TUTORIEL-TEST-MAC.md`](TUTORIEL-TEST-MAC.md)**
- **Passation complète pour une autre IA : [`PASSATION-IA.md`](PASSATION-IA.md)**
- Analyse complète, preuves et limites : [`ANALYSE-FH6-STORE-MACOS.md`](ANALYSE-FH6-STORE-MACOS.md)
- Correctifs : [`patches/`](../patches/)
- Outils de test sans le jeu : [`tools/`](../tools/)

## Où on en est (21 octobre 2026)

**Le jeu se lance et la synchronisation des sauvegardes cloud fonctionne** (21 octobre 2026) : licence acceptée, contrôle de compatibilité
matérielle (FH205/FH206) passé grâce au shim DirectX 12 de Highball, polices des boîtes réparées (FreeType), jetons Xbox fournis par
`xodus-service`, et la boîte « Game Saves » a disparu (`PlayFab operation 0 completed, hr 0`). Les causes (GnuTLS absent, DLL périmées dans le
prefix, `winhttp`) sont dans [`PASSATION-IA.md`](PASSATION-IA.md), phase 13. À confirmer en jeu : la progression du compte est bien
récupérée. Pour jouer, **une seule ligne**, sans journal ni traces (rapide) :

```sh
bash ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT/tools/jouer.sh
```

**Fermer le jeu par son menu** et attendre environ 30 secondes (envoi final des sauvegardes). Si une boîte propose de choisir entre la sauvegarde
locale et celle du cloud, choisir **Cloud**. Commande de diagnostic complète (rapport copié dans le presse-papiers ; après un plantage : `bash tools/mac_crash_report.sh`) :

```sh
pkill -f xodus-cli; pkill -f wineserver; sleep 2; cd ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT && git pull -q && FH6_CX_GPTK=1 FH6_D3DM4=1 FH6_DEBUG="err+all,+loaddll,+pfxgamesave,warn+gdkc" bash tools/mac_all.sh 360
```

**Pour reprendre le travail : lire [`PASSATION-IA.md`](PASSATION-IA.md)** (état, règles, chronologie complète,
outils, pièges, plan). Détails techniques et preuves : section 7 de l'analyse.

## Le diagnostic en bref

Sur macOS, l'exécutable déchiffré du jeu n'a pas de position de lecture propre à chaque ouverture. Sous
Linux, Ferestre la donne en rouvrant le descripteur via `/proc/self/fd`, qui n'existe pas sur macOS.
Forza relit trois fois son propre `.exe` pour en vérifier l'empreinte : dès la deuxième lecture, il lit
depuis la fin du fichier et s'arrête de lui-même, avant de charger `xgameruntime.dll`. Les SIGILL observés
correspondent au mécanisme normal de la protection (handler qui renvoie `EXCEPTION_CONTINUE_EXECUTION`),
pas au blocage. Détails et degré de certitude : voir l'analyse.

## Commandes à lancer sur le Mac

Remplace les chemins entre `<…>` par les tiens.

```sh
cd <ce dépôt> && git pull

# 1. Inventaire : quels patches ton Wine contient vraiment, avec les SHA-256 complets
python3 tools/check_runtime.py <racine de ton Wine installé, celle qui contient lib/wine> | tee out-check-runtime.txt

# 2. Sonde AVANT correctif, lancée comme xodus lance un jeu (aucun fichier du jeu utilisé)
mkdir -p out
python3 tools/mapfd_run.py --wine <ton binaire wine> --fd-kind unlinked --log out/probe-before-unlinked.txt
python3 tools/mapfd_run.py --wine <ton binaire wine> --fd-kind named    --log out/probe-before-named.txt
```

Avec un Wine qui porte Ferestre 0009 sans ce correctif, on attend `FAIL globalroot-read-2`, `-3` et
`independent-offsets`.

```sh
# 3. Correctif Wine (sauvegarde d'abord, retour arrière = remettre le .bak)
cp <wine>/lib/wine/x86_64-unix/ntdll.so <wine>/lib/wine/x86_64-unix/ntdll.so.pre-fh6-reopen.bak
git -C <sources Wine> apply --check "$PWD/patches/wine/0001-ntdll-macos-reopen-mapped-image-by-path.patch" \
  && git -C <sources Wine> apply "$PWD/patches/wine/0001-ntdll-macos-reopen-mapped-image-by-path.patch"
make -C <dossier de build Wine> dlls/ntdll/ntdll.so && \
  cp <dossier de build Wine>/dlls/ntdll/ntdll.so <wine>/lib/wine/x86_64-unix/ntdll.so

# 4. Correctif xodus (sauvegarde du binaire d'abord)
cp <xodus>/target/release/xodus-cli <xodus>/target/release/xodus-cli.pre-fh6-named.bak
git -C <sources xodus> apply --check "$PWD/patches/xodus-cli/0001-macos-keep-decrypted-image-named-on-ramdisk.patch" \
  && git -C <sources xodus> apply "$PWD/patches/xodus-cli/0001-macos-keep-decrypted-image-named-on-ramdisk.patch"
(cd <sources xodus> && cargo build --release -p xodus-cli)

# 5. Sonde APRÈS : tout doit passer en "named"
python3 tools/check_runtime.py <racine Wine> | tee out-check-runtime-after.txt
python3 tools/mapfd_run.py --wine <ton binaire wine> --fd-kind named --log out/probe-after-named.txt

# 6. Le jeu, lancé comme d'habitude, avec un log ciblé
WINEDEBUG=+timestamp,+loaddll,warn+process,err+all <ta commande de lancement habituelle> 2>&1 | tee out/fh6-after.log
grep -E "cannot be reopened|xgameruntime|terminating itself abnormally" out/fh6-after.log
```

Si `git apply --check` refuse un patch, ton arbre diffère de la base indiquée dans l'en-tête du patch.
Ne force rien : envoie la sortie de `--check`.

Fichiers à me renvoyer : `out-check-runtime*.txt`, `out/probe-*.txt`, et les 200 premières et 200
dernières lignes de `out/fh6-after.log`. Aucun jeton ni identifiant n'y figure. Vérifie quand même avant
de partager.
