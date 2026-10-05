#!/bin/zsh
# Builds ui/build/VoiceBudUI from every ui/*.swift (plain swiftc, no SwiftPM/Xcode).
# SDK pinned to 26.5: the leftover 27.0 beta SDK does not link with the installed tools.
set -euo pipefail

UI_DIR="${0:A:h}"
OUT_DIR="$UI_DIR/build"
OUT="$OUT_DIR/VoiceBudUI"
export SDKROOT="${VOICEBUD_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"

if [[ ! -d "$SDKROOT" ]]; then
    echo "build.sh: SDK fehlt: $SDKROOT (Command Line Tools installieren: xcode-select --install)" >&2
    exit 1
fi
if ! command -v swiftc >/dev/null; then
    echo "build.sh: swiftc fehlt (xcode-select --install)" >&2
    exit 1
fi

sources=("$UI_DIR"/*.swift(N))
if (( ${#sources} == 0 )); then
    echo "build.sh: keine Swift-Dateien in $UI_DIR" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
# Embedded Info.plist: names the process "VoiceBud" in the menu bar/Dock while the hub is open.
cat > "$OUT_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VoiceBud</string>
    <key>CFBundleDisplayName</key><string>VoiceBud</string>
    <key>CFBundleIdentifier</key><string>local.voicebud.ui</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>VoiceBud fragt Word nur nach Schrift und Größe an deinem Cursor, damit eingefügte Formeln zum Text passen.</string>
</dict>
</plist>
PLIST

# Build next to the target and move into place: replacing a running binary in place
# would kill it (code signature changes under a live process). Same file name in the
# temp dir, so the ad-hoc signature identifier is "VoiceBudUI".
TMP_DIR="$(mktemp -d "$OUT_DIR/.tmp.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
swiftc -sdk "$SDKROOT" -swift-version 5 -O -target arm64-apple-macosx15.0 \
    -module-name VoiceBudUI \
    -framework AppKit -framework SwiftUI -lsqlite3 \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$OUT_DIR/Info.plist" \
    -o "$TMP_DIR/VoiceBudUI" "${sources[@]}"
mv -f "$TMP_DIR/VoiceBudUI" "$OUT"
echo "build.sh: $OUT"
