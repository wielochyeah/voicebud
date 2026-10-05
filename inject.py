"""Text injection at the cursor: clipboard + synthesized Cmd+V (Quartz CGEvent),
with a per-character Unicode keystroke fallback. Saves/restores the clipboard."""
import threading
import time

import Quartz

from hotkey import OWN_EVENT_MARK   # the hotkey monitors skip VoiceBud's own keys
from AppKit import NSPasteboard, NSPasteboardTypeString

KEY_V = 9  # macOS virtual keycode for 'v'


def _set_clipboard(text):
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)


def _get_clipboard():
    pb = NSPasteboard.generalPasteboard()
    return pb.stringForType_(NSPasteboardTypeString)


def _press_cmd_v():
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    down = Quartz.CGEventCreateKeyboardEvent(src, KEY_V, True)
    up = Quartz.CGEventCreateKeyboardEvent(src, KEY_V, False)
    Quartz.CGEventSetFlags(down, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventSetFlags(up, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventSetIntegerValueField(down, Quartz.kCGEventSourceUserData, OWN_EVENT_MARK)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
    Quartz.CGEventSetIntegerValueField(up, Quartz.kCGEventSourceUserData, OWN_EVENT_MARK)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)


def _type_unicode(text):
    """Fallback: per-character CGEvent Unicode keystrokes (no clipboard involved)."""
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for ch in text:
        down = Quartz.CGEventCreateKeyboardEvent(src, 0, True)
        Quartz.CGEventKeyboardSetUnicodeString(down, len(ch), ch)
        Quartz.CGEventSetIntegerValueField(down, Quartz.kCGEventSourceUserData, OWN_EVENT_MARK)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
        up = Quartz.CGEventCreateKeyboardEvent(src, 0, False)
        Quartz.CGEventKeyboardSetUnicodeString(up, len(ch), ch)
        Quartz.CGEventSetIntegerValueField(up, Quartz.kCGEventSourceUserData, OWN_EVENT_MARK)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)
        time.sleep(0.002)


_lock = threading.Lock()   # two takes never interleave their clipboard save and restore


def copy_only(text):
    """Text to the clipboard without pasting (the app in front changed since the stop)."""
    if text:
        _set_clipboard(text)


def inject(text, cfg):
    with _lock:
        _inject(text, cfg)


def _inject(text, cfg):
    if not text:
        return
    if cfg.get("method", "paste") == "type":
        _type_unicode(text)
        return
    old = _get_clipboard() if cfg.get("restore_clipboard", True) else None
    _set_clipboard(text)
    time.sleep(0.03)  # let the pasteboard settle
    _press_cmd_v()
    if old is not None:
        time.sleep(0.15)  # let the paste land before restoring
        _set_clipboard(old)
