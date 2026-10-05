"""main.VoiceBud without microphone, LLM or UI: what the island is told after a take."""
import os
import sqlite3
import time
import unittest

import yaml

import _util


class ProcessTest(unittest.TestCase):
    def setUp(self):
        os.environ["VOICEBUD_UI"] = "/nonexistent"     # headless bridge
        import main
        self.main = main
        cfg = yaml.safe_load((_util.ROOT / "config.yaml").read_text())
        cfg["llm"]["enabled"] = False
        self.vb = main.VoiceBud(cfg, open_mic=False)
        import tempfile
        from pathlib import Path
        self.vb.dictionary.path = Path(tempfile.mkdtemp(prefix="vb-main-")) / "dictionary.json"  # learned words stay here
        self.vb.dictionary.set_terms([])
        self.vb.dictionary.set_replacements({})
        self.states, self.pasted = [], []
        self.vb.ui.state = lambda phase, mode=None, **kw: self.states.append((phase, kw))
        self._inject, self._target = main.inject.inject, main.paste_target
        self._copy, self._front = main.inject.copy_only, main.context.frontmost
        self.copied, self.front_pid = [], 7
        main.inject.inject = lambda text, c: self.pasted.append(text)
        main.inject.copy_only = lambda text: self.copied.append(text)
        main.context.frontmost = lambda own=(): {"pid": self.front_pid, "name": "Mail", "bundle": "com.apple.mail", "path": ""}
        main.paste_target = lambda *_: "pasted"

    def tearDown(self):
        self.main.inject.inject, self.main.paste_target = self._inject, self._target
        self.main.inject.copy_only, self.main.context.frontmost = self._copy, self._front
        self.vb.worker.shutdown()
        self.vb.history.close()
        os.environ.pop("VOICEBUD_UI", None)

    def _take(self, text):
        from stream import TakeResult

        class FakeTake:
            def finish(self):
                return TakeResult(text, "de", 1, 3.0, 0.1, 1, 0)
        return FakeTake()

    def _empty(self, audio_s):
        from stream import TakeResult

        class FakeTake:
            def finish(self):
                return TakeResult("", None, 0, audio_s, 0.1, 0, 0)
        return FakeTake()

    def test_long_selection_is_refused(self):
        # Challenge 04.10.: the snapshot keeps 4000 characters, so a longer selection was replaced
        # by the edited first 4000 and the rest was gone
        self.vb.seq = 1
        self.vb._ctx = {1: self._snap(selected="x" * 4000, selected_len=10000)}
        self.vb.cleaner.command = lambda *a: "y"
        self.vb._process(self._take("mach das förmlicher"), "command", time.time(), "Mail", 1, pid=7)
        self.assertEqual(self.pasted, [])
        self.assertIn("zu lang", self.states[-1][1]["message"])

    def test_empty_takes_say_why(self):
        for audio_s, peak, phase, message in ((0.3, 0.0, "empty", None),
                                              (3.0, 0.0, "error", "Kein Ton vom Mikrofon, Eingang prüfen"),
                                              (3.0, 0.02, "error", "Nichts verstanden")):
            self.vb.seq += 1
            self.vb._process(self._empty(audio_s), "dictate", time.time(), "Mail", self.vb.seq, peak=peak)
            self.assertEqual(self.states[-1][0], phase)
            self.assertEqual(self.states[-1][1].get("message"), message)

    def test_error_after_transcription_keeps_the_words(self):
        self.vb.seq = 1
        self.vb.cleaner.clean = lambda *a, **k: 1 / 0
        self.vb._process(self._take("Das Angebot kommt morgen früh, versprochen."), "dictate", time.time(), "Mail", 1)
        self.assertEqual(self.copied, ["Das Angebot kommt morgen früh, versprochen."])
        self.assertEqual(self.states[-1][0], "error")
        self.assertIn("Zwischenablage", self.states[-1][1]["message"])

    def test_locked_screen_take_goes_to_the_clipboard(self):
        self.vb.seq = 1
        self.vb._process(self._take("Das Angebot kommt morgen früh."), "dictate", time.time(), "Mail", 1,
                         pid=7, to_clipboard=True)
        self.assertEqual((self.pasted, self.copied), ([], ["Das Angebot kommt morgen früh."]))

    def test_context_leaves_ram_after_an_empty_take(self):
        self.vb.seq = 1
        snap = self._snap(before="geheimer Feldtext")
        self.vb._ctx, self.vb._ctx_threads = {1: snap}, {}
        self.vb._process(self._empty(2.0), "dictate", time.time(), "Mail", 1, peak=0.02)
        self.assertEqual(self.vb._ctx, {})
        self.assertEqual(snap.before, "")

    def test_cancelled_chord_pastes_nothing(self):
        aborted = []

        class FakeTake:
            def abort(self):
                aborted.append(1)
        self.vb.owner, self.vb.seq, self.vb.take = "dictate", 3, FakeTake()
        self.vb.worker.begin_take()
        self.vb.cancel_rec("dictate")
        self.assertIsNone(self.vb.owner)
        self.assertEqual(aborted, [1])
        self.assertEqual(self.states[-1][0], "idle")
        self.assertEqual(self.pasted + self.copied, [])

    def test_speculated_cleanup_only_with_equal_inputs(self):
        import threading
        cancelled = []
        self.vb.cleaner.cancel = lambda ticket: cancelled.append(ticket)
        key = ("Das Angebot kommt morgen.", "de", ("Claude",), "doc", None)

        def entry(result="Das Angebot kommt morgen.", ran=True):
            t = {"done": threading.Event(), "ran": ran, "result": result, "stats": {"tokens": 9}}
            t["done"].set()
            return {"key": key, "ticket": t}
        self.vb._spec_llm = {1: entry()}
        self.assertEqual(self.vb._speculated_clean(1, key, 1), "Das Angebot kommt morgen.")
        self.assertTrue(self.vb.cleaner.last_stats["speculative"])
        self.vb._spec_llm = {2: entry()}
        other = ("Das Angebot kommt morgen.", "de", ("Claude",), "mail", None)   # the app changed
        self.assertIsNone(self.vb._speculated_clean(2, other, 1))
        self.assertEqual(len(cancelled), 1)
        self.vb._spec_llm = {3: entry(ran=False)}                             # never reached the model
        self.assertIsNone(self.vb._speculated_clean(3, key, 1))

    def test_hotkey_cancels_a_slow_take(self):
        sent = []
        self.vb.cleaner.cancel_take = lambda seq: sent.append(("cancel", seq))
        self.vb.seq, self.vb._shown_seq = 5, 5
        self.vb._processing = {5: (time.monotonic() - 11, "dictate", 10.0)}    # 11 s, hint after 10 s
        self.vb.start_rec("dictate")
        self.assertIsNone(self.vb.owner, "the press cancels, it does not start a recording")
        self.assertEqual(sent, [("cancel", 5)])
        self.assertEqual(self.states[-1][1]["message"], "Abgebrochen, nichts eingefügt")
        self.vb._process(self._take("Das kam viel zu spät an."), "dictate", time.time(), "Mail", 5)
        self.assertEqual(self.pasted + self.copied, [])
        self.assertEqual(self.vb._cancelled, set())
        # a take within twice its usual time is not touched (it is only counted)
        self.vb._processing, self.vb._shown_seq = {6: (time.monotonic() - 11, "dictate", 30.0)}, 6   # usual 15 s
        self.assertFalse(self.vb._cancel_slow())

    def test_cancel_keeps_a_finished_transcript(self):
        self.vb.cleaner.cancel_take = lambda seq: None
        self.vb.seq, self.vb._shown_seq = 7, 7
        self.vb._processing = {7: (time.monotonic() - 12, "dictate", 10.0)}
        self.vb._raw = {7: "Das lange Diktat von eben."}
        self.vb.start_rec("dictate")
        self.assertEqual(self.copied, ["Das lange Diktat von eben."])
        self.assertEqual(self.states[-1][1]["message"], "Abgebrochen, Rohtext in der Zwischenablage")

    def test_fixed_dictation_language_reaches_the_take(self):
        # 05.10.: the hub's "Diktat: Deutsch / Englisch" fixes the language of the take; "auto"
        # leaves the choice to the take (config.yaml)
        seen = []
        real = self.main.Take

        class Recorder:
            def __init__(self, *a, language=None, **k):
                seen.append(language)

            def abort(self):
                pass
        self.main.Take = Recorder
        try:
            for value, expected in (("en", "en"), ("de", "de"), ("auto", self.vb.cfg["stt"].get("language"))):
                self.vb.settings["dictationLanguage"] = value
                self.vb.start_rec("dictate")
                self.vb.cancel_rec("dictate")
                self.assertEqual(seen[-1], expected)
        finally:
            self.main.Take = real

    def test_fixed_language_skips_detection(self):
        import stream

        class Fake:
            forced_lang, lang_final = "en", None

            class stt:
                @staticmethod
                def detect_language(*a):
                    raise AssertionError("no detection with a fixed language")
        self.assertEqual(stream.Take._language(Fake(), None, None, 1.0), "en")

    def test_usual_processing_time_is_learned(self):
        import tempfile
        from pathlib import Path
        path = Path(tempfile.mkdtemp()) / "speed.json"
        sp = self.main._Speed(path)
        self.assertAlmostEqual(sp.expected(20), 1.5 * (1.1 + 0.8))         # cautious before 3 takes
        for audio_s, took in ((20, 7.6), (60, 14.0), (10, 6.0)):            # an M1: about 4x
            sp.add(audio_s, took)
        self.assertGreater(sp.expected(60), 13)
        self.assertEqual(self.main._Speed(path).ratios, sp.ratios)            # kept across restarts
        self.assertGreater(max(10.0, 2 * sp.expected(60)), 25)                # no false alarm for a 1-min take

    def test_learned_words_fix_the_next_take(self):
        """Nils 04.10.: what the dictionary learns must really be used in the next dictations."""
        self.vb._learned("USB-Flow", "WhisperFlow", "USB-Flow", "WhisperFlow", exact=True)
        self.vb._learned("Tingo", "Tiingo", "Tingo", "Tiingo")
        self.vb._learned("Clout Code", "Claude Code", "Clout Code", "Claude Code", exact=True)
        for n, (said, want) in enumerate([("Ich nutze USB-Flow seit gestern für alles.", "WhisperFlow"),
                                          ("Ich nutze USB Flow seit gestern für alles.", "WhisperFlow"),
                                          ("Die Kurse kommen jeden Abend von Tingo.", "Tiingo"),
                                          ("Frag doch mal Clout Code nach dem Fehler.", "Claude Code")], start=1):
            self.vb.seq = n
            self.vb._process(self._take(said), "dictate", time.time(), "Mail", n)
            self.assertIn(want, self.pasted[-1], said)
        # and after a restart (the file, not only memory)
        from dictionary import Dictionary
        d = Dictionary.load(self.vb.dictionary.path) if getattr(self.vb.dictionary, "path", None) else Dictionary.load()
        self.assertIn("WhisperFlow", d.correct("Ich nutze USB-Flow."))

    def test_failure_after_paste_is_not_an_error(self):
        def boom(**_row):
            raise sqlite3.OperationalError("disk I/O error")
        self.vb.history.add = boom
        self.vb.seq = 1
        self.vb._process(self._take("Hallo Frau Becker, das Angebot kommt morgen."), "dictate", time.time(), "Mail", 1)
        self.assertEqual(self.pasted, ["Hallo Frau Becker, das Angebot kommt morgen."])
        self.assertEqual([p for p, _ in self.states], ["done"])

    def _snap(self, **kw):
        import context
        s = context.Snapshot({"pid": 7, "name": "Mail", "bundle": "com.apple.mail", "path": ""}, context.CURSOR)
        for k, v in kw.items():
            setattr(s, k, v)
        return s

    def test_context_is_used_and_never_stored(self):
        rows = []
        self.vb.history.add = lambda **row: rows.append(row)
        self.vb.seq = 1
        snap = self._snap(before="Wir haben das geprüft", after=" und melden uns.", names=["Szymańska"],
                          title="Re: Angebot")
        self.vb._ctx = {1: snap}
        self.vb._process(self._take("Und Frau Schimanska bekommt es morgen."), "dictate", time.time(), "Mail", 1, pid=7)
        self.assertEqual(self.pasted[-1], " und Frau Szymańska bekommt es morgen")
        done = [kw for p, kw in self.states if p == "done"][-1]
        self.assertEqual(done["context"]["label"], "Kontext aus Mail")
        self.assertIn(["Korrigiert", "Schimanska zu Szymańska"], done["context"]["rows"])
        self.assertNotIn("geprüft", str(done["context"]))
        self.assertEqual(snap.before, "")                 # cleared after the paste
        # prompt mode with a selection: material appended verbatim, never stored
        sel = self._snap(selected="Bitte bis Freitag das Angebot schicken.", title="Re: Angebot")
        self.vb.seq = 2
        self.vb._ctx = {2: sel}
        self.vb._process(self._take("Fass das kurz zusammen bitte"), "prompt", time.time(), "Mail", 2, pid=7)
        self.assertIn("<material quelle=\"Markierter Text aus Mail („Re: Angebot“)\">\nBitte bis Freitag das Angebot schicken.\n</material>",
                      self.pasted[-1])
        self.assertNotIn("Bitte bis Freitag", rows[-1]["final"])
        self.assertIn("nicht gespeichert", rows[-1]["final"])
        self.assertIn("warning", [kw for p, kw in self.states if p == "done"][-1]["context"])

    def test_other_app_in_front_gets_the_clipboard_only(self):
        self.vb.seq = 1
        self.front_pid = 99                     # the user switched apps while VoiceBud worked
        self.vb._process(self._take("Das Angebot kommt morgen früh."), "dictate", time.time(), "Mail", 1, pid=7)
        self.assertEqual((self.pasted, self.copied), ([], ["Das Angebot kommt morgen früh."]))
        self.assertEqual([kw for p, kw in self.states if p == "done"][-1]["target"], "clipboard")

    def test_command_mode(self):
        self.vb.seq = 1
        self.vb._ctx = {1: self._snap(selected="Hey, kannst du mir die Zahlen schicken?")}
        self.vb.cleaner.command = lambda instr, sel, lang: "Könnten Sie mir bitte die Zahlen schicken?"
        self.vb._process(self._take("förmlicher bitte"), "command", time.time(), "Mail", 1, pid=7)
        self.assertEqual(self.pasted[-1], "Könnten Sie mir bitte die Zahlen schicken?")
        done = [kw for p, kw in self.states if p == "done"][-1]
        self.assertEqual(done["context"]["rows"], [["Markierung", "39 Zeichen"]])
        # nothing selected, or the model failed: nothing is pasted, the selection stays
        for snap, cmd in ((self._snap(), lambda *a: "x"), (self._snap(selected="Text"), lambda *a: None)):
            self.vb.seq += 1
            self.vb._ctx = {self.vb.seq: snap}
            self.vb.cleaner.command = cmd
            n = len(self.pasted)
            self.vb._process(self._take("mach das kürzer"), "command", time.time(), "Mail", self.vb.seq, pid=7)
            self.assertEqual(len(self.pasted), n)
            self.assertEqual(self.states[-1][0], "error")

    def test_context_dropped_when_the_app_changed(self):
        self.vb.seq = 1
        self.front_pid = 99                     # Notizen came to the front before the stop
        self.vb._ctx = {1: self._snap(before="Wir haben das geprüft", names=["Szymańska"])}
        self.vb._process(self._take("Frau Schimanska bekommt es."), "dictate", time.time(), "Notizen", 1, pid=99)
        self.assertEqual(self.pasted[-1], "Frau Schimanska bekommt es.")
        done = [kw for p, kw in self.states if p == "done"][-1]
        self.assertEqual(done["context"]["label"], "Ohne Kontext, App gewechselt")

    def test_live_done_preview_keeps_lines(self):
        text = "Hallo Frau Becker,\n\nvielen Dank für die Rückmeldung.\n\nViele Grüße\nNils"
        self.vb.seq = 1
        self.vb._process(self._take(text), "dictate", time.time(), "Mail", 1, True)
        self.vb._process(self._take(text), "dictate", time.time(), "Mail", 1, False)
        live, plain = [kw["preview"] for p, kw in self.states if p == "done"]
        self.assertEqual(live, "Hallo Frau Becker,\nvielen Dank für die Rückmeldung.\nViele Grüße\nNils")
        self.assertNotIn("\n", plain)

    def test_done_carries_the_whole_final_text(self):
        # SPEC §0 (03.10.): the preview is cut, "text" is the pasted text in full (paragraphs kept),
        # so the confirmation can unfold to it on hover
        paragraph = ("Den Termin am Freitag kann ich leider nicht wahrnehmen, weil ich an dem Tag "
                     "den ganzen Vormittag beim Kunden in Frankfurt bin. ")
        text = "Hallo Frau Becker,\n\n" + paragraph * 4 + "\n\nViele Grüße\nNils"
        self.vb.seq = 1
        for live in (False, True):
            self.vb._process(self._take(text), "dictate", time.time(), "Mail", 1, live)
        dones = [kw for p, kw in self.states if p == "done"]
        self.assertEqual(len(dones), 2)
        for kw in dones:
            self.assertEqual(kw["text"], self.pasted[0])
            self.assertIn("\n\n", kw["text"])
            self.assertTrue(kw["preview"].endswith("…"))
            self.assertLess(len(kw["preview"]), len(kw["text"]))
        self.assertEqual(self.pasted[0], self.pasted[1])


if __name__ == "__main__":
    unittest.main()
