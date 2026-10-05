// English texts for hub (Localization.swift): German text as written in the code -> English.
// Not listed because they read the same in English: "Alcove", "Apps", "Cursor", "Original", "Prompt".
extension Loc {
    static let hub: [String: String] = [
        // sidebar and pane titles
        "Verlauf": "History",
        "Texterkennung": "Text Recognition",
        "Wörterbuch": "Dictionary",
        "Kürzel": "Snippets",
        "Einstellungen": "Settings",
        "Insel & Kapsel": "Island & Capsule",
        "Wellenform": "Waveform",
        "Wenn Alcove läuft": "When Alcove Is Running",
        "Bildschirmkontext": "Screen Context",
        "Allgemein": "General",
        "Alles lokal und offline": "All local and offline",
        "Nichts verlässt den Mac": "Nothing leaves your Mac",
        "Ein": "On",
        "Aus": "Off",

        // Verlauf
        "Diktate durchsuchen": "Search dictations",
        "Erkannte Texte durchsuchen": "Search recognized text",
        "Suche löschen": "Clear search",
        "Treffer": "found",
        "Heute noch nichts diktiert": "Nothing dictated today",
        "Einträge insgesamt": "in total",
        "Wort heute": "word today",
        "Wörter heute": "words today",
        "Diktat (Anzahl)": "dictation",
        "Diktate": "dictations",
        "Ø %@": "%@",
        "Verarbeitung": "average processing",
        "Heute": "Today",
        "Gestern": "Yesterday",
        "1 Wort": "1 word",
        "%@ Wörter": "%@ words",
        "Diktat": "Dictation",
        "Befehl": "Command",
        "Kopieren": "Copy",
        "Kopiert": "Copied",
        "Noch keine erkannten Texte": "No recognized text yet",
        "drücken und einen Bereich aufziehen.": "to select an area of the screen.",
        "Noch keine Diktate": "No dictations yet",
        "Halte": "Hold",
        "gedrückt, sprich und lass los.": "while you speak, then let go.",
        "Jedes Diktat landet hier, durchsuchbar und nur auf diesem Mac.":
            "Every dictation lands here, searchable and only on this Mac.",
        "Keine Treffer": "No results",
        "Nichts gefunden für „%@“.": "Nothing found for “%@”.",

        // Wörterbuch
        "Namen und Fachbegriffe, die VoiceBud genau so schreiben soll. Ähnlich klingende Wörter ersetzt es beim Diktieren automatisch.":
            "Names and terms VoiceBud should spell exactly as written. Words that sound alike are replaced automatically as you dictate.",
        "1 Begriff": "1 Term",
        "%@ Begriffe": "%@ Terms",
        "Begriff hinzufügen": "Add a term",
        "%@ entfernen": "Remove %@",
        "Gelernte Korrekturen": "Learned Corrections",
        "statt „%@“": "instead of “%@”",
        "Entfernen": "Remove",

        // Kürzel
        "Sag den Auslöser beim Diktieren, und VoiceBud setzt den ganzen Text wörtlich ein, etwa deine Adresse oder Signatur.":
            "Say the trigger while dictating and VoiceBud inserts the full text word for word, like your address or signature.",
        "Wenn ich sage": "When I say",
        "meine Signatur": "my signature",
        "schreibt VoiceBud": "VoiceBud writes",
        "Viele Grüße\nDein Name": "Best regards\nYour name",
        "Hinzufügen": "Add",
        "1 Kürzel": "1 Snippet",
        "%d Kürzel": "%d Snippets",
        "Noch keine Kürzel.": "No snippets yet.",

        // Insel & Kapsel
        "Insel an der Notch": "Island at the Notch",
        "Kapsel": "Capsule",
        "Live-Text beim Sprechen": "Live text while speaking",
        "Aus: nur die Kapsel, ohne Streaming": "Off: just the capsule, no streaming",
        "Aus: kompakte Insel, ohne Streaming": "Off: a compact island, no streaming",
        "Bestätigung anzeigen": "Show confirmation",
        "Beim Überfahren ausklappen": "Expand on hover",
        "Die Bestätigung zeigt dann den ganzen Text und bleibt offen, solange die Maus darauf ist.":
            "The confirmation then shows the full text and stays open while the pointer is on it.",
        "Schwebt als Kapsel unter der Menüleiste. Auf Bildschirmen ohne Notch sieht VoiceBud immer so aus.":
            "Floats as a capsule below the menu bar. On displays without a notch, VoiceBud always looks like this.",
        "Wächst seitlich aus der Notch. Nach dem Einfügen klappt sie kurz auf und bestätigt.":
            "Grows sideways out of the notch. After pasting, it briefly expands to confirm.",
        "Ohne Live-Text erkennt VoiceBud erst nach dem Loslassen.":
            "Without live text, VoiceBud transcribes only after you let go.",
        "Mit Live-Text hängt beim Sprechen eine Karte mit deinem Text darunter.":
            "With live text, a card with your words hangs below it while you speak.",
        "Mit Live-Text klappt sie beim Sprechen auf und zeigt mit, was ankommt.":
            "With live text, it expands while you speak and shows what comes in.",
        "Menüleisten-Symbol beim Aufnehmen": "Menu Bar Icon While Recording",
        "Schlicht": "Plain",
        "Farbe": "Color",
        "Roter Punkt": "Red Dot",
        "Zeit": "Timer",
        "Das Symbol bleibt immer gleich. Dass aufgenommen wird, zeigt der orange Punkt von macOS neben dem Kontrollzentrum.":
            "The icon never changes. The orange dot macOS shows next to Control Center tells you it’s recording.",
        "Das Mikrofon färbt sich in der Farbe des Modus: Diktat violett, Prompt türkis, Befehl bernstein. Bei stummem Ton steht ein durchgestrichener Lautsprecher daneben.":
            "The microphone takes the color of the mode: violet for dictation, teal for prompt, amber for command. When sound is muted, a crossed-out speaker appears next to it.",
        "Das Mikrofon bekommt einen kleinen roten Aufnahmepunkt, wie bei Bildschirmaufnahmen. Bei stummem Ton steht ein durchgestrichener Lautsprecher daneben.":
            "The microphone gets a small red recording dot, like during a screen recording. When sound is muted, a crossed-out speaker appears next to it.",
        "Das Symbol wird zur Kapsel mit laufender Zeit. Am auffälligsten, braucht aber mehr Platz in der Menüleiste.":
            "The icon turns into a capsule with a running timer. The most visible option, but it takes more room in the menu bar.",
        // the live-text sample in the island preview
        "Den Termin am Donnerstag kann ich leider ": "Unfortunately I can’t make the meeting on ",
        "nicht wahrnehmen, nein, ich meine Freitag": "Thursday, no, wait, Friday",

        // Wellenform
        "Fein": "Fine",
        "Symmetrisch": "Symmetric",
        "Linie": "Line",
        "Folgt deiner Stimme live": "Follows your voice live",
        "Aus: ruhige Animation statt echtem Pegel": "Off: a calm animation instead of your real level",

        // Alcove
        "Läuft gerade": "Running",
        "Läuft gerade nicht": "Not running",
        "Automatisch": "Automatic",
        "Ausweichen": "Step Aside",
        "Übernehmen": "Take Over",
        "VoiceBud nimmt die Notch, solange Alcove dort nichts zeigt. Spielt gerade Musik und Alcove zeigt sie an, erscheint VoiceBud als Kapsel direkt darunter. In Alcove musst du nichts umstellen.":
            "VoiceBud uses the notch while Alcove shows nothing there. If music is playing and Alcove shows it, VoiceBud appears as a capsule right below. Nothing to change in Alcove.",
        "Alcove behält die Notch. VoiceBud erscheint als Kapsel direkt darunter, Live-Text hängt als Karte darunter. In Alcove musst du nichts umstellen.":
            "Alcove keeps the notch. VoiceBud appears as a capsule right below it, with live text in a card underneath. Nothing to change in Alcove.",
        "Während du diktierst, gehört die Notch VoiceBud. Stell dafür in Alcove unter „Idle Activity“ auf „None“, sonst liegen zwei Inseln übereinander.":
            "While you dictate, the notch belongs to VoiceBud. In Alcove, set “Idle Activity” to “None”, otherwise two islands sit on top of each other.",

        // Bildschirmkontext
        "Nur App": "App Only",
        "Text am Cursor": "Text at Cursor",
        "Ganzes Fenster": "Whole Window",
        "Fenster": "Window",
        "VoiceBud liest nichts vom Bildschirm.": "VoiceBud reads nothing from the screen.",
        "VoiceBud sieht nur, in welcher App du schreibst, und wählt danach den Stil.":
            "VoiceBud only sees which app you’re writing in and picks the style to match.",
        "Empfohlen. Dazu der Text vor und nach dem Cursor, markierter Text sowie Empfänger und Betreff. So stimmen Namen, Anrede und Anschluss.":
            "Recommended. Plus the text before and after the cursor, selected text, and the recipient and subject. Names, greetings and flow come out right.",
        "Dazu der sichtbare Text im aktiven Fenster, etwa ein Chatverlauf. So stimmen auch Namen aus dem Gespräch.":
            "Plus the visible text in the active window, such as a chat. Names from the conversation come out right too.",
        "Im Prompt-Modus": "In Prompt Mode",
        "„Diese Mail“ dazusagen": "Say “this email”",
        "Sagst du „diese Mail“, „dieser Text“ oder „das hier“, liest VoiceBud für dieses eine Diktat das ganze Fenster und hängt den Text wörtlich unter den Prompt. Markierter Text kommt immer mit.":
            "Say “this email”, “this text” or “this message”, and VoiceBud reads the whole window for that one dictation and adds the text word for word below the prompt. Selected text always comes along.",
        "Electron-Apps freischalten": "Unlock Electron apps",
        "Claude, Slack und Co. zeigen ihren Text erst, wenn VoiceBud sie beim Wechsel nach vorne freischaltet.":
            "Claude, Slack and others only share their text once VoiceBud unlocks them as you switch to them.",
        "Standard": "Default",
        "Eigene Wahl": "Custom",
        "Zurücksetzen": "Reset",
        "Weitere App": "Another app",
        "App hinzufügen …": "Add App…",
        "Eine App aus dem Programme-Ordner auswählen. Sie liest dann das ganze Fenster.":
            "Choose an app from the Applications folder. It then reads the whole window.",
        "Immer ausgenommen": "Always excluded",
        "Passwörter, Schlüsselbund, 1Password, Bitwarden und VoiceBud selbst, dazu Passwortfelder, sichere Eingabe und private Fenster.":
            "Passwords, Keychain Access, 1Password, Bitwarden and VoiceBud itself, plus password fields, secure input and private windows.",
        "Alles bleibt auf diesem Mac und wird nach dem Einfügen sofort verworfen. Im Verlauf steht nie, was VoiceBud gelesen hat.":
            "Everything stays on this Mac and is discarded right after pasting. The history never shows what VoiceBud read.",

        // Allgemein
        "Sprache": "Language",
        "Oberfläche": "Interface",
        "Sprache von Hub, Insel, Menü und Einrichtung": "Language of the hub, island, menu and setup",
        "Wie macOS": "System",
        "Automatisch erkennt Deutsch oder Englisch je Aufnahme": "Automatic picks German or English for each take",
        "Deutsch": "German",
        "Englisch": "English",
        "Texterkennung mit ⇧⌘2": "Text recognition with ⇧⌘2",
        "Erkannte Texte im Verlauf": "Recognized text in history",
        "Formeln je App": "Formulas per App",
        "Erkannte Texte": "Recognized Text",
        "Formeln": "Formulas",
        "⌥ antippen beim Aufziehen": "Tap ⌥ While Choosing",
        "Nach ⇧⌘2 schaltet ⌥ zwischen Text und Formeln um, die Insel zeigt, was gilt. Brüche, Hochzahlen, Wurzeln und der Text drumherum, gelesen vom lokalen Sprachmodell.":
            "After ⇧⌘2, ⌥ switches between text and formulas, and the island shows which one applies. Fractions, powers, roots and the text around them, read by the local language model.",
        "Bereich aufziehen, der Text landet in der Zwischenablage": "Drag over an area and the text goes to the clipboard",
        "Formel": "Equation",
        "Zeichen": "Characters",
        "Eine App aus dem Programme-Ordner auswählen und festlegen, was dort ankommt.": "Pick an app from the Applications folder and choose what it receives.",
        "LaTeX für Apps, die Formeln selbst setzen, etwa Claude, ChatGPT oder Overleaf im Browser. Formel wird zur echten, bearbeitbaren Formel, getestet mit Word. Zeichen geht überall, etwa σ² oder √(x + 1).":
            "LaTeX for apps that typeset formulas themselves, such as Claude, ChatGPT or Overleaf in a browser. Equation becomes a real, editable equation, tested with Word. Characters work everywhere, such as σ² or √(x + 1).",
        "Eigener Verlauf, getrennt von den Diktaten": "A separate history, apart from your dictations",
        "Verhalten": "Behavior",
        "Start- und Stopp-Ton": "Start and stop sound",
        "Leiser Ton beim Drücken und beim Loslassen": "A soft sound when you press and when you let go",
        "Im Vollbild ausblenden": "Hide in full screen",
        "Keine Insel, solange eine App im Vollbild läuft": "No island while an app is in full screen",
        "Ton aus während der Aufnahme": "Mute sound while recording",
        "Musik und Videos schweigen, solange du diktierst": "Music and videos go quiet while you dictate",
        "Ton bleibt an bei": "Keep Sound On For",
        "Ist sie vorne oder spielt sie Ton (etwa ein Anruf), bleibt der Ton an.":
            "When it’s in front or playing sound (like a call), sound stays on.",
        "Speicher": "Memory",
        "Modelle im RAM halten": "Keep models in RAM",
        "Aus spart RAM: Whisper wird nach 10 Minuten Leerlauf entladen, das Sprachmodell für die Aufbereitung nach 5 Minuten. Beide laden beim nächsten Diktat nach.":
            "Off saves RAM: Whisper unloads after 10 idle minutes, the cleanup model after 5. Both reload with your next dictation.",
        "Kurzbefehle": "Keyboard Shortcuts",
        "Text markieren, halten, sagen was passieren soll": "Select text, hold, say what should happen",
        "Diktat und Prompt: einmal drücken zum Starten, nochmal zum Beenden. Befehl: halten, sprechen, loslassen. Die Tasten legst du in config.yaml fest.":
            "Dictation and Prompt: press once to start, again to stop. Command: hold, speak, let go. Set the keys in config.yaml.",
    ]
}
