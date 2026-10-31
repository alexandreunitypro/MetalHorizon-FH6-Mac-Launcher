#!/bin/bash
# Installs Steam into the game's Steam-only Wine prefix (MH_PREFIX), downloading Valve's own installer straight
# from steampowered.com. No account is needed to download it; signing in and installing the game are the user's
# own step in Steam's window, same as Microsoft sign-in is for the Xbox edition.
#   MH_ENGINE    Blackwell Engine (Steam variant: bin/wine, its own GnuTLS/FreeType/MoltenVK)
#   MH_PREFIX    the Steam-only prefix (<game>/.blackwell-wine-steam)
#   MH_DRY_RUN=1 print the environment and the command, start nothing
set -u
ENGINE="${MH_ENGINE:?}"; PREFIX="${MH_PREFIX:?}"
fail() { echo "STOP: $1"; exit 1; }
[ -x "$ENGINE/bin/wine" ] || fail "Blackwell Engine (Steam variant) is not installed ($ENGINE)"

# Not pinned by SHA-256 like the rest of MetalHorizon's downloads: Valve updates this installer on its own
# schedule, unlike the tarballs MetalHorizon builds and hosts itself.
SETUP="$HOME/Library/Application Support/MetalHorizon/Downloads/SteamSetup.exe"
export CX_ROOT="$ENGINE" WINEPREFIX="$PREFIX" WINEDEBUG="${MH_WINEDEBUG:--all}"
export DYLD_LIBRARY_PATH="$ENGINE/lib"

if [ -n "${MH_DRY_RUN:-}" ]; then
    export -p | sed -n 's/^declare -x //p' | grep -E '^(CX_|WINE|DYLD_)' | sort
    echo "run: curl -fL -o $SETUP https://cdn.steampowered.com/download/SteamSetup.exe && $ENGINE/bin/wine $SETUP"
    exit 0
fi

mkdir -p "$PREFIX" "$(dirname "$SETUP")"
echo "== downloading Steam's own installer from steampowered.com"
curl -fL --retry 3 -o "$SETUP.part" "https://cdn.steampowered.com/download/SteamSetup.exe" && mv "$SETUP.part" "$SETUP" \
    || fail "could not download Steam's installer"
echo "== starting Steam's own installer. Click through it, then sign in. Steam itself downloads Forza Horizon 6 if you own it."
"$ENGINE/bin/wine" "$SETUP"
echo "== Steam's installer window closed"
