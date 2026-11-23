#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$PROJECT_DIR/.deploy.local"
XCODEPROJ="$PROJECT_DIR/ios/FujiTransfer.xcodeproj"
SCHEME="FujiTransfer"
DERIVED_DATA="/tmp/fuji-ios-refresh-dd"
APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/FujiTransfer.app"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "FEHLER: Lokale Konfiguration '.deploy.local' fehlt."
  echo "Bitte kopiere '.deploy.local.example' nach '.deploy.local' und trage"
  echo "deine DEVELOPMENT_TEAM, BUNDLE_ID und DEVICE_ID ein."
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -z "${DEVELOPMENT_TEAM:-}" || -z "${BUNDLE_ID:-}" || -z "${DEVICE_ID:-}" ]]; then
  echo "FEHLER: Bitte DEVELOPMENT_TEAM, BUNDLE_ID und DEVICE_ID in '.deploy.local' ausfuellen."
  exit 1
fi

echo "=================================================="
echo " FujiTransfer – Neu signieren & aufs iPhone laden"
echo "=================================================="
echo ""
echo "[1/3] Baue & signiere FujiTransfer (Release)..."
xcodebuild \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" || true

if [[ ! -d "$APP_PATH" ]]; then
  echo ""
  echo "FEHLER: Build fehlgeschlagen. Bitte iPhone per Kabel/WLAN verbinden und erneut versuchen."
  exit 1
fi

echo ""
echo "[2/3] Installiere FujiTransfer auf iPhone..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo ""
echo "[3/3] Starte FujiTransfer auf dem iPhone..."
if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"; then
  echo ""
  echo "Hinweis: App ist installiert! Falls sie neu installiert wurde, einmalig am iPhone unter"
  echo "Einstellungen -> Allgemein -> VPN & Geraeteverwaltung dem Entwicklerprofil vertrauen."
  exit 0
fi

echo ""
echo "Fertig! FujiTransfer ist wieder fuer 7 Tage signiert und gestartet."
