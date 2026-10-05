"""Lernendes Wörterbuch: after a paste VoiceBud watches the pasted text for a minute (same text
field, through the Accessibility API). Every word the user corrects there ("Schimanska" ->
"Szymańska") goes into the dictionary, several in one text too. Only the corrected words are kept,
never the text around them. A text that went to the clipboard (another app came to the front) is
looked for wherever the user pastes it within two minutes."""
import difflib
import re
import threading
import time

import context
from dictionary import _lev, is_word, phonetic

WATCH_S = 60.0
POLL_S = 1.0
LOCATE_S = 3.0             # Electron apps update their accessibility text a moment after the paste
PASTE_WAIT_S = 120.0       # clipboard delivery: how long to wait for the user's own paste
EXTEND_S = 20.0            # after each learned fix, keep watching at least this long (more fixes)
_WORD = re.compile(r"[^\W\d_][^\W\d_'’-]*")


def exact_worthy(heard, corrected):
    """A misheard name that is not spelled like what Whisper wrote ("USB-Flow" for "WhisperFlow",
    "Clout Code" for "Claude Code"): learned only as an EXACT replacement of that wording, which
    Whisper tends to repeat. The fix must look like a name (every word capitalised, a CamelCase,
    hyphenated or unknown word, a digit), and what was heard must be unusual (an acronym, no
    dictionary word) or sound almost the same. A content edit ("Apple" -> "Google", "die API" ->
    "die SDK") is neither."""
    hw, cw = heard.split(), corrected.split()
    if not (1 <= len(hw) <= 3 and 1 <= len(cw) <= 3) or heard.lower() == corrected.lower():
        return False
    if not 0.4 <= len(corrected) / max(1, len(heard)) <= 2.5:
        return False
    if re.sub(r"[\s-]", "", heard).lower() == re.sub(r"[\s-]", "", corrected).lower():
        return False      # only spaced differently ("Haustür" -> "Haus Tür"): worth_learning decides

    def unusual(w):
        return bool(re.search(r"[A-ZÄÖÜ]{2,}", w)) or any(not is_word(p) for p in w.split("-") if p)

    def name_like(w):
        if len(cw) > 1:
            return w[:1].isupper() or w[:1].isdigit()
        return bool(re.search(r"[a-zäöüß][A-ZÄÖÜ]", w) or re.search(r"\d", w)) or \
            ("-" in w and all(p[:1].isupper() for p in w.split("-") if p)) or \
            (w[:1].isupper() and not is_word(w))
    if not all(name_like(w) for w in cw):
        return False
    a, b = phonetic(re.sub(r"[\s-]", "", heard)), phonetic(re.sub(r"[\s-]", "", corrected))
    sounds_alike = bool(a and b) and _lev(a, b) <= max(1, len(b) // 4)
    return any(unusual(w) for w in hw) or sounds_alike


def worth_learning(heard, corrected):
    """A real spelling fix: similar in sound or letters. Names and brands ("Claude", "Wieloch",
    "Szymańska") count even when macOS knows them; an ordinary lowercase word does not ("das" to
    "dass" is grammar, "gut" to "super" style, neither a spelling to learn)."""
    if heard == corrected or len(corrected) < 3 or heard.lower() == corrected.lower():
        return False
    squashed, target = heard.replace(" ", ""), corrected.replace(" ", "")
    similar = phonetic(squashed) == phonetic(target) or \
        _lev(squashed.lower(), target.lower()) <= max(1, len(target) // 3)
    if not similar and corrected[:1].isupper() and not is_word(squashed) and not is_word(squashed.lower()):
        # what was heard is no word at all and the fix is a name: one sound apart is enough
        # ("Notschen" -> "Notion"); content edits are two or more apart (Montag/Dienstag)
        a, b = phonetic(squashed), phonetic(target)
        similar = bool(a and b) and _lev(a, b) <= 1
    if not similar:
        return False
    h, c = squashed.lower(), target.lower()
    if h != c and abs(len(h) - len(c)) <= 3 and (h.startswith(c) or c.startswith(h) or h.endswith(c) or c.endswith(h)):
        # a cut-off read ("Danke" -> "anke": shorter) or an inflection of a real word ("Unterlage"
        # -> "Unterlagen") is no spelling; a name completed ("Claud" -> "Claude") is
        if len(c) < len(h) or is_word(squashed):
            return False
    words = corrected.split()
    if len(words) > 1:
        # several words ("Wispaflow" -> "Wispr Flow"): a name or brand, each word with a capital
        # (not "zu Hause"), and not an ordinary word split up ("Haustür" -> "Haus Tür")
        return all(any(c.isupper() or c.isdigit() for c in w) for w in words) and \
            not (is_word(squashed) and all(is_word(w) for w in words))
    return not (corrected[:1].islower() and is_word(corrected))


def corrections(pasted, now):
    """(heard, corrected) pairs: one corrected word for one to three heard ones ("Mai Pace" ->
    "myPACE"), a name of two or three words for one to three heard ones ("Wispaflow" -> "Wispr
    Flow"), and neighbouring words corrected one by one ("Tingo Abi" -> "Tiingo API"). A name not
    spelled like what was heard comes as the exact wording around it, at least two words, as
    written ("USB-Flow" -> "WhisperFlow"); see exact_worthy."""
    am, bm = list(_WORD.finditer(pasted)), list(_WORD.finditer(now))
    a, b = [m.group() for m in am], [m.group() for m in bm]
    sm = difflib.SequenceMatcher(None, [w.lower() for w in a], [w.lower() for w in b], autojunk=False)
    ops = sm.get_opcodes()
    # a rewrite (a translation in command mode, a rephrased sentence) is not a spelling fix: when
    # more than a quarter of the pasted words were replaced or deleted, nothing is learned
    changed = sum(i2 - i1 for tag, i1, i2, _, _ in ops if tag in ("replace", "delete"))
    if changed > max(3, len(a) // 4):
        return []
    out = []
    for tag, i1, i2, j1, j2 in ops:
        if tag != "replace":
            continue
        if 1 <= i2 - i1 <= 3 and j2 - j1 == 1:
            pairs = [(" ".join(a[i1:i2]), b[j1])]
        elif i2 - i1 == j2 - j1:
            pairs = [p for p in zip(a[i1:i2], b[j1:j2]) if worth_learning(*p)] or \
                [(" ".join(a[i1:i2]), " ".join(b[j1:j2]))]
        elif 1 <= i2 - i1 <= 3 and 2 <= j2 - j1 <= 3:
            pairs = [(" ".join(a[i1:i2]), " ".join(b[j1:j2]))]
        else:
            continue
        similar = [p for p in pairs if worth_learning(*p)]
        if similar:
            out += similar
            continue
        # exact wording: never a lone word (a lone "API" -> "SDK" would rewrite every API), so a
        # one-word change takes the unchanged word next to it ("USB" -> "Whisper" in "USB-Flow")
        if i2 - i1 == 1 and j2 - j1 == 1:
            if i2 < len(a) and j2 < len(b) and a[i2].lower() == b[j2].lower():
                i2, j2 = i2 + 1, j2 + 1
            elif i1 > 0 and j1 > 0 and a[i1 - 1].lower() == b[j1 - 1].lower():
                i1, j1 = i1 - 1, j1 - 1
            else:
                continue
        heard = pasted[am[i1].start():am[i2 - 1].end()]
        fixed = now[bm[j1].start():bm[j2 - 1].end()]
        if exact_worthy(heard, fixed):
            out.append((heard, fixed))
    return out


def with_neighbour(pasted, now, heard, corrected):
    """The pair widened by one word that stayed the same ("Clout" -> "Claude" becomes "Clout Code"
    -> "Claude Code"), so a learned fix of an ordinary word ("clout") only fires in that context."""
    a, b = _WORD.findall(pasted), _WORD.findall(now)
    hw = heard.split()
    for i in range(len(a) - len(hw) + 1):
        if [w.lower() for w in a[i:i + len(hw)]] != [w.lower() for w in hw]:
            continue
        nxt = a[i + len(hw)] if i + len(hw) < len(a) else None
        prv = a[i - 1] if i > 0 else None
        for j, w in enumerate(b):
            if w != corrected:
                continue
            if nxt and j + 1 < len(b) and b[j + 1].lower() == nxt.lower():
                return f"{heard} {nxt}", f"{corrected} {b[j + 1]}"
            if prv and j > 0 and b[j - 1].lower() == prv.lower():
                return f"{prv} {heard}", f"{b[j - 1]} {corrected}"
    return heard, corrected


def _u16(s):
    """Length in UTF-16 units, the unit of accessibility text ranges."""
    return len(s.encode("utf-16-le")) // 2


def find_pasted(text, region, min_ratio=0.9):
    """(start, end) of the pasted `text` inside `region` (the field text before the cursor), found
    by its words: rich editors (the Claude app, Slack, Notion) do not keep a paste character for
    character (blank lines collapse, list dashes become bullets). None when under 90 % of its words
    line up."""
    a = [w.lower() for w in _WORD.findall(text)]
    spans = [(m.start(), m.end()) for m in _WORD.finditer(region)]
    b = [region[i:j].lower() for i, j in spans]
    if not a or not b:
        return None
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    blocks = [m for m in sm.get_matching_blocks() if m.size]
    if sum(m.size for m in blocks) < min_ratio * len(a):
        return None
    while len(blocks) > 1 and blocks[0].size < 3:   # a stray "und" in the text before the paste
        blocks.pop(0)
    first, last = blocks[0], blocks[-1]
    # widen over words of the text that no longer match at either end (the user corrected them)
    i = max(0, first.b - first.a)
    j = min(len(spans) - 1, last.b + last.size - 1 + (len(a) - last.a - last.size))
    return spans[i][0], spans[j][1]


class Learner:
    def __init__(self, on_learn, allowed=lambda app: True, own_pids=lambda: ()):
        self.on_learn = on_learn            # called with (heard, corrected) from a worker thread
        self.allowed = allowed              # may this app's text field be read (context settings)?
        self.own_pids = own_pids
        self._gen = 0

    def cancel(self):
        """End any watch (a new take starts: its paste or a command edit is not a correction)."""
        self._gen += 1

    def watch(self, pid, text):
        """Follow the text just pasted into the app `pid` (a newer paste ends the old watch).
        pid None: the text went to the clipboard; follow it into whichever app it is pasted."""
        self._gen += 1
        threading.Thread(target=self._run_pooled, args=(self._gen, pid, text), name="learn", daemon=True).start()

    def _run_pooled(self, gen, pid, text):
        import objc
        with objc.autorelease_pool():
            self._run(gen, pid, text)

    def _find(self, a, gen, pid, text):
        """(app pid, field, start, length) once the text is in the focused field, else None."""
        wait = LOCATE_S if pid else PASTE_WAIT_S
        waited = 0.0
        while waited < wait and gen == self._gen:
            time.sleep(0.4 if pid else POLL_S)
            waited += 0.4 if pid else POLL_S
            front = context.frontmost(self.own_pids())
            if front is None or (pid and front["pid"] != pid) or not self.allowed(front) \
                    or not context.readable_now(front["pid"]):
                continue
            try:
                el, start, n = self._locate(a, front["pid"], text)
            except Exception:
                el = None
            if el is not None:
                return front["pid"], el, start, n
        return None

    def _run(self, gen, pid, text):
        a = context.ax()
        hit = self._find(a, gen, pid, text)
        if hit is None:
            if gen == self._gen:
                print("learn: pasted text not found in the field" if pid else "learn: clipboard text not pasted")
            return
        pid, el, start, n = hit
        print("learn: watching the pasted text")
        seen, learned, deadline, misses = set(), set(), time.time() + WATCH_S, 0
        while time.time() < deadline and gen == self._gen:
            time.sleep(POLL_S)
            front = context.frontmost()
            if front is None or front["pid"] != pid:
                continue                  # another app in front: pause (the deadline still runs)
            if not context.readable_now(pid):
                print("learn: secure input or private window, stopped")
                return
            # found again on every read: an edit before the text shifts it, and a fixed window
            # then read cut-off words as "corrections" ("Danke" -> "anke")
            lo = max(0, start - 300)
            region = self._read(a, el, lo, n + 600)
            span = find_pasted(text, region, min_ratio=0.6) if region else None
            if span is None:
                misses += 1
                if misses >= 5:
                    print("learn: pasted text gone, stopped")
                    return
                continue
            misses = 0
            now = region[span[0]:span[1]]
            found = set(corrections(text, now))
            for heard, corrected in sorted((found & seen) - learned):   # seen twice: not half typed
                learned.add((heard, corrected))
                if worth_learning(heard, corrected):
                    self.on_learn(heard, corrected, *with_neighbour(text, now, heard, corrected))
                else:                     # not alike in spelling: only this exact wording
                    self.on_learn(heard, corrected, heard, corrected, exact=True)
                deadline = max(deadline, time.time() + EXTEND_S)
            seen = found
        print(f"learn: {len(learned)} corrections" if learned else "learn: no correction")

    @staticmethod
    def _locate(a, pid, text):
        """The focused field, where the pasted text starts in it and how long it is there (both in
        the field's own units), or (None, 0, 0). The paste ends at the cursor; the stretch before
        it is read with some slack and the text found by its words (find_pasted)."""
        err, el = a.get(a.app(pid), "AXFocusedUIElement")
        if err != 0 or el is None:
            return None, 0, 0
        err, f = a.multi(el, context.FOCUS_ATTRS)
        if err != 0 or f["AXSubrole"] == context.SECURE_SUBROLE:
            return None, 0, 0
        rng, chars = a.range_of(f["AXSelectedTextRange"]), f["AXNumberOfCharacters"]
        if rng is None or not isinstance(chars, int):
            return None, 0, 0
        lo = max(0, rng[0] - _u16(text) - max(200, len(text) // 4))
        e, region = a.string_for_range(el, lo, rng[0] - lo)
        span = find_pasted(text, region) if e == 0 and region else None
        if span is None:
            return None, 0, 0
        i, j = span
        return el, lo + _u16(region[:i]), _u16(region[i:j])

    @staticmethod
    def _read(a, el, start, length):
        err, f = a.multi(el, ["AXNumberOfCharacters"])
        chars = f.get("AXNumberOfCharacters") if err == 0 else None
        if not isinstance(chars, int) or chars <= start:
            return None
        e, got = a.string_for_range(el, start, min(length, chars - start))
        return got if e == 0 else None
