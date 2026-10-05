# VoiceBud v2: Plan

Stand: 3. Oktober 2026. Grundlage ist eine Recherche in fünf Strängen (Wispr Flow, Alcove, lokale Spracherkennung, lokale Textaufbereitung, UI-Architektur mit Machbarkeitstest auf dem M5 Pro). Jeder Strang wurde von einem unabhängigen Faktenprüfer gegengecheckt: 43 von 49 Kernaussagen bestätigt, 1 widerlegt, 5 nicht prüfbar. UI-Entwürfe: `design/konzept-v2.html`.

---

## 1. Warum Wispr Flow schneller und strukturierter ist

**Wispr Flow läuft komplett in der Cloud** („Transcription always occurs on the cloud", kein Offline-Modus).

- Das Audio geht schon während des Sprechens an die Server. Nach dem Loslassen bleibt nur der Rest.
- Spracherkennung: seit 17.09.2026 „Canto", ein eigenes Modell mit ~2 Mrd. Parametern. Die Textaufbereitung macht ein angepasstes Llama auf Rechenzentrums-GPUs.
- Veröffentlichtes Zeitbudget nach dem Loslassen: höchstens 0,7 s (Spracherkennung 0,2 s, Aufbereitung 0,2 s, Netz 0,2 s).
- Trick bei der Aufbereitung: Unveränderter Text wird einfach durchkopiert statt neu erzeugt (spekulatives Dekodieren). Das halbiert die Zeit.
- Zu Beginn jeder Aufnahme schickt die App Kontext mit: App-Name und -Typ, Text vor, in und nach dem Cursor, Namen, Gesprächsverlauf und Wörterbuch.
- Die Aufbereitung *darf* umbauen: Listen, Absätze, Selbstkorrekturen („actually …"), gesprochene Befehle („new paragraph"), Stil pro App, ein Wörterbuch, das aus deinen Korrekturen lernt.

**VoiceBud heute:**

- Alles beginnt erst nach dem Stopp.
- Die Aufbereitung brauchte auf dem alten M1 Max 7,5 s für ein 20-s-Diktat. Das ist das 4- bis 5-Fache dessen, was das Modell können sollte. Vermutete Ursachen: Neuladen nach der Pause und eine zu große Standard-Kontextlänge. Das wird gemessen.
- Der Prompt *verbietet* jede Strukturierung.
- VoiceBud nutzt keinen Kontext und hat kein Wörterbuch.

Warum Wispr Flow kaum RAM braucht: Auf dem Mac rechnet fast nichts, die Modelle laufen auf deren Servern.

## 2. Zielbild

| | heute | Ziel v2 |
|---|---|---|
| Zeit nach Stopp, 20-s-Diktat | ~8,6 s | ≤ 1 s |
| kurze Diktate | ~1–2 s | 0,2–0,5 s |
| Prompt-Modus | 10–15 s | 2–3 s, live sichtbar |
| RAM im Leerlauf | ~1,6 GB + Qwen | nahe null, Modelle nur während der Nutzung |
| Struktur | nur Füllwörter weg | Listen, Absätze, Selbstkorrekturen, Befehle, Stil pro App |
| Kontext | keiner | App, Text am Cursor, Namen (alles lokal) |
| Oberfläche | Pille unten | Notch-Insel A/B umschaltbar, Kapsel, Hub, Einstellungen in Alcoves Linie |

Alles bleibt lokal. Nichts verlässt den Mac.

## 3. Architektur (Empfehlung)

**Native Swift-App (SwiftUI/AppKit), gebaut mit `swiftc`, ohne Xcode.** Auf deinem Mac bereits nachgewiesen: Ein Testbuild mit Menüleisten-App, Notch-Fenster, Verlaufsfenster, Federanimationen und SQLite-Volltextsuche lief durch (453 KB, Erstbuild 29 s, danach 2 s).

- Swift übernimmt Hotkey, Mikrofon, Einfügen, Insel, Hub und Verlauf. Damit laufen alle Freigaben unter **„VoiceBud"** statt „Python".
- Spracherkennung und Aufbereitung liegen hinter austauschbaren Schnittstellen („Engines").

**Spracherkennung, Kandidaten (entschieden wird per Messung auf deiner Stimme):**

- **Apple SpeechTranscriber** (macOS 26, eingebaut). Auf deinem Mac gemessen: 23 s Audio in 0,22 s. Live gefüttert kam der letzte Text 0,05–0,08 s nach dem Stopp (englischer Test). Das Modell läuft im Systemdienst: höchstens ~94 MB, im Leerlauf 7 MB. Dafür auf Deutsch etwas ungenauer (FLEURS ~6,3 % gegenüber ~4,1 % Wortfehlerquote bei Whisper), und die Sprache wird nicht automatisch erkannt.
- **Whisper large-v3-turbo** (heute). Genauester Kandidat für Deutsch, hält aber ~1,6–2 GB, solange er geladen ist.
- Mögliche Kombination: Apple für den Live-Text, Whisper für das Endergebnis.

**Textaufbereitung, Kandidaten (entschieden wird per deutschem Testset):**

- **Apple Foundation Model** (eingebaut, kein App-RAM). Auf deinem Mac gemessen: 1,25 s, Deutsch wird unterstützt. Risiken: Schutzfilter, die normalen Text verweigern können, 4096 Token Obergrenze, und im Test wurde einmal aus einer Frage eine Aussage.
- **Qwen3 / Qwen3.5 4B oder Gemma 4 E4B über MLX.** Wird beim Hotkey-Druck geladen und nach ein paar Minuten Leerlauf wieder entladen.
- **Qualitätsmodus:** Qwen3.6-35B-A3B (~20 GB, nur solange er geladen ist).

**GPU oder Neural Engine?** mlx-whisper (Whisper heute) läuft auf der **GPU**, nicht auf der Neural Engine. Das stand früher falsch in der Config und ist korrigiert. Auf dem M5 ist das trotzdem schnell, denn jeder GPU-Kern hat jetzt eigene „Neural Accelerators". MLX ab Version 0.30 nutzt sie: Das Verarbeiten des Audios wird etwa 3- bis 4-mal schneller, das Schreiben des Texts etwa 1,2- bis 1,3-mal. Auf der echten Neural Engine laufen Apples Spracherkennung und Parakeet (über FluidAudio). Die ist besonders stromsparend, gut für den Akku.

**Welches Whisper-Modell?** large-v3-turbo ist der beste Kompromiss. Fast so genau wie large-v3, aber viel schneller, weil der Decoder nur 4 statt 32 Schichten hat. RAM: ~1,6 GB in voller Genauigkeit, ~0,8 GB als 8-Bit-Version (kaum Verlust), ~0,45 GB als 4-Bit (Verlust möglich, wird gemessen). small und medium scheiden für Deutsch aus: small machte im Juli aus „ähm ich" „Emich", medium war sechsmal langsamer. Distil-Whisper ist vor allem fürs Englische trainiert. Wichtig: **Whisper schreibt nur auf, was du sagst.** Aufzählungspunkte, Absätze und Selbstkorrekturen macht der zweite Schritt, die Textaufbereitung.

**Werkzeug-Einschränkung:** Die Paketverwaltung von Swift ist in deinen Command Line Tools defekt. Pakete wie WhisperKit, FluidAudio oder MLX Swift brauchen deshalb das kostenlose Xcode. Die erste Version kommt ohne Pakete aus (nur Apple-Frameworks und SQLite). Das übrig gebliebene Beta-SDK 27 wird außerdem `@State` brechen, sobald es Standard wird. Der Build wird deshalb fest auf SDK 26.5 gesetzt.

## 4. Phasen

### Phase 0: Mac wiederherstellen und messen (Tag 1)
- **[Nils]** Homebrew installieren (braucht dein Passwort).
- **[Claude]** Python 3.12, Ollama, ffmpeg und Node einrichten (die letzten beiden auch für die Kursvideos). Die Python-Umgebung neu aufbauen. Die alte VoiceBud läuft dann wieder als Übergang.
- **[Nils]** Mikrofon, Eingabemonitoring und Bedienungshilfen neu freigeben.
- **[Claude]** Zeitmessung pro Stufe bei jedem Diktat. Kontextlänge auf 4096 festsetzen. Erste Messwerte auf dem M5 erheben und die Ursache der 7,5 s klären.
- Sofortverbesserungen: Spracherkennung nur noch zwischen Deutsch und Englisch wählen lassen, Whisper beim Start vorwärmen, Qwen beim Hotkey-Druck laden.

### Phase 0: Stand 03.10.2026: erledigt
Homebrew, Python, Ollama, ffmpeg und Node sind installiert, VoiceBud läuft mit nativem Starter. Gemessen auf dem M5: Spracherkennung 0,5 s und Aufbereitung 1,2 s für 20 s Audio (vorher 1,1 s und 7,5 s). Behoben: Endlos-Wiederholungen, Prompt im Text, „Thank you" bei Stille, „Yeah" statt „Ja".

### Phase 1: Testlauf 1 erledigt, siehe `bakeoff/ERGEBNISSE.md`
Ergebnis: Whisper turbo 8-Bit ist am genauesten auf deiner Stimme, bei 40 % weniger RAM, und ist in VoiceBud übernommen. Die Neural-Engine-Modelle sind 3-mal schneller, machen aber etwa doppelt so viele Fehler. Sie sind Kandidaten für den Live-Text. Fachbegriffe brauchen das Wörterbuch. Offen sind mehr echte Aufnahmen und der Vergleich der Textaufbereitung.

### Phasen 2 bis 4: Stand 03.10.2026, 12:00: v2 installiert
Umgesetzt wurde die native Swift-Oberfläche (Insel an der Notch oder Kapsel, Live-Text-Schalter, Alcove-Koexistenz, dünne Wellenform mit drei Stilen, Hub mit Verlauf, Wörterbuch und Einstellungen). Gesteuert wird sie vom Python-Kern. Dazu kommen Streaming für den Live-Text, ein vollständiger Durchgang für das Endergebnis, Wörterbuch-Korrektur, das Zurücksetzen von Umformulierungen und die RAM-Verwaltung. Die Bewegungen folgen Alcoves exakten Federwerten, und alle 57 Tests bestehen. Gemessen: 104 MB im Leerlauf, 1,1 s von Stopp bis Text bei 79 s Sprache.
Noch offen: deine Abnahme der Animationen und das, was sich nur am echten Bildschirm prüfen lässt (Vollbild-Erkennung, Fokus-Rückgabe beim Schließen des Hubs). Später kommen Stile pro App, Kontext vom Bildschirm und eine schnellere Textaufbereitung (Prompt-Lookup) dazu.

### Phase 1: Testlauf mit deiner Stimme (Tag 2–3)
- **[Nils]** 15–20 echte Diktate aufnehmen (überwiegend Deutsch, ein paar Englisch) und den Referenztext korrigieren. Dafür baue ich ein kleines Werkzeug.
- **[Nils]** Zustimmung zum einmaligen Download des deutschen Apple-Sprachmodells.
- **[Claude]** Spracherkennung vergleichen: Apple, Whisper turbo in voller Genauigkeit, Whisper turbo 8-Bit und 4-Bit, Parakeet v3, optional Qwen3-ASR-1.7B. Gemessen werden Fehlerquote, Zeit nach dem Stopp und RAM.
- **Pflichtfälle im Testset:**
  - **Denglisch:** englische Wörter mitten im deutschen Satz („das Deadline-Meeting", „Feedback", „deployen", „Prompt").
  - **Begriffe vom Bildschirm:** Diktate mit Namen und Begriffen, die gerade sichtbar sind, etwa Empfänger, Betreff oder Fenstertext.
  - Jeder Kandidat läuft **mit und ohne Vokabelhinweise**. Englische Wörter und Bildschirmbegriffe bekommen eine eigene Fehlerquote.
  - Kandidaten, die Vokabelhinweise annehmen, haben dabei einen Vorteil: Whisper per Start-Prompt, Apple per Kontextliste des Diktiermodus, Qwen3-ASR per Kontext. Parakeet kann das nicht.
- **Begriffe vom Bildschirm doppelt nutzen:** als Hinweis an die Spracherkennung **und** als Liste bekannter Begriffe für die Aufbereitung. Die korrigiert „Bäcker" zu „Becker", wenn „Becker" auf dem Bildschirm steht, aber nur bei klanglich ähnlichen Wörtern, nie blind. So macht es auch Wispr Flow.
- **[Claude]** Aufbereitung vergleichen: Apple FM gegen Qwen und Gemma gegen den Qualitätsmodus. Das deutsche Testset prüft automatisch: Liste vorhanden? „Freitag" statt „Donnerstag"? Frage nicht beantwortet? „Sie" bleibt „Sie"? Zahlen richtig formatiert? Dazu die Zeit.
- Ergebnis: eine Tabelle, nach der du entscheidest.

**Stand 03.10.2026, Aufbereitung erledigt.** Getestet mit 25 Fällen (Selbstkorrekturen, Listen, Sprachbefehle, Zahlen, Mail, Chat, Englisch, dein echtes Memo) auf MLX:

| Modell | richtig ohne Wächter | richtig mit Wächter | pro Diktat | Spitze RAM |
|---|---|---|---|---|
| Qwen3.5-4B | 24 von 25 | 25 von 25 | 0,25 bis 0,4 s | 3,7 GB |
| Qwen3-4B-2507 (wie bisher in Ollama) | 20 von 25 | 21 von 25 | ähnlich | 3,2 GB |
| Qwen3.5-2B | 13 von 25 | 17 von 25 | 0,2 s | 2,3 GB |
| Qwen3-1.7B | 12 von 25 | 12 von 25 | 0,2 s | 1,9 GB |

Eingebaut ist Qwen3.5-4B in einem eigenen Prozess (llm_worker.py), der beim Sprechen startet und sich nach 5 Minuten Leerlauf beendet. Ollama ist raus. Sprachbefehle („neuer Absatz“, „Fragezeichen“) laufen als feste Regel vor dem Modell, der Stil richtet sich nach der App (Mail, Chat, Dokument). Der Wächter hatte bisher jede Struktur zerstört (alle Zeilenumbrüche, auch im Prompt-Modus) und Selbstkorrekturen zurückgesetzt. Beides ist behoben. Apple FM und der Qualitätsmodus wurden nicht mehr getestet, weil Qwen3.5-4B alle Fälle schafft.

### Phase 2: Native App-Kern (Woche 1)
- Swift-App mit Menüleiste.
- Hotkeys: Auch die Fn/Globus-Taste geht, anders als der alte Kommentar behauptet. Dafür stellst du ein, dass die Globus-Taste nichts tut. Halten = sprechen, doppelt tippen = freihändig, Esc = abbrechen.
- Mikrofon nur während der Aufnahme offen.
- **Streaming:** Die Aufnahme wird an Sprechpausen zerschnitten, jedes Stück sofort erkannt. Nach dem Stopp bleibt nur das letzte Stück.
- Einfügen direkt über die Bedienungshilfen, sonst über die Zwischenablage. Dazu ein Kürzel „Letztes einfügen".
- Verlauf in SQLite mit Volltextsuche und einem Zeitprotokoll pro Diktat.
- Signatur mit einem selbstsignierten Zertifikat, damit Freigaben Updates überleben (braucht deine Zustimmung).

### Phase 3: Intelligenz (Woche 1–2)
- **Neuer deutscher Aufbereitungs-Prompt** mit 8–10 Beispielen. Er erlaubt ausdrücklich:
  - Listen bei Aufzählungen („erstens …", „eins … zwei …")
  - Absätze bei Themenwechseln
  - Selbstkorrekturen („Donnerstag, nein, ich meine Freitag" → „Freitag")
  - gesprochene Befehle („neuer Absatz", „Fragezeichen")
  - deutsche Schreibweise für Zahlen und Daten (14:30 Uhr, 3. Oktober, 5 %, „…")
  - E-Mail-Layout mit Anrede und Gruß

  Er beantwortet nie Fragen und übersetzt nie.
- **Stil pro App:** E-Mail (Anrede und Gruß, Du/Sie beibehalten), Chat (kein Schlusspunkt bei Kurzem), Dokument, Prompt, Wörtlich (Terminal und Code ohne KI).
- **Kontext in drei Stufen:**
  - nur App
  - plus Text am Cursor (Standard)
  - plus Bildschirminhalt (nur auf Wunsch, braucht die Freigabe „Bildschirmaufnahme")

  Passwortfelder werden nie gelesen, und der Kontext wird nicht gespeichert.
- **Wörterbuch und Auto-Lernen:** 10–20 s nach dem Einfügen liest die App das Feld erneut und schlägt deine Korrekturen als Wörterbuch-Einträge vor. Dazu Kurzbefehle (Snippets).
- **Schutzregeln:** Kippt die Bedeutung (Frage wird Aussage, Zahlen oder Namen fehlen, Sprache gewechselt), wird stattdessen der bereinigte Rohtext eingefügt.
- **Abkürzung:** Kurze, saubere Diktate gehen ohne KI durch (0,2–0,5 s).
- **Befehlsmodus:** Text markieren und „mach das kürzer" sagen. Der Prompt-Modus nutzt den Kontext mit.
- **Tempo:** Der feste Teil des Prompts wird vorberechnet. „Unveränderten Text durchkopieren" wie bei Wispr (Prompt-Lookup). Eine Live-Vorschau zeigt den Text in der Insel.

### Phase 4: Oberfläche (Woche 2)
- Insel **A (Kompakt)** und **B (Live)** umschaltbar, dazu die **Kapsel** für Macs ohne Notch und externe Monitore. Die Notch wird pro Bildschirm gemessen, weil sich ihre Größe mit der Skalierung ändert. Die Insel erscheint auf dem Bildschirm mit dem aktiven Textfeld.
- **Alcove-Koexistenz:** Weg 1 (Ausweichen) oder Weg 2 (Übernehmen). VoiceBud erkennt, ob Alcove läuft.
- **Wellenform:** drei Stile (Fein mit 4 Balken wie Alcove, Symmetrisch mit 7 Balken auf 23 px Breite, Linie), 2 px dünn, mit Farbverlauf, ruhig gedämpft statt zappelig. In Stille werden die Balken zu Punkten. Sie folgt live den echten Frequenzbändern deines Mikrofons. Abschaltbar, dann läuft eine ruhige Animation.
- **Bewegung nach Alcoves Werten**, abgelesen aus Alcoves eigenem Website-Nachbau:
  - Hover federnd (0,40 s, Dämpfung 0,44)
  - Aufklappen (0,51 s, Dämpfung 0,82)
  - Inhalte blenden mit 10 px Unschärfe und horizontalem Stauchen zur Notch hin ein

  Dazu Start- und Stopp-Töne. Ist „Bewegung reduzieren" aktiv, wird nur weich überblendet.
- **Hub:** Verlauf (nach Tagen gruppiert, Suche mit ⌘F, Pfeiltasten, Kopieren, Einfügen, Original, Löschen), Statistik (Wörter, Wörter pro Minute, Tage in Folge), Wörterbuch, Stile, Kurzbefehle.
- **Einstellungen in Alcoves Linie:** farbige Symbol-Kacheln, Karten, Kachelauswahl mit federndem Ring und Live-Vorschau, Regler mit Rastpunkten und Wertkapsel, Tonvorschau.
- **Einführung:** Freigaben Schritt für Schritt, mit Mikrofontest.
- **Datenschutz:** Der Verlauf speichert nur Text, kein Audio. Aufbewahrung wählbar: immer, 24 h oder nie.

### Phase 5: Weitergabe
- Build-Skript ohne Xcode, ZIP mit Anleitung.
- Voraussetzungen: Apple Silicon und macOS 26 für die Apple-Engines, sonst der Whisper-Weg.

## 5. Deine Entscheidungen

1. **Architektur:** native Swift-App (Empfehlung) oder die Python-App weiterpflegen.
2. **Alcove:** Weg 1 (Ausweichen) oder Weg 2 (Übernehmen).
3. **Xcode installieren** (kostenlos, App Store)? Es erlaubt Pakete wie WhisperKit, FluidAudio und MLX Swift und macht den Build zukunftssicher. Sonst geht es vorerst ohne.
4. **Selbstsigniertes Zertifikat** für stabile Freigaben.
5. **Qualitätsmodus** mit großem Modell (~20 GB, nur während der Nutzung)?
6. **Bildschirminhalt als Kontext** (Freigabe Bildschirmaufnahme)? Standard ist aus.
7. **Verlauf:** Wie lange aufbewahren? Vorschlag: nur Text, unbegrenzt, kein Audio.

## 6. Ehrliche Grenzen

- Wispr trainiert Canto mit echten Diktaten vieler Nutzer und lernt nutzerübergreifend. Das können wir lokal nicht nachbauen. Wie gut Wispr auf Deutsch tatsächlich ist, ist kaum dokumentiert. Deshalb messen wir an deiner Stimme.
- Viele M5-Zahlen sind Schätzungen oder stammen von Dritten. Phase 0 und 1 ersetzen sie durch eigene Messungen.
- Apple-Engines brauchen macOS 26 und Apple Intelligence. Das Apple-Modell hat Schutzfilter und eine Längengrenze, deshalb gibt es immer einen Rückfallweg.

## Später: VoiceBud als DMG für andere (Wunsch 03.10.2026, nach dem Bildschirmkontext)

Vorgaben von Nils: Gegenüber hat kein Homebrew und keine Entwicklerwerkzeuge, schwächstes Gerät ist ein M1 MacBook Air mit mindestens 16 GB RAM. Das heißt: eigene Python-Laufzeit in der App, Modelle lädt das Onboarding herunter, Signatur und Notarisierung klären.

Entscheidung 03.10.2026: ohne Apple-Developer-Mitgliedschaft. Die DMG wird ad-hoc signiert; Empfänger öffnen sie beim ersten Mal über Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“ und erteilen die Freigaben nach Updates neu. Das Onboarding muss beides Schritt für Schritt erklären.
