"""Screen context (KONTEXT-PLAN.md): a read-only snapshot of where the user is writing, taken
through the Accessibility API. It lives in RAM for one take only: never written to history or
logs (the Kontext-Probe logs lengths, roles and timings, never text).

Fail closed: any Accessibility error while finding the focused field withholds the field text;
app-level context (name, bundle id) may still be used. Hard rules that no setting overrides:
secure text fields, secure event input, password managers, VoiceBud itself, private windows."""
import ctypes
import json
import os
import re
import threading
import time
from pathlib import Path

OFF, APP, CURSOR, WINDOW, OCR = range(5)
DEFAULT_LEVEL = CURSOR
MAX_BEFORE = 500
MAX_AFTER = 500
MAX_VALUE = 20000           # read AXValue as a fallback only for fields up to this length
AX_TIMEOUT_S = 0.25
PROBE_LOG = Path.home() / "Library" / "Logs" / "voicebud-context.jsonl"

ALWAYS_EXCLUDED = {
    "com.apple.passwords", "com.apple.keychainaccess", "com.1password.1password",
    "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
    "com.dashlane.dashlanephonefinal", "com.lastpass.lastpassmacdesktop", "org.keepassxc.keepassxc",
    "local.voicebud",
}
# apps where what you answer is in the window (chats, AI chats): "Ganzes Fenster" by default while
# the base level is "Text am Cursor". The hub lists the same apps (ui/Hub.swift HubContextCopy).
DEFAULT_APP_LEVELS = {b: WINDOW for b in (
    "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "net.whatsapp.whatsapp",
    "desktop.whatsapp", "com.apple.mobilesms", "ru.keepcoder.telegram", "org.telegram.desktop",
    "org.whispersystems.signal-desktop", "com.hnc.discord", "com.anthropic.claudefordesktop", "com.openai.chat")}
CAPPED_CATEGORIES = {"public.app-category.finance", "public.app-category.medical"}
# browsers without a reliable private-window signal: at most "Text am Cursor"
NO_PRIVATE_SIGNAL = {"com.apple.safari", "com.google.chrome", "com.microsoft.edgemac",
                     "company.thebrowser.browser", "company.thebrowser.dia", "com.brave.browser",
                     "com.operasoftware.opera"}
PRIVATE_TITLE = re.compile(r"privater modus|private browsing|privates surfen|privates fenster|"
                           r"inkognito|incognito", re.I)
# Electron editors switch to "screen reader optimised" mode when AX is forced on: never touch them
NEVER_ELECTRON = {"com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.todesktop.230313mzl4w4u92",
                  "com.exafunction.windsurf", "com.vscodium"}

SECURE_SUBROLE = "AXSecureTextField"
FOCUS_ATTRS = ["AXRole", "AXSubrole", "AXNumberOfCharacters", "AXSelectedTextRange",
               "AXSelectedText", "AXPlaceholderValue"]


# -- the Accessibility layer (replaced by a fake in tests) ----------------------------------------
class _AX:
    """Thin pyobjc wrapper. Every call returns (error, value); error 0 = success."""

    def __init__(self):
        import ApplicationServices as ax
        self.ax = ax

    def trusted(self):
        return bool(self.ax.AXIsProcessTrusted())

    def set_timeout(self, seconds):
        # only the system-wide element sets the process-wide timeout (AXUIElement.h)
        self.ax.AXUIElementSetMessagingTimeout(self.ax.AXUIElementCreateSystemWide(), seconds)

    def app(self, pid):
        return self.ax.AXUIElementCreateApplication(pid)

    def get(self, el, attr):
        return self.ax.AXUIElementCopyAttributeValue(el, attr, None)

    def multi(self, el, attrs):
        err, vals = self.ax.AXUIElementCopyMultipleAttributeValues(el, attrs, 0, None)
        if err != 0 or vals is None:
            return err, {a: None for a in attrs}
        out = {}
        for a, v in zip(attrs, vals):
            if v is not None and type(v).__name__ == "AXValueRef" and \
                    self.ax.AXValueGetType(v) == self.ax.kAXValueAXErrorType:
                v = None
            out[a] = v
        return 0, out

    def range_of(self, value):
        if value is None:
            return None
        ok, r = self.ax.AXValueGetValue(value, self.ax.kAXValueCFRangeType, None)
        return (int(r[0]), int(r[1])) if ok else None

    def string_for_range(self, el, loc, length):
        if length <= 0:
            return 0, ""
        rng = self.ax.AXValueCreate(self.ax.kAXValueCFRangeType, (loc, length))
        err, s = self.ax.AXUIElementCopyParameterizedAttributeValue(el, "AXStringForRange", rng, None)
        return err, (str(s) if err == 0 and s is not None else None)

    def set_bool(self, el, attr, value):
        return self.ax.AXUIElementSetAttributeValue(el, attr, value)

    def param(self, el, attr, value):
        return self.ax.AXUIElementCopyParameterizedAttributeValue(el, attr, value, None)

    def marker_start(self, marker_range):
        return self.ax.AXTextMarkerRangeCopyStartMarker(marker_range)

    def marker_range(self, start, end):
        return self.ax.AXTextMarkerRangeCreate(None, start, end)


_ax = None


def ax():
    global _ax
    if _ax is None:
        _ax = _AX()
    return _ax


def set_timeout():
    try:
        ax().set_timeout(AX_TIMEOUT_S)
    except Exception:
        pass


# -- process facts -------------------------------------------------------------------------------
def identity():
    """Which process macOS holds responsible for our permissions, and whether Accessibility is
    granted to it. Reads nothing from other apps and never raises a system dialog."""
    out = {"pid": os.getpid(), "responsible": None, "trusted": None}
    try:
        libc = ctypes.CDLL(None)
        f = libc.responsibility_get_pid_responsible_for_pid
        f.restype, f.argtypes = ctypes.c_int, [ctypes.c_int]
        rpid = f(os.getpid())
        buf = ctypes.create_string_buffer(4096)
        libc.proc_pidpath(rpid, buf, 4096)
        out["responsible"] = buf.value.decode() or None
    except Exception:
        pass
    try:
        out["trusted"] = ax().trusted()
    except Exception:
        pass
    return out


_carbon = None


def secure_input_active():
    """True while any app holds secure event input (password prompts, Terminal's secure
    keyboard entry). No context at all then."""
    global _carbon
    try:
        if _carbon is None:
            _carbon = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Carbon.framework/Carbon")
            _carbon.IsSecureEventInputEnabled.restype = ctypes.c_ubyte
        return bool(_carbon.IsSecureEventInputEnabled())
    except Exception:
        return True     # unknown counts as active: the privacy rule fails closed


def readable_now(pid):
    """The hard privacy rules for reading the focused field of `pid` outside a snapshot (the
    learner): no secure event input, no private window. Settings are checked by the caller."""
    if secure_input_active():
        return False
    try:
        a = ax()
        err, win = a.get(a.app(pid), "AXFocusedWindow")
        if err == 0 and win is not None:
            e2, title = a.get(win, "AXTitle")
            if e2 == 0 and title and PRIVATE_TITLE.search(str(title)):
                return False
        return True
    except Exception:
        return False


def _category(path):
    try:
        from Foundation import NSBundle
        b = NSBundle.bundleWithPath_(path)
        return str(b.objectForInfoDictionaryKey_("LSApplicationCategoryType") or "") if b else ""
    except Exception:
        return ""


def is_electron(path):
    return bool(path) and os.path.isdir(os.path.join(path, "Contents/Frameworks/Electron Framework.framework"))


def frontmost(own_pids=()):
    """The app in front as a dict, or None when it is VoiceBud itself or unknown."""
    try:
        from AppKit import NSWorkspace
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
    except Exception:
        return None
    if app is None or int(app.processIdentifier()) in own_pids:
        return None
    path = str(app.bundleURL().path()) if app.bundleURL() else ""
    return {"pid": int(app.processIdentifier()), "name": str(app.localizedName() or ""),
            "bundle": str(app.bundleIdentifier() or ""), "path": path}


# -- snapshot ------------------------------------------------------------------------------------
class Snapshot:
    __slots__ = ("level", "app", "bundle", "pid", "electron", "title", "role", "subrole", "chars",
                 "before", "selected", "after", "via", "withheld", "missing", "errors", "ms", "header",
                 "window", "names", "register", "selected_len")

    def __init__(self, app, level):
        self.level = level
        self.app, self.bundle, self.pid = app.get("name", ""), app.get("bundle", ""), app.get("pid", 0)
        self.electron = is_electron(app.get("path", ""))
        self.title = self.role = self.subrole = self.via = ""
        self.before = self.selected = self.after = ""
        self.selected_len = 0     # full length of the selection (selected keeps at most 4000)
        self.chars = None
        self.withheld = None      # a privacy rule: nothing of this take may be used
        self.missing = None       # no field text (reading view, list in focus); the rest still counts
        self.errors = {}
        self.ms = 0.0
        self.header = ""          # other text fields of the window (recipients, subject)
        self.window = ""          # visible window text: level WINDOW, or once for a prompt-mode "diese Mail"
        self.names = []
        self.register = None      # "Sie" | "du" | None

    @property
    def has_text(self):
        return bool(self.before or self.selected or self.after)

    def redacted(self):
        """What may be logged: lengths, roles, timings, reasons. Never text."""
        return {"app": self.app, "bundle": self.bundle, "electron": self.electron, "level": self.level,
                "withheld": self.withheld, "missing": self.missing, "role": self.role, "subrole": self.subrole, "via": self.via,
                "chars": self.chars, "before": len(self.before), "selected": len(self.selected),
                "after": len(self.after), "title": len(self.title), "errors": self.errors, "ms": self.ms}

    def clear(self):
        self.title = self.before = self.selected = self.after = self.header = self.window = ""
        self.names = []


def trim_before(text, limit=MAX_BEFORE):
    if len(text) <= limit:
        return text
    cut = text[-limit:]
    m = re.search(r"\s", cut)
    return cut[m.end():] if m else cut


def trim_after(text, limit=MAX_AFTER):
    if len(text) <= limit:
        return text
    cut = text[:limit]
    m = max(cut.rfind(" "), cut.rfind("\n"))
    return cut[:m] if m > 0 else cut


def effective_level(level, app, per_app=None):
    """The level after per-app settings and the fixed caps; (level, reason or None)."""
    bundle = (app.get("bundle") or "").lower()
    if bundle in ALWAYS_EXCLUDED:
        return OFF, "excluded"
    own = next((v for k, v in (per_app or {}).items() if k.lower() == bundle and isinstance(v, int)), None)
    if own is not None:
        level = own
    elif level == CURSOR:
        level = DEFAULT_APP_LEVELS.get(bundle, level)
    if level <= OFF:
        return OFF, "off"
    if _category(app.get("path", "")) in CAPPED_CATEGORIES:
        level = min(level, APP)
    if bundle in NO_PRIVATE_SIGNAL:
        level = min(level, CURSOR)
    return level, None


def capture(level=DEFAULT_LEVEL, own_pids=(), per_app=None, app=None, cap=None):
    """Snapshot of the frontmost app at `level`, or None when there is nothing to read (VoiceBud
    itself in front, level off, excluded app). Bounded by the 0.25 s Accessibility timeout."""
    t0 = time.perf_counter()
    app = app or frontmost(own_pids)
    if app is None:
        return None
    lvl, reason = effective_level(level, app, per_app)
    if cap is not None:
        lvl = min(lvl, cap)          # the Befehlsmodus: the selection, never the chat app's window
    snap = Snapshot(app, lvl)
    if lvl <= OFF:
        snap.withheld = reason
        return snap
    if secure_input_active():
        snap.withheld = "secure_input"
        return snap
    a = ax()
    try:
        if not a.trusted():
            snap.withheld = "no_permission"
            return snap
        app_el = a.app(snap.pid)
        err, win = a.get(app_el, "AXFocusedWindow")
        if err == 0 and win is not None:
            e2, title = a.get(win, "AXTitle")
            snap.title = str(title) if e2 == 0 and title else ""
        else:
            snap.errors["window"] = err
        if PRIVATE_TITLE.search(snap.title):
            snap.withheld = "private_window"
            snap.title = ""
            return snap
        if lvl < CURSOR:
            return snap
        err, el = a.get(app_el, "AXFocusedUIElement")
        if err != 0 or el is None:
            snap.errors["focus"] = err
            snap.missing = "no_focus"
            el = None
        else:
            _read_caret(a, el, snap)
        if snap.withheld is None and win is not None:
            snap.header = _field_text(a, win, skip=el)
            if lvl >= WINDOW:
                snap.window = window_text(snap.pid, a)
        return snap
    except Exception as e:                       # anything unexpected: no field text
        snap.errors["exception"] = type(e).__name__
        snap.before = snap.selected = snap.after = ""
        snap.withheld = snap.withheld or "ax_error"
        return snap
    finally:
        snap.ms = round((time.perf_counter() - t0) * 1000, 1)


def _read_caret(a, el, snap):
    err, f = a.multi(el, FOCUS_ATTRS)
    if err != 0:
        snap.errors["attrs"] = err
        snap.missing = "ax_error"
        return
    snap.role, snap.subrole = str(f["AXRole"] or ""), str(f["AXSubrole"] or "")
    if snap.subrole == SECURE_SUBROLE:
        snap.withheld = "secure_field"
        return
    n, rng = f["AXNumberOfCharacters"], a.range_of(f["AXSelectedTextRange"])
    snap.chars = int(n) if isinstance(n, int) else None
    if (rng is None or snap.chars is None) and snap.role == "AXWebArea":
        _read_marker_caret(a, el, snap)
        return
    if rng is None or snap.chars is None:
        snap.missing = "no_caret"
        return
    loc, ln = rng
    start, end = max(0, loc - MAX_BEFORE - 200), loc + ln
    e1, before = a.string_for_range(el, start, loc - start)
    e2, after = a.string_for_range(el, end, min(MAX_AFTER + 200, snap.chars - end))
    selected = f["AXSelectedText"] if isinstance(f["AXSelectedText"], str) else None
    if before is not None:
        snap.via = "range"
        if selected is None:
            _, selected = a.string_for_range(el, loc, ln)
    elif snap.chars <= MAX_VALUE:
        ev, value = a.get(el, "AXValue")
        if ev == 0 and isinstance(value, str):
            snap.via = "value"
            before, after = value[start:loc], value[end:end + MAX_AFTER + 200]
            selected = selected if selected is not None else value[loc:end]
    if before is None:
        snap.errors["range"] = e1
        snap.missing = "no_text"
        return
    snap.before, snap.after = trim_before(before), trim_after(after or "")
    snap.selected_len = len(selected or "")
    snap.selected = (selected or "")[:4000]
    ph = f["AXPlaceholderValue"]
    if ph and (snap.before + snap.after).strip() == str(ph).strip():
        snap.before = snap.after = ""            # a placeholder is not content


def _read_marker_caret(a, web, snap):
    """Mail's compose body and other WebKit editors focus an AXWebArea without a plain range:
    caret marker -> the element that owns it -> its editable ancestor, then the normal range
    path; else the document text from its start up to the caret."""
    try:
        err, sel = a.get(web, "AXSelectedTextMarkerRange")
        if err != 0 or sel is None:
            snap.missing = "no_caret"
            return
        caret = a.marker_start(sel)
        err, owner = a.param(web, "AXUIElementForTextMarker", caret)
        editable = None
        if err == 0 and owner is not None:
            for attr in ("AXEditableAncestor", "AXHighestEditableAncestor"):
                e, editable = a.get(owner, attr)
                if e == 0 and editable is not None:
                    break
        if editable is not None:
            _read_caret(a, editable, snap)
            if snap.has_text:
                snap.via = "marker-owner"
                return
            snap.missing = None
        err, start = a.get(web, "AXStartTextMarker")
        if err != 0 or start is None:
            snap.missing = "no_caret"
            return
        err, before = a.param(web, "AXStringForTextMarkerRange", a.marker_range(start, caret))
        _, selected = a.param(web, "AXStringForTextMarkerRange", sel)
        if err != 0 or before is None:
            snap.missing = "no_text"
            return
        snap.selected_len = len(str(selected or ""))
        snap.before, snap.selected, snap.via = trim_before(str(before)), str(selected or "")[:4000], "marker-document"
    except Exception as e:
        snap.errors["marker"] = type(e).__name__
        snap.missing = "no_text"


# -- paste target ----------------------------------------------------------------------------------
def paste_state(own_pids=()):
    """'pasted' when the app in front has a focused element, 'clipboard' when it reports none.
    Unknown counts as pasted (we paste either way; this only decides what the island says).
    Asks the app in front, not the system-wide element, which fails in Electron apps."""
    try:
        a = ax()
        if not a.trusted():
            return "clipboard"      # without Accessibility the synthetic Cmd+V cannot land
        app = frontmost(own_pids)
        if app is None:
            return "pasted"
        err, el = a.get(a.app(app["pid"]), "AXFocusedUIElement")
    except Exception:
        return "pasted"
    if err == 0:
        if el is None:
            return "clipboard"
        return "pasted" if _takes_text(a, el) else "clipboard"
    return "clipboard" if err == -25212 else "pasted"   # kAXErrorNoValue: nothing has focus


# focused elements that take no typed text: a paste there lands nowhere
NON_TEXT_ROLES = {"AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXImage", "AXButton",
                  "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXGrid",
                  "AXDisclosureTriangle", "AXSplitter", "AXColumn"}


def _takes_text(a, el):
    """Does the focused element take typed text? A message list, a file in Finder or a button has
    focus too, and a paste there lands nowhere (the card then says "Zwischenablage"). Anything
    else counts as yes, web areas included (Mail's compose window is one, and saying "Zwischen-
    ablage" for a text that was pasted makes people paste it twice)."""
    try:
        err, role = a.get(el, "AXRole")
        return not (err == 0 and role is not None and str(role) in NON_TEXT_ROLES)
    except Exception:
        return True


# -- Electron ----------------------------------------------------------------------------------------
class ElectronAX:
    """Electron apps expose their text only after AXManualAccessibility is set, and build the tree
    about 2 s later. So it is set when such an app comes to the front, not at the hotkey, and left
    on while the app runs (once per process)."""

    def __init__(self, enabled=lambda: True):
        self.enabled = enabled
        self.enabled_at = {}          # pid -> time it was switched on
        self._token = None

    def start(self):
        try:
            from AppKit import (NSWorkspace, NSWorkspaceApplicationKey,
                                NSWorkspaceDidActivateApplicationNotification)
        except Exception:
            return
        ws = NSWorkspace.sharedWorkspace()

        def on_activate(note):
            info = note.userInfo()
            app = info.objectForKey_(NSWorkspaceApplicationKey) if info is not None else None
            if app is not None:
                self.consider(app)
        self._token = ws.notificationCenter().addObserverForName_object_queue_usingBlock_(
            NSWorkspaceDidActivateApplicationNotification, None, None, on_activate)
        front = ws.frontmostApplication()
        if front is not None:
            self.consider(front)

    def consider(self, app):
        if not self.enabled():
            return
        pid = int(app.processIdentifier())
        bundle = str(app.bundleIdentifier() or "").lower()
        path = str(app.bundleURL().path()) if app.bundleURL() else ""
        if pid in self.enabled_at or bundle in NEVER_ELECTRON or bundle in ALWAYS_EXCLUDED or not is_electron(path):
            return
        self.enabled_at[pid] = time.time()
        threading.Thread(target=self._switch_on, args=(pid,), name="electron-ax", daemon=True).start()

    def _switch_on(self, pid):
        try:
            ax().set_bool(ax().app(pid), "AXManualAccessibility", True)
        except Exception:
            pass

    def age(self, pid):
        t = self.enabled_at.get(pid)
        return None if t is None else round(time.time() - t, 1)


# -- Kontext-Probe ----------------------------------------------------------------------------------
_WALK_ATTRS = ["AXRole", "AXSubrole", "AXValue", "AXTitle", "AXDescription", "AXChildren"]
_LEAF_ROLES = {"AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell"}


def _walk_counts(a, root, max_nodes=1500, budget_s=0.25):
    """Window walk for the probe: how much text the whole window would give (counts only)."""
    t0, nodes, chars, queue = time.perf_counter(), 0, 0, [root]
    # (same list rule as window_text: huge lists are walked past)
    while queue and nodes < max_nodes and time.perf_counter() - t0 < budget_s:
        el = queue.pop(0)
        nodes += 1
        err, v = a.multi(el, _WALK_ATTRS)
        if err != 0:
            break
        if v["AXSubrole"] == SECURE_SUBROLE:
            continue
        if v["AXRole"] in _LEAF_ROLES:
            for key in ("AXValue", "AXTitle", "AXDescription"):
                if isinstance(v[key], str) and v[key].strip():
                    chars += len(v[key])
                    break
        queue.extend(_children(v))
    return {"nodes": nodes, "chars": chars, "ms": round((time.perf_counter() - t0) * 1000, 1),
            "truncated": bool(queue)}


_LABELS = {"excluded": "App ausgenommen", "secure_input": "sichere Eingabe aktiv",
           "secure_field": "Passwortfeld", "private_window": "privates Fenster",
           "no_permission": "Bedienungshilfen fehlen", "no_focus": "kein Textfeld gefunden",
           "no_caret": "Feld ohne Cursor", "no_text": "Feld gibt keinen Text her",
           "ax_error": "App antwortet nicht", "off": "Kontext aus", "app_changed": "App gewechselt"}


def probe(level=DEFAULT_LEVEL, own_pids=(), per_app=None, electron=None):
    """One snapshot plus a window walk, written redacted to PROBE_LOG. Returns (ok, summary)."""
    app = frontmost(own_pids)
    if app is None:
        return False, "Kontext-Probe: keine App vorne"
    snap = capture(level, own_pids, per_app, app=app)
    rec = {"ts": round(time.time(), 1), **snap.redacted(), "identity": identity(),
           "electron_age_s": electron.age(snap.pid) if electron else None}
    walk, doc = None, 0
    if snap.withheld is None:
        try:
            a = ax()
            win = _focused_window(a, snap.pid)
            walk = _walk_counts(a, win) if win is not None else None
            t = time.perf_counter()
            doc = len(main_text(snap.pid, a))
            rec["doc"] = {"chars": doc, "ms": round((time.perf_counter() - t) * 1000, 1)}
        except Exception:
            walk = None
    rec["walk"] = walk
    snap.clear()
    try:
        PROBE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(PROBE_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass
    name = app["name"] or "App"
    if snap.withheld:
        return False, f"{name}: {_LABELS.get(snap.withheld, snap.withheld)}"
    cursor = rec["before"] + rec["after"] + rec["selected"]
    parts = [f"Cursor {_num(cursor)} Zeichen" if snap.missing is None else _LABELS.get(snap.missing, "kein Textfeld")]
    if doc:
        parts.append(f"Dokument {_num(doc)}")
    if walk:
        parts.append(f"Fenster {_num(walk['chars'])}")
    return True, f"{name}: " + ", ".join(parts)


def _num(n):
    return f"{n:,}".replace(",", ".")


# -- what a snapshot is used for ---------------------------------------------------------------
_SKIP_ROLES = {"AXMenuBar", "AXMenu", "AXMenuItem", "AXScrollBar", "AXImage", "AXValueIndicator"}
_LIST_ROLES = {"AXTable", "AXOutline", "AXList", "AXBrowser"}
BIG_LIST = 200              # a list this long is an inbox or a file list: walked past, not into


def _children(v):
    kids = v["AXChildren"] or []
    return [] if v["AXRole"] in _LIST_ROLES and len(kids) > BIG_LIST else list(kids)


def _field_text(a, win, skip=None, max_nodes=300, budget_s=0.08, max_chars=1500):
    """Values of the window's other single-line fields (Mail: To, Cc, subject), for names."""
    t0, nodes, out, queue = time.perf_counter(), 0, [], [win]
    while queue and nodes < max_nodes and time.perf_counter() - t0 < budget_s:
        el = queue.pop(0)
        nodes += 1
        err, v = a.multi(el, _WALK_ATTRS)
        if err != 0:
            break
        role = v["AXRole"]
        if role in _SKIP_ROLES or v["AXSubrole"] == SECURE_SUBROLE or el == skip:
            continue
        if role in ("AXTextField", "AXComboBox") and isinstance(v["AXValue"], str) and v["AXValue"].strip():
            out.append(v["AXValue"].strip()[:300])
        if role != "AXTextArea":
            queue.extend(_children(v))
    return "\n".join(out)[:max_chars]


def _focused_window(a, pid):
    app_el = a.app(pid)
    err, win = a.get(app_el, "AXFocusedWindow")
    if err == 0 and win is not None:
        return win
    err, wins = a.get(app_el, "AXMainWindow")
    return wins if err == 0 else None


def window_text(pid, a=None, max_nodes=1500, budget_s=0.25, max_chars=12000, root=None):
    """Visible text of the focused window (static texts, fields), bounded in nodes, time and size."""
    a = a or ax()
    win = root if root is not None else _focused_window(a, pid)
    if win is None:
        return ""
    t0, nodes, out, seen, total, queue = time.perf_counter(), 0, [], set(), 0, [win]
    while queue and nodes < max_nodes and total < max_chars and time.perf_counter() - t0 < budget_s:
        el = queue.pop(0)
        nodes += 1
        err, v = a.multi(el, _WALK_ATTRS)
        if err != 0:
            break
        if v["AXRole"] in _SKIP_ROLES or v["AXSubrole"] == SECURE_SUBROLE:
            continue
        if v["AXRole"] in _LEAF_ROLES:
            for key in ("AXValue", "AXTitle", "AXDescription"):
                text = v[key]
                if isinstance(text, str) and text.strip():
                    line = " ".join(text.split())[:2000]
                    if line not in seen:
                        seen.add(line)
                        out.append(line)
                        total += len(line)
                    break
        queue.extend(_children(v))
    return "\n".join(out)[:max_chars]


def main_text(pid, a=None, max_nodes=2500, budget_s=0.2):
    """The document the window shows (the open mail, a web page): the largest web area of the
    focused window, without the lists and sidebars around it. "" when there is none."""
    a = a or ax()
    win = _focused_window(a, pid)
    if win is None:
        return ""
    t0, nodes, best, queue = time.perf_counter(), 0, (0, None), [win]
    while queue and nodes < max_nodes and time.perf_counter() - t0 < budget_s:
        el = queue.pop(0)
        nodes += 1
        err, v = a.multi(el, _WALK_ATTRS)
        if err != 0:
            break
        if v["AXRole"] in _SKIP_ROLES or v["AXSubrole"] == SECURE_SUBROLE:
            continue
        if v["AXRole"] == "AXWebArea":
            size = len(v["AXChildren"] or [])
            if size > best[0]:
                best = (size, el)
            continue                  # its text is read below, its inside is not searched further
        queue.extend(_children(v))
    return window_text(pid, a, root=best[1]) if best[1] is not None else ""


_NAME_TOKEN = re.compile(r"[^\W\d_][^\W\d_'’-]*(?:-[^\W\d_]+)?")
_FOREIGN = re.compile(r"[ąćęłńśźżčřšžťďňůýáíéóúàèìòùâêîôûëïñçåøæœ]", re.I)
MAX_NAMES = 20


def names_from(snap, is_word=None):
    """Names for the per-take spelling tier: capitalised tokens that are no ordinary word, carry
    letters German does not use, or follow a name cue ("Frau Becker"). At most MAX_NAMES."""
    from dictionary import NAME_CUES
    if is_word is None:
        from dictionary import is_word
    text = "\n".join(x for x in (snap.title, snap.header, snap.before, snap.selected, snap.after,
                                  snap.window) if x)
    out, seen, prev = [], set(), ""
    for m in _NAME_TOKEN.finditer(text):
        tok = m.group().strip("'’-")
        low = tok.lower()
        cue = prev in NAME_CUES
        prev = low.rstrip(".")
        if len(tok) < 3 or not tok[0].isupper() or tok in seen:
            continue
        if cue or _FOREIGN.search(tok) or not is_word(tok):
            seen.add(tok)
            out.append(tok)
            if len(out) >= MAX_NAMES:
                break
    return out


_SIE = re.compile(r"(?<![.!?:\n]\s)(?<=\s)(Sie|Ihnen|Ihr|Ihre|Ihren|Ihrem|Ihrer|Ihres)\b")
_SIE_FORMULA = re.compile(r"sehr geehrte|mit freundlichen grüßen|beste grüße an sie", re.I)
_DU = re.compile(r"\b(du|dir|dich|dein|deine|deinen|deinem|deiner|euch|euer|eure)\b", re.I)


def register_of(snap):
    """'Sie' when the text around the cursor addresses formally, 'du' when informally, else None.
    The own draft counts three times as much as the other fields."""
    near = " ".join(x for x in (snap.before, snap.selected, snap.after) if x)
    far = " ".join(x for x in (snap.header, snap.window) if x)
    sie = 3 * (len(_SIE.findall(" " + near)) + 2 * len(_SIE_FORMULA.findall(near))) + \
        len(_SIE.findall(" " + far)) + 2 * len(_SIE_FORMULA.findall(far))
    du = 3 * len(_DU.findall(near)) + len(_DU.findall(far))
    if sie > du:
        return "Sie"
    if du > sie:
        return "du"
    return None


def withheld_label(reason):
    return _LABELS.get(reason, reason)
