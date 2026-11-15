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

version=${SCANLINE_VERSION:-1.0}
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
