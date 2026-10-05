# VoiceBud v2 UI — build spec (contract for all implementers)

## 0. Hard rules from Nils (override everything below AND the concept HTML)

- **No middle dots `·` anywhere in UI text** (not "Alles lokal · offline", not "31 Wörter · 0,7 s",
  not "Eingefügt in Mail · 31 Wörter"). Nils reads them as AI slop. Separate information by layout
  (two text elements with spacing, a line break, a secondary colour) or with a plain comma.
- **No ALL-CAPS headings or labels** (no `.textCase(.uppercase)`, no `uppercased()`, no letter-spaced
  caps like "HEUTE", "VERLAUF", "DIKTAT"). Use German sentence case ("Heute", "Gestern",
  "Einstellungen") with weight/size/colour for hierarchy.
- **RAM and speed are acceptance criteria for EVERY change (Nils, 03.10.)** — measure before and
  after, report the numbers, and fail the change if a budget is broken:
  - idle (no take for 10 min): Python core ≤ 120 MB footprint, VoiceBudUI ≤ 30 MB, CPU ≈ 0 %
    (no timers/polling/display links while idle; windows that were closed release their views);
  - during a take: no new resident models; peak core footprint stays ≤ today's (~2.2 GB incl.
    Whisper q8 + MLX scratch) plus at most 50 MB;
  - latency: stop → pasted text must not get slower (today ≈ 1.5 s for 20 s audio); work that is
    not needed after stop (screen context capture, model preloads) runs at hotkey press in the
    background, with hard timeouts (e.g. Accessibility messaging timeout 0.25 s);
  - heavy optional features (OCR, model downloads, onboarding window) load lazily and are released
    when done; new Python imports in the hot path are lazy.
- The island's top corners must flow into the menu bar with small concave "ears" (inverse fillets),
  exactly like the hardware notch and Alcove — never hard 90° corners at the top edge.
- **Motion exactly like Alcove, for EVERY surface (notch island, capsule/pill, live card, done card,
  settings previews).** Values read from Alcove's own web replica (framer-motion, mass 1); use
  `Animation.interpolatingSpring(mass: 1, stiffness: S, damping: D)` with these exact pairs:
  - width changes (grow out of the notch, widen for a card): **150 / 20**
  - height + bottom radius + ear radius when expanding (drop-down, live text growing): **250 / 21**
  - collapsing back / hiding: height **250 / 25**, width **200 / 20**
  - content swap inside a surface (e.g. waveform → spinner → check): scale 0.8 → 1, small y offset,
    blur(height/6) → 0, opacity, spring **150 / 14**
  - content entering: opacity 0, blur 10, scaleX 0.75 (from the notch side) → identity, 0.30 s ease-out;
    content leaving: opacity 0, blur 4, scaleX 0.25, 0.25 s ease-in
  Width and height must animate with their OWN springs (value-scoped `.animation(_:value:)` on the
  width and on the height, not one global `withAnimation`). Every surface is ONE continuously morphing
  black shape (animatable width, height, corner/ear radii) — never cross-fade two different shapes.
  The capsule grows out of a tiny pill (~36×8 pt) at its anchor and shrinks back into it.
  Ear radius ≈ 8 collapsed, 13 expanded; bottom radius ≈ 12 collapsed, 19 card, 24 live.
  Start the animation before ordering the panel front and fade the panel alpha in over 0.1 s to hide
  the first frame. Reduce Motion → 0.2 s cross-fades only.
- **Live text is its own switch (decided 03.10.):** settings get `"liveText": true|false` next to the
  shape choice. The shape picker has two tiles, "Insel an der Notch" and "Kapsel" (`islandStyle`
  "insel"|"kapsel"; read the old values "kompakt" → insel + liveText false, "live" → insel +
  liveText true). With liveText on, the island drops down with the live transcript (variant B) and
  the capsule hangs a live card below itself; off → compact island / plain capsule. With liveText
  off, Python does not stream at all.
- **Hover on the confirmation (decided 03.10.):** new setting `confirmHoverExpand` (Bool, default
  true), a toggle in "Insel & Kapsel" below the duration slider: "Beim Überfahren ausklappen", hint
  "Die Bestätigung zeigt dann den ganzen Text und bleibt offen, solange die Maus darauf ist."
  While a done card is visible (notch island, capsule, live card) poll `NSEvent.mouseLocation` at
  ~30 Hz with a timer that exists ONLY while the card is visible (idle CPU stays 0; the helper has no
  permissions, so no global event monitors). Pointer inside the card's screen rect → cancel the
  auto-hide, expand the SAME card (height 250/21, width 150/20 up to 470 pt) to show the full final
  text (`DoneInfo.fullText`, up to ~12 lines, then scrollable with a soft fade at the bottom) plus a
  small "Kopieren" button (NSPasteboard, brief "Kopiert" feedback). Only while the pointer is inside
  the card set `panel.ignoresMouseEvents = false` (so the button is clickable); the moment it leaves,
  set it back to `true`, wait 0.6 s, collapse with the collapse springs and hide after the remaining
  confirmation time (at least 0.8 s). Same behaviour for clipboard targets (⌘V capsule stays).
  Protocol: the done message carries `"text": "<full final text>"`; `DoneInfo` gains `fullText`
  (additive, defaults to the preview). Reduce Motion → cross-fade.
- **Alcove "Automatisch" (decided 03.10., becomes the DEFAULT):** `alcove` gains `"auto"` next to
  "dodge"/"takeover"; the "Wenn Alcove läuft" picker shows three tiles Ausweichen / Automatisch /
  Übernehmen, hint for Automatisch: "In der Notch, solange Alcove nichts zeigt. Zeigt Alcove etwas,
  zum Beispiel Musik, erscheint VoiceBud darunter." Decided ONCE at recording start (never switch
  mid-take): Alcove not running → notch. Running → read Alcove's preference `idleActivity`
  (`UserDefaults(suiteName: "com.henrikruscon.Alcove")`, verified readable; current value
  "nowPlaying"): "nowPlaying" → dodge only while audio output is running
  (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default output device, verified
  working, no permission), else notch; a value meaning "none"/off → notch; calendar/duo or anything
  unknown → dodge if audio is running or calendar is enabled (`enableCalendar`), else notch;
  unreadable prefs → audio heuristic. Alcove's transient HUDs/notifications cannot be predicted and
  may briefly overlap; accepted.
- **Final text = one full-audio Whisper pass after stop (decided 03.10.).** Streaming segments only
  feed the live text; the pasted text always comes from the whole take (streaming cost 2-5 WER points
  on long real speech at segment edges).

Architecture: the Python core (`main.py`, existing, owns hotkeys, microphone, STT, LLM, paste and
all macOS permissions) spawns a native Swift helper `VoiceBudUI` as a child process and talks to it
over **JSON lines on stdin/stdout**. The helper owns ALL UI: menu-bar item, notch island / capsule,
hub window (history, dictionary, settings). It needs no macOS permissions itself.

Visual reference: `design/konzept-v2.html` (open it; variants A/B, capsule, Alcove coexistence,
settings window, hub). Alcove's real settings window is the quality bar (no "AI slop" design).

Build: plain `swiftc` (NO SwiftPM, NO Xcode). Always:
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftc -sdk $SDKROOT -swift-version 5 -O -target arm64-apple-macosx15.0`
(the default MacOSX27.0 SDK is broken with the installed linker). Frameworks: SwiftUI, AppKit,
SQLite3 (`import SQLite3`, link `-lsqlite3`). No third-party code.

## 1. Files and ownership

| File | Owner | Content |
|---|---|---|
| `ui/Model.swift` | contract (do not change existing API; additive only) | `AppState`, `UISettings`, enums, colors, paths |
| `ui/main.swift` | core | NSApplication bootstrap (accessory), AppDelegate, status item + menu, wiring |
| `ui/IPC.swift` | core | stdin reader thread → main-thread dispatch into `AppState`; `IPC.send(_:)` to stdout |
| `ui/Island.swift` | island | SwiftUI: `NotchShape`, `IslandView`, `CapsuleView`, `WaveformView`, state contents |
| `ui/IslandWindow.swift` | island | NSPanel controller: screen + notch geometry, Alcove detection, show/hide, re-layout |
| `ui/Hub.swift` | hub | Hub window (NSWindow + SwiftUI): sidebar, History, Dictionary, Settings panes |
| `ui/HistoryStore.swift` | hub | read-only SQLite access to the history DB (+ FTS search) |
| `ui/Render.swift` | island + hub | `--render <dir>`: headless PNG rendering of every island state and hub pane via `ImageRenderer` |
| `ui/build.sh` | core | builds `ui/build/VoiceBudUI` |
| Python files | python | see §6 |

## 2. Protocol (one JSON object per line, UTF-8, `\n`-terminated)

Python → UI (UI's stdin):
- `{"type":"hello","version":1,"hotkeys":{"dictate":"ctrl+shift","prompt":"ctrl+alt"},"dataDir":"~/Library/Application Support/VoiceBud"}`
- `{"type":"state","phase":"recording","mode":"dictate"|"prompt"}`
- `{"type":"level","bands":[7 floats 0…1],"rms":float}` — ~30 Hz while recording only
- `{"type":"partial","text":"…"}` — the full live transcript so far (replace, don't append)
- `{"type":"state","phase":"processing","mode":…}`
- `{"type":"state","phase":"done","mode":…,"app":"Mail","words":31,"seconds":0.7,"preview":"Hallo Frau …","target":"pasted"|"clipboard","text":"<der ganze eingefügte Text>"}`
- `{"type":"state","phase":"empty","mode":…}` — nothing was said: show nothing/short fade, never text
- `{"type":"state","phase":"error","mode":…,"message":"…"}`
- `{"type":"state","phase":"idle"}`
- `{"type":"history_changed"}`

UI → Python (UI's stdout; nothing else may be printed to stdout — logs go to stderr):
- `{"type":"ready"}` once after launch
- `{"type":"settings_changed"}` after writing `settings.json` or `dictionary.json`
- `{"type":"quit"}` from the menu → Python shuts everything down

## 3. Shared files in `~/Library/Application Support/VoiceBud/` (create dir if missing)

- `settings.json` (written by UI, read by both; unknown keys must be preserved):
  `{"islandStyle":"kompakt"|"live"|"kapsel", "waveStyle":"fein"|"sym"|"linie", "waveLive":true,
    "alcove":"dodge"|"takeover", "confirmSeconds":1.5, "sounds":true, "hideInFullscreen":false,
    "keepModelsLoaded":false}`
- `dictionary.json`: `{"terms":["AI-Slop","shadcn","FS-SC", …]}`
- `history.sqlite` (written ONLY by Python, WAL mode; UI reads):
  ```sql
  CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY, ts REAL NOT NULL, mode TEXT NOT NULL,
    app TEXT, raw TEXT, final TEXT, lang TEXT, audio_s REAL, stt_s REAL, llm_s REAL,
    total_s REAL, words INTEGER);
  CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(final, raw, content='entries', content_rowid='id');
  -- + AFTER INSERT/DELETE triggers keeping entries_fts in sync
  ```

## 4. Island behaviour

- Target screen: the screen containing the mouse pointer at the moment recording starts.
- Notch detection: `screen.safeAreaInsets.top > 0` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`
  give notch width = screen width − both aux widths, notch height = safeAreaInsets.top. Re-measure on
  `NSApplication.didChangeScreenParametersNotification`. Never hard-code 185×32.
- Style: `islandStyle` "kompakt" (variant A: ears only; done state drops down briefly), "live"
  (variant B: drops down while recording and shows `partial` text, newest words bright, older dim),
  "kapsel" (floating black capsule top-centre below the menu bar). Screens WITHOUT a notch always use
  the capsule look (same states).
- Alcove (`com.henrikruscon.Alcove` running, checked via NSWorkspace each time recording starts):
  `alcove`="dodge" → use the capsule positioned directly below the notch area (y = notch height + 8);
  live text then hangs as a card below it. "takeover" → normal island.
- Window: one fixed-size transparent `NSPanel` (borderless, nonactivating, `hasShadow=false`,
  `ignoresMouseEvents=true`, `collectionBehavior=[.canJoinAllSpaces,.stationary,.fullScreenAuxiliary,.ignoresCycle]`,
  level `.statusBar + 8`), ~640×240 pt at top-centre; the shape animates inside it. Order out when
  idle (0 CPU idle). `hideInFullscreen` → skip showing when the frontmost space is fullscreen.
- States: recording (left ear: mode mic glyph + red rec dot `#FF453A`; right ear: waveform; live
  variant adds timer + live text), processing (rec dot off; ring spinner in kompakt/kapsel; shimmer
  over the text in live), done (check in mode colour, "Eingefügt in {app}" or "In der Zwischenablage"
  + `⌘V` key capsule when target=clipboard, words · seconds, one-line preview; auto-hide after
  `confirmSeconds`), empty (collapse quietly), error (short message, auto-hide 2.5 s).
- Colours: dictate violet `#B89EFA` (gradient `#8F6CF2`→`#E4DAFF`), prompt teal `#6BE6D4`
  (`#2FBFAA`→`#C8FAF1`). Island fill pure `#000`, text white / white 55 %.
- Shape: `NotchShape` with animatable top concave ear radius and bottom corner radius (closed ≈ 6/11,
  done/live ≈ 10/22–28). Width compact ≈ notch + 2×48, done ≈ 400, live ≈ 470.
- Motion (SwiftUI springs): grow `.spring(response:0.40,dampingFraction:0.66)`, expand/drop-down
  `.spring(response:0.51,dampingFraction:0.82)`, collapse `.spring(response:0.40,dampingFraction:0.79)`;
  content enters with blur(10)→0 + scaleX 0→1 anchored towards the notch + opacity (0.3 s), leaves with
  blur + scaleX 0.25. Respect Reduce Motion (cross-fade only).
- Waveform (`waveStyle`): "fein" 4 bars, "sym" 7 centre-weighted bars, "linie" a 24×14 pt line;
  bars 2 pt wide, 1.5 pt gap, max 14 pt, min 2 pt (dots in silence), vertical gradient in mode
  colour. `waveLive`=true → driven by `level.bands` with attack 0.3 / release 0.1 smoothing;
  false → calm synthetic speech-like animation. Must look calm, not twitchy.
- Sounds (`sounds`): soft start/stop via `NSSound(named:)` system sounds ("Tink"/"Pop"), quiet.

## 5. Hub window (menu item "Verlauf & Einstellungen …")

NSWindow (titled, closable, resizable, fullSizeContentView, transparent titlebar), ~900×620, SwiftUI
`NavigationSplitView` sidebar (~224 pt) in Alcove style: coloured 22 pt squircle icons, groups.
Opening switches `NSApp.setActivationPolicy(.regular)` + activates; closing switches back to `.accessory`.
- **Verlauf**: one quiet stats line (words today, entries, Ø seconds), search field (FTS), list grouped
  by day ("Heute", "Gestern", date), row = time · app · mode badge (violet "Diktat"/teal "Prompt") ·
  final text (2 lines) · words · seconds; hover actions "Kopieren" (NSPasteboard) and "Original"
  (expands raw text, removed words shown struck through via a word diff). Refresh on `history_changed`.
- **Wörterbuch**: list of terms, add field, delete; writes `dictionary.json` + sends `settings_changed`.
- **Einstellungen** (Alcove style: grouped cards, 44 pt rows, tile pickers with a ring that springs to
  the selected tile via matchedGeometryEffect, tiles show live previews; violet toggles; slider with
  detent dots and a monospaced value capsule): "Insel & Kapsel" (style tiles Kompakt/Live/Kapsel with a
  live preview island above that morphs on selection, confirmation duration slider), "Wellenform"
  (tiles Fein/Symmetrisch/Linie + toggle "Folgt deiner Stimme live"), "Wenn Alcove läuft" (tiles
  Ausweichen/Übernehmen), "Allgemein" (toggles: Start- und Stopp-Ton, Im Vollbild ausblenden,
  Modelle im RAM halten [explain: aus = spart RAM, Whisper lädt beim Hotkey nach]). Writes
  `settings.json` + sends `settings_changed`. Follows system light/dark.

## 6. Python side (owner: python)

- `ui_bridge.py`: spawn `VoiceBudUI` (path from env `VOICEBUD_UI`, else `ui/build/VoiceBudUI`;
  missing → log once, run headless), writer thread with a queue (drop stale `level` messages when
  backed up), reader thread → callbacks `on_quit`, `on_settings_changed`. UI crash → respawn once.
- `settings.py`: read `settings.json` with defaults; `dictionary.py`: load terms + `correct(text)`
  (phonetic fuzzy replacement, see tests), `history.py`: writer for `history.sqlite` (schema §3).
- `stream.py`: streaming transcription during recording — Silero VAD on the not-yet-committed tail;
  a segment is committed at ≥ 0.5 s silence after speech or when it exceeds 12 s (cut at the last
  pause); committed segments are transcribed on ONE worker thread (MLX is not re-entrant) and the
  joined text is sent as `partial`; at stop only the tail remains. Language decided once per take
  (German preferred, existing `_detect_de_en`), reused for later segments.
- `audio.py`: recorder also delivers chunks to the streamer and exposes 7 log-spaced band levels
  (120 Hz–5 kHz) for the UI at ~30 Hz, calm (dB-scaled, gamma ≈ 1.4).
- `main.py`: send states; frontmost app name (`NSWorkspace.frontmostApplication().localizedName()`)
  at stop; `target`="clipboard" when there is no focused UI element (AX) — paste anyway; write history;
  apply `dictionary.correct` to the final text and pass terms to the cleanup prompt as known terms;
  RAM: `mx.set_cache_limit(64 MB)`, `mx.clear_cache()` after every take, unload Whisper after 10 min
  idle unless `keepModelsLoaded`, preload on hotkey press (hidden behind speaking).
- Remove the old PyObjC overlay and status item from `main.py` (the UI owns them).


## Nachtrag 03.10.2026: Bildschirmkontext und Alcove „Automatisch“

- done trägt optional `"context": {"label", "used", "app", "bundle", "rows": [[Bezeichnung, Wert]], "warning"?}`. Nie Kontexttext, nur Quellen, Zählwerte und verwendete Namen. Die eingeklappte Karte zeigt „mit Kontext“, bei harten Regeln „ohne Kontext, Passwortfeld“ usw. Ausgeklappt folgt der Abschnitt „Verwendeter Kontext“ (höchstens vier Zeilen, der Volltext dann höchstens acht Zeilen) und der Knopf „In <App> ausschalten“ (setzt `contextApps[bundle] = 0`, dann settings_changed).
- state error mit `"tone":"ok"`: neutrale Hinweiskarte mit Haken statt Ausrufezeichen (Kontext-Probe).
- UI → Python: `{"type":"probe"}` aus dem versteckten Menüpunkt „Kontext-Probe“ (⌥ beim Öffnen des Menüs).
- settings.json: `contextLevel` (0 Aus, 1 Nur App, 2 Text am Cursor, 3 Ganzes Fenster; Standard 2), `contextApps` ({Bundle-ID: Stufe}), `contextElectron` (Standard an). Hub-Seite „Bildschirmkontext“.
- `alcove`: "auto" | "dodge" | "takeover", Standard "auto". Bei "auto" entscheidet die Insel beim Aufnahmestart: Alcove-Einstellung idleActivity "none" heißt Notch, "nowPlaying" oder unlesbar heißt ausweichen nur, solange das Ausgabegerät Ton spielt (CoreAudio, ohne Freigabe), alles andere heißt ausweichen.
