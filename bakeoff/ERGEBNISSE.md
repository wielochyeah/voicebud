# Spracherkennung: Testlauf 1 (3. Oktober 2026, M5 Pro)

Alle Modelle bekamen identisch vorverarbeitetes Audio (Stille per VAD abgeschnitten, wie in VoiceBud) und liefen nacheinander, je dreimal pro Aufnahme. Zeit = schnellster Lauf, reine Erkennung ohne Modell-Laden. RAM = Spitzenwert des eigenen Prozesses. Bei Apple liegt das Modell zusätzlich in einem Systemdienst und zählt hier nicht mit.

| Modell | Chip | 20-s-Text | deine 77-s-Aufnahme | Fehler deine Aufnahme* | Deutsch / mit Rauschen | Denglisch | Englisch | RAM |
|---|---|---|---|---|---|---|---|---|
| Whisper turbo | GPU | 0,48 s | 1,25 s | ~6 | 0 % / 0 % | 6 % | 0 % | 1,9 GB |
| **Whisper turbo 8-Bit** ✅ | GPU | 0,46 s | 1,16 s | **~6** | 0 % / 0 % | 6 % | 0 % | **1,1 GB** |
| Whisper turbo 4-Bit | GPU | 0,43 s | 1,07 s | ~10 | 4 % / 4 % | 6 % | 0 % | 0,8 GB |
| Qwen3-ASR 1.7B | GPU | 0,86 s | 3,21 s | viele, ohne Satzzeichen | 0 % / 0 % | 6 % | 0 % | 2,4 GB |
| Apple (allgemein) | Neural Engine | 0,16 s | 0,45 s | ~14 | 6 % / 6 % | 13 % | nur mit en-Einstellung | 0,03 GB (+ System) |
| Apple (Diktiermodus) | Neural Engine | 0,43 s | 2,70 s | ~20 | 2 % / 4 % | 6 % | nur mit en-Einstellung | 0,03 GB (+ System) |
| Parakeet v3 | Neural Engine | 0,14 s | 0,42 s | ~13 | 2 % / 4 % | 6 % | 0 % | 0,25 GB |

\* echte Fehler nach Wort-für-Wort-Prüfung. Umgangssprachliche Formen wie „hab", „ne", „nix" zählen nicht, denn die hat Nils vermutlich so gesagt. Der Referenztext wurde aus der Whisper-Abschrift entworfen und von Nils an drei Stellen korrigiert. Das bevorzugt Whisper leicht, deshalb die Prüfung.

## Ergebnis
- **Genauigkeit:** Whisper turbo 8-Bit ist auf Nils' echter Stimme am genauesten (etwa halb so viele Fehler wie Apple oder Parakeet), bei 40 % weniger RAM als das bisherige Modell. **In VoiceBud übernommen.**
- **Tempo:** Die Neural-Engine-Modelle (Apple, Parakeet) sind etwa 3-mal schneller und brauchen fast keinen RAM. Mit Streaming (v2) bleibt nach dem Stopp aber ohnehin nur ein kurzes Stück, dann zählt der Tempo-Vorteil kaum noch.
- **Mögliche Kombination für v2:** Parakeet oder Apple liefert auf der Neural Engine den Live-Text in der Insel (Variante B), Whisper 8-Bit auf der GPU das Endergebnis. Die beiden konkurrieren nicht um denselben Chip.
- **Fachbegriffe** („AI-Slop", „shadcn", „FS-SC") erkennt kein Modell. Vokabelhinweise an Whisper sind unzuverlässig (mal besser, mal schlechter, einmal Schleife). Apples Kontextliste zeigte keine Wirkung. **Lösung: Wörterbuch-Korrektur nach der Erkennung.**
- Qwen3-ASR 1.7B: gut bei kurzen, sauberen Sätzen, schwach bei langer echter Sprache, langsam, viel RAM. Nicht weiter verfolgt.
- Parakeet erzwingt kein Deutsch (kurzes „Ja" → „Yeah") und behält Füllwörter. Apple erkennt die Sprache nicht selbst.

## Einschränkung
Nur eine echte Aufnahme, der Rest sind Computerstimmen. Für eine endgültige Wahl braucht es 15–20 echte Diktate. Runner und Messwerkzeug liegen im Scratchpad der Sitzung.
