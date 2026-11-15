#!/bin/zsh
# Builds the release app, installs it to /Applications and keeps ~/Desktop/Scanline pointing there.
set -euo pipefail
root=${0:A:h:h}
git -C "$root" fetch --tags --quiet 2>/dev/null || true   # dev builds take their version from the latest tag
"$root/scripts/build_release.sh"
osascript -e 'quit app "Scanline"' 2>/dev/null || true
sleep 1
# Replace, never merge: ditto over an old copy keeps files the new build no longer has,
# which breaks the signature seal.
rm -rf /Applications/Scanline.app
ditto "$root/build/Release/Scanline.app" /Applications/Scanline.app
alias_ok=$(osascript -e 'tell application "Finder" to try
  return POSIX path of (original item of alias file "Scanline" of (path to desktop folder) as alias)
end try' 2>/dev/null || true)
if [[ "$alias_ok" != "/Applications/Scanline.app/" ]]; then
  rm -f ~/Desktop/Scanline
  osascript -e 'tell application "Finder" to set a to make new alias file at (path to desktop folder) to (POSIX file "/Applications/Scanline.app")' \
            -e 'tell application "Finder" to set name of a to "Scanline"' >/dev/null
fi
echo "Installed /Applications/Scanline.app (Desktop alias: Scanline)"
open /Applications/Scanline.app
