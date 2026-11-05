#!/bin/bash
# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
LICENSE_MODE=release
if [[ "${COLD_ARCHIVE_LOCAL_BUILD:-0}" == 1 ]]; then
    LICENSE_MODE=local
fi
if [[ "$LICENSE_MODE" == release ]]; then
    python3 -B scripts/public-source.py
fi
python3 scripts/release-materials.py --mode "$LICENSE_MODE"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
SOURCE_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/coldarchive-source.XXXXXX")
trap 'rm -f "$SOURCE_SNAPSHOT"' EXIT
python3 scripts/source-manifest.py snapshot "$SOURCE_SNAPSHOT"
swift build -c release --disable-sandbox
DEFAULT_APP="$PWD/dist/冷归档 2.0.17.app"
if [[ "$LICENSE_MODE" == local ]]; then
    DEFAULT_APP="$PWD/dist/冷归档 2.0.17 许可验证.app"
fi
APP="${COLD_ARCHIVE_APP_PATH:-$DEFAULT_APP}"
rm -rf "$APP/Contents"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ColdArchive "$APP/Contents/MacOS/ColdArchive"
cp -R Sources/ColdArchive/Resources/Engine "$APP/Contents/Resources/"
find "$APP/Contents/Resources/Engine" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$APP/Contents/Resources/Engine" -type f \( -name 'test_*.py' -o -name '*.pyc' -o -name '.DS_Store' \) -delete
python3 scripts/release-materials.py --mode "$LICENSE_MODE" --resources "$APP/Contents/Resources"
python3 scripts/package-runtime.py "$APP/Contents/Resources/Runtime"
python3 scripts/release-materials.py --mode "$LICENSE_MODE" --verify-resources "$APP/Contents/Resources"
cp Assets/ColdArchive.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ColdArchive</string>
<key>CFBundleIdentifier</key><string>local.coldarchive.mac</string>
<key>CFBundleName</key><string>冷归档</string>
<key>CFBundleDisplayName</key><string>冷归档</string>
<key>CFBundleIconFile</key><string>ColdArchive</string>
<key>CFBundleVersion</key><string>56</string>
<key>CFBundleShortVersionString</key><string>2.0.17</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 scripts/source-manifest.py verify "$SOURCE_SNAPSHOT"
cp "$SOURCE_SNAPSHOT" "$APP/Contents/Resources/SourceManifest.json"
chmod 644 "$APP/Contents/Resources/SourceManifest.json"
if [[ "$LICENSE_MODE" == release ]]; then
    python3 scripts/sign-app.py "$APP"
fi
printf '%s\n' "$APP"
