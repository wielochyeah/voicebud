"""Bridge to the native VoiceBudUI helper (ui/SPEC.md §2): JSON lines over the child's
stdin/stdout. The UI owns menu bar, island and hub; Python only reports state.

- path: env VOICEBUD_UI, else ui/build/VoiceBudUI next to this file. Missing -> log once and run
  headless (every send is a no-op).
- writer thread with a queue; `level` messages are dropped while the queue is backed up, so a
  slow UI never delays states or partial text, and queued `partial` messages collapse into the
  newest text (each one is the full transcript anyway).
- only the writer thread touches the child's stdin, closing included: a writer stuck in flush()
  (child stopped) holds the pipe's lock, so close() never waits on it; it waits on the process,
  then terminates / kills it, which unblocks the write with EPIPE.
- reader thread: `quit` -> on_quit, `settings_changed` -> on_settings_changed. If the UI dies on its
  own it is respawned once (hello + last state are re-sent); after that we stay headless. A UI
  that ran for RESPAWN_RESET_S before it died gets the budget back, so only a rapid crash loop
  ends headless."""
import json
import os
import queue
import subprocess
import threading
import time
from pathlib import Path

DEFAULT_PATH = Path(__file__).resolve().parent / "ui" / "build" / "VoiceBudUI"
LEVEL_BACKLOG = 2       # drop level updates when more messages than this are waiting
RESPAWN_DELAYS = (0.0, 5.0, 30.0, 300.0)  # waits before restarting a crashed UI (the last repeats)
RESPAWN_RESET_S = 600.0  # a UI that lived this long before crashing starts the delays over
_CLOSE = object()       # writer: close the child's stdin and stop
_PARTIAL = object()     # writer: send the newest pending partial text


def log(msg):
    print(f"[ui] {msg}", flush=True)


class UIBridge:
    def __init__(self, hello, on_quit=None, on_settings_changed=None, path=None, env=None, on_probe=None,
                 on_onboarding=None, on_lost=None, on_slow_hint=None, on_ocr_result=None):
        self.hello = dict(hello, type="hello")
        self.on_lost = on_lost or (lambda: None)   # the UI died: undo what only it would undo
        self.on_slow_hint = on_slow_hint or (lambda: None)   # the island offers to cancel a slow take
        self.on_ocr_result = on_ocr_result or (lambda msg: None)  # Texterkennung: a text for the history
        self.on_quit = on_quit or (lambda: None)
        self.on_settings_changed = on_settings_changed or (lambda: None)
        self.on_probe = on_probe or (lambda: None)
        self.on_onboarding = on_onboarding or (lambda msg: None)
        self.path = Path(path or os.environ.get("VOICEBUD_UI") or DEFAULT_PATH)
        self.env = env
        self._proc = None
        self._queue = queue.Queue()
        self._lock = threading.Lock()
        self._closing = False
        self._respawns = 0
        self._spawned_at = 0.0
        self._partial = None     # newest partial text not yet written (see partial())
        self._last_state = None
        self.ready = threading.Event()
        self.headless = True
        self.dropped_levels = 0
        self.sent = 0

    # -- lifecycle -----------------------------------------------------------------------------
    def start(self):
        if not (self.path.is_file() and os.access(self.path, os.X_OK)):
            log(f"VoiceBudUI not found at {self.path} — running headless (no island, no menu bar item)")
            return self
        threading.Thread(target=self._writer, name="ui-writer", daemon=True).start()
        self._spawn()
        return self

    def _spawn(self):
        try:
            proc = subprocess.Popen(
                [str(self.path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None,
                env=self.env)
        except OSError as e:
            log(f"VoiceBudUI failed to start ({e}) — running headless")
            self.headless = True
            return
        with self._lock:
            self._proc = proc
            self.headless = False
            self._spawned_at = time.monotonic()
        self.ready.clear()
        threading.Thread(target=self._reader, args=(proc,), name="ui-reader", daemon=True).start()
        self._queue.put(self.hello)
        last = self._last_state
        if last is not None:
            self._queue.put(last)
        log(f"VoiceBudUI started (pid {proc.pid})")

    def close(self, timeout=1.5):
        """Stop the child: the writer closes its stdin (after anything still queued), which makes
        it terminate; terminate / kill it if it hangs or stopped reading."""
        with self._lock:
            self._closing = True
            proc, self._proc = self._proc, None
            self.headless = True
        self._queue.put((_CLOSE, proc))
        if proc is None:
            return
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()

    @property
    def alive(self):
        with self._lock:
            return self._proc is not None and self._proc.poll() is None

    # -- sending -----------------------------------------------------------------------------
    def send(self, msg):
        if self.headless or self._closing:
            return
        self._queue.put(msg)

    def state(self, phase, mode=None, **extra):
        msg = {"type": "state", "phase": phase}
        if mode is not None:
            msg["mode"] = mode
        msg.update(extra)
        self._last_state = msg if phase in ("recording", "processing") else None
        self.send(msg)

    def level(self, bands, rms):
        if self.headless or self._closing:
            return
        if self._queue.qsize() > LEVEL_BACKLOG:
            self.dropped_levels += 1
            return
        self._queue.put({"type": "level", "bands": bands, "rms": rms})

    def partial(self, text):
        if self.headless or self._closing:
            return
        with self._lock:
            queued = self._partial is not None
            self._partial = text
        if not queued:
            self._queue.put(_PARTIAL)

    def history_changed(self):
        self.send({"type": "history_changed"})

    def _writer(self):
        while True:
            msg = self._queue.get()
            if isinstance(msg, tuple) and msg and msg[0] is _CLOSE:
                proc = msg[1]
                if proc is not None:
                    try:
                        proc.stdin.close()
                    except (OSError, ValueError):
                        pass
                return
            if msg is _PARTIAL:
                with self._lock:
                    text, self._partial = self._partial, None
                if text is None:
                    continue
                msg = {"type": "partial", "text": text}
            with self._lock:
                proc = self._proc
            if proc is None or proc.poll() is not None:
                continue  # the reader decides about respawning
            try:
                line = _encode(msg)
            except Exception as e:      # one bad message must not end the writer (and the island)
                log(f"dropping a message that cannot be sent: {e!r}")
                continue
            try:
                proc.stdin.write(line)
                proc.stdin.flush()
                self.sent += 1
            except (BrokenPipeError, OSError, ValueError):
                pass  # child gone; the reader sees EOF and handles it

    # -- receiving ---------------------------------------------------------------------------
    def _reader(self, proc):
        quit_requested = False
        for raw in proc.stdout:
            try:
                msg = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                log(f"ignoring non-JSON line from UI: {raw[:120]!r}")
                continue
            kind = msg.get("type") if isinstance(msg, dict) else None
            if kind == "ready":
                self.ready.set()
            elif kind == "settings_changed":
                self._call(self.on_settings_changed)
            elif kind == "probe":
                self._call(self.on_probe)
            elif kind == "slow_hint":
                self._call(self.on_slow_hint)
            elif kind == "ocr_result":
                self._call(lambda m=msg: self.on_ocr_result(m))
            elif kind == "onboarding":
                self._call(lambda m=msg: self.on_onboarding(m))
            elif kind == "quit":
                quit_requested = True
                with self._lock:
                    self._closing = True
                self._call(self.on_quit)
            else:
                log(f"ignoring unknown message from UI: {msg!r}")
        code = proc.wait()
        for pipe in (proc.stdout, proc.stdin):
            try:
                pipe.close()
            except (OSError, ValueError):
                pass
        with self._lock:
            current = self._proc is proc
            closing = self._closing
            lived = time.monotonic() - self._spawned_at
            if current:
                self._proc = None
                self.headless = True
        if not current or closing or quit_requested:
            return
        self._call(self.on_lost)
        if lived >= RESPAWN_RESET_S:
            self._respawns = 0
        # never stay without a UI: recording without island and menu bar item is the worst case
        delay = RESPAWN_DELAYS[min(self._respawns, len(RESPAWN_DELAYS) - 1)]
        self._respawns += 1
        log(f"VoiceBudUI exited unexpectedly (code {code}) — restarting it in {delay:g} s")

        def again():
            if not self._closing:
                self._spawn()
        timer = threading.Timer(delay, again)
        timer.daemon = True
        timer.start()

    @staticmethod
    def _call(fn):
        try:
            fn()
        except Exception as e:
            log(f"callback failed: {e!r}")


def _finite(o):
    """NaN and infinity become 0 (JSON has no literal for them; the UI dropped such lines)."""
    if isinstance(o, float):
        return o if o == o and o not in (float("inf"), float("-inf")) else 0.0
    if isinstance(o, dict):
        return {k: _finite(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_finite(v) for v in o]
    return o


def _encode(msg):
    """One JSON line, valid UTF-8 even when screen text carried a lone surrogate."""
    try:
        text = json.dumps(msg, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    except ValueError:
        text = json.dumps(_finite(msg), ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    return (text + "\n").encode("utf-8", "replace")
