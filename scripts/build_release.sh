#!/bin/zsh
# Release build of Scanline.app, checked and packaged for distribution.
#   scripts/build_release.sh [--clean]
# Env: APP_VERSION (default 1.0), APP_BUILD (default: commit count).
# Output in build/Release/: Scanline.app, Scanline.zip, Scanline.app.dSYM
set -euo pipefail
root=${0:A:h:h}
cd "$root"
[[ ${1:-} == --clean ]] && rm -rf .build build
export SCANLINE_VERSION=${APP_VERSION:-1.0}
export SCANLINE_BUILD=${APP_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
scripts/build-app.sh

out=build/Release
rm -rf "$out"; mkdir -p "$out"
ditto build/Scanline.app "$out/Scanline.app"

# Checks: the bundle is complete, versioned and validly (ad-hoc) signed.
app="$out/Scanline.app"
for f in Contents/MacOS/Scanline Contents/Resources/ScanlineHelper Contents/Resources/AppIcon.icns Contents/Info.plist; do
  [[ -e "$app/$f" ]] || { echo "missing $f" >&2; exit 1; }
done
[[ $(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist") == "$SCANLINE_VERSION" ]] || { echo "version mismatch" >&2; exit 1; }
lipo -archs "$app/Contents/MacOS/Scanline" | grep -q arm64 || { echo "not arm64" >&2; exit 1; }
codesign --verify --strict "$app/Contents/Resources/ScanlineHelper"
codesign --verify --strict "$app"

dsymutil "$app/Contents/MacOS/Scanline" -o "$out/Scanline.app.dSYM" 2>/dev/null || true
(cd "$out" && ditto -c -k --keepParent Scanline.app Scanline.zip)
echo "Scanline $SCANLINE_VERSION ($SCANLINE_BUILD) -> $out/Scanline.zip"
