# Bildschirmkontext: Plan

**Stand 03.10.2026 abends: Abschnitte 1 bis 4 und der Befehlsmodus sind gebaut, getestet und
installiert.** Offen sind nur noch die Texterkennung (Abschnitt 5, braucht eine feste Signatur)
und die 2-Minuten-Kontext-Probe mit Nils (⌥ gedrückt halten und das Menüleisten-Symbol öffnen,
dann „Kontext-Probe“ in jeder Haupt-App einmal). Claude Desktop ist schon geprüft: Feld und
Fenster werden gelesen, Schnappschuss 136 ms, Fenster 7.057 Zeichen in 59 ms.

Stand 03.10.2026. Grundlage sind fünf Recherche-Stränge (Konkurrenz, macOS-Bedienungshilfen,
Einsatz im Sprachmodell, Datenschutz und Bedienung, kritische Gegenprüfung). Alle Messungen
stammen von diesem Mac mit macOS 26.6.

## Was du davon hast

- Namen stimmen. Schreibst du Frau Szymańska, steht ihr Name im Empfängerfeld. VoiceBud
  schreibt ihn dann richtig, auch wenn Whisper „Schimanska“ hört.
- Der Text passt an die Stelle, an der der Cursor steht. Mitten im Satz geht es klein weiter.
  Das Leerzeichen davor stimmt, und ein Schlusspunkt fällt weg, wenn danach noch Text kommt.
- Der Tonfall stimmt. Siezt du im Fenster, wird „Sie“ großgeschrieben.
- Im Prompt-Modus kannst du sagen „fass diese Mail zusammen“. Die Mail hängt dann unter dem
  fertigen Prompt.

## Wie es funktioniert

Beim Drücken des Hotkeys macht VoiceBud über die Bedienungshilfen einen Schnappschuss. Er
enthält die App, den Fenstertitel, bis zu 500 Zeichen vor und nach dem Cursor, markierten Text
und Namen aus Empfänger- und Chatfeldern. Das dauert 1 bis 50 ms und läuft parallel zum
Sprechen. Nach dem Stopp entsteht keine zusätzliche Wartezeit.

Beim Diktat bekommt das Sprachmodell den Bildschirmtext nie roh. Im Test hat rohes Material
das 4B-Modell dazu gebracht, Bildschirmtext in die Ausgabe zu kopieren, und einmal sogar die
Bedeutung umgedreht. Stattdessen wird der Kontext fest verdichtet:

1. Namen und Fachbegriffe aus dem Fenster gehen an den Lautabgleich des Wörterbuchs, nur für
   dieses Diktat. Der Abgleich lernt dafür Akzente und polnische Buchstabenpaare (sz, cz, rz).
   Er greift nur mit Hinweiswort davor („Frau“, „Herr“, „Hallo“ …) oder wenn das gehörte Wort
   kein normales deutsches Wort ist. Jede Namenskorrektur steht in der Bestätigungskarte und
   lässt sich mit einem Klick zurücknehmen.
2. Die Anrede wird erkannt (Sie oder du). Nur „Sie“ geht als kurzer Hinweis ans Modell.
3. Der Anschluss an den Cursor läuft als feste Regel nach dem Modell.
4. Den Stil pro App gibt es schon (Mail, Chat, Dokument, seit heute eingebaut).

Im Prompt-Modus schreibt das Modell nur den Prompt selbst. Das Material (markierter Text oder
die gemeinte Mail) hängt der Code wörtlich an. Ließ man das Modell das Material umschreiben,
gingen im Test Fakten verloren: Die Frist „Freitag“ fehlte dreimal von drei.

## Stufen in den Einstellungen

| Stufe | Was VoiceBud liest | Berechtigung |
|---|---|---|
| Aus | nichts | keine |
| Nur App | App und Fenstertitel, danach der Stil | keine |
| Text am Cursor (Empfehlung) | dazu Text vor und nach dem Cursor, Markierung, Namen | Bedienungshilfen, schon erteilt |
| Ganzes Fenster | dazu sichtbarer Text im Fenster, etwa ein Chatverlauf | Bedienungshilfen, schon erteilt |
| Bildschirmtext per Texterkennung | Bild vom aktiven Fenster, auf dem Mac gelesen | Bildschirmaufnahme, fragt macOS regelmäßig neu |

Jede App lässt sich einzeln herunterstufen oder ausnehmen.

## Feste Datenschutzregeln

Diese Regeln sind keine Einstellungen.

- Passwortfelder und sichere Eingabe: kein Kontext für dieses Diktat.
- Passwortmanager und Schlüsselbund sind immer ausgenommen, ebenso VoiceBud selbst.
- Nichts wird gespeichert. Der Kontext liegt nur im Arbeitsspeicher und wird nach dem Einfügen
  verworfen. Der Verlauf merkt sich nur, ob Kontext genutzt wurde, nie welcher.
- Wechselst du während der Aufnahme die App, wird der Kontext verworfen.
- Private Browserfenster: Firefox ist erkennbar. Bei Safari und Chrome gibt es kein
  verlässliches Zeichen, dort gilt höchstens „Text am Cursor“.
- Fenstertext wörtlich im Prompt (der dann oft in einen Cloud-Chat geht) ist ein eigener
  Schalter, und die Karte zeigt es an.

Die Bestätigungskarte zeigt bei jedem Diktat einen kleinen Hinweis, etwa „Kontext aus Mail“
oder „Ohne Kontext, Passwortfeld“. Ausgeklappt steht dort, was genutzt wurde, mit einem
Schalter „In Mail ausschalten“. So weit geht keiner der Konkurrenten. Wispr schickt den Kontext
in die Cloud und zeigt ihn nicht an, Superwhisper speichert ihn im Verlauf.

## Was die Gegenprüfung vorher verlangt

1. **Wem die Berechtigungen gehören.** VoiceBuds Bedienungshilfen-Freigabe hängt derzeit an der
   Starter-Kette über zsh, nicht an „Python“. Das Homebrew-Update auf Python 3.12.15 hat das
   verschoben. Vor dem Kontextbau prüft ein automatischer Test (ohne Systemdialog), unter
   welcher Identität VoiceBud liest. Das Ergebnis kommt ins Startprotokoll.
2. **Fokus-Suche für Claude Desktop.** Die heutige Suche über das systemweite Element scheitert
   in Electron-Apps. 5 deiner 9 Diktate in Claude zeigten deshalb „Zwischenablage“, obwohl
   eingefügt wurde. Neu: erst die App vorne, dann ihr fokussiertes Feld. Bei Fehlern gibt es
   keinen Feldtext (sicher zu). Electron-Apps legen ihren Text erst offen, wenn man sie
   freischaltet, und das dauert 2,1 s. VoiceBud schaltet sie deshalb frei, sobald sie nach vorne
   kommen, nicht erst beim Hotkey.
3. **Eigene Wächter für den Prompt-Modus**, bevor er Kontext bekommt: keine Zahlen, Daten,
   Mailadressen oder Links, die weder gesprochen wurden noch im Material stehen.

## Prüfen, ohne dir Fenster nach vorne zu holen

- **Kontext-Probe:** ein versteckter Menüpunkt. Du klickst ihn einmal in Mail, Claude,
  WhatsApp, Slack, Safari, Chrome, Word, Outlook und Terminal. Protokolliert werden nur Längen,
  Rollen und Zeiten, nie Text. Dauert etwa 2 Minuten.
- Optional eine Woche stilles Mitmessen. Der Kontext wird dabei berechnet, aber nicht benutzt,
  und nur als geschwärzte Messwerte protokolliert. Eingeschaltet wird erst, wenn in Claude und
  deinen anderen Haupt-Apps mindestens 90 % der Schnappschüsse klappen.
- Automatische Tests mit Testfenstern, deren Text nur über die Bedienungshilfen gesetzt wird.
  Es gibt keine simulierten Tastendrücke und keinen Fensterwechsel, solange du am Mac arbeitest.

## Bauabschnitte

1. **Fundament:** Identitätstest, neue Fokus-Suche (repariert auch die falsche Anzeige
   „Zwischenablage“), Datenschutz-Tor, Electron-Freischaltung, Kontext-Probe.
2. **Diktat mit Kontext:** Anschluss an den Cursor, Namen-Abgleich, Anrede, Hinweis in der
   Karte samt Rücknahme.
3. **Prompt-Modus mit Material** und eigenen Wächtern.
4. **Ganzes Fenster** über die Bedienungshilfen, auf Wunsch.
5. **Texterkennung** zuletzt. Sie braucht eine feste Signatur, sonst verliert der Helfer die
   Freigabe bei jedem Neubau.

## Kosten

- RAM: dauerhaft 0. Der Kontext lebt nur während eines Diktats und ist wenige Kilobyte groß.
- Tempo nach dem Stopp: 0. Der Schnappschuss ist fertig, lange bevor Whisper fertig ist.
- Im Sprachmodell: 20 bis 60 Token mehr, etwa 0,02 s.

## Deine Entscheidungen

A. Standardstufe: **entschieden 03.10., Mittelweg.** Standard ist „Text am Cursor“. Sagst du im
   Prompt-Modus „diese Mail“, „dieser Text“ oder „das hier“ und nichts ist markiert, liest VoiceBud
   nur für dieses Diktat das ganze Fenster. „Ganzes Fenster“ lässt sich pro App dauerhaft
   einschalten. **Das Onboarding muss das einmal erklären** (im Prompt-Modus „diese Mail“ dazusagen).
B. Fenstertext wörtlich im Prompt: **entschieden 03.10., Empfehlung.** Material kommt nur bei
   einer Markierung oder wenn du dich darauf beziehst („diese Mail“, „das hier“).
C. Prüfung: **entschieden 03.10., nur die 2-Minuten-Kontext-Probe mit dir.**
D. Befehlsmodus: **entschieden 03.10., direkt nach dem Fundament.**
