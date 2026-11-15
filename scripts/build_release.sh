#!/bin/zsh
# Release build of Scanline.app, checked and packaged for distribution.
#   scripts/build_release.sh [--clean] [--notarize]
# Env: APP_VERSION (set: a release build, e.g. 1.0.7; unset: a dev build versioned from the
#      latest v* tag), APP_BUILD (default: commit count), NOTARIZE=1 (same as --notarize),
#      SCANLINE_SIGN_IDENTITY (see scripts/signing.sh; "-" forces ad-hoc).
# Signing: Developer ID when an identity is available, otherwise ad-hoc. --notarize needs
# Developer ID and notarytool credentials (see scripts/notarize.sh).
# Output in build/Release/: Scanline.app, Scanline.zip, Scanline.app.dSYM (and NOTARIZED)
set -euo pipefail
root=${0:A:h:h}
cd "$root"
clean=0; notarize=${NOTARIZE:-0}
for arg in "$@"; do
  case $arg in
    --clean) clean=1 ;;
    --notarize) notarize=1 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done
source scripts/signing.sh
identity=$(resolve_identity)
if [[ $notarize == 1 ]] && ! is_developer_id "$identity"; then
  echo "--notarize needs a Developer ID identity; none found (or SCANLINE_SIGN_IDENTITY=-)" >&2
  exit 1
fi
export SCANLINE_SIGN_IDENTITY=$identity   # build-app.sh signs with exactly this one
if (( clean )); then rm -rf .build build; fi
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
codesign --verify --strict --deep "$app"
if is_developer_id "$identity"; then
  # Both binaries: hardened runtime, secure timestamp, a team; the helper has no entitlements.
  for bin in "$app" "$app/Contents/Resources/ScanlineHelper"; do
    info=$(codesign -dvv "$bin" 2>&1)
    [[ $info == *"flags="*"runtime"* ]] || { echo "$bin: no hardened runtime" >&2; exit 1; }
    [[ $info == *"Timestamp="* ]] || { echo "$bin: no secure timestamp" >&2; exit 1; }
    [[ $info == *"TeamIdentifier="* && $info != *"TeamIdentifier=not set"* ]] || { echo "$bin: no team" >&2; exit 1; }
  done
  [[ $(codesign -dvv "$app/Contents/Resources/ScanlineHelper" 2>&1) == *"Identifier=local.scanline.helper"* ]] \
    || { echo "helper identifier unexpected" >&2; exit 1; }
  [[ -z $(codesign -d --xml --entitlements - "$app/Contents/Resources/ScanlineHelper" 2>/dev/null | grep -i '<key>') ]] \
    || { echo "helper has entitlements" >&2; exit 1; }
fi

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
# Notarize and staple before zipping: a zip can't be stapled, the ticket goes into the app.
signing=$(is_developer_id "$identity" && echo "Developer ID" || echo "ad-hoc")
if [[ $notarize == 1 ]]; then
  scripts/notarize.sh "$app"
  signing="$signing, notarized"
fi
(cd "$out" && ditto -c -k --keepParent Scanline.app Scanline.zip)
echo "Scanline $stamped ($SCANLINE_BUILD, $kind, $signing) -> $out/Scanline.zip"
