"""Personal dictionary: fixes how Whisper spells terms it cannot know ("AI-Slog" -> "AI-Slop",
"ChatCN" -> "shadcn", "FSSC" -> "FS-SC") by phonetic fuzzy matching after transcription.

Ordinary words must never change, so a fuzzy match is only accepted when
  - the candidate sounds almost the same as the term (phonetic skeleton, see `phonetic`), and
  - a single word is NOT a real German or English word (macOS spell checker), and
  - a word group starts with the term's first part or contains a non-word ("Chat CN",
    "AI Slot"). Two real words never fuse into a term on sound alone ("that line" stays, it
    does not become "Deadline").
Inflected forms of a term ("Repos", "Feedbacks", "deploy") are left alone.
Exact spellings that differ only in hyphens/spaces/inner case ("FSSC", "AI Slop") are always
normalised; a different first letter only where the term is lowercase and the word does not
start a sentence ("nur Shadcn-Komponenten" -> "nur shadcn-Komponenten"). A capitalised word is
never upper-cased into an all-caps term ("Herr Acar" stays, it does not become "ACAR").
A span that already is one of the terms (or a variant kept above) is never rewritten into
another term, so adding "AI-Slot" or "Acar" to the dictionary protects them."""
import json
import re
import unicodedata
import threading
from functools import lru_cache

import settings

UNIT = re.compile(r"[^\W_]+")          # letters/digits incl. umlauts
KEEP = -1.0                             # _score: the span already is a term, leave it alone
JOINABLE = re.compile(r"[ \-‐‑]?")      # what may sit between the parts of one term
MAX_SPAN = 3                            # "To Do Liste" is three units

_TRANSLIT = str.maketrans({"ä": "a", "ö": "o", "ü": "u", "ß": "s", "é": "e", "è": "e",
                           "à": "a", "á": "a", "ó": "o", "í": "i", "ñ": "n", "ç": "s"})
_MULTI = [(re.compile(p), r) for p, r in (
    (r"tsch", "S"), (r"sch", "S"), (r"sh", "S"), (r"ch", "S"), (r"ck", "K"), (r"ph", "F"),
    (r"th", "T"), (r"qu", "KF"), (r"dt", "T"), (r"tz|ts|z", "S"), (r"x", "KS"),
    (r"c(?=[eiy])", "S"), (r"c", "K"))]
_SINGLE = {**{v: "A" for v in "aeiouy"}, "b": "P", "p": "P", "d": "T", "t": "T", "g": "K",
           "k": "K", "q": "K", "f": "F", "v": "F", "w": "F", "s": "S", "l": "L", "m": "M",
           "n": "N", "r": "R", "j": "J", "h": ""}


def _key(s):
    return "".join(UNIT.findall(s.lower()))


def phonetic(word):
    """Rough German/English sound skeleton: vowels -> A, voiced/unvoiced pairs merged,
    sch/sh/ch -> S, h silent, repeats collapsed. 'ChatCN' and 'shadcn' both give 'SATKN'.
    Accents fall away first, so a learned 'Szymańska' still matches the heard 'Schimanska'."""
    s = _key(word).replace("ł", "l")
    s = "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c) or c in "\u0308")
    s = unicodedata.normalize("NFC", s).translate(_TRANSLIT)
    for pattern, repl in _MULTI:
        s = pattern.sub(repl, s)
    out = []
    for ch in s:
        sym = ch if ch.isupper() or ch.isdigit() else _SINGLE.get(ch, ch)
        if sym and (not out or out[-1] != sym):
            out.append(sym)
    return "".join(out)


def _lev(a, b):
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


_spell_lock = threading.Lock()
_spell = {"checker": None, "failed": False}


@lru_cache(maxsize=4096)
def is_word(word):
    """True when macOS knows `word` in German or English. A capital after the first letter
    ("ChatCN", "FSSC") marks an acronym or a brand, never an ordinary word; the spell checker
    waves those through, so they are decided here. Without AppKit every word counts as a real
    word, which only makes the dictionary more cautious."""
    if any(c.isupper() for c in word[1:]):
        return False
    with _spell_lock:
        if _spell["checker"] is None and not _spell["failed"]:
            try:
                from AppKit import NSSpellChecker
                _spell["checker"] = NSSpellChecker.sharedSpellChecker()
            except Exception:
                _spell["failed"] = True
        checker = _spell["checker"]
        if checker is None:
            return True
        for lang in ("de", "en"):
            rng, _ = checker.checkSpellingOfString_startingAt_language_wrap_inSpellDocumentWithTag_wordCount_(
                word, 0, lang, False, 0, None)
            if rng.length == 0:
                return True
    return False


class _Term:
    def __init__(self, text):
        self.text = text
        self.key = _key(text)
        self.parts = [p.lower() for p in UNIT.findall(text)]
        self.code = phonetic(text)


def _first_letter_case_only(surface, term):
    return surface != term and surface[1:] == term[1:] and surface[:1].lower() == term[:1].lower()


def _sentence_start(text, pos):
    before = text[:pos].rstrip()
    return not before or before[-1] in ".!?:\n" or "\n" in text[len(before):pos]


class Dictionary:
    def __init__(self, terms=()):
        self.set_terms(terms)

    @classmethod
    def load(cls, path=None):
        d = cls()
        d.path = path
        d.reload()
        return d

    def reload(self):
        path = getattr(self, "path", None) or settings.data_dir() / "dictionary.json"
        self.broken = False
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            terms = data.get("terms", []) if isinstance(data, dict) else []
            repl = data.get("replacements", {}) if isinstance(data, dict) else {}
        except FileNotFoundError:
            terms, repl = [], {}
        except (OSError, ValueError):
            # unreadable: keep it as it is (a backup next to it) and never write over it, or the
            # next learned word would replace every term with that one word
            self.broken = True
            terms, repl = [], {}
            try:
                backup = path.with_name(path.name + ".broken")
                if not backup.exists():
                    backup.write_bytes(path.read_bytes())
                print(f"dictionary: {path.name} cannot be read; kept, copy in {backup.name}, learning paused")
            except OSError:
                pass
        self.set_terms(terms)
        self.set_replacements(repl)

    def set_replacements(self, repl):
        """Learned fixes {"clout code": "Claude Code"}: exact heard phrases, case and spacing free."""
        self.replacements = {k: v for k, v in (repl or {}).items() if isinstance(k, str) and isinstance(v, str) and k.strip()}
        # words of a learned wording may come with spaces or hyphens ("USB-Flow", "USB Flow")
        self._repl = [(re.compile(r"(?<!\w)" + r"[\s\-]+".join(map(re.escape, re.split(r"[\s\-]+", k))) + r"(?!\w)", re.I), v)
                      for k, v in sorted(self.replacements.items(), key=lambda kv: -len(kv[0]))]

    def set_terms(self, terms):
        seen, clean = set(), []
        for t in terms:
            if isinstance(t, str) and t.strip() and t.strip() not in seen:
                seen.add(t.strip())
                clean.append(t.strip())
        self.terms = clean
        self._terms = [_Term(t) for t in clean if _key(t)]

    def _write(self, update):
        path = getattr(self, "path", None) or settings.data_dir() / "dictionary.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            data = data if isinstance(data, dict) else {}
        except FileNotFoundError:
            data = {}
        except (OSError, ValueError):
            raise OSError("dictionary.json cannot be read; not written")
        update(data)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(path)
        return data

    def add_replacement(self, heard, corrected):
        key = " ".join(heard.lower().split())
        if not key or self.replacements.get(key) == corrected:
            return False
        try:
            data = self._write(lambda d: d.setdefault("replacements", {}).__setitem__(key, corrected))
        except OSError as e:
            print(f"dictionary: {e}")
            return False
        self.set_replacements(data.get("replacements", {}))
        return True

    def add_term(self, term):
        """Learned spelling: into dictionary.json (other keys kept) and into this dictionary."""
        term = term.strip()
        if not term or term in self.terms:
            return False
        path = getattr(self, "path", None) or settings.data_dir() / "dictionary.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            data = data if isinstance(data, dict) else {}
        except FileNotFoundError:
            data = {}
        except (OSError, ValueError):
            print("dictionary: file cannot be read, the learned word is not written")
            return False
        terms = [t for t in data.get("terms", []) if isinstance(t, str)] + [term]
        data["terms"] = terms
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(path)
        self.set_terms(terms)
        return True

    # -- matching -------------------------------------------------------------------------
    def _score(self, units, text, term):
        """None = no match, KEEP = the span already is this term (or a variant that stays),
        else a cost (lower is better)."""
        start, end = units[0].start(), units[-1].end()
        surface = text[start:end]
        key = "".join(u.group().lower() for u in units)
        if key == term.key:
            if surface == term.text:
                return KEEP
            # a capital first letter is left alone at a sentence start and for capitalised
            # terms ("repo" in English stays); "Shadcn" mid-sentence becomes "shadcn"
            if _first_letter_case_only(surface, term.text) and (
                    term.text[:1].isupper() or _sentence_start(text, start)):
                return KEEP
            # an all-caps term never upper-cases a capitalised word: "Herr Acar" is a name
            letters = [c for c in term.text if c.isalpha()]
            if len(units) == 1 and len(letters) > 1 and all(c.isupper() for c in letters) \
                    and surface[:1].isupper() and surface[1:].islower():
                return KEEP
            return 0.0
        n, m = len(key), len(term.key)
        if m < 4 or n < 4 or abs(n - m) > 2:
            return None
        # inflected forms of the term itself ("Repos", "Feedbacks", "deploy")
        if (key.startswith(term.key) and n - m <= 3) or (term.key.startswith(key) and m - n <= 2):
            return None
        code = phonetic(key)
        if not code or code[0] != term.code[0]:
            return None
        d_ph, d_surf = _lev(code, term.code), _lev(key, term.key)
        if m <= 5:
            ok = d_ph == 0 and d_surf <= 1
        elif m <= 8:
            ok = (d_ph == 0 and d_surf <= 3) or (d_ph <= 1 and d_surf <= 1)
        else:
            ok = (d_ph == 0 and d_surf <= 3) or (d_ph <= 1 and d_surf <= 2)
        if not ok:
            return None
        words = [u.group() for u in units]
        if len(words) == 1:
            # a real word stays (macOS knows German nouns only capitalised too, so "capitalised
            # only" cannot tell a name like "Tingo" from "Bäcker"; such names are fixed by the
            # exact wordings the learner adds)
            if is_word(words[0]):
                return None
        else:
            joined = "".join(words)
            if is_word(joined) or is_word(joined[:1] + joined[1:].lower()):
                return None
            anchored = len(term.parts) > 1 and words[0].lower() == term.parts[0]
            has_non_word = any(len(w) > 1 and not is_word(w) for w in words)
            if not (anchored or has_non_word):
                return None
        return d_ph + 0.5 * d_surf + 0.01 * len(words)

    def correct(self, text):
        for pattern, value in getattr(self, "_repl", []):
            text = pattern.sub(value, text)
        if not text or not self._terms:
            return text
        units = list(UNIT.finditer(text))
        out, pos, i = [], 0, 0
        while i < len(units):
            best = None
            for span in range(1, MAX_SPAN + 1):
                group = units[i:i + span]
                if len(group) < span:
                    break
                if span > 1 and not JOINABLE.fullmatch(text[group[-2].end():group[-1].start()]):
                    break
                for term in self._terms:
                    cost = self._score(group, text, term)
                    if cost is not None and (best is None or cost < best[0]):
                        best = (cost, span, term)
            if best is None:
                i += 1
                continue
            cost, span, term = best
            if cost == KEEP:
                i += span       # already a term: no other term may claim these words
                continue
            start, end = units[i].start(), units[i + span - 1].end()
            out.append(text[pos:start])
            out.append(term.text)
            pos = end
            i += span
        out.append(text[pos:])
        return "".join(out)


# -- names from the screen (per take, KONTEXT-PLAN.md) --------------------------------------------
NAME_CUES = {"frau", "herr", "herrn", "dr", "prof", "hallo", "hi", "hey", "liebe", "lieber", "liebes",
             "geehrte", "geehrter", "an", "mit", "von", "dear", "mr", "mrs", "ms"}
_WORD = re.compile(r"[^\W\d_][^\W\d_'’]*(?:-[^\W\d_]+)*")


def _fold_name(word):
    """Spelling-independent form: accents dropped, Polish sz/cz/rz as German sounds them."""
    s = unicodedata.normalize("NFKD", word.lower().replace("ł", "l"))
    s = "".join(c for c in s if not unicodedata.combining(c))
    return s.replace("sz", "sch").replace("cz", "tsch").replace("rz", "sch")


def correct_names(text, names):
    """'Schimanska' -> 'Szymańska' when that name is on screen. Only capitalised words; exactly
    one name may share the sound; the heard word must be no ordinary word unless a cue ("Frau",
    "Hallo") precedes it; names of five letters or fewer need a cue and at most one letter off.
    Returns (text, [(heard, name), ...])."""
    cands = [(n, phonetic(_fold_name(n))) for n in dict.fromkeys(names) if len(n) >= 3]
    if not text or not cands:
        return text, []
    fixes = []

    def repl(m):
        w = m.group()
        if not w[0].isupper() or any(w == n for n, _ in cands):
            return w
        code = phonetic(_fold_name(w))
        hits = {n for n, c in cands if c == code or (len(c) >= 6 and _lev(c, code) <= 1)}
        if len(hits) != 1:
            return w
        name = hits.pop()
        prev = text[:m.start()].split()[-1:]
        cue = bool(prev) and prev[0].lower().strip(".,:;!") in NAME_CUES
        if len(name) <= 5 and not (cue and _lev(_fold_name(w), _fold_name(name)) <= 1):
            return w
        if not cue and is_word(w):
            return w
        fixes.append((w, name))
        return name
    return _WORD.sub(repl, text), fixes


def spell_fix(text):
    """macOS autocorrection for words that are wrong in German and English alike ("Beamr" ->
    "Beamer"). The 4B model picks wrong words here ("Beamter"), the system spell checker does not.
    Names and words valid in either language stay."""
    with _spell_lock:
        if _spell["checker"] is None and not _spell["failed"]:
            try:
                from AppKit import NSSpellChecker
                _spell["checker"] = NSSpellChecker.sharedSpellChecker()
            except Exception:
                _spell["failed"] = True
        checker = _spell["checker"]
    if checker is None or not text:
        return text
    out, pos, done = [], 0, 0
    while pos < len(text):
        with _spell_lock:
            rng, _ = checker.checkSpellingOfString_startingAt_language_wrap_inSpellDocumentWithTag_wordCount_(
                text, pos, "de", False, 0, None)
        if rng.length == 0:
            break
        word = text[rng.location:rng.location + rng.length]
        pos = rng.location + rng.length
        if is_word(word) or any(c.isupper() for c in word[1:]):
            continue
        with _spell_lock:
            fix = checker.correctionForWordRange_inString_language_inSpellDocumentWithTag_(rng, text, "de", 0)
        if fix and str(fix) != word:
            out.append(text[done:rng.location])
            out.append(str(fix))
            done = pos
    out.append(text[done:])
    return "".join(out)

