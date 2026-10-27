#!/bin/bash
# FH6 quits with "Installation path is too long", and xodus resolves symlinks, so a symlink to the game
# folder is not enough. Rename the game folder to ~/FH6 (same disk: a rename, nothing is copied) and
# leave a symlink at the old place, so every existing script and path keeps working.
# Undo: tools/mac_move_short.sh --undo
OLD="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/audit/gamefarm-audit"
NEW="$HOME/FH6"
if pgrep -f "xodus-cli|wineserver" >/dev/null; then echo "STOP: the game or Wine is still running (pkill -f xodus-cli; pkill -f wineserver)"; exit 1; fi
if [ "${1:-}" = "--undo" ]; then
    [ -L "$OLD" ] && [ -d "$NEW" ] && [ ! -L "$NEW" ] || { echo "STOP: nothing to undo"; exit 1; }
    rm "$OLD" && mv "$NEW" "$OLD" && echo "game folder back at $OLD"; exit 0
fi
if [ -d "$NEW" ] && [ ! -L "$NEW" ] && [ -L "$OLD" ]; then echo "already moved: $NEW"; exit 0; fi
[ -L "$NEW" ] && rm "$NEW"                     # the earlier ~/FH6 symlink
[ -e "$NEW" ] && { echo "STOP: $NEW exists"; exit 1; }
[ -d "$OLD" ] && [ ! -L "$OLD" ] || { echo "STOP: $OLD is not a folder"; exit 1; }
[ "$(stat -f %d "$OLD")" = "$(stat -f %d "$HOME")" ] || { echo "STOP: not on the same disk, a move would copy the whole game"; exit 1; }
mv "$OLD" "$NEW" && ln -s "$NEW" "$OLD" && echo "moved: $NEW (old path is now a symlink to it)"
ls -ld "$OLD" "$NEW"
