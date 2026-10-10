#!/bin/zsh
# Builds dist/VoiceBud.app and dist/VoiceBud.dmg: VoiceBud for any Apple Silicon Mac with the
# macOS its libraries need (read from the binaries: 26.2 with today's MLX), without Homebrew or
# a Python install. The app carries its own Python
# (python-build-standalone 3.12.15, the same version as the development venv, so the venv's
# compiled packages are copied as they are). The speech models are not in the DMG; the app
# downloads them on first start. Signed ad hoc (no Apple Developer membership): recipients
# open it once via System Settings > Privacy & Security > "Open Anyway".
set -e
PROJ="${0:A:h:h}"
PKG="$PROJ/packaging"
DIST="$PROJ/dist"
RUNTIME="$PKG/cache/cpython-3.12.15+20261001-aarch64-apple-darwin-install_only.tar.gz"
VENV_SP="$PROJ/.venv/lib/python3.12/site-packages"
# the built app sits in a ".noindex" folder: Spotlight would otherwise list it as a second
# VoiceBud next to the installed one in Launchpad and the Apps view
APP="$DIST/build.noindex/VoiceBud.app"
C="$APP/Contents"
R="$C/Resources"
BUNDLE_ID="app.voicebud.VoiceBud"
VERSION="2.0"

[[ -f "$RUNTIME" ]] || { echo "build-dmg: Python-Laufzeit fehlt: $RUNTIME" >&2; exit 1; }
[[ -d "$VENV_SP" ]] || { echo "build-dmg: .venv fehlt (Bibliotheken werden von dort kopiert)" >&2; exit 1; }

zsh "$PROJ/ui/build.sh"
rm -rf "$DIST"
mkdir -p "$C/MacOS" "$R/app"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "build-dmg: Python-Laufzeit"
tar -xzf "$RUNTIME" -C "$R"
rm -rf "$R/python/lib/python3.12/"{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3} \
       "$R/python/lib/"{tcl*,tk*,itcl*,thread*} "$R/python/share" 2>/dev/null || true

echo "build-dmg: Bibliotheken"
rsync -a --exclude-from="$PKG/exclude.txt" "$VENV_SP/" "$R/python/lib/python3.12/site-packages/"

echo "build-dmg: VoiceBud"
for f in "$PROJ"/*.py; do
    [[ "${f:t}" == prove.py ]] || cp "$f" "$R/app/"
done
cp -R "$PROJ/prompts" "$R/app/prompts"
cp "$PROJ/config.yaml" "$R/app/config.yaml"
cp "$PROJ/assets/AppIcon.icns" "$R/AppIcon.icns"

UIAPP="$R/VoiceBudUI.app"
mkdir -p "$UIAPP/Contents/MacOS" "$UIAPP/Contents/Resources"
cp "$PROJ/ui/build/VoiceBudUI" "$UIAPP/Contents/MacOS/VoiceBudUI"
cp "$PROJ/assets/AppIcon.icns" "$UIAPP/Contents/Resources/AppIcon.icns"
plist() {  # name, id, executable, extra keys
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$1</string>
    <key>CFBundleDisplayName</key><string>$1</string>
    <key>CFBundleIdentifier</key><string>$2</string>
    <key>CFBundleExecutable</key><string>$3</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MINOS</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSUIElement</key><true/>
$4
</dict>
</plist>
PLIST
}
APPLE_EVENTS="    <key>NSAppleEventsUsageDescription</key><string>VoiceBud fragt Word nur nach Schrift und Größe an deinem Cursor, damit eingefügte Formeln zum Text passen.</string>"

echo "build-dmg: Starter"
# a left-over beta SDK can be newer than the installed linker understands: prefer a release SDK
sysroot=()
for s in /Library/Developer/CommandLineTools/SDKs/MacOSX{26,15}*.sdk(NOn); do
    [[ -f "$s/usr/include/stdlib.h" ]] && { sysroot=(-isysroot "$s"); break; }
done
clang -O2 -arch arm64 -mmacosx-version-min=15.0 "${sysroot[@]}" \
    -I"$R/python/include/python3.12" -L"$R/python/lib" -lpython3.12 \
    -Wl,-rpath,@executable_path/../Resources/python/lib \
    -o "$C/MacOS/VoiceBud" "$PKG/launcher.c"
rm -rf "$R/python/include"

echo "build-dmg: Mindest-macOS"
# the oldest macOS VoiceBud runs on is the newest minimum any bundled binary names. MLX's macOS 26
# wheel is built for 26.2: on an older macOS it loads, then every take fails on the GPU. Read from
# the binaries, never typed in, so the Info.plist cannot promise a macOS the libraries refuse
# (oscheck.py says the same at start, for launches that bypass Finder).
MINOS=$(find "$APP" -type f \( -name '*.so' -o -name '*.dylib' -o -perm +111 \) -print0 \
    | xargs -0 otool -l 2>/dev/null \
    | awk '/cmd LC_BUILD_VERSION/ {b = 1} b && $1 == "platform" {mac = ($2 == 1)} b && $1 == "minos" {if (mac) print $2; b = 0}' \
    | sort -V | tail -1)
[[ "$MINOS" == <->.<->* ]] || { echo "build-dmg: Mindest-macOS nicht lesbar ($MINOS)" >&2; exit 1; }
plist VoiceBud "$BUNDLE_ID.ui" VoiceBudUI "$APPLE_EVENTS" > "$UIAPP/Contents/Info.plist"
plist VoiceBud "$BUNDLE_ID" VoiceBud "    <key>NSMicrophoneUsageDescription</key><string>VoiceBud hört nur zu, während du diktierst. Alles bleibt auf diesem Mac.</string>
$APPLE_EVENTS" \
    > "$C/Info.plist"

echo "build-dmg: vorkompilieren"
"$R/python/bin/python3.12" -m compileall -q -j0 "$R/app" "$R/python/lib/python3.12" >/dev/null 2>&1 || true

echo "build-dmg: signieren"
codesign --force --deep --sign - "$APP"

echo "build-dmg: DMG"
# the window: background with the install hints (packaging/dmg/Background.swift, style insel|welle),
# the app on the left, Programme on the right; laid out by dmgbuild, no Finder scripting needed
STYLE="${DMG_STYLE:-insel}"
BG="$PKG/cache/dmg-bg"
swiftc -sdk "${sysroot[2]:-$(xcrun --show-sdk-path)}" -O -target arm64-apple-macosx15.0 \
    -o "$PKG/cache/dmgbg" "$PKG/dmg/Background.swift" 2>/dev/null
"$PKG/cache/dmgbg" "$BG" "$PROJ/assets/AppIcon.icns"
tiffutil -cathidpicheck "$BG/bg-$STYLE.png" "$BG/bg-$STYLE@2x.png" -out "$BG/bg.tiff" >/dev/null 2>&1
rm -f "$DIST/VoiceBud.dmg"
RW="$PKG/cache/VoiceBud-rw.dmg"
rm -f "$RW"
"$PKG/cache/dmgvenv/bin/dmgbuild" -s "$PKG/dmg/settings.py" -D app="$APP" -D background="$BG/bg.tiff" \
    VoiceBud "$RW" >/dev/null
# Finder shows ".background.tiff" despite the dot (and scrolls the window for it): flag it hidden
MNT="$(mktemp -d)"
hdiutil attach -nobrowse -noverify -mountpoint "$MNT" "$RW" >/dev/null
chflags hidden "$MNT/.background.tiff" "$MNT/.DS_Store" 2>/dev/null || true
hdiutil detach "$MNT" >/dev/null
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DIST/VoiceBud.dmg"
rm -f "$RW"
"$LSR" -u "$APP" >/dev/null 2>&1 || true       # never listed as an installed app on this Mac
echo "build-dmg: $(du -sh "$APP" | cut -f1) App, $(du -sh "$DIST/VoiceBud.dmg" | cut -f1) DMG, ab macOS $MINOS -> $DIST/VoiceBud.dmg"
