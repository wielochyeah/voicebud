"""Deterministic structuring around the LLM: spoken commands before it, small format fixes
after it, and the writing style per app. Runs for every take, also the short ones that skip
the LLM, and never changes what was said."""
import re

# Spoken commands. Layout commands become line breaks, punctuation commands the character.
_COMMANDS = {
    "de": [("neuer absatz", "\n\n"), ("neue zeile", "\n"), ("nächste zeile", "\n"),
           ("fragezeichen", "?"), ("ausrufezeichen", "!"), ("doppelpunkt", ":"),
           ("semikolon", ";")],
    "en": [("new paragraph", "\n\n"), ("new line", "\n"), ("next line", "\n"),
           ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!")],
}
# "ein Fragezeichen hinter dem Projekt", "die neue Zeile im Vertrag": the word is a noun there
_ARTICLES = {"ein", "eine", "einen", "einem", "einer", "eines", "der", "die", "das", "den",
             "dem", "des", "kein", "keine", "keinen", "jede", "jeder", "diese", "dieser",
             "the", "a", "an", "this", "that", "every", "no"}
_SALUTATION = re.compile(
    r"(?:^|\n)\s*(hallo|hi|hey|moin|servus|liebe|lieber|liebes|sehr geehrte|sehr geehrter|"
    r"guten (morgen|tag|abend)|dear|hello)\b[^\n.!?,]{0,40}$", re.I)
_TRAIL_PUNCT = " ,.;:"


def _cap(text):
    m = re.search(r"[^\W\d_]", text)
    return text if not m else text[:m.start()] + text[m.start()].upper() + text[m.start() + 1:]


def _decap(text):
    m = re.search(r"[^\W\d_]", text)
    return text if not m else text[:m.start()] + text[m.start()].lower() + text[m.start() + 1:]


def _apply_one(text, phrase, symbol, lang):
    pat = re.compile(r"(?<![\w-])" + r"\s+".join(phrase.split()) + r"(?![\w-])[,.;:!?]*", re.I)
    pos = 0
    while True:
        m = pat.search(text, pos)
        if not m:
            return text
        before, after = text[:m.start()], text[m.end():]
        prev_word = re.findall(r"[\wäöüß]+", before[-40:].lower())
        if not before.strip() or (prev_word and prev_word[-1] in _ARTICLES):
            pos = m.end()       # a noun, or nothing to apply the command to
            continue
        if symbol in "?!" and re.match(r"\s+[a-zäöü]", after) and lang == "de":
            # "das Fragezeichen setzen wir später": a lowercase verb follows, not a new sentence
            pos = m.end()
            continue
        head = before.rstrip(_TRAIL_PUNCT + "\n")
        tail = after.lstrip(" ,.;:")
        mark = before.rstrip()[len(head):].strip(" \n")
        if symbol in "?!:;":
            tail = tail if not tail else " " + (_cap(tail) if symbol in "?!" else tail)
            text = head + symbol + tail
        else:
            salutation = bool(_SALUTATION.search(head))
            if salutation:
                end = ","
                tail = _decap(tail) if lang == "de" else tail
            elif symbol == "\n\n":
                end = mark[-1:] if mark[-1:] in ".!?:" else "."
                tail = _cap(tail)
            else:
                end = mark[-1:] if mark[-1:] in ".!?:" else ""
                tail = _cap(tail)
            text = head + end + symbol + tail
        pos = len(head) + 1


def apply_commands(text, lang="de"):
    """Execute spoken layout and punctuation commands ("neuer Absatz", "Fragezeichen")."""
    if not text:
        return text
    for phrase, symbol in _COMMANDS.get(lang if lang in _COMMANDS else "de", []):
        if phrase.split()[0] in text.lower():
            text = _apply_one(text, phrase, symbol, lang)
    return text


def tidy(text, lang="de"):
    """Small, safe format fixes on the final text."""
    if not text:
        return text
    text = re.sub(r"[ \t]+\n", "\n", text)          # markdown hard breaks ("  \n")
    text = re.sub(r"\n{3,}", "\n\n", text)
    if lang == "de":
        text = re.sub(r"\b0(\d)[:.](\d\d)(?=\s?Uhr\b)", r"\1:\2", text)   # 09:15 Uhr -> 9:15 Uhr
        text = re.sub(r"\b(\d+),0(?=\s?%)", r"\1", text)                  # 7,0 % -> 7 %
    return text.strip()


# Writing style per app. "mail": salutation and closing on their own lines; "chat": short, no
# paragraphs; "doc": everything else. Settings "appStyles" ({bundle id: style}) overrides.
STYLES = ("doc", "mail", "chat")
_APP_STYLES = {
    "com.apple.mail": "mail", "com.microsoft.outlook": "mail", "com.readdle.smartemail-mac": "mail",
    "com.superhuman.electron": "mail", "it.bloop.airmail2": "mail", "com.google.chrome.app.gmail": "mail",
    "com.apple.mobilesms": "chat", "net.whatsapp.whatsapp": "chat", "desktop.whatsapp": "chat",
    "com.tinyspeck.slackmacgap": "chat", "com.microsoft.teams2": "chat", "com.microsoft.teams": "chat",
    "ru.keepcoder.telegram": "chat", "org.telegram.desktop": "chat", "org.whispersystems.signal-desktop": "chat",
    "com.hnc.discord": "chat", "com.facebook.archon": "chat",
}


def style_for(bundle_id, overrides=None):
    key = (bundle_id or "").lower()
    for k, v in (overrides or {}).items():
        if k.lower() == key and v in STYLES:
            return v
    return _APP_STYLES.get(key, "doc")


# Words that start a dictation but continue a sentence in lower case. A closed list, so a noun
# ("Budget") never gets lowered.
_LOWER_OK = set("""und oder aber denn sondern doch also dann danach dabei dafür damit dazu deshalb trotzdem
außerdem auch noch nur schon sogar eben bitte ich wir du er sie es ihr man mich mir uns dich dir
das der die den dem des ein eine einen einem einer eines kein keine mein meine dein deine unser
unsere sein seine mit ohne für bei von vom zu zum zur in im an am auf aus nach vor über unter
zwischen weil dass wenn ob als wie wo was wer so sehr ganz etwa vielleicht natürlich eigentlich
gerne gern jetzt heute morgen gestern hier da dort and or but so then also the a an i'm we you it
this that with for in on at to of if when because""".split())


def fit_to_cursor(text, before, after, lang="de"):
    """Fit the dictation to where it lands: lower-case start mid-sentence, a space after a word
    right before the cursor, no closing period when the sentence goes on after the cursor."""
    if not text or (before is None and after is None):
        return text
    b, a = before or "", after or ""
    head = b.rstrip(" \t")
    mid_sentence = bool(head) and not head.endswith("\n") and head[-1] not in ".!?:…\"»“"
    if mid_sentence:
        first = re.match(r"\S+", text)
        word = first.group() if first else ""
        core = word.strip(",.;:!?\"'»«“”()")
        if core and core.lower() in _LOWER_OK and core != "I" and not (lang == "de" and core in {"Sie", "Ihnen", "Ihr", "Ihre"}):
            text = text[:first.start()] + word.replace(core, core[0].lower() + core[1:], 1) + text[first.end():]
    if b and not b[-1].isspace() and text[0] not in ",.;:!?)»”":
        text = " " + text
    tail = a.lstrip(" \t")
    if tail and (tail[0].islower() or tail[0] in ",;:)") and text.endswith(".") and not text.endswith(".."):
        text = text[:-1]
    if a and not a[0].isspace() and text[-1:].isalnum() and a[0].isalnum():
        text += " "
    return text
