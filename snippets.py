"""Sprachkürzel: a spoken trigger ("meine Signatur") becomes a fixed text, word for word. Applied
after the LLM, so the text is never reworded; the match ignores case and punctuation."""
import json
import re

import settings


def path():
    return settings.data_dir() / "snippets.json"


def load():
    """[(trigger, text), ...] from snippets.json ({"snippets": [{"trigger", "text"}]})."""
    try:
        data = json.loads(path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    items = data.get("snippets", []) if isinstance(data, dict) else []
    return [(s["trigger"].strip(), s["text"]) for s in items
            if isinstance(s, dict) and isinstance(s.get("trigger"), str) and isinstance(s.get("text"), str)
            and s["trigger"].strip() and s["text"]]


def apply(text, snippets):
    """(text with every spoken trigger replaced, the triggers used). Longer triggers first, so
    "meine Adresse privat" wins over "meine Adresse"."""
    used = []
    for trigger, value in sorted(snippets, key=lambda s: -len(s[0])):
        words = re.findall(r"[^\W_]+", trigger.lower())
        if not words:
            continue
        # a closing period after the trigger goes only at the very end ("Meine Signatur.")
        pattern = re.compile(r"(?<!\w)" + r"[\s,.\-]+".join(map(re.escape, words)) +
                             r"(?!\w)(?:[.!](?=\s*$))?", re.I)
        text, n = pattern.subn(lambda _m: value, text)
        if n:
            used.append(trigger)
    return text, used
