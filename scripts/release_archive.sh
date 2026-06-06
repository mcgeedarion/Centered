#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Centered.xcodeproj"
SCHEME="Centered"
CONFIGURATION="Release"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
ARCHIVE_PATH="$ROOT_DIR/build/Centered.xcarchive"
EXPORT_PATH="$ROOT_DIR/build/export"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required. Run this script on macOS with Xcode installed." >&2
  exit 127
fi

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$ROOT_DIR/build"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  clean test

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/Centered.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: archive did not produce Centered.app at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$EXPORT_PATH"
ditto -c -k --keepParent "$APP_PATH" "$EXPORT_PATH/Centered.app.zip"

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

if command -v spctl >/dev/null 2>&1; then
  spctl --assess --type execute --verbose=4 "$APP_PATH" || {
    echo "warning: Gatekeeper assessment failed. Notarize the app before public distribution." >&2
  }
fi

echo "Release archive: $ARCHIVE_PATH"
echo "Release zip: $EXPORT_PATH/Centered.app.zip"
