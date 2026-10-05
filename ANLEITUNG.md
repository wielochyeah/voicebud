# VoiceBud — lokales Diktieren auf dem Mac (Deutsch + Englisch)

Drück `ctrl+shift`, sprich, drück nochmal `ctrl+shift` — und der bereinigte Text
steht an deinem Cursor, egal in welcher App. Füllwörter (ähm, äh …) werden
entfernt, Zeichensetzung ergänzt. Zweiter Modus: `ctrl+alt` verwandelt eine
gesprochene Anweisung in einen fertig strukturierten KI-Prompt (Rolle, Aufgabe,
Kontext, Anforderungen, Format).

Alles läuft **komplett offline** auf deinem Mac. Keine Cloud, kein Abo.

## Voraussetzungen

- Mac mit **Apple Silicon** (M1 oder neuer) — Intel-Macs funktionieren NICHT
- **Rosetta wird NICHT gebraucht** — fragt macOS danach, ist die App veraltet
  gebaut: einfach `zsh make-app.sh` erneut ausführen (siehe unten)
- ~10 GB freier Speicherplatz (KI-Modelle)
- Einmalig Internet für die Downloads

## Schritt 1: Grundwerkzeuge installieren

Terminal öffnen (Programme → Dienstprogramme → Terminal) und nacheinander:

```bash
# Homebrew (Paketmanager) — überspringen, falls schon installiert
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Python 3.12
brew install python@3.12
```

## Schritt 2: VoiceBud einrichten

Den VoiceBud-Ordner an einen dauerhaften Ort legen (z. B. in den Benutzerordner,
also `~/VoiceBud-Local-Riad` — NICHT in Downloads liegen lassen, die App
verweist später fest auf diesen Ort). Dann im Terminal:

```bash
cd ~/VoiceBud-Local-Riad        # ggf. Pfad anpassen

# Eigene Python-Umgebung anlegen und Bibliotheken installieren
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt

# Das Sprachmodell für die Aufbereitung laden (~3 GB, einmalig). Es läuft danach
# komplett offline auf dem Mac (Apple-Grafikchip über MLX), Ollama braucht es nicht mehr.
.venv/bin/python -c "from huggingface_hub import snapshot_download as s; s('mlx-community/Qwen3.5-4B-MLX-4bit')"
```

## Schritt 3: App bauen

```bash
zsh make-app.sh
```

Das erzeugt **VoiceBud** in deinem Programme-Ordner — mit Icon, per Doppelklick
startbar. Die App hat kein Fenster und kein Dock-Symbol: Sie lebt als kleines
**Mikrofon-Icon oben rechts in der Menüleiste** (dort auch „Quit").

## Schritt 4: Freigaben erteilen (einmalig, wichtig!)

VoiceBud.app per Doppelklick starten. Der allererste Start dauert ein paar
Minuten — das Sprachmodell (~1,6 GB) wird automatisch geladen. Dann in
**Systemeinstellungen → Datenschutz & Sicherheit** drei Freigaben erteilen:

1. **Eingabemonitoring** — damit der Hotkey systemweit funktioniert
2. **Bedienungshilfen** — damit der Text eingefügt werden kann
3. **Mikrofon** — fragt macOS beim ersten Diktat automatisch → „Erlauben"

**Stolperfalle:** macOS führt die App in diesen Listen oft als **„Python"**
statt „VoiceBud" (die Rechte hängen am Python-Programm im Inneren). Also: Wenn
in der Liste „Python" auftaucht → aktivieren. Taucht gar nichts auf, die
Python-App im Finder anzeigen lassen und per Drag & Drop in die Liste ziehen:

```bash
open -R "$(dirname "$(readlink -f ~/VoiceBud-Local-Riad/.venv/bin/python)")/../Resources/Python.app"
```

Nach den Freigaben die App **einmal neu starten** (Menüleisten-Mikro → Quit →
Doppelklick).

## Schritt 5: Benutzen

- **Diktat:** in ein Textfeld klicken → `ctrl+shift` → sprechen (violette
  Wellenform erscheint unten) → nochmal `ctrl+shift`. Pulsierende Punkte =
  Verarbeitung läuft; danach steht der Text am Cursor.
- **Prompt-Modus:** `ctrl+alt` (türkise Wellenform) → Anweisung sprechen, z. B.
  „Schreib mir eine Mail an den Vermieter, dass die Heizung kaputt ist" →
  nochmal `ctrl+alt` → ein strukturierter KI-Prompt wird eingefügt (dauert
  10–15 s, ein ganzes Modell schreibt mit).
- Warst du in keinem Textfeld: Der Text liegt in der Zwischenablage → `cmd+V`.
- Nach dem Hotkey-Druck ~0,1 s warten, bevor du sprichst (das Mikro geht erst
  dann an — Datenschutz: es ist NUR während des Diktats offen).

## Autostart (optional)

Systemeinstellungen → Allgemein → **Anmeldeobjekte** → „+" → VoiceBud.
Ab dann startet VoiceBud automatisch mit dem Mac.

## Anpassen (config.yaml im Projektordner, danach App neu starten)

- `hotkey.key` / `prompt_hotkey.key` — Tastenkombis (z. B. `alt_r`, `cmd+shift`;
  `fn` geht auf macOS nicht)
- `stt.language` — `null` = Deutsch/Englisch automatisch, `"de"` = fest Deutsch
- `llm.idle_unload_minutes` — nach wie vielen Minuten ohne Diktat das
  Sprachmodell (~3 GB) den Arbeitsspeicher wieder freigibt
- `llm.model` — anderes MLX-Modell für die Aufbereitung (ein Repo von
  `mlx-community`, vorher wie in Schritt 2 laden)
- `prompts/` — die Anweisungen an das Sprachmodell und die Stile pro App
  (Mail, Chat, Dokument)

## Wenn etwas hakt

- macOS will beim Öffnen **Rosetta installieren**: abbrechen und im
  Projektordner `zsh make-app.sh` ausführen — das baut die App mit einem
  nativen Apple-Silicon-Starter neu.
- Neuer Mac / Daten übertragen: Homebrew (`/opt/homebrew`) und die
  Python-Umgebung (`.venv`) werden beim Umzug oft NICHT mitgenommen →
  Schritte 1–3 einfach wiederholen (Modelle sind meist noch da, geht schnell).
- Log ansehen: `tail -20 ~/Library/Logs/voicebud.log` — steht dort
  „SETUP NEEDED", fehlen noch Freigaben (Schritt 4).
- Text kommt roh/unbereinigt an: Im Log steht „LLM … is not downloaded“ →
  den Modell-Befehl aus Schritt 2 erneut ausführen.
- Kurzes erstes Diktat nach längerer Pause kommt unaufbereitet an: normal.
  Das Sprachmodell braucht ~2,5 s zum Laden und wird nur ab 10 Wörtern
  abgewartet, damit kurze Diktate nie warten.
- Nach einem Python-Update per Homebrew können die Freigaben neu fällig werden
  (gleiche Symptome wie am Anfang) → Schritt 4 wiederholen.


## Bildschirmkontext und Befehlsmodus

- VoiceBud liest beim Diktieren, wo du schreibst: den Text vor und nach dem Cursor, Markierung,
  Empfänger und Betreff. So stimmen Namen, Anrede und Anschluss. In Chat-Apps sowie Claude und
  ChatGPT liest es das ganze Fenster. Einstellbar unter Verlauf & Einstellungen → Bildschirmkontext,
  auch pro App. Nichts davon wird gespeichert.
- Prompt-Modus: Sag „diese Mail“, „dieser Text“ oder „das hier“, dann hängt VoiceBud den Text
  wörtlich unter den Prompt. Markierter Text kommt immer mit.
- Befehlsmodus: Text markieren, `ctrl+cmd` halten und sagen, was passieren soll („mach das kürzer“,
  „förmlicher“, „übersetz ins Englische“, „korrigier die Rechtschreibung“). Das Ergebnis ersetzt
  die Markierung, ⌘Z macht es rückgängig.
- Kontext-Probe: ⌥ gedrückt halten, Menüleisten-Symbol öffnen, „Kontext-Probe“. Zeigt, was
  VoiceBud in der App vorne lesen kann; das Protokoll (~/Library/Logs/voicebud-context.jsonl)
  enthält nur Längen und Zeiten, nie Text.
