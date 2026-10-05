"""Quality check of the learning dictionary: real misrecognitions the user corrects must fix the next
dictation; content edits must teach nothing. Runs the new learner and, with --old, the one from
before 04.10. afternoon (no exact fixes, capitalised-only names protected like ordinary words).

    .venv/bin/python tests/eval_learning.py [--old]
"""
import os
import sys
import time

import _util  # noqa: F401  (temp data dir)

os.environ["VOICEBUD_UI"] = "/nonexistent"
os.chdir(_util.ROOT)
import yaml  # noqa: E402

import dictionary  # noqa: E402
import learn  # noqa: E402

# (pasted, what the user changed it to, the next dictation as Whisper writes it, word it must contain)
LEARN = [
    ("Wir nutzen USB-Flow im Team.", "Wir nutzen WhisperFlow im Team.", "Ich habe USB-Flow installiert.", "WhisperFlow"),
    ("Frag Clout Code dazu.", "Frag Claude Code dazu.", "Das hat Clout Code gemacht.", "Claude Code"),
    ("Die Daten kommen von Tingo.", "Die Daten kommen von Tiingo.", "Tingo liefert die Kurse.", "Tiingo"),
    ("Hallo Frau Schimanska, danke.", "Hallo Frau Szymańska, danke.", "Frau Schimanska kommt morgen.", "Szymańska"),
    ("Das liegt im Ripo von uns.", "Das liegt im Repo von uns.", "Schau mal ins Ripo.", "Repo"),
    ("Wir nutzen Notschen für alles.", "Wir nutzen Notion für alles.", "Leg es in Notschen ab.", "Notion"),
    ("Der Kunde heißt Halbert seit gestern.", "Der Kunde heißt Halberd seit gestern.", "Halbert hat angerufen.", "Halberd"),
    ("Wir treffen Alvantik morgen früh.", "Wir treffen Alvantiq morgen früh.", "Alvantik schickt das Angebot.", "Alvantiq"),
    ("Nutz Hagging Face dafür bitte.", "Nutz Hugging Face dafür bitte.", "Das Modell liegt auf Hagging Face.", "Hugging Face"),
    ("Das läuft auf Wispaflow ganz gut.", "Das läuft auf Wispr Flow ganz gut.", "Wispaflow ist schnell.", "Wispr Flow"),
    ("Öffne bitte Fickma für das Design.", "Öffne bitte Figma für das Design.", "In Fickma liegt alles.", "Figma"),
]
# (pasted, changed to, next dictation, word that must stay)
KEEP = [
    ("Ich nutze Apple seit gestern.", "Ich nutze Google seit gestern.", "Apple hat ein neues Telefon.", "Apple"),
    ("Das läuft über die API von OpenAI.", "Das läuft über die SDK von OpenAI.", "Die API ist schnell.", "API"),
    ("Termin mit Herrn Meier morgen.", "Termin mit Herrn Schulz morgen.", "Herr Meier ruft an.", "Meier"),
    ("Wir fliegen morgen nach Berlin.", "Wir fliegen morgen nach Hamburg.", "Berlin ist schön.", "Berlin"),
    ("Wir sehen uns am Montag im Büro.", "Wir sehen uns am Dienstag im Büro.", "Am Montag geht es los.", "Montag"),
    ("Schick mir bitte die PDF heute.", "Schick mir bitte die DOCX heute.", "Die PDF ist angekommen.", "PDF"),
    ("Das ist wirklich gut geworden.", "Das ist wirklich super geworden.", "Das ist gut gelaufen.", "gut"),
    ("Das Projekt startet im Mai.", "The project starts in May.", "Das Projekt startet im Mai.", "Projekt"),
    ("Die Haustür klemmt schon wieder.", "Die Haus Tür klemmt schon wieder.", "Die Haustür ist zu.", "Haustür"),
    ("Wir nehmen das Haus am See.", "Wir nehmen die Wohnung am See.", "Das Haus ist alt.", "Haus"),
    ("Frag Jonas nach den Zahlen.", "Frag Lena nach den Zahlen.", "Jonas hat die Zahlen.", "Jonas"),
]


def run(old):
    import main
    if old:
        real = dictionary.is_word
        dictionary.is_word = lambda w: real(w) or (w[:1].islower() and real(w[:1].upper() + w[1:]))
        learn.exact_worthy = lambda h, c: False
    cfg = yaml.safe_load((_util.ROOT / "config.yaml").read_text())
    cfg["llm"]["enabled"] = False
    rows = []
    for kind, cases in (("lernen", LEARN), ("nicht lernen", KEEP)):
        for pasted, fixed, nxt, word in cases:
            vb = main.VoiceBud(cfg, open_mic=False)
            import tempfile
            from pathlib import Path
            vb.dictionary.path = Path(tempfile.mkdtemp(prefix="vb-eval-")) / "dictionary.json"   # own file per case
            vb.dictionary.set_terms([])
            vb.dictionary.set_replacements({})
            vb.ui.state = lambda *a, **k: None
            learned = []
            for heard, corrected in learn.corrections(pasted, fixed):
                learned.append((heard, corrected))
                if learn.worth_learning(heard, corrected):
                    vb._learned(heard, corrected, *learn.with_neighbour(pasted, fixed, heard, corrected))
                else:
                    vb._learned(heard, corrected, heard, corrected, exact=True)
            out = vb.dictionary.correct(nxt)
            ok = (word in out) if kind == "lernen" else (word in out and not learned)
            rows.append((kind, fixed, learned, out, ok))
            vb.worker.shutdown()
            vb.history.close()
    return rows


if __name__ == "__main__":
    old = "--old" in sys.argv
    rows = run(old)
    print(f"\n{'vorher' if old else 'neu'}:")
    for kind, fixed, learned, out, ok in rows:
        print(f"  {'ok ' if ok else 'XX '} {kind:12s} {fixed[:38]:38s} gelernt {learned}  nächstes: {out}")
    good = sum(r[4] for r in rows if r[0] == "lernen"), sum(r[4] for r in rows if r[0] != "lernen")
    print(f"== {'vorher' if old else 'neu'}: richtig gelernt {good[0]}/{len(LEARN)}, richtig nicht gelernt {good[1]}/{len(KEEP)}")
    sys.stdout.flush()
    os._exit(0)
