#!/bin/bash
# Builds MacPaper.app (with the screen saver inside) into ./build, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacPaper"
APP="build/MacPaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacPaper"

if [ ! -f build/AppIcon.icns ] || [ Assets/AppIcon.png -nt build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift Assets/AppIcon.png build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Effects "$APP/Contents/Resources/Effects"
cp -R Samples "$APP/Contents/Resources/Samples"
cp FORMAT.md "$APP/Contents/Resources/FORMAT.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.adilkairolla.macpaper</string>
  <key>CFBundleName</key><string>MacPaper</string>
  <key>CFBundleDisplayName</key><string>MacPaper Engine</string>
  <key>CFBundleExecutable</key><string>MacPaper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>MacPaper checks when your next calendar event starts so a wallpaper character can react just before it. Nothing leaves your Mac.</string>
  <key>NSScreenCaptureUsageDescription</key><string>MacPaper listens to system audio so audio-reactive wallpapers can follow your music. No video is recorded.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.adilkairolla.macpaper</string>
    <key>CFBundleURLSchemes</key><array><string>macpaper</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.adilkairolla.macpaper.wallpaper</string>
    <key>UTTypeDescription</key><string>MacPaper Wallpaper</string>
    <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
    <key>UTTypeIconFile</key><string>AppIcon</string>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>macpaper</string></array>
    </dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>MacPaper Wallpaper</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSTypeIsPackage</key><true/>
    <key>LSItemContentTypes</key><array><string>com.adilkairolla.macpaper.wallpaper</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# The screen saver compiles the format, library and renderer straight into a loadable bundle.
SAVER="$APP/Contents/Resources/MacPaper.saver"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources" build/saver
SAVER_SOURCES=(
  $(find Sources/MacPaper/Format Sources/MacPaper/Library Sources/MacPaper/Render -name '*.swift')
  Sources/MacPaper/Desktop/DesktopWindow.swift
  Sources/MacPaperSaver/*.swift
)
if [ "$CONFIG" = release ]; then OPT=(-O -wmo); else OPT=(-Onone -g); fi
swiftc "${OPT[@]}" -swift-version 5 -parse-as-library -emit-library \
  -module-name MacPaperSaver -target "$(uname -m)-apple-macos26.0" \
  -framework ScreenSaver -framework Metal -framework MetalFX -framework ScreenCaptureKit \
  -module-cache-path build/saver/cache -o "$SAVER/Contents/MacOS/MacPaperSaver" "${SAVER_SOURCES[@]}"
sips -z 116 116 build/icon-1024.png --padToHeightWidth 116 180 --padColor 0B1430 --out "$SAVER/Contents/Resources/thumbnail.png" >/dev/null
sips -z 232 232 build/icon-1024.png --padToHeightWidth 232 360 --padColor 0B1430 --out "$SAVER/Contents/Resources/thumbnail@2x.png" >/dev/null
cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.adilkairolla.macpaper.saver</string>
  <key>CFBundleName</key><string>MacPaper</string>
  <key>CFBundleDisplayName</key><string>MacPaper</string>
  <key>CFBundleExecutable</key><string>MacPaperSaver</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(date +%s)</string>
  <key>NSPrincipalClass</key><string>MacPaperSaverView</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$SAVER" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
