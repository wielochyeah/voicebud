"""Deterministic guards against the classic failure modes of Whisper and small LLMs:
repetition loops, invented phrases on silence, leaked instructions, and rewording."""
import re
from difflib import SequenceMatcher

# Phrases Whisper invents on silence or noise (it learned them from subtitled video).
HALLUCINATIONS = {
    "thank you", "thank you very much", "thanks", "thanks for watching",
    "thank you for watching", "bye", "you", "okay", "vielen dank", "danke",
    "danke schön", "dankeschön", "tschüss", "bis zum nächsten mal",
}
HALLUCINATION_PATTERN = re.compile(
    r"untertitel|amara\.org|zdf für funk|copyright (wdr|swr|ndr)", re.I)

# Fragments of our own instructions that must never end up in the pasted text.
LEAK_MARKERS = (
    "kopiere den folgenden text", "füllwörter", "übersetze ihn nicht", "transkript-bereiniger",
    "copy the following text", "filler words", "transcript cleaner", "never translate",
    "bekannte begriffe (", "known terms (",
)
PREAMBLE = re.compile(
    r"^\s*(hier ist|hier der|gerne|natürlich|sure|here is|here's|bereinigter text|"
    r"der bereinigte text|cleaned text)[^:\n]{0,60}:\s*", re.I)


def _norm(word):
    return re.sub(r"[^\wäöüß]", "", word.lower())


def collapse_repeats(text, min_repeats=4, max_n=8):
    """Collapse runs of the same 1..max_n word sequence repeated >= min_repeats times
    into one occurrence (also swallowing a cut-off partial repeat at the very end).
    Real speech rarely repeats a phrase 4+ times in a row; decoder loops do. Line breaks and
    list layout stay as they are."""
    pieces = re.findall(r"(\s*)(\S+)", text)
    words = [w for _, w in pieces]
    keys = [_norm(w) for w in words]
    out, i = [], 0
    while i < len(words):
        for n in range(1, max_n + 1):  # shortest unit first, so "a b a b …" collapses to "a b"
            unit = keys[i:i + n]
            if len(unit) < n or not any(unit):
                continue
            k = 1
            while keys[i + k * n:i + (k + 1) * n] == unit:
                k += 1
            if k >= min_repeats:
                out.extend(pieces[i:i + n])
                i += k * n
                tail = keys[i:]
                if 0 < len(tail) < n and tail == unit[:len(tail)]:
                    i = len(words)
                break
        else:
            out.append(pieces[i])
            i += 1
    return "".join(ws + w for ws, w in out).strip()


_HUM = re.compile(r"^(m+|mh+|hm+|mhm+|ähm|äh|öhm)[,…]$", re.I)


def strip_hums(text):
    """Drop the hums Whisper sometimes writes out ("Also M, ich wollte"). Only comma-marked
    ones go, so a real "Größe M." stays."""
    words = text.split(" ")
    kept = [w for w in words if not _HUM.match(w)]
    if len(kept) == len(words):
        return text
    if kept and words and _HUM.match(words[0]):
        kept[0] = kept[0][:1].upper() + kept[0][1:]
    return " ".join(kept)


def drop_cut_repeat(text, min_n=8):
    """Stop pressed mid-sentence: Whisper sometimes closes the take by repeating a stretch said
    earlier ("Trotzdem sollten wir die ersten Ergebnisse aus der Umfrage und die sehen
    eigentlich ganz gut aus." with sentence 2 again). collapse_repeats only sees adjacent loops.
    A final sentence that is at least two thirds made of 8+ word runs already said earlier in
    the take is dropped (a deliberate short repeat like "Ich wiederhole: bis Freitag die Zahlen
    schicken." stays). Only for the final text of a take whose speech runs into the stop."""
    parts = re.split(r"(?<=[.!?…])\s+", text.strip())
    if len(parts) < 2:
        return text
    last = [k for k in (_norm(w) for w in parts[-1].split()) if k]
    if len(last) < min_n:
        return text
    before = [k for k in (_norm(w) for w in " ".join(parts[:-1]).split()) if k]
    said = set(before)
    if any(i >= 3 and w not in said for i, w in enumerate(last)):
        # a new word past a short lead-in: a parallel sentence ("... für den Kunden Schulz."),
        # not Whisper repeating itself (its repeats only invent a lead-in like "Trotzdem sollten wir")
        return text
    grams = {tuple(before[i:i + min_n]) for i in range(len(before) - min_n + 1)}
    covered = set()
    for i in range(len(last) - min_n + 1):
        if tuple(last[i:i + min_n]) in grams:
            covered.update(range(i, i + min_n))
    if 3 * len(covered) >= 2 * len(last):
        return " ".join(parts[:-1])
    return text


def is_hallucination(text, speech_seconds, no_speech_prob):
    """True when a transcript is almost certainly invented rather than spoken."""
    key = " ".join(_norm(w) for w in text.split()).strip()
    if HALLUCINATION_PATTERN.search(text) and speech_seconds < 3.0:
        return True
    return key in HALLUCINATIONS and (speech_seconds < 0.35 or no_speech_prob > 0.5)


def clean_llm_output(output, source):
    """Return the LLM output with a leading 'Hier ist …:' stripped, or None when it must
    be rejected (leaked instructions, runaway length, nothing left)."""
    out = re.sub(r"</?(transkript|transcript)>", "", output, flags=re.I)
    out = PREAMBLE.sub("", out).strip().strip('"„“').strip()
    low = out.lower()
    if not out or any(m in low for m in LEAK_MARKERS):
        return None
    n_src, n_out = len(source.split()), len(out.split())
    if n_src >= 6 and not (0.5 <= n_out / n_src <= 1.6):
        return None
    return collapse_repeats(out)


# --- faithful cleanup ------------------------------------------------------------------------
# The LLM may delete fillers and repeated words, fix punctuation, capitalisation, number format
# and layout. Every other word change ("Trotzdem"->"Trotdem", "wollte"->"möchte",
# "Ungefähr"->"Etwa", dropped content words, invented words) is put back to what was said.

FILLERS = {
    "äh", "ähm", "ähh", "ähhm", "öh", "öhm", "hm", "hmm", "mhm", "ehm", "eh", "em", "m", "mm", "mh",
    "mmh", "halt", "quasi",
    "sozusagen", "also", "ja", "ne", "nee", "genau", "irgendwie", "eigentlich", "mal", "eben",
    "einfach", "so", "okay", "ok", "naja", "gell", "um", "uh", "uhm", "erm", "ah", "like",
    "basically", "actually", "literally", "well", "yeah", "right", "just",
    "erstens", "zweitens", "drittens", "viertens", "firstly", "secondly", "thirdly",
}
FILLER_PHRASES = [("und", "so"), ("oder", "so"), ("weißt", "du"), ("na", "ja"),
                  ("you", "know"), ("i", "mean"), ("sort", "of"), ("kind", "of")]
REPEAT_WINDOW = 3     # "das das", "ob … ob" within three words
CLAUSE_STARTERS = {"dass", "ob", "weil", "wenn", "als", "obwohl", "damit", "sodass", "aber",
                   "sondern", "denn", "doch", "wie", "wo", "was", "that", "because", "but",
                   "which", "if", "when"}
CONJUNCTIONS = {"und", "and", "oder", "or"}
# spoken enumeration the LLM turns into list markers ("and third the guest list" -> "3. The guest list")
ENUMERATORS = {"erstens", "zweitens", "drittens", "viertens", "fünftens", "sechstens", "siebtens",
               "achtens", "neuntens", "zehntens", "first", "second", "third", "fourth", "fifth",
               "firstly", "secondly", "thirdly", "lastly", "finally"}
# self-corrections: "am Dienstag, nein, sorry, am Mittwoch" -> "am Mittwoch"
LIST_WORDS = {"punkt", "nummer", "number", "point"}     # "Punkt eins, die Folien" -> "1. Die Folien"
# spoken punctuation the LLM may turn into the character itself
SPOKEN_MARKS = {"punkt": ".", "komma": ",", "fragezeichen": "?", "ausrufezeichen": "!", "doppelpunkt": ":",
                "semikolon": ";", "period": ".", "comma": ","}
CORRECTION_CUES = [("nein",), ("nee",), ("sorry",), ("korrektur",), ("pardon",), ("quatsch",),
                   ("ich", "meine"), ("also", "eigentlich"), ("oder", "besser"),
                   ("no",), ("i", "mean"), ("or", "rather"), ("scratch", "that")]
MAX_REPARANDUM = 4    # words the speaker takes back before the cue
MAX_LEAD_IN = 2       # words repeated after the cue ("am" in "am Dienstag, nein, am Mittwoch")
COMMA_BEFORE = {"dass", "weil", "obwohl", "sodass"}
_SENTENCE_END = re.compile(r"[.!?…:][\"'»«“”)\]]*$")
_EDGES = re.compile(r"^([^\w%€$]*)(.*?)([^\w%€$]*)$", re.S)
_LIST_MARKER = re.compile(r"^(\d{1,2}[.)]|[-–—•*])$")
_SWAPS = [{"das", "dass"}]

_DE_UNITS = {"null": 0, "ein": 1, "eins": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1,
             "zwei": 2, "zwo": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7,
             "acht": 8, "neun": 9}
_DE_TEENS = {"zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14, "fünfzehn": 15,
             "sechzehn": 16, "siebzehn": 17, "achtzehn": 18, "neunzehn": 19}
_DE_TENS = {"zwanzig": 20, "dreißig": 30, "dreissig": 30, "vierzig": 40, "fünfzig": 50,
            "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90}
_DE_ORD = {"erst": 1, "zweit": 2, "dritt": 3, "viert": 4, "fünft": 5, "sechst": 6, "siebt": 7,
           "siebent": 7, "acht": 8, "neunt": 9}
_EN_SMALL = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
    "fifteen sixteen seventeen eighteen nineteen".split())}
_EN_TENS = {w: 10 * i for i, w in enumerate(
    "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()) if w != "_"}
_EN_ORD = {"first": 1, "second": 2, "third": 3, "fifth": 5, "eighth": 8, "ninth": 9, "twelfth": 12}
_UNIT_WORDS = {"prozent": "%", "percent": "%", "%": "%", "euro": "€", "€": "€", "dollar": "$",
               "$": "$"}
_DECIMAL_WORDS = {"komma", "point"}


def _de_below_100(s):
    for table in (_DE_UNITS, _DE_TEENS, _DE_TENS):
        if s in table:
            return table[s]
    if "und" in s:
        a, b = s.split("und", 1)
        if a in _DE_UNITS and b in _DE_TENS and _DE_UNITS[a] > 0:
            return _DE_UNITS[a] + _DE_TENS[b]
    return None


def _de_below_1000(s):
    if "hundert" in s:
        a, b = s.split("hundert", 1)
        # "zwölfhundertfünfzig" = 1250, "neunzehnhundertneunundachtzig" = 1989
        h = 1 if a in ("", "ein", "eins") else _DE_UNITS.get(a) or _de_below_100(a)
        rest = 0 if not b else _de_below_100(b.removeprefix("und"))
        return None if h is None or rest is None else h * 100 + rest
    return _de_below_100(s)


def _en_below_100(s):
    if s in _EN_SMALL:
        return _EN_SMALL[s]
    if s in _EN_TENS:
        return _EN_TENS[s]
    for tens, val in _EN_TENS.items():
        if s.startswith(tens) and s[len(tens):] in _EN_SMALL and _EN_SMALL[s[len(tens):]] > 0:
            return val + _EN_SMALL[s[len(tens):]]
    return None


def _cardinal(s):
    if "tausend" in s:
        a, b = s.split("tausend", 1)
        t = 1 if a in ("", "ein") else _de_below_1000(a)
        rest = 0 if not b else _de_below_1000(b.removeprefix("und"))
        return None if t is None or rest is None else t * 1000 + rest
    n = _de_below_1000(s)
    if n is None:
        n = _en_below_100(s)
    if n is None and s.endswith("hundred"):
        h = _en_below_100(s[:-7]) if s[:-7] else 1
        n = None if h is None else h * 100
    return n


def number_value(word):
    """Value of a spoken number word (German or English, cardinal or ordinal), else None."""
    s = re.sub(r"[^\wäöüß]", "", word.lower())
    if not s or s.isdigit():
        return int(s) if s else None
    n = _cardinal(s)
    if n is not None:
        return n
    if s in _EN_ORD:
        return _EN_ORD[s]
    for suffix in ("sten", "ster", "stes", "stem", "ste", "ten", "ter", "tes", "tem", "te"):
        if s.endswith(suffix):
            base = s[: -len(suffix)]
            if base + "t" in _DE_ORD and suffix.startswith("t"):
                return _DE_ORD[base + "t"]
            if base in _DE_ORD and not suffix.startswith("s"):
                return _DE_ORD[base]
            n = _cardinal(base)
            if n is not None and n >= 4:
                return n
    if s.endswith("th"):
        n = _cardinal(s[:-2]) or _cardinal(s[:-3] + "e") or _cardinal(s[:-4] + "y")
        if n is not None:
            return n
    return None


_MULTIPLIERS = {"hundert": 100, "hundred": 100, "tausend": 1000, "thousand": 1000,
                "million": 10 ** 6, "millionen": 10 ** 6, "mio": 10 ** 6, "milliarde": 10 ** 9,
                "milliarden": 10 ** 9, "mrd": 10 ** 9}


def _numeric(piece, dates=True):
    """Values of a digit token: "12.500" and "1.250,50" (German thousands), "2,5", "2.5", and
    dates or times like "1.12.2026" as their parts. A trailing dot marks a German date or ordinal
    ("5.11." is the fifth of November, not 5.11; "3." is third). Never raises."""
    if piece.endswith("."):
        parts = piece[:-1].split(".")
        if dates and all(x.isdigit() for x in parts) and (
                len(parts) == 1 or (len(parts) in (2, 3) and 1 <= int(parts[0]) <= 31 and 1 <= int(parts[1]) <= 12)):
            return [float(x) for x in parts]
        piece = piece[:-1]
    if re.fullmatch(r"\d{1,3}(\.\d{3})+(,\d+)?", piece):
        return [float(piece.replace(".", "").replace(",", "."))]
    if re.fullmatch(r"\d+[.,]\d+", piece) and not re.fullmatch(r"\d+\.\d{3}", piece):
        return [float(piece.replace(",", "."))]
    return [float(x) for x in re.split(r"[.,]", piece) if x]


def _number_signature(words, dates=True):
    """(has a number, numbers, other words) of a token run, so '70 %' == 'siebzig Prozent',
    '14:30 Uhr' == 'vierzehn Uhr dreißig' and '2,5' == 'zwei Komma fünf'."""
    nums, other, has_number = [], [], False
    pieces = re.findall(r"\d+(?:[.,]\d+)*\.?|[^\W\d_]+|[%€$]", " ".join(words).lower())
    pending_decimal = False
    cents = False                                # "zwölfhundertfünfzig Euro fünfzig" == "1.250,50 €"
    prev_num = False                             # the piece before was a number (for multipliers)
    for p in pieces:
        after_currency, cents = cents, False
        last_was_number, prev_num = prev_num, False
        if p[0].isdigit():
            vals = _numeric(p, dates)
            has_number = True
            prev_num = True
            if pending_decimal and vals:
                nums[-1] = float(f"{int(nums[-1])}.{int(vals[0])}")
                pending_decimal = False
                vals = vals[1:]
            if after_currency and nums and len(vals) == 1 and vals[0] < 100:
                nums[-1] = round(nums[-1] + vals[0] / 100, 2)
                continue
            nums.extend(vals)
            continue
        elif p in _UNIT_WORDS:
            other.append(_UNIT_WORDS[p])
            cents = _UNIT_WORDS[p] in "€$" and bool(nums)
            continue
        elif p in _DECIMAL_WORDS and nums:
            pending_decimal = True
            continue
        elif p in _MULTIPLIERS and nums and not pending_decimal and last_was_number:
            nums[-1] *= _MULTIPLIERS[p]          # "zwei tausend" -> 2000
            prev_num = True
            continue
        else:
            v = number_value(p)
            if v is None:
                other.append(p)
                continue
            val = float(v)
        has_number = True
        prev_num = True
        if pending_decimal:
            nums[-1] = float(f"{int(nums[-1])}.{int(val)}")
            pending_decimal = False
        elif after_currency and nums and val < 100:
            nums[-1] = round(nums[-1] + val / 100, 2)
        else:
            nums.append(val)
    return has_number, nums, other


def _numbers_equal(raw_words, clean_words, paused=False):
    """paused: a comma or a sentence end inside the raw stretch (the token edges carry it)."""
    r_has, r_nums, r_other = _number_signature(raw_words)
    # "zwanzig sechsundzwanzig" as 2026, never across a comma ("zwanzig, dreißig Stück")
    years = _years(r_nums) if not paused and "," not in " ".join(raw_words) else None
    # a token with a final dot is read both ways: a German date or ordinal ("5.11.") and a
    # decimal at a sentence end ("3.5.")
    for dates in (True, False):
        c_has, c_nums, c_other = _number_signature(clean_words, dates)
        if (r_has or c_has) and r_other == c_other and (r_nums == c_nums or years == c_nums):
            return True
    return False


def _years(nums):
    """'zwanzig sechsundzwanzig' said for 2026: 19 or 20 followed by 0..99 read as one year."""
    out, i = [], 0
    while i < len(nums):
        if i + 1 < len(nums) and nums[i] in (19.0, 20.0) and 0 <= nums[i + 1] < 100 and nums[i + 1] == int(nums[i + 1]):
            out.append(nums[i] * 100 + nums[i + 1])
            i += 2
        else:
            out.append(nums[i])
            i += 1
    return out


class _Tok:
    __slots__ = ("ws", "text", "lead", "core", "trail", "norm", "content", "raw", "flags")

    def __init__(self, ws, text, marker_ok=False):
        self.ws, self.text = ws, text
        self.lead, self.core, self.trail = _EDGES.match(text).groups()
        self.norm = _norm_token(self.core)
        self.content = bool(self.norm) and not (marker_ok and _LIST_MARKER.match(text))
        self.raw = None      # aligned raw token, when known
        self.flags = set()

    def render(self):
        return self.ws + self.lead + self.core + self.trail


def _norm_token(core):
    core = core.lower().replace("%", "prozent").replace("€", "euro")
    return re.sub(r"[^\wäöüß]|_", "", core)


def _tokens(text, cleaned=False):
    toks = []
    for m in re.finditer(r"(\s*)(\S+)", text):
        ws, word = m.groups()
        line_start = not toks or "\n" in ws
        toks.append(_Tok(ws, word, marker_ok=cleaned and line_start))
    return toks


def _ends_sentence(tok):
    return bool(_SENTENCE_END.search(tok.core + tok.trail))


def _set_first_case(word, upper):
    for i, ch in enumerate(word):
        if ch.isalpha():
            return word[:i] + (ch.upper() if upper else ch.lower()) + word[i + 1:]
    return word


def _correction_span(R, positions):
    """All positions of a deleted run that is one self-correction: up to MAX_REPARANDUM words
    taken back, then only cues and fillers, then at most MAX_LEAD_IN words, and the repair
    still follows in the raw text. A cue with nothing taken back before it ("Nein, ich meine
    das ernst") is not a correction."""
    norms = [R[p].norm for p in positions]
    cue_at = set()
    for k in range(len(norms)):
        for cue in CORRECTION_CUES:
            if tuple(norms[k:k + len(cue)]) == cue:
                cue_at.update(range(k, k + len(cue)))
    if not cue_at or positions[-1] + 1 >= len(R):
        return set()
    last = max(cue_at)
    # every stretch before a cue is something taken back ("an Herrn Weber, nein, an Frau Weber,
    # also nein, eigentlich an die Buchhaltung"); each may be up to MAX_REPARANDUM words
    segments, current = [], []
    for k, n in enumerate(norms[:last + 1]):
        if k in cue_at:
            if current:
                segments.append(current)
            current = []
        elif n not in FILLERS:
            current.append(n)
    if not segments or not norms[0] or (min(cue_at) == 0) or any(len(seg) > MAX_REPARANDUM for seg in segments):
        return set()
    # after the last cue only a repeated lead-in ("am" in "am Dienstag, nein, am Mittwoch") may
    # go; the repair itself stays, even when the LLM rewrote it ("um zehn, nein, um elf" -> 11)
    said = {n for seg in segments for n in seg} | {R[q].norm for q in range(max(0, positions[0] - 3), positions[0])}
    ok = set(positions[:last + 1])
    for k in range(last + 1, len(norms)):
        if norms[k] in FILLERS or (norms[k] in said and k - last <= MAX_LEAD_IN):
            ok.add(positions[k])
        else:
            break
    return ok


def _allowed_deletions(R, positions, filler_free, conj_last=False):
    """Raw content positions whose deletion is fine: fillers, filler phrases, a word repeated
    nearby, a stutter fragment, a self-correction, or a phrase the speaker had just said ("das
    wäre ganz cool … also das das wäre ganz cool")."""
    ok = _correction_span(R, positions) if positions else set()
    norms = [R[p].norm for p in positions]
    i = 0
    while i < len(positions):
        hit = next((len(ph) for ph in FILLER_PHRASES if tuple(norms[i:i + len(ph)]) == ph), 0)
        if hit:
            ok.update(positions[i:i + hit])
            i += hit
            continue
        p, n = positions[i], norms[i]
        near = [R[q].norm for q in range(max(0, p - REPEAT_WINDOW), min(len(R), p + REPEAT_WINDOW + 1))
                if q != p]
        nxt = R[p + 1].norm if p + 1 < len(R) else ""
        repeat = n in near and number_value(n) is None
        if n in FILLERS or repeat or (len(n) >= 3 and nxt != n and nxt.startswith(n)):
            ok.add(p)
        i += 1
    if conj_last:
        # "… cool. Und schau" -> "… cool. Schau"; "und drittens die Liste" -> "3. die Liste"
        for p in reversed(positions):
            n = R[p].norm
            # cardinals only ("Punkt drei" -> "3."): an ordinal is content ("bis zum fünften
            # elften" -> "5.11." must never lose the date)
            card = _cardinal(n)
            # an ordinal only as a list marker: "Erster Punkt, …", "Erstes, das Budget" -> "1."
            listy = (p + 1 < len(R) and R[p + 1].norm in LIST_WORDS) or R[p].trail[:1] in (",", ":")
            val = card if card is not None else (number_value(n) if listy else None)
            small = (val if val is not None else 99) <= 20 and not any(ch.isdigit() for ch in n)
            if n not in CONJUNCTIONS and n not in ENUMERATORS and n not in FILLERS and n not in LIST_WORDS and not small:
                break
            ok.add(p)
    rest = [p for p in positions if p not in ok]
    if len(rest) >= 2:
        # a self-repetition sits right next to its first version once fillers and the
        # repeats already accepted are skipped; a parallel structure ("dass du X machst,
        # dass du Y machst") does not, so that one stays
        seq = [q for q in filler_free if q not in ok]
        if rest[0] in seq:
            start = seq.index(rest[0])
            phrase = [R[p].norm for p in rest]
            n = len(phrase)
            before = [R[q].norm for q in seq[max(0, start - n):start]]
            after = [R[q].norm for q in seq[start + n:start + 2 * n]]
            if before == phrase or after == phrase:
                ok.update(rest)
    return ok


def _phrase_matches(raw_toks, clean_toks, term_keys):
    """True when a differing stretch is still an allowed change: same letters (hyphens,
    spacing, case), same numbers in another notation, a dictionary spelling, or das/dass."""
    if not raw_toks or not clean_toks:
        return False
    jr = "".join(t.norm for t in raw_toks)
    jc = "".join(t.norm for t in clean_toks)
    if jr == jc:
        return True
    if len(raw_toks) == len(clean_toks) == 1 and {jr, jc} in _SWAPS:
        return True
    for key in term_keys:
        if key and key in jc:
            before, _, after = jc.partition(key)
            if jr.startswith(before) and jr.endswith(after) and len(jr) > len(before) + len(after):
                # the LLM may respell what was said ("AI-Slog" -> "AI-Slop"), never swap in a
                # term for other words ("die Folien" -> "die Slides", "Rückmeldung" -> "Feedback")
                if _sounds_like(jr[len(before):len(jr) - len(after)], key):
                    return True
    if any("@" in t.core or re.search(r"\w\.\w", t.core) for t in clean_toks):
        # a spoken address: "nils at alvantiq punkt com" -> "nils@alvantiq.com", compared with its
        # @ and dots in place (letters alone let "nilswieloch@" for "nils punkt wieloch at" pass)
        spoken = "".join(_ADDRESS_WORDS.get(t.norm, t.core.lower()) for t in raw_toks)
        if spoken == "".join(t.core.lower() for t in clean_toks):
            return True
    return _numbers_equal([t.core for t in raw_toks], [_with_date_dot(t) for t in clean_toks],
                          paused=any(t.trail.strip() for t in raw_toks[:-1]))


def _with_date_dot(t):
    """The core keeps its trailing dot when it is a German date or ordinal ("5.11.", "3.")."""
    return t.core + "." if t.trail.startswith(".") and re.fullmatch(r"\d{1,2}(\.\d{1,2}(\.\d{2,4})?)?", t.core) else t.core


_ADDRESS_WORDS = {"at": "@", "ät": "@", "punkt": ".", "dot": ".", "bindestrich": "-", "minus": "-",
                  "unterstrich": "_", "underscore": "_"}


def _sounds_like(said, term_key):
    """The raw stretch is the term, or sounds like it (same phonetic skeleton, or one sound off
    for terms of five sounds or more), the dictionary's own measure."""
    if said == term_key:
        return True
    from dictionary import _lev, phonetic
    a, b = phonetic(said), phonetic(term_key)
    if not a or not b or a[0] != b[0] or abs(len(said) - len(term_key)) > 3:
        return False
    d = _lev(a, b)
    return d == 0 or (d == 1 and len(b) >= 5)


def _has_number(toks):
    return any(any(ch.isdigit() for ch in t.core) or number_value(t.core) is not None for t in toks)


def _merge_number_ops(ops, R, C, cw, term_keys):
    """'vierzehn Uhr dreißig' vs '14:30 Uhr' aligns as replace/equal/delete. Join such runs
    (short equal gaps included) into one block when the joined block is number-equivalent."""
    out, k = [], 0
    while k < len(ops):
        tag, i1, i2, j1, j2 = ops[k]
        if tag != "equal" and (_has_number(R[i1:i2]) or _has_number([C[cw[j]] for j in range(j1, j2)])):
            best = None
            end = k
            while end + 2 < len(ops) and ops[end + 1][0] == "equal" and \
                    ops[end + 1][2] - ops[end + 1][1] <= 2 and ops[end + 2][0] != "equal":
                end += 2
                e_i2, e_j2 = ops[end][2], ops[end][4]
                if _numbers_equal([t.core for t in R[i1:e_i2]], [_with_date_dot(C[cw[j]]) for j in range(j1, e_j2)],
                                  paused=any(t.trail.strip() for t in R[i1:e_i2 - 1])):
                    best = end
            if best is not None:
                out.append(("replace", i1, ops[best][2], j1, ops[best][4]))
                k = best + 1
                continue
        out.append(ops[k])
        k += 1
    return out


def restore_substitutions(raw, cleaned, terms=(), stats=None):
    """Word-level alignment of the LLM output against the raw transcript; see the block comment
    above for what may change. `terms` are dictionary spellings the LLM may introduce.
    `stats` (a dict) receives counts of reverted / reinserted / dropped words."""
    stats = stats if stats is not None else {}
    for k in ("reverted", "reinserted", "dropped"):
        stats.setdefault(k, 0)
    R = [t for t in _tokens(raw) if t.content]
    C = _tokens(cleaned, cleaned=True)
    if not R or not C:
        return cleaned
    trailing_ws = cleaned[len(cleaned.rstrip()):]
    leading_ws = C[0].ws
    term_keys = {_norm_token(t) for t in terms} - {""}
    filler_free = [q for q, t in enumerate(R) if t.norm not in FILLERS]
    cw = [j for j, t in enumerate(C) if t.content]
    pre = [[] for _ in range(len(cw) + 1)]
    pos = 0
    for t in C:
        if t.content:
            pos += 1
        else:
            pre[pos].append(t)
    out = []
    emitted = set()

    def emit_pre(j):
        """Non-word tokens (list markers, dashes) in front of content position j, once."""
        if j not in emitted:
            emitted.add(j)
            out.extend(pre[j])

    def last_content():
        return next((t for t in reversed(out) if t.content), None)

    def starts_line(j):
        """Cleaned content position j begins a sentence, a line or a list item."""
        if j >= len(cw):
            return False
        tok = C[cw[j]]
        prev = C[cw[j - 1]] if j > 0 else None
        return prev is None or _ends_sentence(prev) or "\n" in tok.ws or \
            any("\n" in t.ws or _LIST_MARKER.match(t.text) for t in pre[j])

    def reinsert(raw_toks, j):
        if not raw_toks:
            return
        stats["reinserted"] += len(raw_toks)
        new = []
        for r in raw_toks:
            n = _Tok(" ", r.text)
            n.raw = r
            new.append(n)
        prev = last_content()
        # the comma the speaker's raw text had after prev comes back with the words
        raw_comma = "," if prev is not None and prev.raw is not None and prev.raw.trail.strip() == "," else ""
        if prev is not None and _ends_sentence(raw_toks[-1]):
            # "… FS-SC-Design nur." closed the sentence in the raw text: attach it there
            new[-1].trail = prev.trail or raw_toks[-1].trail
            prev.trail = raw_comma
        elif prev is not None and not _ends_sentence(prev):
            # mid-sentence: the LLM's comma moves behind the run, except before a clause
            # starter ("machst, dass du …")
            if raw_toks[0].norm in CLAUSE_STARTERS and prev.trail.strip() == ",":
                new[-1].trail = ""
            else:
                new[-1].trail = prev.trail
                prev.trail = raw_comma
                comma_before(raw_toks[0])
        else:
            new[0].flags.add("cap")
            if prev is None and j < len(cw):
                new[0].ws, C[cw[j]].ws = C[cw[j]].ws, " "
            if j < len(cw):
                C[cw[j]].flags.add("raw_case")
        out.extend(new)

    def comma_before(first_raw):
        """German needs a comma before 'dass'/'weil' when we put such a clause back."""
        prev = last_content()
        if first_raw.norm in COMMA_BEFORE and prev is not None and not prev.trail:
            prev.trail = ","

    def drop(j):
        c = C[cw[j]]
        stats["dropped"] += 1
        prev = last_content()
        if c.trail and prev is not None and not prev.trail and _SENTENCE_END.search(c.trail):
            prev.trail = c.trail
        if (prev is None or _ends_sentence(prev)) and j + 1 < len(cw):
            C[cw[j + 1]].flags.add("cap")
            if prev is None:
                C[cw[j + 1]].ws = c.ws

    def revert_pair(c, r):
        stats["reverted"] += 1
        if c.core.isdigit() and c.trail.startswith(".") and not r.trail.startswith("."):
            c.trail = c.trail[1:]             # "12." (ordinal) back to "zwölften": no period
        if c.core[:1].isalpha() and r.core[:1].isalpha():
            c.core = _set_first_case(r.core, c.core[:1].isupper())
        else:
            c.core = r.core
        c.norm, c.raw = r.norm, r
        c.flags.add("raw_case")

    ops = _merge_number_ops(
        SequenceMatcher(None, [t.norm for t in R], [C[j].norm for j in cw], autojunk=False).get_opcodes(),
        R, C, cw, term_keys)
    for tag, i1, i2, j1, j2 in ops:
        full = R[i1:i2]
        clean = [C[cw[j]] for j in range(j1, j2)]
        # "und" may go where the LLM starts a new sentence or list item
        allowed = _allowed_deletions(R, list(range(i1, i2)), filler_free,
                                     conj_last=starts_line(j1 if tag == "delete" else j2)) if full else set()
        kept = [R[q] for q in range(i1, i2) if q not in allowed]
        if tag == "equal":
            for k, j in enumerate(range(j1, j2)):
                emit_pre(j)
                C[cw[j]].raw = R[i1 + k]
                out.append(C[cw[j]])
            continue
        if tag == "delete" and kept and all(t.norm in SPOKEN_MARKS for t in kept):
            prev = last_content()
            if prev is not None and all(SPOKEN_MARKS[t.norm] in prev.trail for t in kept):
                continue
        if tag == "delete":
            prev = last_content()
            if kept and (prev is None or _ends_sentence(prev)):
                emit_pre(j1)      # a new line/item starts here: the words go after its marker
            reinsert(kept, j1)
            continue
        if tag == "replace" and (_phrase_matches(full, clean, term_keys) or _phrase_matches(kept, clean, term_keys)):
            for j in range(j1, j2):
                emit_pre(j)
                out.append(C[cw[j]])
            continue
        if tag == "replace" and len(full) == len(clean):
            for k, j in enumerate(range(j1, j2)):
                emit_pre(j)
                c, r = C[cw[j]], full[k]
                if _phrase_matches([r], [c], term_keys):
                    c.raw = r
                    out.append(c)
                elif (i1 + k) in allowed:
                    drop(j)           # the LLM swapped a filler for a word of its own
                else:
                    revert_pair(c, r)
                    out.append(c)
            continue
        if tag == "replace" and kept and len(kept) == len(clean):
            for j, r in zip(range(j1, j2), kept):
                emit_pre(j)
                c = C[cw[j]]
                if _phrase_matches([r], [c], term_keys):
                    c.raw = r
                else:
                    revert_pair(c, r)
                out.append(c)
            continue
        if tag == "replace" and kept:
            for j in range(j1, j2):
                emit_pre(j)
            first, last = clean[0], clean[-1]
            stats["reverted"] += len(kept)
            new = []
            for r in kept:
                n = _Tok(" ", r.text)
                n.raw = r
                new.append(n)
            comma_before(kept[0])
            new[0].ws, new[0].lead = first.ws, first.lead or new[0].lead
            if first.core[:1].isalpha() and new[0].core[:1].isalpha():
                new[0].core = _set_first_case(new[0].core, first.core[:1].isupper())
            new[-1].trail = last.trail
            out.extend(new)
            continue
        # insert, or a replace whose raw side was only fillers: drop the LLM's own words
        for j in range(j1, j2):
            emit_pre(j)
            drop(j)
    emit_pre(len(cw))

    for k, t in enumerate(out):
        if k == 0:
            t.ws = leading_ws
        elif not t.ws:
            t.ws = " "            # moved tokens must not glue onto their new neighbour
        if not t.content:
            continue
        if k > 0 and out[k - 1].content and t.raw is not None and "\n" in t.raw.ws and "\n" not in t.ws:
            # a spoken "neuer Absatz" / "neue Zeile" (structure.apply_commands) stays
            t.ws = "\n\n" if t.raw.ws.count("\n") >= 2 else "\n"
        prev = next((x for x in reversed(out[:k]) if x.content), None)
        at_start = prev is None or _ends_sentence(prev) or "\n" in t.ws
        if "cap" in t.flags and at_start:
            t.core = _set_first_case(t.core, True)
        elif "raw_case" in t.flags and not at_start and t.raw is not None and t.raw.core[:1].isalpha():
            t.core = _set_first_case(t.core, t.raw.core[:1].isupper())
    text = "".join(t.render() for t in out)
    return text.rstrip() + trailing_ws if text.strip() else cleaned


# --- prompt mode -------------------------------------------------------------------------------
_PROMPT_NUM = re.compile(r"\d+(?:[.,]\d+)*")
_URL_OR_MAIL = re.compile(r"https?://\S+|www\.\S+|[\w.+-]+@[\w-]+\.[\w.]+")


def _values(text):
    vals = set()
    for m in _PROMPT_NUM.finditer(text):
        vals.update(_numeric(m.group()))
    for w in text.split():
        v = number_value(w)
        if v is not None:
            vals.add(float(v))
    return vals


def drop_unsupported(prompt, *sources):
    """Prompt mode may not invent facts: a number, link or mail address that is neither in the
    speech nor in the material goes, with its parenthesis, or its whole bullet line. List markers
    ("1.") and the section names stay."""
    known = set()
    for s in sources:
        known |= _values(s or "")
    joined = " ".join(s or "" for s in sources)
    out = []
    for line in prompt.split("\n"):
        body = re.sub(r"^\s*(\d{1,2}[.)]|[-–•*])\s+", "", line)
        bad = [m for m in _PROMPT_NUM.finditer(body) if _values(m.group()) - known]
        bad += [m for m in _URL_OR_MAIL.finditer(body) if m.group() not in joined]
        if not bad:
            out.append(line)
            continue
        fixed = line
        for m in bad:
            fixed = re.sub(r"\s*\([^()]*" + re.escape(m.group()) + r"[^()]*\)", "", fixed)
        if any(m.group() in fixed for m in bad):
            if re.match(r"^\s*(\d{1,2}[.)]|[-–•*])\s+", line):
                continue                      # an invented requirement: drop the bullet
            fixed = line                      # a sentence: keep it rather than break it
        out.append(fixed)
    return "\n".join(out)
