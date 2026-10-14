#!/bin/bash
# Compila ScanStudio e crea il bundle ScanStudio.app nella cartella build/
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Compilazione (release)…"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/ScanStudio.app"

echo "▸ Creazione del bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ScanStudio" "$APP/Contents/MacOS/ScanStudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Compilazione degli asset (icona)…"
xcrun actool Resources/Assets.xcassets \
    --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --accent-color AccentColor \
    --output-partial-info-plist /dev/null >/dev/null

echo "▸ Firma ad-hoc…"
codesign --force --deep --sign - "$APP"

echo "✓ Fatto: $(pwd)/$APP"
echo "  Avvio con:  open \"$APP\""
echo "  Oppure copialo in /Applicazioni."
