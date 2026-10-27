#!/bin/bash
# Lance Forza Horizon 6 le plus vite possible : sans journal, sans traces, sans verifications, sans reseau (pas de git pull).
#   bash ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT/tools/jouer.sh
# Ferme le jeu par son menu, puis attends environ 30 s (envoi de la sauvegarde cloud). Pas de Ctrl+C.
# Diagnostic (journaux, rapport) : tools/mac_all.sh ou tools/mac_launch_fh6.sh sans FH6_QUICK.
# Il faut avoir ouvert MetalHorizon une fois : l'app installe Blackwell Engine et D3DMetal.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pkill -f xodus-cli 2>/dev/null; sleep 1       # reste d'un lancement precedent ; le lanceur arrete ensuite SON wineserver
export FH6_QUICK=1   # Blackwell Engine + D3DMetal 4 installed by MetalHorizon, no CrossOver.app
exec bash "$REPO/tools/mac_launch_fh6.sh"
