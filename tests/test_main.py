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

        class Worker:      # a real Take (no threads with stream=False), only the model is fake
            class stt:
                @staticmethod
                def detect_language(*a):
                    raise AssertionError("no detection with a fixed language")
        take = stream.Take(Worker(), language="en", stream=False)
        self.assertEqual(take._language(None, None, 1.0), "en")
        take.lang_final = None             # even if the detected language were cleared, fixed wins
        self.assertEqual(take._language(None, None, 1.0), "en")

    def test_formula_reaches_the_ui_in_three_renditions_and_the_history(self):
        """⇧⌘2 with ⌥ (05.10.): the model's Markdown goes to the UI as markdown, plain and html,
        and into the recognition's history; a missing model says "unavailable" (the UI then
        falls back to the usual recognition)."""
        sent, rows = [], []
        self.vb.ui.send = lambda msg: sent.append(msg)
        self.vb.history.add = lambda **row: rows.append(row)
        self.vb.cleaner.formula = lambda path: "Varianz $\\sigma^2$:\n\n$$z_a = \\frac{a - \\mu}{\\sigma}$$"
        self.vb._read_formula({"type": "formula", "id": 3, "path": "/tmp/x.png", "app": "Safari", "bundle": "com.apple.Safari"})
        r = [m for m in sent if m.get("type") == "formula_result"][-1]     # (history_changed follows)
        self.assertEqual(r["id"], 3)
        self.assertIn("$\\sigma^2$", r["markdown"])
        self.assertIn("σ²", r["plain"])
        self.assertIn("zₐ = (a − μ)/σ", r["plain"])
        self.assertEqual(r["html"].count("<math"), 2)
        self.assertEqual((rows[-1]["mode"], rows[-1]["lang"]), ("ocr", "formula"))
        self.assertIn("\\frac", rows[-1]["final"])
        self.vb.cleaner.formula = lambda path: None
        self.vb._read_formula({"type": "formula", "id": 4, "path": "/tmp/x.png"})
        self.assertEqual(sent[-1], {"type": "formula_result", "id": 4, "error": "unavailable"})
        self.vb.cleaner.formula = lambda path: "  "
        self.vb._read_formula({"type": "formula", "id": 5, "path": "/tmp/x.png"})
        self.assertEqual(sent[-1]["error"], "empty")

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



class HotkeyPauseTest(unittest.TestCase):
    """The hub records a new shortcut (10.10.): the core's chords are off meanwhile and come back
    with the new choice, also over a take that was running."""

    def setUp(self):
        ProcessTest.setUp(self)                         # the same headless VoiceBud, not its tests
        from PyObjCTools import AppHelper
        self._after, self._later, self._ptt = AppHelper.callAfter, AppHelper.callLater, self.main.PushToTalk
        self.later = []
        AppHelper.callAfter = lambda fn, *a: fn(*a)
        AppHelper.callLater = lambda delay, fn, *a: self.later.append((delay, fn))
        made = self.made = []

        class FakePTT:
            def __init__(self, key, on_press=None, on_release=None, mode="hold", **kw):
                self.key, self.mode, self.live = key, mode, False
                self.on_press_cb, self.on_release_cb = on_press, on_release
                made.append(self)

            def start(self):
                self.live = True
                return self

            def stop(self):
                self.live = False

        self.main.PushToTalk = FakePTT
        self.sent = []
        self.vb.ui.send = self.sent.append

    def tearDown(self):
        from PyObjCTools import AppHelper
        AppHelper.callAfter, AppHelper.callLater, self.main.PushToTalk = self._after, self._later, self._ptt
        ProcessTest.tearDown(self)

    def live(self):
        return {m: p.key for m, p in self.vb.ptts.items() if p.live}

    def test_pause_and_resume_with_the_new_choice(self):
        self.vb.install_hotkeys()
        self.assertEqual(self.live()["dictate"], "ctrl+shift")
        self.vb._hotkeys_pause(True)
        self.assertEqual(self.live(), {})
        self.assertFalse(any(p.live for p in self.made))
        self.vb.settings["shortcuts"] = {"dictate": "cmd_r"}
        self.vb.install_hotkeys()                       # the settings change arrives during the pause
        self.assertEqual(self.live(), {})
        self.vb._hotkeys_pause(False)
        self.assertEqual(self.live()["dictate"], "cmd_r")
        self.assertEqual(self.sent[-1]["hotkeys"]["dictate"], "cmd_r")
        self.assertEqual(self.vb.ui.hello["hotkeys"]["dictate"], "cmd_r")

    def test_resume_over_a_running_take(self):
        self.vb.install_hotkeys()
        self.vb._hotkeys_pause(True)
        self.vb.owner = "dictate"                       # recording when the pause ends
        self.vb._hotkeys_pause(False)
        self.assertIn("dictate", self.live())           # no waiting: there were no keys to keep
        self.vb.owner = None

    def test_changed_keys_wait_for_a_running_take(self):
        self.vb.install_hotkeys()
        self.vb.owner = "dictate"
        self.later.clear()
        self.vb.install_hotkeys()
        self.assertEqual([d for d, _ in self.later], [1.0])
        self.vb.owner = None

    def test_lost_resume_ends_the_pause(self):
        self.vb.install_hotkeys()
        self.vb._hotkeys_pause(True)
        delay, fn = self.later[-1]
        self.assertEqual(delay, 30.0)
        fn()
        self.assertIn("dictate", self.live())

    def test_key_from_the_ui(self):
        self.vb.settings["shortcuts"] = {"dictate": {"key": 13, "mods": 4096, "label": "⌃W"}}
        self.vb.install_hotkeys()
        self.assertEqual(self.sent[-1]["hotkeys"]["dictate"], "label:⌃W")
        started = []
        self.vb.start_rec = lambda m: started.append(("start", m))
        self.vb.stop_rec = lambda m: started.append(("stop", m))
        self.vb.install_hotkeys()                       # the callbacks above
        self.vb._hotkey("dictate", True)
        self.vb._hotkey("dictate", False)
        self.vb._hotkey("prompt", True)                 # a chord: not the UI's business
        self.assertEqual(started, [("start", "dictate")])
        self.vb._hotkeys_pause(True)
        self.vb._hotkey("dictate", True)                # paused: nothing
        self.assertEqual(started, [("start", "dictate")])

    def test_text_recognition_chord(self):
        self.vb.settings["shortcuts"] = {"ocr": "ctrl+alt+shift"}
        self.vb.install_hotkeys()
        self.assertEqual(self.live().get("ocr"), "ctrl+alt+shift")
        self.vb.ptts["ocr"].on_press_cb()
        self.assertEqual(self.sent[-1], {"type": "screen_text"})

    def test_inner_chord_is_strict(self):
        self.vb.settings["shortcuts"] = {"prompt": "ctrl+alt+shift"}
        self.vb.install_hotkeys()
        self.assertTrue(self.vb.ptts["dictate"].strict)            # ⌃⇧ lies inside ⌃⌥⇧
        self.assertFalse(self.vb.ptts["prompt"].strict)
        self.assertEqual(self.sent[-1]["standard"]["prompt"], "ctrl+alt")

    def test_text_recognition_key_makes_chords_strict(self):
        self.vb.settings["shortcuts"] = {"ocr": {"key": 17, "mods": 4096 | 2048 | 512, "label": "⌃⌥⇧T"}}
        self.vb.install_hotkeys()
        self.assertTrue(self.vb.ptts["dictate"].strict)            # ⌃⇧ inside ⌃⌥⇧T
        self.assertTrue(self.vb.ptts["prompt"].strict)             # ⌃⌥ inside ⌃⌥⇧T
        self.assertFalse(self.vb.ptts["command"].strict)
        self.vb.settings["shortcuts"] = {"dictate": "shift_r"}     # right ⇧ inside the standard ⇧⌘2
        self.vb.install_hotkeys()
        self.assertTrue(self.vb.ptts["dictate"].strict)
        self.vb.settings["screenText"] = False                     # off: no key, nothing strict
        self.vb.install_hotkeys()
        self.assertFalse(self.vb.ptts["dictate"].strict)

    def test_only_the_recognition_key_changed_reinstalls(self):
        calls = []
        self.vb.install_hotkeys = lambda: calls.append(1)
        import settings as st
        old = st.load
        st.load = lambda: dict(old(), shortcuts={"ocr": {"key": 17, "mods": 2304, "label": "⌥⌘T"}})
        try:
            self.vb.reload_settings()
        finally:
            st.load = old
        self.assertEqual(calls, [1])

    def test_defaults_never_strict(self):
        self.vb.install_hotkeys()
        self.assertFalse(any(getattr(p, "strict", False) for p in self.vb.ptts.values()))

    def test_old_timer_does_not_end_a_new_pause(self):
        self.vb.install_hotkeys()
        self.vb._hotkeys_pause(True)
        old = self.later[-1][1]
        self.vb._hotkeys_pause(False)
        self.vb._hotkeys_pause(True)
        old()
        self.assertEqual(self.live(), {})



class StopwatchTest(unittest.TestCase):
    """The stopwatch line (10.10.: testers on old Macs send it): new fields at the end, numbers only,
    and a broken probe never costs the line."""

    def test_machine_line(self):
        import main
        line = main.machine_line()
        self.assertTrue(line.startswith("machine: "))
        self.assertIn("GB", line)

    def test_line_with_and_without_probes(self):
        import io
        import contextlib
        import types
        import main
        vb = types.SimpleNamespace(cleaner=types.SimpleNamespace(last_stats={"tokens": 5, "prefix": 0.12, "cached": True}),
                                   stt=types.SimpleNamespace(last_temperature=0.0, last_encoder=(1, 1)))
        res = types.SimpleNamespace(audio_s=31.0, segments=2, partials=0, speculative=False)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main.VoiceBud._log(vb, res, 0.0, 1.0, 2.0, 2.1, "pasted")
            vb.stt = types.SimpleNamespace(last_temperature=0.0, last_encoder=3)        # broken probe
            vb.cleaner.last_stats = {}
            main.VoiceBud._log(vb, res, 0.0, 1.0, 2.0, 2.1, "pasted")
        first, second = out.getvalue().splitlines()
        self.assertTrue(first.endswith("| enc 1+1 reused, prefix 0.12s cached"))
        self.assertIn("STT after stop 1.00s", first)
        self.assertTrue(second.endswith("| enc ?"))
        vb.stt = types.SimpleNamespace(last_temperature=0.0, last_encoder=None)         # short take: no memo
        out2 = io.StringIO()
        with contextlib.redirect_stdout(out2):
            main.VoiceBud._log(vb, res, 0.0, 1.0, 2.0, 2.1, "pasted")
        self.assertTrue(out2.getvalue().strip().endswith("| enc -"))


if __name__ == "__main__":
    unittest.main()
