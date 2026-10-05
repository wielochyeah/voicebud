#!/bin/zsh
# Baut die VoiceBud.app für DIESEN Mac und legt sie in /Applications ab.
# Die Pfade zum Projektordner werden automatisch eingesetzt — einfach aus dem
# Projektordner heraus ausführen:  ./make-app.sh
# (Optionales Argument: anderes Zielverzeichnis statt /Applications)
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-/Applications}"
APP="$DEST/VoiceBud.app"

if [[ ! -x "$PROJ/.venv/bin/python" ]]; then
    echo "FEHLER: $PROJ/.venv fehlt — bitte erst die Anleitung bis Schritt 2 ausführen." >&2
    exit 1
fi
if ! command -v clang >/dev/null; then
    echo "FEHLER: clang fehlt — bitte zuerst ausführen: xcode-select --install" >&2
    exit 1
fi

# Native Oberfläche (Menüleiste, Insel, Verlauf) — vor dem Löschen der alten App
# bauen, damit ein fehlgeschlagener Build die installierte App nicht zerstört.
if ! "$PROJ/ui/build.sh"; then
    echo "FEHLER: VoiceBudUI ließ sich nicht bauen (Meldungen oben)." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJ/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The menu bar UI as its own small app bundle: as a bare binary macOS lists it as "VoiceBudUI"
# with the grey "exec" icon (menu bar settings, Dock and ⌘Tab while the hub is open).
UIAPP="$APP/Contents/Resources/VoiceBudUI.app"
mkdir -p "$UIAPP/Contents/MacOS" "$UIAPP/Contents/Resources"
cp "$PROJ/ui/build/VoiceBudUI" "$UIAPP/Contents/MacOS/VoiceBudUI"
cp "$PROJ/assets/AppIcon.icns" "$UIAPP/Contents/Resources/AppIcon.icns"
cat > "$UIAPP/Contents/Info.plist" <<'UIPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VoiceBud</string>
    <key>CFBundleDisplayName</key><string>VoiceBud</string>
    <key>CFBundleIdentifier</key><string>local.voicebud.ui</string>
    <key>CFBundleExecutable</key><string>VoiceBudUI</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
UIPLIST
codesign --force --sign - "$UIAPP" >/dev/null 2>&1 || true
chmod +x "$UIAPP/Contents/MacOS/VoiceBudUI"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VoiceBud</string>
    <key>CFBundleDisplayName</key><string>VoiceBud</string>
    <key>CFBundleIdentifier</key><string>local.voicebud</string>
    <key>CFBundleExecutable</key><string>VoiceBud</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceBud nimmt nur auf, während du diktierst (Hotkey gedrückt).</string>
</dict>
</plist>
PLIST

# WICHTIG: python als Kindprozess starten, NICHT per exec — ein exec-ersetzter
# Bundle-Prozess bekommt sein Menüleisten-Icon von macOS nie platziert.
cat > "$APP/Contents/Resources/launch.sh" <<SH
#!/bin/zsh
# VoiceBud launcher: startet die Diktier-App. Das Sprachmodell startet sie selbst als
# eigenen Prozess (llm_worker.py), nur wenn es gebraucht wird.
cd "$PROJ"
# Python startet die Oberfläche als eigenes Kind (ui_bridge.py liest diesen Pfad).
export VOICEBUD_UI="\${0:A:h}/VoiceBudUI.app/Contents/MacOS/VoiceBudUI"
.venv/bin/python -u main.py >> "\$HOME/Library/Logs/voicebud.log" 2>&1 &
PID=\$!
trap 'kill \$PID 2>/dev/null' TERM INT
wait \$PID
SH

# Der eigentliche App-Starter muss ein echtes arm64-Programm sein: Ist er ein
# Skript, verlangt macOS beim Öffnen Rosetta (Intel-Übersetzung).
build_launcher() {
    local out="$APP/Contents/MacOS/VoiceBud" src="$PROJ/assets/launcher.c" sdk
    clang -O2 -arch arm64 -o "$out" "$src" 2>/dev/null && return 0
    # Übrig gebliebene Beta-SDKs können neuer sein als der installierte Linker
    # versteht — dann das zu den Command Line Tools passende SDK nehmen,
    # danach alle anderen installierten, neueste zuerst.
    local clt="$(xcode-select -p)/SDKs"
    for sdk in "$clt/MacOSX.sdk" $clt/MacOSX[0-9]*.sdk(NnOn); do
        clang -O2 -arch arm64 -isysroot "$sdk" -o "$out" "$src" 2>/dev/null && return 0
    done
    return 1
}
if ! build_launcher; then
    echo "FEHLER: App-Starter ließ sich nicht kompilieren. Command Line Tools neu installieren: xcode-select --install" >&2
    exit 1
fi

# LaunchServices sofort über den neuen Starter informieren (sonst kann die
# alte "braucht Rosetta"-Einschätzung im Cache hängen bleiben)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "Fertig: $APP"
echo "Jetzt: App doppelklicken, dann Freigaben erteilen (siehe ANLEITUNG.md Schritt 4)."
