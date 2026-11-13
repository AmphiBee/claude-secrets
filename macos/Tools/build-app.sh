#!/bin/bash
# Assemble ClaudeSecrets.app (Command Line Tools seulement, pas de Xcode).
#   Tools/build-app.sh [debug|release]      -> macos/build/ClaudeSecrets.app
# Signature ad hoc + hardened runtime. Une signature ad hoc change à chaque compilation : l'accès au
# trousseau devra être ré-autorisé après une mise à jour (voir docs/macos/SPIKE.md).
set -euo pipefail
cd "$(dirname "$0")/.."
CONF="${1:-release}"
swift build -c "$CONF" --product ClaudeSecrets 2>&1 | grep -v "ld: warning" | tail -3
BIN="$(swift build -c "$CONF" --show-bin-path 2>/dev/null)/ClaudeSecrets"
APP=build/ClaudeSecrets.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSecrets"
[ -f Resources/AppIcon.icns ] || swift Tools/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Secrets</string>
  <key>CFBundleDisplayName</key><string>Claude Secrets</string>
  <key>CFBundleIdentifier</key><string>fr.amphibee.ClaudeSecrets</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ClaudeSecrets</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.13.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 AmphiBee</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PL
codesign --force --options runtime --sign - "$APP" 2>&1 | tail -1
codesign --verify --deep --strict "$APP" && echo "signature vérifiée (hardened runtime : $(codesign -dv "$APP" 2>&1 | grep -c "flags=.*runtime"))"
echo "OK : $APP"
