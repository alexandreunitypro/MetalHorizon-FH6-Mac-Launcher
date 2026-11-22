# Blackwell Engine the world best Forza Horizon engine

Blackwell Engine est le Wine de MetalHorizon : les sources CrossOver 26.3 publiées par CodeWeavers (LGPL), tous les
patches du projet, et ses propres bibliothèques x86_64. **Il n'utilise rien de CrossOver.app.** L'app MetalHorizon le
télécharge et l'installe toute seule ; ce dossier sert à le construire et à le vérifier.


## Deux variantes (1.1)

| | Xbox (`--variant xbox`, défaut) | Steam (`--variant steam`) |
|---|---|---|
| Série | [`series`](series) : 0001–0009 + 0012 | [`series-steam`](series-steam) : 0001–0013 |
| Architectures | x86_64 | i386 + x86_64 (Steam et son installeur sont 32 bits) |
| Compilateur PE | llvm-mingw | mingw-w64 gcc, comme Highball (« llvm-mingw casse la connexion Steam ») |
| Manettes | SDL2 + GameInput (0012) | idem |
| Fenêtre de Steam | — | DXMT, build de Highball (`renderers/dxmt`) |

```sh
brew install bison pkgconf cmake mingw-w64
bash engine/build.sh --variant xbox ~/BlackwellEngine-build
bash engine/build.sh --variant steam ~/BlackwellEngine-build-steam
bash engine/package.sh 1.1 ~/BlackwellEngine-build
bash engine/package.sh steam-1.1 ~/BlackwellEngine-build-steam
```
