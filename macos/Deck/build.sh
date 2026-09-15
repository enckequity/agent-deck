#!/usr/bin/env bash
# Builds Deck.app and installs it to ~/Applications.  Usage: macos/Deck/build.sh
set -euo pipefail
cd "$(dirname "$0")"
app="$HOME/Applications/Deck.app"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

swift build -c release --scratch-path "$scratch/build" 2>&1 | grep -Ev '^\[[0-9]+/[0-9]+\]' || true
bin="$scratch/build/release/Deck"
[ -x "$bin" ] || { echo "build failed" >&2; exit 1; }

# Icon: rendered from Icon.swift into an .icns
mkdir -p "$scratch/Deck.iconset"
swiftc -O Icon.swift -o "$scratch/icon" 2>/dev/null && "$scratch/icon" "$scratch/Deck.iconset"
iconutil -c icns "$scratch/Deck.iconset" -o "$scratch/Deck.icns"

rm -rf "$app.new"
mkdir -p "$app.new/Contents/MacOS" "$app.new/Contents/Resources"
cp "$bin" "$app.new/Contents/MacOS/Deck"
cp "$scratch/Deck.icns" "$app.new/Contents/Resources/Deck.icns"
cat > "$app.new/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Deck</string>
  <key>CFBundleDisplayName</key><string>Deck</string>
  <key>CFBundleIdentifier</key><string>com.enck.deck</string>
  <key>CFBundleExecutable</key><string>Deck</string>
  <key>CFBundleIconFile</key><string>Deck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$app.new" >/dev/null
rm -rf "$app" && mv "$app.new" "$app"
echo "installed $app"
