#!/bin/zsh
# Builds build/Scanline.app (release, ad-hoc signed; no Apple Developer account needed).
# The privileged helper ships inside the app and is installed from the app on first use.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
swift build -c release --product Scanline
swift build -c release --product ScanlineHelper
bin=$(swift build -c release --show-bin-path)
[[ -f Resources/AppIcon.icns ]] || swift tools/icon/make-icon.swift Resources/AppIcon.icns

# Release builds (release.yml) set SCANLINE_VERSION; anything else is a dev build, versioned
# from the latest v* tag. Dev builds never check for updates on their own.
if [[ -n ${SCANLINE_VERSION:-} ]]; then
  version=$SCANLINE_VERSION
  kind=release
  describe=v$version
else
  tag=$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || echo v0.0.0)
  version=${tag#v}
  kind=dev
  describe=$(git describe --tags --match 'v[0-9]*' --dirty --always 2>/dev/null || echo unknown)
fi
build=${SCANLINE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
app="$root/build/Scanline.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Scanline" "$app/Contents/MacOS/Scanline"
cp "$bin/ScanlineHelper" "$app/Contents/Resources/ScanlineHelper"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Scanline</string>
  <key>CFBundleDisplayName</key><string>Scanline</string>
  <key>CFBundleIdentifier</key><string>local.scanline.app</string>
  <key>CFBundleExecutable</key><string>Scanline</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>ScanlineBuildKind</key><string>$kind</string>
  <key>ScanlineGitDescribe</key><string>$describe</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>Scanline uses this to install its scanner helper.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app/Contents/Resources/ScanlineHelper"
codesign --force --sign - "$app"
echo "$app"
