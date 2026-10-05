"""System-wide push-to-talk hotkey via AppKit NSEvent global monitors.

pynput's darwin backend calls TIS (TISCopyCurrentKeyboardInputSource) from its
listener thread, which hard-aborts on modern macOS ("zsh: abort") — so we
listen with NSEvent monitors on the main thread instead. Requires the same
permissions as before: Input Monitoring + Accessibility.

Supports modifier chords ("ctrl+shift", "ctrl+alt"), side-specific modifiers
("alt_r"), plain modifiers matching either side ("ctrl" = left OR right),
and f13, in two modes:
  hold   — record while the keys are held, stop on release
  toggle — press the chord once to start, press it again to stop (both decided on
           release: by then a longer shortcut has shown itself, and nothing started)
A chord counts only on its own (04.10.): another modifier (ctrl+shift+cmd+4) or
another key while it is held (ctrl+shift+Tab) means the keys were some other
shortcut. A take that chord started is then cancelled (on_cancel: nothing is
pasted), a stop is not carried out, and the chord re-arms only after all its
modifiers were let go.
Note: macOS does not expose the fn key to apps, so fn can't be used.
"""
from AppKit import (
    NSEvent,
    NSEventMaskFlagsChanged,
    NSEventMaskKeyDown,
    NSEventMaskKeyUp,
    NSEventTypeKeyDown,
    NSEventTypeKeyUp,
)

# NX_DEVICE* low-order bits of NSEvent.modifierFlags — distinguish left/right
_L_CTRL, _L_SHIFT, _R_SHIFT, _L_CMD = 0x0001, 0x0002, 0x0004, 0x0008
_R_CMD, _L_ALT, _R_ALT, _R_CTRL = 0x0010, 0x0020, 0x0040, 0x2000
# device-independent modifier families (NSEventModifierFlagShift/Control/Option/Command)
_SHIFT, _CTRL, _ALT, _CMD = 1 << 17, 1 << 18, 1 << 19, 1 << 20
_ALL_FAMILIES = _SHIFT | _CTRL | _ALT | _CMD

MOD_MASKS = {
    "ctrl": _L_CTRL | _R_CTRL, "ctrl_l": _L_CTRL, "ctrl_r": _R_CTRL,
    "shift": _L_SHIFT | _R_SHIFT, "shift_l": _L_SHIFT, "shift_r": _R_SHIFT,
    "cmd": _L_CMD | _R_CMD, "cmd_l": _L_CMD, "cmd_r": _R_CMD,
    "alt": _L_ALT | _R_ALT, "alt_l": _L_ALT, "alt_r": _R_ALT,
}
FAMILIES = {"ctrl": _CTRL, "shift": _SHIFT, "cmd": _CMD, "alt": _ALT}
KEY_CODES = {"f13": 105}
OWN_EVENT_MARK = 0x56425544      # "VBUD" in kCGEventSourceUserData of the keys inject.py posts


def _own_event(event):
    try:
        import Quartz
        cg = event.CGEvent()
        return cg is not None and Quartz.CGEventGetIntegerValueField(cg, Quartz.kCGEventSourceUserData) == OWN_EVENT_MARK
    except Exception:
        return False


class PushToTalk:
    def __init__(self, key_name, on_press, on_release, mode="hold", active=None, on_cancel=None):
        names = [n.strip() for n in key_name.split("+")]
        unknown = [n for n in names if n not in MOD_MASKS and n not in KEY_CODES]
        if unknown:
            choices = sorted(MOD_MASKS) + sorted(KEY_CODES)
            raise ValueError(f"Unknown hotkey(s) {unknown}. Choose from: {choices}")
        self.mod_masks = [MOD_MASKS[n] for n in names if n in MOD_MASKS]
        self.families = 0
        for n in names:
            if n in MOD_MASKS:
                self.families |= FAMILIES[n.split("_")[0]]
        self.key_codes = {KEY_CODES[n] for n in names if n in KEY_CODES}
        self.mode = mode
        self.on_press_cb = on_press
        self.on_release_cb = on_release
        self.on_cancel_cb = on_cancel
        self._keys_down = set()    # non-modifier chord keys currently down
        self._chord_held = False   # chord physically complete (and alone) right now
        self._recording = False    # logical recording state (toggle mode without `active`)
        # toggle mode asks the app whether its recording runs instead of trusting _recording:
        # a press the app ignored (another hotkey was recording) would otherwise leave the two
        # out of step, and the next press did nothing
        self.active = active
        self._started = False      # this press started a take
        self._pending_stop = False # toggle: this press will stop the take on release
        self._spoiled = False      # this press turned out to be another shortcut
        self._armed = True         # False after a spoiled press until the modifiers are let go
        self._monitors = []

    def _chord_complete(self, flags):
        mods_ok = all(flags & m for m in self.mod_masks)
        return mods_ok and self.key_codes <= self._keys_down

    def _extra(self, flags):
        """Modifiers beyond the chord's own (ctrl+shift held, cmd added)."""
        return bool(flags & _ALL_FAMILIES & ~self.families)

    def held_now(self):
        """Are the chord's modifiers physically down right now (missed key-up check)?"""
        from Quartz import CGEventSourceFlagsState, kCGEventSourceStateHIDSystemState
        flags = int(CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState))   # any thread
        return all(flags & f for f in self._family_list())

    def _family_list(self):
        return [f for f in (_SHIFT, _CTRL, _ALT, _CMD) if self.families & f]

    def _spoil(self):
        if self._spoiled:
            return
        self._spoiled = True
        self._armed = False
        self._pending_stop = False
        if self._started:
            self._started = False
            self._recording = False
            if self.on_cancel_cb is not None:
                self.on_cancel_cb()

    def _update(self, complete):
        if complete and not self._chord_held:
            if not self._armed:
                return
            self._chord_held = True
            self._spoiled = False
            if self.mode == "toggle":
                pass                              # decided on release, unless spoiled
            else:  # hold
                self._recording = True
                self._started = True
                self.on_press_cb()
        elif not complete and self._chord_held:
            self._chord_held = False
            started, self._started = self._started, False
            if self.mode == "toggle":
                if not self._spoiled:
                    running = self.active() if self.active is not None else self._recording
                    self._recording = not running
                    (self.on_release_cb if running else self.on_press_cb)()
            elif started and not self._spoiled:
                self._recording = False
                self.on_release_cb()

    def _handle(self, event):
        etype = event.type()
        if etype in (NSEventTypeKeyDown, NSEventTypeKeyUp) and _own_event(event):
            return                              # VoiceBud's own paste, not a key the user pressed
        if etype == NSEventTypeKeyDown:
            if event.isARepeat():
                return
            code = event.keyCode()
            if code in self.key_codes:
                self._keys_down.add(code)
            elif self._chord_held:
                self._spoil()            # another key with the chord: someone else's shortcut
        elif etype == NSEventTypeKeyUp:
            self._keys_down.discard(event.keyCode())
        flags = int(event.modifierFlags())
        if not flags & self.families and not self._keys_down:
            self._armed = True           # every chord modifier let go
        extra = self._extra(flags)
        if extra and self._chord_held:
            self._spoil()
        self._update(self._chord_complete(flags) and not extra)

    def start(self):
        """Install NSEvent monitors. Must run on the main thread, before the
        AppKit run loop starts (events are delivered by that run loop). Key-downs
        are watched too: they tell a chord apart from a longer shortcut."""
        mask = NSEventMaskFlagsChanged | NSEventMaskKeyDown | NSEventMaskKeyUp

        def _global(event):
            self._handle(event)

        def _local(event):
            self._handle(event)
            return event

        # global = other apps focused; local = our own app focused
        self._monitors.append(
            NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(mask, _global))
        self._monitors.append(
            NSEvent.addLocalMonitorForEventsMatchingMask_handler_(mask, _local))
        return self
