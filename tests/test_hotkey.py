"""Toggle hotkeys follow the app's recording state (04.10.: a press the app ignored left the
hotkey out of step, and ctrl+shift seemed dead)."""
import unittest

import _util  # noqa: F401
from hotkey import PushToTalk


class ToggleTest(unittest.TestCase):
    def setUp(self):
        self.owner = None
        self.calls = []

        def start():
            self.calls.append("start")
            if self.owner is None:           # VoiceBud.start_rec ignores a busy microphone
                self.owner = "dictate"

        def stop():
            self.calls.append("stop")
            if self.owner == "dictate":
                self.owner = None

        self.ptt = PushToTalk("ctrl+shift", start, stop, mode="toggle",
                              active=lambda: self.owner == "dictate")

    def press(self):
        self.ptt._update(True)
        self.ptt._update(False)

    def test_start_stop(self):
        self.press()
        self.assertEqual(self.owner, "dictate")
        self.press()
        self.assertIsNone(self.owner)
        self.assertEqual(self.calls, ["start", "stop"])

    def test_ignored_start_does_not_cost_the_next_press(self):
        self.owner = "prompt"                # the prompt hotkey records, ctrl+shift is ignored
        self.press()
        self.owner = None                    # the prompt take ends
        self.press()                         # must start right away, not "stop" a phantom take
        self.assertEqual(self.owner, "dictate")
        self.assertEqual(self.calls, ["start", "start"])

    def test_recording_ended_elsewhere(self):
        self.press()
        self.owner = None                    # e.g. aborted by the app
        self.press()
        self.assertEqual(self.owner, "dictate")
        self.assertEqual(self.calls, ["start", "start"])

    def test_without_app_state_it_still_toggles(self):
        calls = []
        ptt = PushToTalk("ctrl+alt", lambda: calls.append("start"), lambda: calls.append("stop"), mode="toggle")
        for _ in range(3):
            ptt._update(True)
            ptt._update(False)
        self.assertEqual(calls, ["start", "stop", "start"])


import hotkey as hk
from AppKit import NSEventTypeFlagsChanged, NSEventTypeKeyDown, NSEventTypeKeyUp

CTRL = hk._L_CTRL | hk._CTRL
SHIFT = hk._L_SHIFT | hk._SHIFT
CMD = hk._L_CMD | hk._CMD
ALT = hk._L_ALT | hk._ALT


class _Ev:
    def __init__(self, etype, flags, code=0, repeat=False):
        self._t, self._f, self._c, self._r = etype, flags, code, repeat

    def type(self):
        return self._t

    def modifierFlags(self):
        return self._f

    def keyCode(self):
        return self._c

    def isARepeat(self):
        return self._r


class ChordTest(unittest.TestCase):
    """04.10.: a chord inside a longer shortcut (ctrl+shift+Tab, ctrl+shift+cmd+4, ctrl+cmd+F)
    started or stopped takes; now it cancels the take it started and stops nothing."""

    def make(self, keys="ctrl+shift", mode="toggle"):
        self.owner, self.calls = None, []

        def start():
            self.calls.append("start")
            self.owner = "x"

        def stop():
            self.calls.append("stop")
            self.owner = None

        def cancel():
            self.calls.append("cancel")
            self.owner = None
        return hk.PushToTalk(keys, start, stop, mode=mode, active=lambda: self.owner == "x", on_cancel=cancel)

    def flags(self, p, *seq):
        for f in seq:
            p._handle(_Ev(NSEventTypeFlagsChanged, f))

    def key(self, p, code, flags):
        p._handle(_Ev(NSEventTypeKeyDown, flags, code))
        p._handle(_Ev(NSEventTypeKeyUp, flags, code))

    def test_plain_press_starts_and_stops(self):
        p = self.make()
        self.flags(p, CTRL, CTRL | SHIFT, CTRL, 0)
        self.flags(p, CTRL, CTRL | SHIFT, CTRL, 0)
        self.assertEqual(self.calls, ["start", "stop"])

    def test_ctrl_shift_tab_starts_nothing(self):
        # toggle decides on release (Challenge 2, 04.10.): a longer shortcut never starts a take,
        # so no microphone, no muted sound, no cancelled slow take
        p = self.make()
        self.flags(p, CTRL, CTRL | SHIFT)
        self.key(p, 48, CTRL | SHIFT)          # Tab
        self.key(p, 48, CTRL | SHIFT)          # Tab again, still held
        self.flags(p, CTRL, 0)
        self.assertEqual(self.calls, [])
        self.assertIsNone(self.owner)

    def test_screenshot_shortcut_never_restarts(self):
        p = self.make()
        self.flags(p, CTRL, CTRL | SHIFT, CTRL | SHIFT | CMD)   # cmd joins: another shortcut
        self.key(p, 21, CTRL | SHIFT | CMD)                       # 4
        self.flags(p, CTRL | SHIFT, CTRL, 0)                      # cmd up first: no new start
        self.assertEqual(self.calls, [])

    def test_superset_does_not_start(self):
        p = self.make()
        self.flags(p, CMD, CMD | SHIFT, CMD | SHIFT | CTRL, CMD | SHIFT, 0)
        self.assertEqual(self.calls, [])

    def test_shortcut_while_recording_does_not_stop(self):
        p = self.make()
        self.flags(p, CTRL, CTRL | SHIFT, CTRL, 0)             # start
        self.flags(p, CTRL, CTRL | SHIFT)
        self.key(p, 48, CTRL | SHIFT)                           # ctrl+shift+Tab while recording
        self.flags(p, CTRL, 0)
        self.assertEqual(self.calls, ["start"])
        self.assertEqual(self.owner, "x")

    def test_chord_down_announces_a_start(self):
        # 05.10.: the island looks at Alcove while the keys are down; only for a press that will
        # start a take, and a failing look never touches the hotkey
        p = self.make()
        seen = []
        p.on_chord_cb = lambda: seen.append("chord")
        self.flags(p, CTRL, CTRL | SHIFT)
        self.assertEqual(seen, ["chord"])
        self.assertEqual(self.calls, [])                        # nothing starts before the release
        self.flags(p, CTRL, 0)
        self.assertEqual(self.calls, ["start"])
        self.flags(p, CTRL, CTRL | SHIFT, CTRL, 0)              # this press stops: no announcement
        self.assertEqual(seen, ["chord"])
        self.assertEqual(self.calls, ["start", "stop"])

        def broken():
            raise RuntimeError("island gone")
        p.on_chord_cb = broken
        self.flags(p, CTRL, CTRL | SHIFT, CTRL, 0)
        self.assertEqual(self.calls, ["start", "stop", "start"])

    def test_hold_chord_announces_before_the_start(self):
        p = self.make("ctrl+cmd", mode="hold")
        p.on_chord_cb = lambda: self.calls.append("chord")
        self.flags(p, CTRL, CTRL | CMD, CTRL, 0)
        self.assertEqual(self.calls, ["chord", "start", "stop"])

    def test_hold_mode_cancel_and_release(self):
        p = self.make("ctrl+cmd", mode="hold")
        self.flags(p, CTRL, CTRL | CMD)
        self.key(p, 3, CTRL | CMD)                              # ctrl+cmd+F
        self.flags(p, CTRL, 0)
        self.flags(p, CTRL, CTRL | CMD, CTRL, 0)               # a real hold
        self.assertEqual(self.calls, ["start", "cancel", "start", "stop"])

    def test_typing_while_recording_is_fine(self):
        p = self.make()
        self.flags(p, CTRL, CTRL | SHIFT, CTRL, 0)
        self.key(p, 0, 0)                                       # "a" with no modifier
        self.flags(p, CTRL, CTRL | SHIFT, CTRL, 0)
        self.assertEqual(self.calls, ["start", "stop"])

    def test_own_paste_does_not_spoil_a_held_chord(self):
        import hotkey
        p = self.make("ctrl+cmd", mode="hold")
        own = _Ev(NSEventTypeKeyDown, CTRL | CMD, 9)
        self.flags(p, CTRL, CTRL | CMD)
        orig = hotkey._own_event
        hotkey._own_event = lambda e: e is own            # VoiceBud's Cmd+V of an earlier take
        try:
            p._handle(own)
        finally:
            hotkey._own_event = orig
        self.flags(p, CTRL, 0)
        self.assertEqual(self.calls, ["start", "stop"])



class ShortcutChoiceTest(unittest.TestCase):
    """The hub's own shortcuts over config.yaml (10.10.): only keys hotkey.py can watch, never the
    same keys twice."""
    CFG = {"hotkey": {"key": "ctrl+shift", "mode": "toggle"},
           "prompt_hotkey": {"key": "ctrl+alt", "mode": "toggle"},
           "command_hotkey": {"key": "ctrl+cmd", "mode": "hold"}}

    def specs(self, shortcuts):
        from main import hotkey_specs
        return hotkey_specs(self.CFG, {"shortcuts": shortcuts})

    def test_valid(self):
        from hotkey import valid
        for spec in ("ctrl+shift", "ctrl+alt", "cmd_r", "alt_r", "f13", "shift+cmd", "ctrl+cmd+f13"):
            self.assertTrue(valid(spec), spec)
        for spec in ("cmd", "alt_l", "shift", "ctrl+ctrl", "foo+bar", "", None, 5, "ctrl+a"):
            self.assertFalse(valid(spec), spec)

    def test_config_without_choices(self):
        self.assertEqual(self.specs({}), {"dictate": ("ctrl+shift", "toggle"), "prompt": ("ctrl+alt", "toggle"),
                                          "command": ("ctrl+cmd", "hold")})

    def test_own_choice_keeps_the_mode(self):
        got = self.specs({"dictate": "cmd_r", "command": "SHIFT+CMD"})
        self.assertEqual(got["dictate"], ("cmd_r", "toggle"))
        self.assertEqual(got["command"], ("shift+cmd", "hold"))
        self.assertEqual(got["prompt"], ("ctrl+alt", "toggle"))

    def test_invalid_or_taken_choices_fall_back(self):
        got = self.specs({"dictate": "cmd", "prompt": "shift+ctrl", "command": 3})
        self.assertEqual(got["dictate"], ("ctrl+shift", "toggle"))   # a single left key
        self.assertEqual(got["prompt"], ("ctrl+alt", "toggle"))      # dictation's keys, in another order
        self.assertEqual(got["command"], ("ctrl+cmd", "hold"))

    def test_keys_from_the_ui(self):
        key = {"key": 13, "mods": 4096, "label": "⌃W"}
        got = self.specs({"dictate": key, "prompt": dict(key)})
        self.assertEqual(got["dictate"], (key, "toggle"))
        self.assertEqual(got["prompt"], ("ctrl+alt", "toggle"))       # the same key twice keeps the default
        self.assertEqual(self.specs({"dictate": {"key": 13}})["dictate"], ("ctrl+shift", "toggle"))

    def test_text_recognition(self):
        from main import hotkey_specs, hotkey_label
        self.assertNotIn("ocr", self.specs({}))                       # ⇧⌘2: the UI's own key
        self.assertNotIn("ocr", self.specs({"ocr": {"key": 17, "mods": 2304, "label": "⌥⌘T"}}))
        self.assertEqual(self.specs({"ocr": "ctrl+alt+shift"})["ocr"], ("ctrl+alt+shift", "toggle"))
        self.assertNotIn("ocr", self.specs({"ocr": "ctrl+shift"}))    # dictation's chord
        off = hotkey_specs(self.CFG, {"shortcuts": {"ocr": "ctrl+alt+shift"}, "screenText": False})
        self.assertNotIn("ocr", off)
        self.assertEqual(hotkey_label({"key": 13, "mods": 4096, "label": "⌃W"}), "label:⌃W")
        self.assertEqual(hotkey_label("ctrl+alt"), "ctrl+alt")

    def test_move_then_take(self):
        got = self.specs({"prompt": "ctrl+alt+shift", "dictate": "ctrl+alt"})
        self.assertEqual(got["dictate"], ("ctrl+alt", "toggle"))
        self.assertEqual(got["prompt"], ("ctrl+alt+shift", "toggle"))

    def test_swap(self):
        got = self.specs({"dictate": "ctrl+alt", "prompt": "ctrl+shift"})
        self.assertEqual(got["dictate"], ("ctrl+alt", "toggle"))
        self.assertEqual(got["prompt"], ("ctrl+shift", "toggle"))

    def test_settings_without_shortcuts(self):
        from main import hotkey_specs
        self.assertEqual(hotkey_specs(self.CFG, {"shortcuts": "x"})["dictate"], ("ctrl+shift", "toggle"))
        self.assertEqual(hotkey_specs(self.CFG, {})["prompt"], ("ctrl+alt", "toggle"))


class KeyHotkeyTest(unittest.TestCase):
    """Keys the UI holds for the core (10.10.: ⌃W, ⌃⌥D, F5): toggle on the press, hold while down,
    repeats while held ignored."""
    SPEC = {"key": 13, "mods": 4096, "label": "⌃W"}

    def make(self, mode):
        self.owner, self.calls = None, []

        def start():
            self.calls.append("start")
            self.owner = "x"

        def stop():
            self.calls.append("stop")
            self.owner = None
        return hk.KeyHotkey(self.SPEC, start, stop, mode=mode, active=lambda: self.owner == "x",
                            on_chord=lambda: self.calls.append("chord"))

    def test_toggle(self):
        k = self.make("toggle")
        k.event(True); k.event(True); k.event(False)       # a repeat while held does nothing
        k.event(True); k.event(False)
        self.assertEqual(self.calls, ["chord", "start", "stop"])

    def test_toggle_follows_the_app(self):
        k = self.make("toggle")
        k.event(True); k.event(False)
        self.owner = None                                    # the take ended elsewhere
        k.event(True); k.event(False)
        self.assertEqual(self.calls, ["chord", "start", "chord", "start"])

    def test_hold(self):
        k = self.make("hold")
        k.event(True); k.event(True); k.event(False); k.event(False)
        self.assertEqual(self.calls, ["chord", "start", "stop"])

    def test_release_without_press(self):
        k = self.make("hold")
        k.event(False)
        self.assertEqual(self.calls, [])

    def test_valid_key(self):
        self.assertTrue(hk.valid_key(self.SPEC))
        self.assertTrue(hk.valid_key({"key": 13.0, "mods": 4096.0, "label": "⌃W"}))   # as the UI reads it
        self.assertFalse(hk.valid_key({"key": 13.5, "mods": 4096, "label": "⌃W"}))
        for bad in ({"key": 13, "mods": 4096}, {"key": 200, "mods": 0, "label": "x"}, {"key": True, "mods": 0, "label": "x"},
                    {"key": 13, "mods": 1, "label": "x"}, {"key": 13, "mods": 4096, "label": ""}, "ctrl+w", None):
            self.assertFalse(hk.valid_key(bad), bad)



class StrictChordTest(unittest.TestCase):
    """A chord inside a longer shortcut (10.10.: ⌃⌥ for the prompt next to a key ⌃⌥⇧K): letting go of
    the longer one must not complete the inner chord late."""
    make = ChordTest.make
    flags = ChordTest.flags

    def test_inner_chord_not_completed_by_letting_go(self):
        p = self.make("ctrl+alt")
        self.flags(p, CTRL, CTRL | SHIFT, CTRL | SHIFT | ALT, CTRL | ALT, 0)      # ⇧ let go first
        self.assertEqual(self.calls, ["start"])                                  # without strict: a take
        p = self.make("ctrl+alt")
        p.strict = True
        self.flags(p, CTRL, CTRL | SHIFT, CTRL | SHIFT | ALT, CTRL | ALT, 0)
        self.assertEqual(self.calls, [])
        self.flags(p, CTRL, CTRL | ALT, CTRL, 0)                                  # a clean press still works
        self.assertEqual(self.calls, ["start"])

    def test_installed_mid_press_waits(self):
        import Quartz
        held = Quartz.CGEventSourceFlagsState
        Quartz.CGEventSourceFlagsState = lambda state: CTRL | ALT | SHIFT
        try:
            p = self.make("ctrl+shift")
            p._seed_armed()                                                       # what start() does first
        finally:
            Quartz.CGEventSourceFlagsState = held
        self.flags(p, CTRL | SHIFT, 0)                                            # ⌥ let go first
        self.assertEqual(self.calls, [])
        self.flags(p, CTRL, CTRL | SHIFT, CTRL, 0)
        self.assertEqual(self.calls, ["start"])


if __name__ == "__main__":
    unittest.main()
