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


if __name__ == "__main__":
    unittest.main()
