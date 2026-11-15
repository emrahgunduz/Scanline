#!/bin/zsh
# Release build of Scanline.app, checked and packaged for distribution.
#   scripts/build_release.sh [--clean]
# Env: APP_VERSION (set: a release build, e.g. 1.0.7; unset: a dev build versioned from the
#      latest v* tag), APP_BUILD (default: commit count).
# Output in build/Release/: Scanline.app, Scanline.zip, Scanline.app.dSYM
set -euo pipefail
root=${0:A:h:h}
cd "$root"
[[ ${1:-} == --clean ]] && rm -rf .build build
if [[ -n ${APP_VERSION:-} ]]; then export SCANLINE_VERSION=$APP_VERSION; else unset SCANLINE_VERSION; fi
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
plist="$app/Contents/Info.plist"
stamped=$(plutil -extract CFBundleShortVersionString raw "$plist")
kind=$(plutil -extract ScanlineBuildKind raw "$plist")
if [[ -n ${APP_VERSION:-} ]]; then
  [[ $stamped == "$APP_VERSION" && $kind == release ]] || { echo "version/kind mismatch: $stamped $kind" >&2; exit 1; }
else
  [[ $stamped =~ '^[0-9]+(\.[0-9]+){0,3}$' && $kind == dev ]] || { echo "dev version/kind unexpected: $stamped $kind" >&2; exit 1; }
fi
lipo -archs "$app/Contents/MacOS/Scanline" | grep -q arm64 || { echo "not arm64" >&2; exit 1; }
codesign --verify --strict "$app/Contents/Resources/ScanlineHelper"
codesign --verify --strict "$app"

# The helper links only the USB layer, so app-only changes don't change its bytes.
helper="$app/Contents/Resources/ScanlineHelper"
if otool -L "$helper" | grep -qE 'Vision|ImageIO|CoreGraphics'; then
  echo "helper links image frameworks" >&2; exit 1
fi
# Smoke test without a scanner: no argument -> usage (64); hello then close over stdio.
rc=0; "$helper" >/dev/null 2>&1 || rc=$?
[[ $rc == 64 ]] || { echo "helper without --stdio exited $rc, expected 64" >&2; exit 1; }
reply=$(printf '\x04\x03' | "$helper" --stdio 2>/dev/null | xxd -p | tr -d '\n')
[[ $reply == 0004000000????????0000000000 ]] || { echo "helper hello/close reply unexpected: $reply" >&2; exit 1; }

dsymutil "$app/Contents/MacOS/Scanline" -o "$out/Scanline.app.dSYM" 2>/dev/null || true
(cd "$out" && ditto -c -k --keepParent Scanline.app Scanline.zip)
echo "Scanline $stamped ($SCANLINE_BUILD, $kind) -> $out/Scanline.zip"
