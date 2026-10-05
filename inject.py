"""Text injection at the cursor: clipboard + synthesized Cmd+V (Quartz CGEvent),
with a per-character Unicode keystroke fallback. Saves/restores the clipboard."""
import threading
import time

import Quartz

from hotkey import OWN_EVENT_MARK   # the hotkey monitors skip VoiceBud's own keys
from AppKit import NSPasteboard, NSPasteboardItem, NSPasteboardTypeString

KEY_V = 9  # macOS virtual keycode for 'v'


TRANSIENT = "org.nspasteboard.TransientType"   # clipboard histories (Raycast & co.) skip these
SOURCE = "org.nspasteboard.source"


def _set_clipboard(text, transient=False):
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    if not transient:
        pb.setString_forType_(text, NSPasteboardTypeString)
        return
    item = NSPasteboardItem.alloc().init()
    item.setString_forType_(text, NSPasteboardTypeString)
    item.setString_forType_("", TRANSIENT)
    item.setString_forType_("local.voicebud", SOURCE)
    pb.writeObjects_([item])


def _get_clipboard():
    pb = NSPasteboard.generalPasteboard()
    return pb.stringForType_(NSPasteboardTypeString)


def _save_clipboard():
    """Every item with every type (an image, files, rich text), not only the plain text: a paste
    must not lose what was on the clipboard (review 05.10.: an image was gone after a dictation)."""
    pb = NSPasteboard.generalPasteboard()
    saved = []
    for item in pb.pasteboardItems() or []:
        types = {}
        for t in item.types() or []:
            data = item.dataForType_(t)
            if data is not None:
                types[t] = data
        if types:
            saved.append(types)
    return saved


def _restore_clipboard(saved):
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    items = []
    for types in saved:
        item = NSPasteboardItem.alloc().init()
        for t, data in types.items():
            item.setData_forType_(data, t)
        if TRANSIENT not in types:
            item.setString_forType_("", TRANSIENT)   # the user's own content back: no new history entry
        items.append(item)
    if items:
        pb.writeObjects_(items)


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
    restore = cfg.get("restore_clipboard", True)
    old = _save_clipboard() if restore else None
    # transient only when the old content comes back right after: else the text stays on the
    # clipboard on purpose and belongs in its history
    _set_clipboard(text, transient=restore)
    time.sleep(0.03)  # let the pasteboard settle
    _press_cmd_v()
    if old is not None:
        time.sleep(0.15)  # let the paste land before restoring
        _restore_clipboard(old)
