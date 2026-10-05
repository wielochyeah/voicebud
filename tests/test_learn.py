"""Sprachkürzel and the learning dictionary (no real text field is read)."""
import unittest
from unittest import mock

import _util  # noqa: F401
import learn
import snippets


class SnippetsTest(unittest.TestCase):
    S = [("meine Signatur", "Viele Grüße\nNils"), ("meine Adresse", "Musterweg 1, 60311 Frankfurt"),
         ("meine Adresse privat", "Zuhause 2")]

    def test_apply(self):
        self.assertEqual(snippets.apply("Meine Signatur.", self.S)[0], "Viele Grüße\nNils")
        self.assertEqual(snippets.apply("Schick es an meine Adresse, danke.", self.S)[0],
                         "Schick es an Musterweg 1, 60311 Frankfurt, danke.")
        self.assertEqual(snippets.apply("an meine Adresse privat bitte", self.S)[0], "an Zuhause 2 bitte")
        self.assertEqual(snippets.apply("Das ist meine Adresse. Danke.", self.S)[0],
                         "Das ist Musterweg 1, 60311 Frankfurt. Danke.")
        self.assertEqual(snippets.apply("Meine Adressen stimmen.", self.S)[0], "Meine Adressen stimmen.")


class LearnTest(unittest.TestCase):
    def test_corrections(self):
        self.assertEqual(learn.corrections("Hallo Frau Schimanska, danke.", "Hallo Frau Szymańska, danke. Bis bald"),
                         [("Schimanska", "Szymańska")])
        self.assertEqual(learn.corrections("Das ist gut so.", "Das ist super so."), [])       # a style edit
        self.assertEqual(learn.corrections("Das ist gut so.", "Das ist Gut so."), [])         # case only
        self.assertEqual(learn.corrections("Termin am Montag", "Termin am Dienstag"), [])     # another word
        # names macOS knows still count; ordinary lowercase words do not
        self.assertEqual(learn.corrections("Frag mal Cloud dazu.", "Frag mal Claude dazu."), [("Cloud", "Claude")])
        self.assertEqual(learn.corrections("Ich glaube das es klappt.", "Ich glaube dass es klappt."), [])
        self.assertEqual(learn.corrections("Das ist für Mai Pace.", "Das ist für myPACE."), [("Mai Pace", "myPACE")])

    def test_watch_learns_a_stable_correction(self):
        pasted = "Hallo Frau Schimanska, danke."
        states = iter([pasted, "Hallo Frau Szymańska, danke.", "Hallo Frau Szymańska, danke."])
        learned = []
        lr = learn.Learner(lambda heard, corrected, *_phrase: learned.append((heard, corrected)))
        with mock.patch.object(learn.Learner, "_locate", return_value=("field", 0, 200)), \
                mock.patch.object(learn.Learner, "_read", side_effect=lambda *a: next(states, None)), \
                mock.patch.object(learn.context, "frontmost", return_value={"pid": 7}), \
                mock.patch.object(learn.context, "ax", return_value=None), \
                mock.patch.object(learn.context, "readable_now", return_value=True), \
                mock.patch.object(learn.time, "sleep"):
            lr._run(lr._gen, 7, pasted)
        self.assertEqual(learned, [("Schimanska", "Szymańska")])

    def _run(self, states, pid=7, fronts=None, allowed=lambda app: True):
        learned = []
        lr = learn.Learner(lambda heard, corrected, *_phrase: learned.append((heard, corrected)), allowed=allowed)
        states = iter(states)
        fronts = iter(fronts) if fronts is not None else None
        front = (lambda *_: next(fronts, {"pid": 9, "bundle": "x"})) if fronts is not None else (lambda *_: {"pid": 7})
        with mock.patch.object(learn.Learner, "_locate", return_value=("field", 0, 200)) as loc, \
                mock.patch.object(learn.Learner, "_read", side_effect=lambda *a: next(states, None)), \
                mock.patch.object(learn.context, "frontmost", side_effect=front), \
                mock.patch.object(learn.context, "ax", return_value=None), \
                mock.patch.object(learn.context, "readable_now", return_value=True), \
                mock.patch.object(learn.time, "sleep"):
            lr._run(lr._gen, pid, self.P)
        return learned, loc

    P = "Wir laden die Kurse von Tingo und schicken sie an Frau Schimanska."

    def test_several_corrections_one_after_another(self):
        one = self.P.replace("Tingo", "Tiingo")
        two = one.replace("Schimanska", "Szymańska")
        learned, _ = self._run([self.P, one, one, two, two])
        self.assertEqual(learned, [("Tingo", "Tiingo"), ("Schimanska", "Szymańska")])

    def test_neighbouring_words(self):
        self.assertEqual(learn.corrections("Wir nutzen Tingo Abi heute.", "Wir nutzen Tiingo API heute."),
                         [("Tingo", "Tiingo"), ("Abi", "API")])

    def test_clipboard_text_followed_into_the_app_it_is_pasted_in(self):
        fixed = self.P.replace("Tingo", "Tiingo")
        fronts = [{"pid": 5, "bundle": "com.1password"}, {"pid": 9, "bundle": "x"}] + [{"pid": 9, "bundle": "x"}] * 10
        learned, loc = self._run([self.P, fixed, fixed], pid=None, fronts=fronts,
                                 allowed=lambda app: app["pid"] != 5)
        self.assertEqual(loc.call_args[0][1], 9)          # never read the app it may not read
        self.assertEqual(learned, [("Tingo", "Tiingo")])

    def test_clipboard_text_never_pasted(self):
        learned, loc = self._run([], pid=None, fronts=[], allowed=lambda app: False)
        loc.assert_not_called()
        self.assertEqual(learned, [])

    def test_name_of_several_words(self):
        self.assertEqual(learn.corrections("Wir testen Wispaflow heute.", "Wir testen Wispr Flow heute."),
                         [("Wispaflow", "Wispr Flow")])
        self.assertEqual(learn.corrections("Frag Hackingface dazu.", "Frag Hugging Face dazu."),
                         [("Hackingface", "Hugging Face")])
        # ordinary words, not names: never learned
        self.assertEqual(learn.corrections("Ich bin zuhause.", "Ich bin zu Hause."), [])
        self.assertEqual(learn.corrections("Die Haustür klemmt.", "Die Haus Tür klemmt."), [])

    def test_learned_name_of_several_words_corrects_later_takes(self):
        import tempfile, json
        from pathlib import Path
        from dictionary import Dictionary
        path = Path(tempfile.mkdtemp()) / "dictionary.json"
        path.write_text(json.dumps({"terms": []}))
        d = Dictionary.load(path)
        self.assertTrue(d.add_term("Wispr Flow"))
        self.assertEqual(d.correct("Wir testen Wispaflow heute."), "Wir testen Wispr Flow heute.")
        self.assertEqual(d.correct("mit wispr flow"), "mit Wispr Flow")
        self.assertEqual(d.correct("Whisper ist ein Modell"), "Whisper ist ein Modell")

    def test_rewrite_is_not_a_correction(self):
        # command mode translated the text while the learner still watched (Challenge 04.10.)
        de = "Das Projekt startet im Mai und wir liefern bis Montag."
        en = "The Project starts in May and we deliver by Monday."
        self.assertEqual(learn.corrections(de, en), [])

    def test_fragments_and_inflections_are_not_learned(self):
        self.assertFalse(learn.worth_learning("Danke", "anke"))
        self.assertFalse(learn.worth_learning("Unterlage", "Unterlagen"))
        self.assertTrue(learn.worth_learning("Tingo", "Tiingo"))
        self.assertTrue(learn.worth_learning("Wisprflow", "Wispr Flow"))

    def test_edit_before_the_text_does_not_shift_the_watch(self):
        # an edit in front of the pasted text used to shift a fixed window: "Danke" read as "anke"
        pasted = "Danke für die Tingo Daten von heute."
        field1 = "Hallo Anna, " + pasted
        field2 = "Hallo Anna " + pasted.replace("Tingo", "Tiingo")    # comma deleted, word fixed
        lr_learned = []
        lr = learn.Learner(lambda h, c, *_: lr_learned.append((h, c)))
        states = iter([field1, field2, field2])
        with mock.patch.object(learn.Learner, "_locate", return_value=("field", 12, len(pasted))), \
                mock.patch.object(learn.Learner, "_read", side_effect=lambda *a: next(states, None)), \
                mock.patch.object(learn.context, "frontmost", return_value={"pid": 7}), \
                mock.patch.object(learn.context, "ax", return_value=None), \
                mock.patch.object(learn.context, "readable_now", return_value=True), \
                mock.patch.object(learn.time, "sleep"):
            lr._run(lr._gen, 7, pasted)
        self.assertEqual(lr_learned, [("Tingo", "Tiingo")])

    def test_first_word_corrected(self):
        pasted = "Tingo liefert die Kurse für uns heute."
        self.assertEqual(learn.find_pasted(pasted, "x " + pasted.replace("Tingo", "Tiingo"), 0.6)[0], 2)

    def test_private_window_stops_the_watch(self):
        fixed = self.P.replace("Tingo", "Tiingo")
        learned = []
        lr = learn.Learner(lambda h, c, *_: learned.append((h, c)))
        states = iter([self.P, fixed, fixed])
        with mock.patch.object(learn.Learner, "_locate", return_value=("field", 0, 200)), \
                mock.patch.object(learn.Learner, "_read", side_effect=lambda *a: next(states, None)), \
                mock.patch.object(learn.context, "frontmost", return_value={"pid": 7}), \
                mock.patch.object(learn.context, "ax", return_value=None), \
                mock.patch.object(learn.context, "readable_now", side_effect=[True, False, False, False]), \
                mock.patch.object(learn.time, "sleep"):
            lr._run(lr._gen, 7, self.P)
        self.assertEqual(learned, [])

    def test_misheard_names_become_exact_fixes(self):
        # 04.10.: "USB-Flow" for "WhisperFlow" was not learned (not spelled alike)
        ok = [("Ich nutze USB-Flow seit gestern.", "Ich nutze WhisperFlow seit gestern.", ("USB-Flow", "WhisperFlow")),
              ("Ich nutze USB-Flow seit gestern.", "Ich nutze Whisper-Flow seit gestern.", ("USB-Flow", "Whisper-Flow")),
              ("Frag Clout Code dazu.", "Frag Claude Code dazu.", ("Clout Code", "Claude Code"))]
        for pasted, now, pair in ok:
            self.assertEqual(learn.corrections(pasted, now), [pair])
        # content edits are never learned: a lone word would rewrite every later use of it
        for pasted, now in [("Ich nutze Apple seit gestern.", "Ich nutze Google seit gestern."),
                            ("Das läuft über die API von OpenAI.", "Das läuft über die SDK von OpenAI."),
                            ("Wir nehmen das PDF im Anhang.", "Wir nehmen das DOCX im Anhang."),
                            ("Ich gehe ins Kino Berlin.", "Ich gehe ins Kino Hamburg."),
                            ("Termin mit Herrn Meier morgen.", "Termin mit Herrn Schulz morgen.")]:
            self.assertEqual(learn.corrections(pasted, now), [], now)


class ReplacementTest(unittest.TestCase):
    def test_neighbour_and_dictionary_fix(self):
        import tempfile, json
        from pathlib import Path
        from dictionary import Dictionary
        self.assertEqual(learn.with_neighbour("Frag Clout Code dazu", "Frag Claude Code dazu", "Clout", "Claude"),
                         ("Clout Code", "Claude Code"))
        path = Path(tempfile.mkdtemp()) / "dictionary.json"
        path.write_text(json.dumps({"terms": ["Claude"]}))
        d = Dictionary.load(path)
        self.assertTrue(d.add_replacement("Clout Code", "Claude Code"))
        self.assertEqual(d.correct("Ich nutze clout code jeden Tag."), "Ich nutze Claude Code jeden Tag.")
        self.assertEqual(d.correct("He has a lot of clout."), "He has a lot of clout.")     # no context, no fix
        self.assertEqual(json.loads(path.read_text())["terms"], ["Claude"])                 # terms kept


class _FakeField:
    """A focused text field as the accessibility API sees it: ranges in UTF-16 units."""
    def __init__(self, value):
        self.u = value.encode("utf-16-le")
        self.cursor = len(self.u) // 2

    def app(self, pid):
        return "app"

    def get(self, el, attr):
        return 0, "field"

    def multi(self, el, attrs):
        return 0, {"AXSubrole": None, "AXNumberOfCharacters": len(self.u) // 2,
                   "AXSelectedTextRange": (self.cursor, 0)}

    def range_of(self, value):
        return value

    def string_for_range(self, el, loc, length):
        return 0, self.u[2 * loc:2 * (loc + length)].decode("utf-16-le")


class LocateTest(unittest.TestCase):
    """04.10.: a pasted text with paragraphs and a list was not found in the Claude app, whose
    editor keeps it differently (blank lines collapsed), so nothing was learned."""
    PASTED = ("Kurzer Stand zu den Daten.\n\nWir nutzen Tingo für die Kurse:\n\n"
              "- Tagesschlusskurse\n- Dividenden\n\nDanach kommt der Export.")

    def test_rich_editor_layout(self):
        field = ("Davor stand schon etwas mit Daten und Kursen 😀. "
                 + self.PASTED.replace("\n\n", "\n").replace("- ", "• "))
        f = _FakeField(field)
        el, start, n = learn.Learner._locate(f, 7, self.PASTED)
        self.assertEqual(el, "field")
        got = f.string_for_range(el, start, n)[1]
        self.assertTrue(got.startswith("Kurzer Stand"), got)
        self.assertTrue(got.endswith("Export"), got)
        now = got.replace("Tingo", "Tiingo")
        self.assertEqual(learn.corrections(self.PASTED, now), [("Tingo", "Tiingo")])

    def test_plain_field(self):
        f = _FakeField("Hallo " + self.PASTED)
        el, start, n = learn.Learner._locate(f, 7, self.PASTED)
        self.assertEqual(f.string_for_range(el, start, n)[1], self.PASTED[:-1])   # up to the last word

    def test_not_there(self):
        f = _FakeField("Ganz anderer Text, der mit dem Diktat nichts zu tun hat.")
        self.assertEqual(learn.Learner._locate(f, 7, self.PASTED), (None, 0, 0))


if __name__ == "__main__":
    unittest.main()
