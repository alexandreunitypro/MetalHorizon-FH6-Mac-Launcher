#!/bin/bash
# Read-only. Which D3DMetal versions are on this Mac, and is there a complete, matching D3DMetal 4 set
# (PE d3d12.dll + unix d3d12.so + D3DMetal.framework)? Highball needs D3DMetal 4 for FH6; CrossOver's
# is 3.0 and reports shader model 6.6 at most.
ENGINE="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine"
G4="/Users/alexandre/.codex/visualizations/2026/10/19/01a1562c-64fc-74c0-9f71-acf814cbaad7/Blackwell FH6 Final.app/Contents/Resources/GPTK4"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk"
ver() { defaults read "$1/D3DMetal.framework/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?"; }
echo "== D3DMetal.framework versions"
for d in "$G4/external" "$CX/external" "$ENGINE/lib64/apple_gptk/external"; do [ -d "$d" ] && echo "  $(ver "$d")  $d"; done
find /Applications "$HOME/Applications" "$HOME/Library/Application Support" "$HOME/.codex" -maxdepth 8 -name "D3DMetal.framework" -type d 2>/dev/null | while read -r f; do
    echo "  $(defaults read "$f/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null)  $f"; done | sort -u | head -12
echo "== GPTK4 folder"
(cd "$G4" 2>/dev/null && find . -maxdepth 4 \( -name "*.dll" -o -name "*.so" -o -name "*.dylib" -o -name "*.framework" \) | head -30)
echo "== d3d12 halves (sha256, first 12)"
for f in "$ENGINE/lib64/apple_gptk/wine/x86_64-windows/d3d12.dll" "$ENGINE/lib64/apple_gptk/wine/x86_64-unix/d3d12.so" \
         "$CX/wine/x86_64-windows/d3d12.dll" "$CX/wine/x86_64-unix/d3d12.so" \
         $(find "$G4" -name "d3d12.dll" -o -name "d3d12.so" 2>/dev/null); do
    [ -f "$f" ] && echo "  $(shasum -a 256 "$f" | cut -c1-12)  $(stat -f %Sm -t %Y-%m-%d "$f")  ${f#/Users/alexandre/}"
done
echo "== Highball installed?"
ls -d /Applications/Highball.app "$HOME/Applications/Highball.app" 2>/dev/null || echo "  no"
