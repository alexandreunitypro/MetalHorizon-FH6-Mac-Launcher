> **Ce tutoriel date du début du travail et est en partie dépassé.** L'état actuel, les commandes à jour et la
> chronologie complète sont dans [`PASSATION-IA.md`](PASSATION-IA.md).

# Tutoriel : tester le correctif sur ton Mac, étape par étape

Ce guide part de zéro. Chaque étape dit **quoi taper**, **ce que ça fait** et **ce que tu dois voir**.
Fais les étapes dans l'ordre et ne saute rien.

Durée : environ 10 minutes pour les étapes 1 à 4, sans le jeu. Il faut compter plus pour les étapes 5 à 7,
qui recompilent.

---

## L'idée en une image

```
   Disque                          Mémoire (disque RAM de xodus)
 ┌──────────────────────┐        ┌──────────────────────────┐
 │ forzahorizon6.exe    │        │ forzahorizon6.exe        │
 │ (CHIFFRÉ, illisible) │        │ (DÉCHIFFRÉ, le vrai)     │
 └──────────────────────┘        └──────────────────────────┘
                                          ▲  ▲  ▲
               le jeu le relit 3 fois ────┘  │  │
                                             │  │
   Problème sur macOS : les 3 lectures partagent UN SEUL marque-page.
   Lecture 1 : lit tout, le marque-page arrive à la FIN.
   Lecture 2 : part de la fin → lit 0 octet → empreinte fausse → le jeu se ferme.
```

Le correctif donne **un marque-page par lecture**, comme sous Windows.

On va d'abord **vérifier** que ce problème existe chez toi (étapes 1 à 4). On ne corrigera que si c'est
le cas (étapes 5 à 7).

---

## Étape 0 : ouvrir le Terminal

1. Appuie sur `Cmd + Espace`.
2. Tape `Terminal`, puis appuie sur Entrée.

Une fenêtre avec du texte s'ouvre. C'est là que tu colles toutes les commandes de ce guide.
Pour coller : `Cmd + V`, puis Entrée.

---

## Étape 1 : récupérer les fichiers du dépôt

Va dans le dossier du projet. Remplace `~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT` par l'endroit où tu
l'as cloné.

```sh
cd ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT
git fetch origin
git checkout claude/clever-fermat-0kxfc1
git pull
```

**Ce que ça fait :** télécharge les nouveaux fichiers (patches, outils de test).

**Ce que tu dois voir :** la commande suivante doit afficher le dossier `tools`, avec trois éléments dedans.

```sh
ls tools
```

Résultat attendu :

```
check_runtime.py   mapfd_run.py   selfread
```

Vérifie aussi que Python est là :

```sh
python3 --version
```

Tu dois voir `Python 3.x.x`. Si macOS propose d'installer les « outils de ligne de commande », accepte,
puis recommence.

Crée enfin un dossier pour les résultats :

```sh
mkdir -p out
```

---

## Étape 2 : trouver ton Wine

Il faut savoir **où est ton Wine**. Il y a deux choses à trouver.

### 2a. Le programme `wine`

```sh
find ~ /Applications /opt /usr/local -type f \( -name wine -o -name wine64 \) -perm +111 2>/dev/null
```

**Ce que ça fait :** cherche les programmes qui s'appellent `wine` ou `wine64`.

Tu verras une ou plusieurs lignes, par exemple :

```
/Users/toi/blackwell/wine-install/bin/wine
```

Prends **celui que tu utilises pour lancer Forza**. Range-le dans une variable, pour ne plus le retaper :

```sh
export MYWINE="/Users/toi/blackwell/wine-install/bin/wine"
```

(remplace par ton vrai chemin)

Test :

```sh
"$MYWINE" --version
```

Tu dois voir quelque chose comme `wine-11.0`.

### 2b. Le dossier racine de ce Wine

C'est le dossier qui contient `lib/wine`. En général, c'est le dossier **au-dessus** de `bin` :

```sh
export MYWINEROOT="$(dirname "$(dirname "$MYWINE")")"
ls "$MYWINEROOT/lib/wine"
```

Tu dois voir `x86_64-unix` et `x86_64-windows` dans la liste.

**Si tu ne les vois pas**, cherche-les directement :

```sh
find ~ /Applications /opt -type d -name x86_64-unix -path "*lib/wine*" 2>/dev/null
```

Le résultat ressemble à `/chemin/QUELQUECHOSE/lib/wine/x86_64-unix`. Ta racine est
`/chemin/QUELQUECHOSE` :

```sh
export MYWINEROOT="/chemin/QUELQUECHOSE"
```

---

## Étape 3 : l'inventaire (quels patches ton Wine contient vraiment)

```sh
python3 tools/check_runtime.py "$MYWINEROOT" | tee out/check-runtime-before.txt
```

**Ce que ça fait :** ouvre ton `ntdll.so`, ton `ntdll.dll` et ta `concrt140.dll`, et cherche des phrases qui
n'existent que si un patch précis a été compilé dedans. Le script ne modifie rien.

**Ce que tu vas voir :** une liste de lignes `[yes]` ou `[no]`, puis des empreintes `sha256`.

### Comment lire le résultat

| Ligne | Si `yes` | Si `no` |
|---|---|---|
| `loader.memfd-main-image` | ton Wine sait charger l'exe déchiffré | gros problème de base : le jeu ne peut pas démarrer |
| `serve-image-through-file-api (Ferestre 0009)` | le jeu relit bien le vrai exe | le jeu relit l'exe **chiffré** → arrêt certain |
| `mapped-filename from PEB (Ferestre 0010)` | le jeu connaît le nom de son exe | le jeu reçoit un nom vide → arrêt |
| `GlobalRoot form of the image name (Ferestre 0013)` | la forme `\\?\GLOBALROOT\…` est reconnue | relit le fichier chiffré → arrêt |
| `reopen via /proc (Ferestre 0009)` | normal, mais **inutile sur Mac** | — |
| `reopen via F_GETPATH (this repo)` | mon correctif est déjà installé | normal pour l'instant |
| `generic GlobalRoot strip (Proton)` | les autres fichiers en GLOBALROOT marchent | à noter, pas bloquant pour l'exe |

**Important :** si une des lignes 0009, 0010 ou 0013 est à `no`, **arrête-toi ici** et envoie-moi
`out/check-runtime-before.txt`. Le problème est alors plus en amont que mon correctif.

Les lignes `sha256` remplacent les empreintes partielles (`9028b263…`, `f9aff5d6…`) de tes anciens
essais. On saura enfin exactement quels fichiers sont installés.

---

## Étape 4 : le test sans le jeu (AVANT correctif)

```sh
python3 tools/mapfd_run.py --wine "$MYWINE" --fd-kind unlinked --log out/probe-before-unlinked.txt
```

**Ce que ça fait, pas à pas :**

1. crée un dossier temporaire avec un faux `selfread.exe` **rempli de bruit**, comme ton exe chiffré ;
2. met le **vrai** `selfread.exe` dans un fichier caché, comme xodus avec l'exe déchiffré ;
3. lance Wine exactement comme xodus lance Forza ;
4. le programme de test relit son propre exe 3 fois, comme Forza ;
5. il affiche `PASS` (réussi) ou `FAIL` (raté) pour chaque vérification.

Il utilise un **préfixe Wine jetable** et ne touche **jamais** ton préfixe de jeu. Le premier lancement
peut prendre 30 à 60 secondes, le temps de créer ce préfixe.

### Ce que tu vas probablement voir (le problème existe)

```
PASS mapped-filename          ...
PASS globalroot-read-1        err 0 bytes 310265 head 4d5a ...
FAIL globalroot-read-2        err 0 bytes 0 head 0000 ...      ← 0 octet lu !
FAIL globalroot-read-3        err 0 bytes 0 head 0000 ...      ← 0 octet lu !
FAIL independent-offsets      ...
FAIL plain-path-read          ...
...
RESULT 4 failure(s)
```

C'est **exactement** le bug : la lecture 1 lit 310 265 octets, les lectures 2 et 3 lisent 0 octet.
→ Passe à l'étape 5.

### Les autres cas possibles

| Ce que tu vois | Ce que ça veut dire | Quoi faire |
|---|---|---|
| `RESULT 0 failure(s)` | ce bug n'existe **pas** chez toi | ne pas appliquer le correctif, m'envoyer le fichier `out/` |
| `FAIL mapped-filename` | il manque Ferestre 0010 | m'envoyer les fichiers |
| `FAIL globalroot-read-1` | il manque Ferestre 0009 ou 0013 | m'envoyer les fichiers |
| aucune ligne `selfread probe 1` | Wine n'a pas pu lancer le test | m'envoyer `out/probe-before-unlinked.txt` |

### Les 3 lignes `trap-…` (la question des SIGILL)

```
PASS trap-ud2    code c000001d ...
PASS trap-hlt    code c0000096 ...
PASS trap-int3   code 80000003 ...
INFO trap-ud2    2000 traps in ... ms (... us each)
```

Elles vérifient que Wine + Rosetta livrent correctement au programme les instructions « piégées », comme
celles de Forza. Si les trois sont `PASS`, les SIGILL ne sont pas le problème. Note le nombre `us each` :
c'est le coût d'un piège chez toi.

---

## Étape 5 : appliquer le correctif Wine

Il faut le **dossier des sources** de ton Wine et son **dossier de compilation** (build).

### 5a. Trouver les sources

```sh
find ~ -type f -path "*dlls/ntdll/unix/loader.c" 2>/dev/null
```

Le résultat ressemble à `/Users/toi/blackwell/wine-src/dlls/ntdll/unix/loader.c`. Les sources sont le début
du chemin :

```sh
export WINESRC="/Users/toi/blackwell/wine-src"
```

### 5b. Trouver le dossier de compilation

```sh
find ~ -type f -path "*dlls/ntdll/ntdll.so" -not -path "*/lib/wine/*" 2>/dev/null
```

Le résultat ressemble à `/Users/toi/blackwell/wine-build/dlls/ntdll/ntdll.so` :

```sh
export WINEBUILD="/Users/toi/blackwell/wine-build"
```

(si tu compiles dans le dossier des sources, c'est le même chemin que `WINESRC`)

### 5c. Sauvegarder (pour pouvoir revenir en arrière)

```sh
cp "$MYWINEROOT/lib/wine/x86_64-unix/ntdll.so" "$MYWINEROOT/lib/wine/x86_64-unix/ntdll.so.pre-fh6-reopen.bak"
ls -la "$MYWINEROOT/lib/wine/x86_64-unix/" | grep ntdll
```

Tu dois voir **deux** fichiers : `ntdll.so` et `ntdll.so.pre-fh6-reopen.bak`.

### 5d. Vérifier que le patch s'applique, sans rien changer

```sh
git -C "$WINESRC" apply --check "$PWD/patches/wine/0001-ntdll-macos-reopen-mapped-image-by-path.patch" && echo "OK, le patch peut s'appliquer"
```

- Tu vois `OK, le patch peut s'appliquer` → continue.
- Tu vois `error: patch failed` → **arrête-toi**. Ton arbre Wine est différent de celui de Ferestre.
  Copie-moi le message d'erreur complet. Ne force rien.

### 5e. Appliquer et recompiler **seulement** ntdll

```sh
git -C "$WINESRC" apply "$PWD/patches/wine/0001-ntdll-macos-reopen-mapped-image-by-path.patch"
make -C "$WINEBUILD" dlls/ntdll/ntdll.so
```

La fin doit se passer **sans** ligne `error:`. Les lignes `warning:` ne sont pas graves.

### 5f. Installer le nouveau ntdll

```sh
cp "$WINEBUILD/dlls/ntdll/ntdll.so" "$MYWINEROOT/lib/wine/x86_64-unix/ntdll.so"
python3 tools/check_runtime.py "$MYWINEROOT" | grep -A1 "F_GETPATH"
```

Tu dois voir `[yes] reopen via F_GETPATH`. Ça prouve que le correctif est **dans** le fichier installé, pas
seulement compilé.

---

## Étape 6 : appliquer le correctif xodus

Le correctif Wine ne suffit pas seul : xodus doit **garder le nom** du fichier déchiffré. Sinon, Wine n'a
rien à rouvrir.

### 6a. Trouver xodus

```sh
find ~ -type f -path "*crates/xodus-cli/src/commands/run.rs" 2>/dev/null
```

Le résultat ressemble à `/Users/toi/xodus/crates/xodus-cli/src/commands/run.rs` :

```sh
export XODUSSRC="/Users/toi/xodus"
```

### 6b. Sauvegarder le programme actuel

```sh
cp "$XODUSSRC/target/release/xodus-cli" "$XODUSSRC/target/release/xodus-cli.pre-fh6-named.bak"
```

(si le fichier n'est pas là, cherche-le : `find "$XODUSSRC/target" -name xodus-cli -type f`)

### 6c. Vérifier, appliquer, recompiler

```sh
git -C "$XODUSSRC" apply --check "$PWD/patches/xodus-cli/0001-macos-keep-decrypted-image-named-on-ramdisk.patch" && echo "OK, le patch peut s'appliquer"
```

Même règle qu'en 5d : si tu vois une erreur, tu t'arrêtes et tu me l'envoies.

```sh
git -C "$XODUSSRC" apply "$PWD/patches/xodus-cli/0001-macos-keep-decrypted-image-named-on-ramdisk.patch"
(cd "$XODUSSRC" && cargo build --release -p xodus-cli)
```

La fin doit afficher `Finished`.

---

## Étape 7 : refaire le test, puis lancer le jeu

### 7a. Le test sans le jeu (APRÈS correctif)

On utilise maintenant `--fd-kind named`, c'est-à-dire un fichier qui garde son nom, comme le xodus corrigé :

```sh
python3 tools/mapfd_run.py --wine "$MYWINE" --fd-kind named --log out/probe-after-named.txt
```

**Ce que tu dois voir :**

```
PASS globalroot-read-1   bytes 310265 ...
PASS globalroot-read-2   bytes 310265 ...   ← maintenant tout est lu
PASS globalroot-read-3   bytes 310265 ...
PASS independent-offsets ...
...
RESULT 0 failure(s)
```

Si c'est encore `FAIL`, ne lance pas le jeu. Envoie-moi `out/probe-after-named.txt`.

### 7b. Le jeu

Lance Forza **comme d'habitude**, en ajoutant au début de ta commande les réglages de log ci-dessous :

```sh
WINEDEBUG=+timestamp,+loaddll,warn+process,err+all  <ta commande habituelle>  2>&1 | tee out/fh6-after.log
```

**Ce que les réglages font :**
- `+loaddll` : écrit chaque DLL chargée. On veut voir `xgameruntime.dll` apparaître ;
- `warn+process` : écrit le code de sortie si le jeu se ferme tout seul ;
- `err+all` : affiche les erreurs, dont ma ligne `cannot be reopened` si le correctif ne s'active pas.

Ensuite, cherche les trois indices :

```sh
grep -E "cannot be reopened|xgameruntime|terminating itself abnormally" out/fh6-after.log
```

| Ce que tu trouves | Ce que ça veut dire |
|---|---|
| une ligne avec `xgameruntime.dll` | **le jeu a passé le contrôle** : le blocage d'origine est franchi |
| `cannot be reopened` | le correctif Wine est là, mais xodus n'a pas gardé le nom (étape 6 ratée) |
| `terminating itself abnormally, exit code …` | le jeu s'est encore arrêté lui-même. Note le code |
| rien du tout | envoie-moi le log, on regardera la fin |

---

## Revenir en arrière (si besoin)

Ces commandes remettent tout comme avant :

```sh
cp "$MYWINEROOT/lib/wine/x86_64-unix/ntdll.so.pre-fh6-reopen.bak" "$MYWINEROOT/lib/wine/x86_64-unix/ntdll.so"
cp "$XODUSSRC/target/release/xodus-cli.pre-fh6-named.bak" "$XODUSSRC/target/release/xodus-cli"
git -C "$WINESRC" apply -R "$PWD/patches/wine/0001-ntdll-macos-reopen-mapped-image-by-path.patch"
git -C "$XODUSSRC" apply -R "$PWD/patches/xodus-cli/0001-macos-keep-decrypted-image-named-on-ramdisk.patch"
```

---

## Ce qu'il faut m'envoyer

Envoie-moi tout le dossier `out/` :

- `out/check-runtime-before.txt` (et `-after` si tu l'as fait)
- `out/probe-before-unlinked.txt`
- `out/probe-after-named.txt`
- le début et la fin de `out/fh6-after.log` :

```sh
head -200 out/fh6-after.log > out/fh6-debut.txt
tail -200 out/fh6-after.log > out/fh6-fin.txt
```

Ces fichiers ne contiennent ni mot de passe ni jeton. Jette quand même un œil rapide avant de les partager.
Si tu vois une longue suite de lettres qui ressemble à une clé, efface-la.

**Le plus important à me dire en une phrase :** à l'étape 4, les lectures 2 et 3 affichaient-elles
`bytes 0` ?
