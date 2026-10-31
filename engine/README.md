# Blackwell Engine

Blackwell Engine est le Wine de MetalHorizon : les sources CrossOver 26.3 publiées par CodeWeavers (LGPL), tous les
patches du projet, et ses propres bibliothèques x86_64. **Il n'utilise rien de CrossOver.app.** L'app MetalHorizon le
télécharge et l'installe toute seule ; ce dossier sert à le construire et à le vérifier.

## La chaîne complète, sans CrossOver

| Pièce | D'où elle vient | Comment l'utilisateur l'obtient |
|---|---|---|
| Wine (Blackwell Engine) | Sources CrossOver 26.3 + [`series`](series) | Téléchargé par l'app (release GitHub) |
| GnuTLS, GMP, FreeType, MoltenVK (x86_64) | Sources officielles, [`build-deps.sh`](build-deps.sh) | Dans Blackwell Engine (`lib/`) |
| Shim DirectX 12 de Highball | [`tools/tsshim`](../tools/tsshim/), compilé par [`package.sh`](package.sh) | Dans Blackwell Engine (`renderers/tsshim`) |
| D3DMetal 4 + les moitiés d3d12/dxgi de Wine | Le dossier `redist/lib` du Game Porting Toolkit 4 d'Apple, intact | Téléchargé par l'app **après acceptation de la licence d'Apple** |
| xodus (connexion Xbox, téléchargement, licence) | [xodus](https://github.com/xodus-gaming/xodus) + nos patches | Dans l'app |

La licence d'Apple (sections 2A(iii) et 2C) permet de distribuer séparément le Framework et les Redistributables,
à des fins non commerciales et avec leurs mentions. MetalHorizon est gratuit, et l'app affiche `License.rtf` avant
d'installer quoi que ce soit.

## Ce qui remplaçait CrossOver, et pourquoi ça marche maintenant

- **Le pont d3d12** : on croyait que celui du Game Porting Toolkit 4 « ne marchait pas avec ce Wine » (appel à
  l'adresse 0 dans `WineMonitor::Init`). En réalité, dans le kit d'Apple, `d3d12.so`, `dxgi.so`, `d3d12core.so`… sont
  tous des **liens** vers une seule bibliothèque, `libd3dshared.dylib`. Le moteur en contenait des **copies** : macOS
  chargeait alors plusieurs exemplaires séparés, et un seul recevait la table de fonctions de Wine
  (`Win32DispatchInit`). Avec les liens, `D3D12CreateDevice` réussit, avec ou sans le shim, et sans aucun fichier de
  CrossOver (vérifié le 26 octobre 2026 avec `tools/d3d12probe`).
- **Le shim** : il charge le vrai `d3d12.dll` d'Apple sous le nom `apd12.dll`. Wine reconnaît ses DLL intégrées
  par leur nom d'export : la copie doit donc dire `apd12.dll` à l'intérieur. Comme Highball, l'app fait cette copie
  et ce renommage **sur le Mac de l'utilisateur** (`app/Sources/MetalHorizon/PEFile.swift`) : aucun fichier d'Apple
  modifié n'est distribué. `apd12.so` est un lien vers `d3d12.so`, pour rester la même bibliothèque.
- **GnuTLS, FreeType, MoltenVK** : construits ici en x86_64 et rangés dans `lib/` du moteur, avec des chemins
  `@loader_path`. GnuTLS embarque Nettle et ne dépend que de GMP, comme celle de CrossOver.

## Fichiers

| Fichier | Rôle |
|---|---|
| [`inputs.json`](inputs.json) | Sources épinglées par SHA-256 : CrossOver 26.3.0, llvm-mingw 20260908, GMP, Nettle, GnuTLS, FreeType, MoltenVK |
| [`series`](series), [`patches/`](patches/) | Les 9 patches, générés depuis l'arbre du moteur qui fait tourner le jeu |
| [`make-series.py`](make-series.py) | Régénère `patches/` depuis l'arbre de travail ; s'arrête si un fichier modifié n'a pas de groupe |
| [`verify-series.sh`](verify-series.sh) | Prouve que source + série = l'arbre de travail (11 145 fichiers identiques) |
| [`build-deps.sh`](build-deps.sh) | Construit GMP, Nettle, GnuTLS, FreeType en x86_64 et prend MoltenVK |
| [`build.sh`](build.sh) | Construit Blackwell Engine dans `~/BlackwellEngine-build/out/engine` |
| [`package.sh`](package.sh) | Ajoute le shim, refuse tout fichier d'Apple ou de CrossOver, produit `blackwell-engine-<version>.tar.xz` |
| [`package-d3dmetal.sh`](package-d3dmetal.sh) | Emballe le `redist/lib` d'Apple tel quel, avec sa licence : `d3dmetal-<version>-redist.tar.xz` |

## Construire une version

```sh
brew install bison pkgconf
bash engine/build.sh
bash engine/package.sh 1.0
bash engine/package-d3dmetal.sh "Evaluation environment for Windows games 4.0 beta 3.dmg"
bash app/update-components.sh blackwell-engine-1.0 ~/BlackwellEngine-build/blackwell-engine-1.0.tar.xz ~/BlackwellEngine-build/d3dmetal-4.0b3-redist.tar.xz
```

Les deux tarballs vont dans la release GitHub `blackwell-engine-1.0`, puis `app/build-app.sh` construit l'app qui
les connaît.

## Variante Steam (expérimentale)

MetalHorizon joue aussi l'édition **Steam** de Forza Horizon 6, avec un second moteur : les 9 patches ci-dessus,
plus deux patches de Highball copiés tels quels ([`patches/ORIGIN-steam.md`](patches/ORIGIN-steam.md),
LGPL-2.1-or-later) pour qu'une fenêtre de lanceur (celle de Steam) s'affiche au lieu de rester noire. Vérifiés
sans conflit sur l'arbre de travail, mais **pas vérifiés en jeu** : ce projet n'a pas de copie Steam de FH6.

```sh
bash engine/build.sh --series series-steam ~/BlackwellEngine-build-steam
bash engine/package.sh steam-1.0 ~/BlackwellEngine-build-steam
```

Produit `blackwell-engine-steam-<version>.tar.xz`, publié à côté de `blackwell-engine-<version>.tar.xz` dans la
même release GitHub. L'app choisit ce moteur toute seule quand le dossier du jeu a l'air d'une installation
Steam (`steam_appid.txt` ou `steam_api64.dll`), et lance le jeu via Steam lui-même (`steam.exe -applaunch`),
pour que le client Steam tourne dans le même préfixe (sans ça, Highball note que le jeu se referme après ~12 s).

## Encore à faire

- **Highball 0025** (« fermer des E/S asynchrones ne plante plus ») n'est appliqué qu'à moitié dans l'arbre de
  travail. Il est dans `series` en commentaire, à activer après un essai en jeu.
- Les patches 0004, 0005 et 0009 contiennent des **diagnostics** (FHTRACE, `fh6fault`, pile `+seh`, texte des boîtes).
  Attention au 0005 : la protection du jeu réagit aux changements dans le chemin d'exception de `ntdll.dll`.
- Les **shaders de remplacement** (traces de pneus, 8 pipelines) se construisent à partir des shaders du jeu
  (`tools/mac_shader_fixes.sh`) et ne sont pas distribués.
- Une **CI** GitHub Actions qui refait `build.sh` et `package.sh` à chaque version.
