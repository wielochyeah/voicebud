"""cleanup.Cleaner against a fake worker process: protocol, latency rules, crash recovery."""
import sys
import time
import unittest

import yaml

import _util
from cleanup import Cleaner

FAKE = str(_util.ROOT / "tests" / "fake_llm_worker.py")


def cfg():
    return yaml.safe_load((_util.ROOT / "config.yaml").read_text())["llm"]


def wait(cond, timeout=5):
    t = time.time()
    while not cond():
        if time.time() - t > timeout:
            return False
        time.sleep(0.02)
    return True


class CleanerTest(unittest.TestCase):
    def make(self, *extra):
        c = Cleaner(cfg(), worker_cmd=[sys.executable, FAKE, *extra])
        self.addCleanup(c.shutdown)
        return c

    def test_clean_through_worker(self):
        c = self.make()
        c.warm()
        self.assertTrue(wait(c.is_ready))
        text = "ähm, das Meeting ist morgen um zehn Uhr im großen Raum."
        self.assertEqual(c.clean(text, "de", terms=[], style="mail"),
                         "Das Meeting ist morgen um zehn Uhr im großen Raum.")
        self.assertEqual(c.last_stats["tokens"], 10)

    def test_short_take_skips_the_llm(self):
        c = self.make()
        c.warm()
        self.assertTrue(wait(c.is_ready))
        self.assertEqual(c.clean("ähm, ja gut", "de"), "ähm, ja gut")
        self.assertEqual(c.last_stats, {})

    def test_cold_model_is_awaited_only_for_long_takes(self):
        c = self.make()
        mid = "ähm, das passt so für morgen früh"            # 7 words: not worth waiting for a load
        self.assertEqual(c.clean(mid, "de"), mid)
        self.assertFalse(c._alive(), "a short take must not start the model")
        long = "ähm, das Meeting ist morgen um zehn Uhr im großen Raum."
        self.assertEqual(c.clean(long, "de"), "Das Meeting ist morgen um zehn Uhr im großen Raum.")
        self.assertIn("load", c.last_stats)

    def test_crash_falls_back_and_restarts(self):
        c = self.make("--crash")
        c.warm()
        self.assertTrue(wait(c.is_ready))
        long = "ähm, das Meeting ist morgen um zehn Uhr im großen Raum."
        self.assertEqual(c.clean(long, "de"), long)
        self.assertTrue(wait(lambda: not c._alive()))
        c._worker_cmd = [sys.executable, FAKE]
        c.warm()
        self.assertTrue(wait(c.is_ready))
        self.assertEqual(c.clean(long, "de"), "Das Meeting ist morgen um zehn Uhr im großen Raum.")

    def test_prompt_mode_keeps_its_lines(self):
        c = self.make()
        out = c.promptify("mach mir einen Trainingsplan für zwölf Wochen", "de")
        self.assertEqual(out, "Rolle: Coach\n\nAufgabe: Plan")

    def test_disabled_returns_raw(self):
        conf = cfg()
        conf["enabled"] = False
        c = Cleaner(conf)
        self.assertEqual(c.clean("ähm, das Meeting ist morgen um zehn Uhr im großen Raum.", "de"),
                         "ähm, das Meeting ist morgen um zehn Uhr im großen Raum.")


class SpeculationTest(unittest.TestCase):
    """Challenge 2 (04.10.): a speculative request must never take the model from a real one."""

    def setUp(self):
        import threading
        self.threading = threading
        self.c = Cleaner({"enabled": True, "model": "x"}, worker_cmd=["true"])
        self.sent = []
        self.c._send = lambda msg: self.sent.append(msg) or True

    def test_stays_out_while_a_real_request_is_open(self):
        self.c._pending, self.c._tags = {1: [self.threading.Event(), None]}, {1: 7}
        ticket = {}
        self.assertIsNone(self.c._generate("s", "u", 10, 0.0, 1.0, ticket=ticket))
        self.assertEqual(self.sent, [])

    def test_timeout_of_a_speculation_never_kills_the_worker(self):
        killed = []

        class Proc:
            def kill(self):
                killed.append(1)
        self.c._proc = Proc()
        ticket = {}
        self.assertIsNone(self.c._generate("s", "u", 10, 0.0, 0.05, ticket=ticket))
        self.assertEqual(killed, [])
        self.assertTrue(ticket.get("cancelled"))

    def test_cancel_take_stops_only_that_take(self):
        self.c._pending = {1: [None, None], 2: [None, None], 3: [None, None]}
        self.c._tags = {1: 5, 2: 6, 3: "spec"}
        self.c.cancel_take(5)
        self.assertEqual(self.sent, [{"op": "cancel", "id": 1}])



class CommandTidyTest(unittest.TestCase):
    """Befehlsmodus (05.10. challenge): the tidying must never cut into the edited text itself."""

    def test_table_rows_are_not_collapsed(self):
        from cleanup import _tidy_command
        self.assertEqual(_tidy_command("| Export | yes | yes | yes |", "| Export | ja | ja | ja |"),
                         "| Export | yes | yes | yes |")

    def test_the_texts_own_first_line_is_no_preamble(self):
        from cleanup import _tidy_command
        sel = "Hier ist die Agnda für Montag:\n- Budget"
        self.assertEqual(_tidy_command("Hier ist die Agenda für Montag:\n- Budget", sel),
                         "Hier ist die Agenda für Montag:\n- Budget")
        self.assertEqual(_tidy_command("Hier ist der überarbeitete Text:\nSehr geehrte Frau Albers", "hi frau albers"),
                         "Sehr geehrte Frau Albers")

    def test_quotes_go_only_when_they_wrap_the_answer(self):
        from cleanup import _tidy_command
        self.assertEqual(_tidy_command("„Wir liefern pünktlich“, hat er gesagt", "„Wir liefern puenktlich“, hat er gesagt"),
                         "„Wir liefern pünktlich“, hat er gesagt")
        self.assertEqual(_tidy_command('"Dear Ms Albers"', "hi ms albers"), "Dear Ms Albers")

    def test_guards_language_and_meta(self):
        import cleanup
        self.assertEqual(cleanup._text_lang("Thanks a lot, I will sign the contract and send it to you"), "en")
        self.assertEqual(cleanup._text_lang("Danke, ich werde den Vertrag unterschreiben und dir schicken"), "de")
        self.assertTrue(cleanup._META.search("Das Wetter ist nicht im Text angegeben."))
        self.assertFalse(cleanup._META.search("Der Text beschreibt die Quartalszahlen."))   # a summary stays
        self.assertTrue(cleanup._TRANSLATE.search("übersetz das ins Englische"))
        self.assertFalse(cleanup._TRANSLATE.search("mach das förmlicher"))
        for asks in ("mach eine englische Version daraus", "schreib das als englische Mail", "die deutsche Fassung bitte",
                     "auf Spanisch bitte", "mach das auf französisch", "in French please"):
            self.assertTrue(cleanup._TRANSLATE.search(asks), asks)
        # review 05.10.: an ordinary sentence with "nicht enthalten" is no answer about the text
        self.assertFalse(cleanup._META.search("Die Anfahrt ist im Preis nicht enthalten."))
        self.assertFalse(cleanup._META.search("| Lieferzeit | nicht angegeben |"))
        self.assertTrue(cleanup._META.search("Im Text wird kein Datum genannt."))
        # a German note quoting an English mail is neither language: no retry
        self.assertIsNone(cleanup._text_lang("Kurz zur Info für dich, der Kunde hat mir das geschrieben und ich wollte "
                                             "es dir noch zeigen: Thanks for the update, we will review it and get back to you."))

if __name__ == "__main__":
    unittest.main()
