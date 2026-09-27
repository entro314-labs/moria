#!/usr/bin/env bash
# Builds build/Moria.app: release binaries, bundled ripgrep, icon, Info.plist, code signature.
#
#   Scripts/package_app.sh            # sign with the first "Apple Development" identity
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/package_app.sh
#
# A stable signing identity matters: macOS ties Full Disk Access to the code signature, so an
# ad-hoc signed build would lose the permission on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
source version.env

RG_VERSION=15.2.0
RG_SHA256=3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4  # pinned; update together with RG_VERSION
APP=build/Moria.app
CACHE=build/cache

swift build -c release --product MoriaApp
swift build -c release --product moria
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
cp "$BIN/MoriaApp" "$APP/Contents/MacOS/Moria"
cp "$BIN/moria" "$APP/Contents/Resources/moria"

# ripgrep: official static build (the Homebrew one links Homebrew's PCRE2).
RG_TARBALL="$CACHE/ripgrep-$RG_VERSION-aarch64-apple-darwin.tar.gz"
RG_URL="https://github.com/BurntSushi/ripgrep/releases/download/$RG_VERSION/ripgrep-$RG_VERSION-aarch64-apple-darwin.tar.gz"
if [[ ! -f "$RG_TARBALL" ]]; then
  curl -fsSL "$RG_URL" -o "$RG_TARBALL"
fi
echo "$RG_SHA256  $RG_TARBALL" | shasum -a 256 -c - >/dev/null
tar -xzf "$RG_TARBALL" -C "$CACHE"
cp "$CACHE/ripgrep-$RG_VERSION-aarch64-apple-darwin/rg" "$APP/Contents/Resources/rg"

# Icon
if [[ ! -f build/icon/AppIcon.icns || Scripts/make_icon.swift -nt build/icon/AppIcon.icns ]]; then
  mkdir -p build/icon/AppIcon.iconset
  swift Scripts/make_icon.swift build/icon/AppIcon.iconset
  iconutil -c icns build/icon/AppIcon.iconset -o build/icon/AppIcon.icns
fi
cp build/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.entro314labs.moria</string>
  <key>CFBundleName</key><string>Moria</string>
  <key>CFBundleDisplayName</key><string>Moria</string>
  <key>CFBundleExecutable</key><string>Moria</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 entro314 labs</string>
  <key>NSDesktopFolderUsageDescription</key><string>Moria indexes your Desktop so you can search it.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Moria indexes your Documents so you can search them.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Moria indexes your Downloads so you can search them.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Moria indexes folders you add on external drives.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Moria indexes folders you add on network volumes.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.entro314labs.moria</string>
      <key>CFBundleURLSchemes</key><array><string>moria</string></array>
    </dict>
  </array>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Search with Moria</string></dict>
      <key>NSMessage</key><string>searchText</string>
      <key>NSPortName</key><string>Moria</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Search in Folder with Moria</string></dict>
      <key>NSMessage</key><string>searchFolder</string>
      <key>NSPortName</key><string>Moria</string>
      <key>NSSendFileTypes</key><array><string>public.folder</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
</dict>
</plist>
PLIST

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
if [[ -z "$IDENTITY" ]]; then
  echo "No signing identity found; set SIGN_IDENTITY." >&2
  exit 1
fi
for nested in "$APP/Contents/Resources/rg" "$APP/Contents/Resources/moria"; do
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$nested"
done
codesign --force --options runtime --timestamp=none --identifier com.entro314labs.moria --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($MARKETING_VERSION build $BUILD_NUMBER), signed by: $IDENTITY"
