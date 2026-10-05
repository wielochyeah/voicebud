import json
import unittest

import _util  # noqa: F401  (sets sys.path + temp data dir)
from dictionary import Dictionary, phonetic

TERMS = ["AI-Slop", "shadcn", "FS-SC", "Alvantiq", "myPACE", "ACAR", "Repo", "Slides",
         "Excel-Sheet", "To-do-Liste", "Deadline", "Feedback", "deployen"]

# Whisper transcripts of the bench recordings (non-streaming run, 03.10.2026)
NILS_RAW = (
    "Ja, also ich habe nochmal eine Aufgabe für dich, so eine kleine Task. Und zwar wäre es halt "
    "ganz cool, wenn wir jetzt hier in dem Repo nochmal schauen könnten, ob der Code wirklich "
    "komplett clean ist. Und dann, also ob da kein AI-Slog drin ist, ob die eine geile "
    "Repo-Struktur hat. Ob, wenn ich das jetzt dem Kunden schicken würde, ob der es geil findet, "
    "dann schaue ich nochmal nach technischen Schwächen und so. das wäre eigentlich ganz cool genau "
    "also das das wäre ganz cool ja und schau auch mal dass du geile Slides daraus machst dass du "
    "ein Excel-Sheet daraus machst dass du mir eine To-Do-Liste erstellst dass du mir eine "
    "Dokumentation von einem Code machst und achte immer darauf dass kein AI-Slot drin ist nicht "
    "diese komischen Mittelpunkte nicht diese Headlines in Caps und so. Das wäre eigentlich alles "
    "schon ganz cool. Schau logischerweise, dass du nur ChatCN-Komponenten nimmst, nichts anderes. "
    "Und das halt für in dem FSSC-Design nur. Dafür schaut ihr einfach alles an.")
BENCH_SENTENCES = [
    "Also ich wollte nochmal kurz über das Projekt sprechen. Wir haben jetzt die ersten Ergebnisse "
    "aus der Umfrage und die sehen eigentlich ganz gut aus. Ungefähr 70% der Teilnehmer sind "
    "zufrieden mit dem neuen Prozess. Trotzdem sollten wir halt nochmal über die Details reden, "
    "weil ein paar Rückmeldungen kritisch waren.",
    "Ich schicke dir das Feedback zum Deadline-Meeting noch heute, und dann deployen wir am Freitag.",
    "Let's move the deadline to next Wednesday, because the client hasn't sent the files yet.",
    "Okay, ja genau, mach das so, und schick mir die Datei bis morgen.",
]
NORMAL_GERMAN = [
    "Gestern habe ich mit meiner Kollegin über den Quartalsbericht gesprochen. Wir müssen die "
    "Zahlen bis Freitag prüfen, weil der Vorstand am Montag eine Entscheidung treffen will. "
    "Außerdem fehlen noch die Rückmeldungen aus dem Vertrieb, und ohne die können wir keine "
    "verlässliche Prognose abgeben. Ich schlage vor, dass wir uns morgen um zehn Uhr kurz "
    "abstimmen und dann die offenen Punkte verteilen.",
    "Der Bauer pflügt seinen Acker, während im Schatten der alten Eiche zwei Kinder spielen. Die "
    "Akte liegt noch auf dem Schreibtisch, der Reporter wartet auf ein Interview, und der Rapport "
    "des Teams kommt später. Im Slot um vierzehn Uhr stellt die Agentur ihren neuen Slogan vor.",
    "Die Deadlines verschieben sich, das Feedback kam spät, und die Repos sind noch nicht "
    "aufgeräumt. Auf der Slide fehlt eine Quelle, aber die anderen Slides sind fertig. Wir "
    "deployen erst, wenn alle Tests grün sind. Die Feedbacks der Kunden lesen wir am Abend.",
    "Die EU, die ARD und die KI-Strategie der Bundesregierung waren Thema. Das FSC-Siegel steht "
    "auf dem Papier, SAP liefert die Daten, und die USA ziehen nach. Schade, dass Schatz und "
    "Schaden so ähnlich klingen, aber die Sache ist schnell erledigt.",
    "Meine Schwester arbeitet als Ärztin in einer Klinik am Stadtrand. Sie erzählt oft von langen "
    "Nächten, schwierigen Entscheidungen und kleinen Momenten, die alles wieder gutmachen. Wenn "
    "sie frei hat, fährt sie mit dem Fahrrad an den See, liest ein Buch und trinkt Kaffee.",
    "Let's schedule the meeting for Friday. The repo is clean, the slides look great, and the "
    "feedback from the client was positive. Please deploy the fix after lunch.",
]


class DictionaryTest(unittest.TestCase):
    def setUp(self):
        self.d = Dictionary(TERMS)

    def test_required_corrections(self):
        cases = {
            "AI-Slog": "AI-Slop", "AI-Slot": "AI-Slop", "AI Slot": "AI-Slop", "ai slop": "AI-Slop",
            "ChatCN": "shadcn", "Chat CN": "shadcn", "ChatCN-Komponenten": "shadcn-Komponenten",
            "Chat-CN-Komponenten": "shadcn-Komponenten",
            "FSSC": "FS-SC", "FSSC-Design": "FS-SC-Design", "FS SC": "FS-SC",
            "To-Do-Liste": "To-do-Liste", "Alvantik": "Alvantiq", "My Pace": "myPACE",
            "nimm nur Shadcn-Komponenten": "nimm nur shadcn-Komponenten",
        }
        for wrong, right in cases.items():
            with self.subTest(wrong=wrong):
                self.assertEqual(self.d.correct(wrong), right)

    def test_in_sentence(self):
        self.assertEqual(self.d.correct("dass kein AI Slot drin ist, nur Chat CN und das FSSC Design."),
                         "dass kein AI-Slop drin ist, nur shadcn und das FS-SC Design.")

    def test_nils_transcript_changes_only_the_terms(self):
        out = self.d.correct(NILS_RAW)
        expected = (NILS_RAW.replace("AI-Slog", "AI-Slop").replace("AI-Slot", "AI-Slop")
                    .replace("ChatCN", "shadcn").replace("FSSC", "FS-SC")
                    .replace("To-Do-Liste", "To-do-Liste"))
        self.assertEqual(out, expected)

    def test_ordinary_text_unchanged(self):
        for text in BENCH_SENTENCES + NORMAL_GERMAN:
            with self.subTest(text=text[:40]):
                self.assertEqual(self.d.correct(text), text)

    def test_inflections_and_sentence_start_left_alone(self):
        for text in ["Repos", "Feedbacks", "deploy", "Slide", "To-Do-Listen", "Shadcn ist gut.",
                     "the repo", "slides"]:
            with self.subTest(text=text):
                self.assertEqual(self.d.correct(text), text)

    def test_real_word_groups_and_names_stay(self):
        for text in ["Please delete that line from the file.", "Move that line up.",
                     "Herr Acar kommt morgen.", "Der Acar-Bericht liegt vor."]:
            with self.subTest(text=text):
                self.assertEqual(self.d.correct(text), text)

    def test_a_term_protects_itself(self):
        d = Dictionary(TERMS + ["AI-Slot", "Acar"])
        self.assertEqual(d.correct("Ich baue die Folie für den AI-Slot in der Vollversammlung."),
                         "Ich baue die Folie für den AI-Slot in der Vollversammlung.")
        self.assertEqual(d.correct("Herr Acar kommt morgen."), "Herr Acar kommt morgen.")
        self.assertEqual(d.correct("kein AI-Slog drin"), "kein AI-Slop drin")   # still corrected
        self.assertEqual(d.correct("ACAR läuft"), "ACAR läuft")

    def test_idempotent(self):
        once = self.d.correct(NILS_RAW)
        self.assertEqual(self.d.correct(once), once)

    def test_phonetic_skeleton(self):
        self.assertEqual(phonetic("ChatCN"), phonetic("shadcn"))
        self.assertEqual(phonetic("FSSC"), phonetic("FS-SC"))
        self.assertNotEqual(phonetic("Schatten"), phonetic("shadcn"))

    def test_load_from_file(self):
        path = _util.Path(_util.os.environ["VOICEBUD_DATA_DIR"]) / "dict-test.json"
        path.write_text(json.dumps({"terms": ["AI-Slop", "", 3, "AI-Slop", "shadcn"]}))
        d = Dictionary.load(path)
        self.assertEqual(d.terms, ["AI-Slop", "shadcn"])
        path.write_text("{broken")
        d.reload()
        self.assertEqual(d.terms, [])
        self.assertEqual(d.correct("AI Slot"), "AI Slot")


if __name__ == "__main__":
    unittest.main()
