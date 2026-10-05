"""Transcript cleanup and prompt mode with a local LLM (MLX, see llm_worker.py). The model name
comes ONLY from config.

Faithful by construction: whatever the LLM returns passes guards.clean_llm_output (leaks,
runaway length) and then guards.restore_substitutions, which puts back every word the LLM
changed beyond fillers, repeats, self-corrections, punctuation, capitalisation, number format
and layout.

RAM: the model lives in a child process that warm() starts while the user speaks and that exits
by itself after idle_unload_minutes, so idle VoiceBud holds none of it (SPEC §0)."""
import difflib
import itertools
import json
import re
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import guards

# -- command mode (05.10. challenge) -------------------------------------------------------------
_QUOTES = "\"„“”«»'‚‘’"
_TRANSLATE = re.compile(r"übersetz|translat|auf (deutsch|englisch)|ins (deutsche|englische)|"
                        r"in(to)? (english|german)|\b(englisch|deutsch|english|german)\b", re.I)
_META = re.compile(r"\bnicht (im (markierten |obigen |vorliegenden )?Text )?(angegeben|enthalten|erwähnt|genannt)\b|"
                   r"\bnot (mentioned|specified|stated|included) in the (selected |given )?text\b|"
                   r"\bthe (selected |given )?text (does not|doesn't) (contain|mention|say)\b|"
                   r"\b(Der|Im) (markierte |obige |vorliegende )?Text enthält (lediglich|nur|keine)\b", re.I)
_SUBJECT = re.compile(r"betreff|subject", re.I)
_DE_WORDS = set("der die das und ist nicht ich wir sie du ein eine mit für auf den dem zu im bitte noch".split())
_EN_WORDS = set("the and is not i we you a an with for on to in please of it be will".split())


def _text_lang(text):
    """German or English by their commonest small words (None: too short to tell)."""
    words = re.findall(r"[a-zäöüß]+", text.lower())
    de, en = sum(w in _DE_WORDS for w in words), sum(w in _EN_WORDS for w in words)
    return "de" if de > en else "en" if en > de else None


def _tidy_command(out, selection):
    """The model's answer without its wrapping, never cutting into the text itself: a preamble
    only if the selection does not start with those words, quotes only around the whole answer
    and only if the selection has none at its ends, repeats only if the selection has none."""
    out = re.sub(r"</?(text|anweisung|instruction)>", "", out)
    out = re.sub(r"^\s*(Ausgabe|Output):\s*", "", out)
    m = guards.PREAMBLE.match(out)
    if m:
        # the selection's own first words (a typo in them corrected: still the same words)
        said = m.group(0).strip().lower()
        head = selection.lstrip()[:len(said) + 4].lower()
        if difflib.SequenceMatcher(None, said, head[:len(said)]).ratio() < 0.8:
            out = out[m.end():]
    out = out.strip()
    sel = selection.strip()
    if len(out) >= 2 and out[0] in _QUOTES and out[-1] in _QUOTES and not (sel[:1] in _QUOTES or sel[-1:] in _QUOTES):
        out = out[1:-1].strip()
    if not out:
        return None
    return out if guards.collapse_repeats(selection) != sel else guards.collapse_repeats(out)

HERE = Path(__file__).resolve().parent
PROMPTS = HERE / "prompts"
WORKER = HERE / "llm_worker.py"
LOAD_TIMEOUT_S = 15.0
RETRY_S = 120.0          # after a load error or a failed start the model is tried again this much later


def hf_snapshot(repo):
    """Local snapshot folder of a Hugging Face repo with its weights present, else None. Looked
    up on disk, so the core never imports the hub client."""
    hub = os.environ.get("HF_HUB_CACHE") or os.path.join(
        os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface"), "hub")
    snaps = Path(hub) / ("models--" + repo.replace("/", "--")) / "snapshots"
    for snap in sorted(snaps.glob("*"), key=lambda p: p.stat().st_mtime, reverse=True) if snaps.is_dir() else []:
        if (snap / "config.json").exists() and any(p.exists() for p in snap.glob("*.safetensors")):
            return snap
    return None


class _Prompts:
    def __init__(self):
        self.clean = {lang: (PROMPTS / f"clean_{lang}.txt").read_text() for lang in ("de", "en")}
        self.command = {lang: (PROMPTS / f"command_{lang}.txt").read_text() for lang in ("de", "en")}
        self.styles = json.loads((PROMPTS / "styles.json").read_text())

    def system(self, language, style):
        lang = "de" if language == "de" else "en"
        styles = self.styles[lang]
        return self.clean[lang].replace("{MODUS}", styles.get(style) or styles["doc"])


class Cleaner:
    def __init__(self, cfg, worker_cmd=None):
        self.cfg = cfg
        self.enabled = bool(cfg.get("enabled", True))
        self.model = cfg["model"]
        self.idle_s = float(cfg.get("idle_unload_minutes", 5)) * 60
        # LATENCY RULE: takes under min_words get only the deterministic pass; a model that is
        # not loaded yet is waited for only from wait_words on (a short take never waits ~2 s)
        self.min_words = int(cfg.get("min_words_for_cleanup", 4))
        self.wait_words = int(cfg.get("min_words_to_wait_for_load", 10))
        self.temperature = float(cfg.get("temperature", 0.0))
        self.last_stats = {}
        self._keep = False
        self._worker_cmd = worker_cmd
        self._proc = None
        self._ready = threading.Event()
        self._needs_prefill = False       # started for a formula: the dictation prompts follow after
        self._load_s = 0.0
        self._lock = threading.Lock()
        self._pending = {}
        self._tags = {}                   # request id -> take seq or "real" (real requests), "spec"
        self._tag = threading.local()
        self._ids = itertools.count(1)
        self.prompts = _Prompts()
        # "switched on" and "downloaded" are separate: the onboarding downloads the model while
        # the app runs, and it must work as soon as the files are there (no restart)
        self._missing = self.enabled and worker_cmd is None and hf_snapshot(self.model) is None
        self._missing_checked = time.time()
        if self._missing:
            print(f"LLM {self.model} is not downloaded yet; raw transcripts until it is.")

    # -- worker process ---------------------------------------------------------------------
    @property
    def keep_loaded(self):
        return self._keep

    @keep_loaded.setter
    def keep_loaded(self, value):
        self._keep = bool(value)
        self._send({"op": "keep", "value": self._keep})

    @staticmethod
    def _python():
        """The interpreter for child processes: the dev venv, else the DMG build's own Python."""
        venv = HERE / ".venv" / "bin" / "python"
        bundled = Path(sys.prefix) / "bin" / "python3.12"
        return venv if venv.exists() else bundled if bundled.exists() else Path(sys.executable)

    def _command(self):
        if self._worker_cmd:
            return list(self._worker_cmd)
        cmd = [str(self._python()), "-u", str(WORKER),
               "--model", self.model, "--idle", str(self.idle_s)]
        return cmd + (["--keep"] if self._keep else [])

    def _alive(self):
        return self._proc is not None and self._proc.poll() is None

    @property
    def usable(self):
        """Enabled and not cooling down after a load error (a single error used to switch the
        cleanup off until the app restarted, and every take came raw without a word)."""
        if not self.enabled or time.time() - getattr(self, "_failed_at", 0.0) < RETRY_S:
            return False
        if getattr(self, "_missing", False):
            if time.time() - self._missing_checked < 10.0:
                return False
            self._missing_checked = time.time()
            self._missing = hf_snapshot(self.model) is None
            if not self._missing:
                print(f"LLM {self.model} is downloaded now; cleanup on.")
        return not getattr(self, "_missing", False)

    def warm(self, prefill=True):
        """Start the model process if it is not running (returns at once; loading takes ~2 s).
        prefill=False (a formula): no system prompts first, they would queue ahead of it."""
        if not self.usable:
            return
        with self._lock:
            if self._alive():
                self._send({"op": "touch"})     # still needed: restart its idle clock
                if prefill and self._needs_prefill:
                    self._prefill()
                return
            self._ready.clear()
            try:
                proc = subprocess.Popen(self._command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        text=True, bufsize=1, cwd=str(HERE))
            except OSError as e:
                print(f"LLM worker failed to start ({e}); raw text for {RETRY_S:.0f} s.")
                self._failed_at = time.time()
                return
            self._proc = proc
        threading.Thread(target=self._reader, args=(proc,), name="llm-reader", daemon=True).start()
        self._needs_prefill = True
        if prefill:
            self._prefill()

    def _prefill(self):
        # the cached system prompts are ready before the take stops (~0.3 s each, while speaking)
        self._needs_prefill = False
        self._send({"op": "prefill", "systems": [self.prompts.system("de", st) for st in ("doc", "mail", "chat")]
                    + [self.prompts.command["de"]]})

    def _reader(self, proc):
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("event") == "ready":
                self._load_s = float(msg.get("load_s", 0.0))
                self._ready.set()
            elif msg.get("event") == "error":
                print(f"LLM worker: {msg.get('error')}; raw text for {RETRY_S:.0f} s.")
                self._failed_at = time.time()
            elif "id" in msg:
                slot = self._pending.get(msg["id"])
                if slot is not None:
                    slot[1] = msg
                    slot[0].set()
        # the process ended (idle exit, crash or quit): reap it, close its pipes (a long-running
        # VoiceBud sees one idle exit after every pause) and wake every waiting request
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        for pipe in (proc.stdin, proc.stdout):
            try:
                pipe.close()
            except OSError:
                pass
        with self._lock:
            if self._proc is proc:
                self._proc = None
                self._ready.clear()
        for slot in list(self._pending.values()):
            slot[0].set()

    def _send(self, obj):
        proc = self._proc
        if proc is None or proc.poll() is not None:
            return False
        try:
            proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
            proc.stdin.flush()
            return True
        except (OSError, ValueError):
            return False

    def release(self):
        """keepModelsLoaded switched off: the worker goes back to its idle exit."""
        self._send({"op": "keep", "value": False})

    def shutdown(self):
        self.enabled = False      # a take still running must not start a new worker while quitting
        proc = self._proc
        if proc is not None and proc.poll() is None:
            self._send({"op": "quit"})
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def is_ready(self):
        return self._alive() and self._ready.is_set()

    def _ensure(self, words):
        """Model ready for a take of `words` words; False means: use the raw text."""
        if self.is_ready():
            return True
        if words < self.wait_words:
            return False
        self.warm()
        t = time.time()
        while not self._ready.wait(0.05):
            if not self.usable or not self._alive() or time.time() - t > LOAD_TIMEOUT_S:
                return False
        self.last_stats["load"] = self._load_s
        return True

    def _generate(self, system, user, max_tokens, temp, timeout, loop_guard=False, ticket=None, stats=None):
        """ticket (a dict) marks a speculative request: it gets the request id (for cancel) and
        yields to every real request in the worker."""
        if ticket is not None and (ticket.get("cancelled") or self._real_pending()):
            return None                   # a real request is open (it has the model) or it was stopped
        rid = next(self._ids)
        slot = [threading.Event(), None]
        self._pending[rid] = slot
        self._tags[rid] = "spec" if ticket is not None else getattr(self._tag, "seq", "real")
        if ticket is not None:
            ticket["rid"] = rid
        try:
            if not self._send({"op": "generate", "id": rid, "system": system, "user": user,
                               "max_tokens": max_tokens, "temp": temp, "loop_guard": loop_guard,
                               "spec": ticket is not None}):
                return None
            answered = slot[0].wait(timeout)
            # a formula read ahead of it (one request at a time in the worker): its time is not
            # this request's, so it is waited for instead of killing the worker and the formula
            while not answered and any(tag == "formula" for tag in list(self._tags.values())):
                answered = slot[0].wait(timeout)
            if not answered:
                if ticket is not None:    # speculative: it only waited behind real work; never kill
                    self.cancel(ticket)
                    return None
                print(f"LLM did not answer within {timeout:.0f}s; restarting it.")
                proc = self._proc
                if proc is not None:
                    proc.kill()
                return None
            msg = slot[1]
            if msg is not None and msg.get("cancelled"):
                if ticket is not None:
                    ticket["cancelled"] = True
                return None
            if msg is None or "error" in msg:
                if msg is not None:
                    print(f"LLM error: {msg['error']}")
                return None
            (stats if stats is not None else self.last_stats).update(msg.get("stats", {}))
            return msg.get("text", "")
        finally:
            self._pending.pop(rid, None)
            self._tags.pop(rid, None)

    def _real_pending(self):
        """A real request is waiting for an answer (speculation then stays out of its way)."""
        return any(self._tags.get(rid, "real") != "spec" for rid in list(self._pending))

    def tag(self, seq):
        """Requests from this thread belong to take `seq` (cancel_take stops exactly those)."""
        self._tag.seq = seq

    def cancel_take(self, seq):
        """The user cancelled take `seq`: stop its requests, nothing else."""
        for rid, tag in list(self._tags.items()):
            if tag == seq and rid in self._pending:
                self._send({"op": "cancel", "id": rid})

    def cancel(self, ticket):
        """Stop a speculative request (its result is no longer needed). Marked even before it was
        sent, so a request still waiting for the model never goes out."""
        if not ticket:
            return
        ticket["cancelled"] = True
        rid = ticket.get("rid")
        if rid is not None:
            self._send({"op": "cancel", "id": rid})

    # -- formulas (05.10.) -------------------------------------------------------------------
    def warm_formula(self):
        """⌥ tapped in ⇧⌘2: the model and its vision part get ready while the user still drags."""
        if not self.usable:
            return
        self.warm(prefill=False)
        self._send({"op": "vision"})          # queued behind the load; nothing to do once built

    def formula(self, image, budget=52.0):
        """A screen region read by the vision part of the model: Markdown with LaTeX (formula.py
        makes the renditions), or None. A real request: speculation yields to it. `budget`
        covers the load too and stays under the UI's 60 s, so the UI never gives up on a read
        that still lands in the history."""
        if not self.usable:
            return None
        cold = not self._alive()
        self.warm(prefill=False)
        t = time.time()
        while not self._ready.wait(0.05):
            if not self.usable or not self._alive() or time.time() - t > min(LOAD_TIMEOUT_S, budget):
                return None
        timeout = max(1.0, budget - (time.time() - t))
        rid = next(self._ids)
        slot = [threading.Event(), None]
        self._pending[rid] = slot
        self._tags[rid] = "formula"
        try:
            if not self._send({"op": "formula", "id": rid, "image": str(image)}):
                return None
            if not slot[0].wait(timeout):
                self._send({"op": "cancel", "id": rid})
                return None
            msg = slot[1]
            if msg is None or "error" in msg or msg.get("cancelled"):
                if msg is not None and "error" in msg:
                    print(f"formula error: {msg['error']}")
                return None
            self.formula_stats = dict(msg.get("stats", {}), load=round(time.time() - t, 3) if cold else 0.0)
            return msg.get("text", "")
        finally:
            self._pending.pop(rid, None)
            self._tags.pop(rid, None)
            if self._needs_prefill:
                self._prefill()               # a dictation right after finds its prompts ready

    # -- the two jobs -----------------------------------------------------------------------
    def clean(self, text, language=None, terms=(), style="doc", register=None, ticket=None):
        """ticket: a speculative run (computed in a speech pause); it holds the request id, whether
        the model really ran ("ran") and the stats. last_stats is only set by real runs."""
        stats = {}
        if ticket is None:
            self.last_stats = stats
        if not self.usable or not text:
            return text
        words = len(text.split())
        if words < self.min_words or not self._ensure(words):
            return text
        # no term list here: dictionary.correct already fixed the spelling before the LLM, and a
        # list in the prompt made the 4B model skip lists and loop (LLM eval 2026-10-03); the
        # terms still go to restore_substitutions
        tag = "transkript" if language == "de" else "transcript"
        user = f"<{tag}>\n{text}\n</{tag}>"
        if register == "Sie" and language == "de":
            # from the screen (context.register_of): settles "sie" vs "Sie" for the model
            user = "Hinweis: Der Text siezt, also Sie, Ihnen, Ihr großschreiben.\n\n" + user
        # ~1.8x the transcript's tokens (German ~3 chars per token): stops runaway loops
        max_tokens = int(len(text) * 0.6) + 64
        # the time limit grows with the text: an 18-minute take needed 27 of a fixed 30 s, and an
        # M1 decodes about four times slower than the M5 Pro this was measured on
        out = self._generate(self.prompts.system(language, style), user, max_tokens=max_tokens,
                             temp=self.temperature, timeout=min(300.0, 20.0 + max_tokens * 0.05),
                             ticket=ticket, stats=stats)
        if out is None:
            return text
        if ticket is not None:
            ticket["ran"], ticket["stats"] = True, stats
        checked = guards.clean_llm_output(out, text)
        if checked is None:
            print("Cleanup output rejected (leak or length); using raw transcript.")
            stats["rejected"] = True
            return text
        restored = {}
        try:
            result = guards.restore_substitutions(text, checked, terms=terms, stats=restored)
        except Exception as e:  # a guard bug must never cost the dictation
            print(f"restore_substitutions failed ({e!r}); using raw transcript.")
            return text
        stats.update(restored)
        if ticket is not None:
            ticket["stats"] = stats
        return result

    def promptify(self, text, language=None, terms=(), material=None):
        """Prompt mode: turn a rough spoken instruction into a structured AI prompt
        (role, goal, context, requirements, format). Routed by detected language."""
        self.last_stats = {}
        if not text or len(text.split()) < 3:
            return text
        if not self.enabled or not self._ensure(self.wait_words):
            print("Prompt mode needs the local LLM; pasting the raw transcript instead.")
            return text
        if language == "de":
            system = self.cfg.get("promptify_system_prompt_de", "")
            user = ("Gesprochene Anweisung (roh, aus Speech-to-Text):\n\n"
                    f"{text}\n\n"
                    "Erzeuge daraus jetzt den strukturierten Prompt.")
            if material:
                # the material itself never reaches the model: code appends it verbatim below
                user += f"\n\nUnter den Prompt wird automatisch angehängt: {material}."
        else:
            system = self.cfg.get("promptify_system_prompt", "")
            user = ("Spoken instruction (raw speech-to-text):\n\n"
                    f"{text}\n\n"
                    "Now produce the structured prompt.")
            if material:
                user += f"\n\nAttached automatically below the prompt: {material}."
        out = self._generate(system, user, max_tokens=900,
                             temp=float(self.cfg.get("promptify_temperature", 0.2)), timeout=60,
                             loop_guard=True)
        if not out:
            return text
        out = guards.PREAMBLE.sub("", out).strip()
        return guards.collapse_repeats(out) or text

    def command(self, instruction, selection, language=None):
        """Befehlsmodus: edit the selected text as the spoken instruction says ("mach das kürzer").
        Returns the new text, or None when it could not be done (the selection stays untouched).

        05.10. challenge (37 real cases, 14 good): the model's text was often right and the
        tidying here broke it (a table row collapsed, the first line taken for a preamble, a
        quotation mark of the text cut off), and a few answers had no business replacing the
        selection. The prompt stays as it is (every change to it flipped ~8 cases either way);
        the guards below act only in their own failure case."""
        self.last_stats = {}
        if not self.usable or not instruction.strip() or not self._ensure(self.wait_words):
            return None
        lang = "de" if language == "de" else "en"
        tag = "anweisung" if lang == "de" else "instruction"
        user = f"<{tag}>\n{instruction}\n</{tag}>\n<text>\n{selection}\n</text>"
        max_tokens = len(selection) // 2 + 300

        def run(u):
            raw = self._generate(self.prompts.command[lang], u, max_tokens=max_tokens,
                                 temp=0.0, timeout=min(300.0, 30.0 + max_tokens * 0.05), loop_guard=True)
            return _tidy_command(raw, selection) if raw else None

        out = run(user)
        if not out:
            return None
        # the language flipped although no translation was asked for (an English text with
        # "mach das förmlicher" came back German): once more with a hint, else leave it
        src = _text_lang(selection)
        if src and not _TRANSLATE.search(instruction) and _text_lang(out) not in (None, src):
            name = {"de": ("Deutsch", "German"), "en": ("Englisch", "English")}[src]
            hint = (f"Hinweis: Der Text ist {name[0]}. Die Ausgabe bleibt {name[0]}." if lang == "de"
                    else f"Note: The text is {name[1]}. The output stays {name[1]}.")
            self.last_stats["lang_retry"] = True
            out = run(hint + "\n\n" + user)
            if not out or _text_lang(out) not in (None, src):
                return None
        # an answer about the text instead of the text ("Das Wetter ist nicht im Text angegeben")
        # must not replace the selection
        if _META.search(out) and not _META.search(selection):
            self.last_stats["meta_rejected"] = True
            return None
        # asked for a subject line, got only that line for a whole mail: it goes on top of the mail
        if _SUBJECT.search(instruction) and "\n" not in out.strip() and "\n" in selection.strip() \
                and re.match(r"(Betreff|Subject)\s*:", out):
            out = out.strip() + "\n\n" + selection.strip()
        # no drop_unsupported here: a translation or a sum brings numbers the selection does not
        # have, and dropping those lines silently cut the result (the user sees it in place and
        # can undo; a cut they do not notice is worse)
        return out
