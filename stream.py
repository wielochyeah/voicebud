"""Live text while the user speaks, and the final text after stop.

The recorder feeds 20 ms chunks into a `Take`. With live text on (settings `liveText`), a
segmenter thread runs Silero VAD on the part that is not yet committed and commits a segment at
>= 0.5 s of silence after speech, or when the open part exceeds 12 s (cut at its longest pause,
else at its quietest 100 ms, never mid-word at a fixed 12 s: Whisper invents endings for cut-off
words). Committed segments are transcribed in order on the single MLX thread (`SttWorker`) and the
joined text goes to the UI as `partial`. The language is decided once per take (German preferred,
same rules as before) and reused for every later segment. With live text off nothing runs while
recording: the take only buffers audio.

The pasted text never comes from those segments (SPEC §0, 03.10.): at stop ONE Whisper pass runs
over the whole take, because segment edges cost 2-5 WER points on long real speech (nils-01:
0.096 streamed vs 0.051 in one pass). Streaming only feeds the live text.

`SttWorker` is the only thread that touches MLX. It also owns the RAM policy: preload on hotkey
press, `mx.clear_cache()` after every take, unload Whisper after 10 min idle unless the user asked
to keep the models loaded."""
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

import guards
# via transcribe: it keeps torch and numba out of the process before faster_whisper loads
from transcribe import (MIN_SPEECH_S, SAMPLE_RATE, SHORT_TAKE_S, VadOptions, footprint_mb,
                        get_speech_timestamps, speech_stats)

SR = SAMPLE_RATE
POLL_S = 0.15            # how often the open tail is checked
COMMIT_SILENCE_S = 0.5   # silence after speech that closes a segment
MAX_SEGMENT_S = 12.0     # longer open parts are cut at their last pause
MIN_COMMIT_SPEECH_S = 0.8  # a lone "Ja" waits for more speech instead of becoming its own segment
CUT_PAD_S = 0.3          # silence kept at the end of a committed segment
SILENCE_KEEP_S = 1.0     # leading silence kept in front of the open part
DETECT_MAX_S = 30.0      # Whisper's language detection only looks at the first 30 s
SEG_VAD = VadOptions(min_silence_duration_ms=200, speech_pad_ms=0)
PREVIEW_MIN_S = 1.5      # open part needs this much speech before a live preview is decoded
PREVIEW_EVERY_S = 1.0
SPEC_PAUSE_S = 0.6       # silence after speech before the final pass is computed ahead (live text off)
SPEC_MIN_NEW_S = 1.0     # speech since the last speculation before another one is worth it
CONTEXT_WORDS = 24       # words of the previous segments given to Whisper as prompt (opt-in:
                         # measured no better on nils-01 and it once produced "Ich bin zufrieden"
                         # out of "… sind" + "zufrieden")


def log(msg):
    print(msg, flush=True)


def _quietest_point(audio, frame=320, window=5, earliest_s=4.0):
    """Fluent speech can run 12 s without a pause the VAD calls silence. Cut in the quietest
    100 ms after the first 4 s instead of mid-word at a fixed 12 s."""
    n = audio.size // frame
    first = int(earliest_s * SR) // frame
    if n - first < window:
        return audio.size
    rms = np.sqrt((audio[: n * frame].reshape(n, frame) ** 2).mean(axis=1))
    smooth = np.convolve(rms, np.ones(window) / window, mode="same")
    k = first + int(np.argmin(smooth[first:]))
    return k * frame + frame // 2


def join_segments(texts):
    """Whisper marks a cut sentence with '...' at the segment edge; drop those marks
    between segments (a trailing one on the last segment stays: the speaker trailed off)."""
    texts = [t for t in texts if t]
    out = []
    for i, t in enumerate(texts):
        t = re.sub(r"^(\.\.\.|…)\s*", "", t)
        if i < len(texts) - 1:
            t = re.sub(r"\s*(\.\.\.|…)$", "", t)
        if t:
            out.append(t)
    return " ".join(out)


class SttWorker:
    """One thread for every MLX call, plus the model's RAM lifetime."""

    def __init__(self, transcriber, idle_unload_s=600.0, keep_loaded=lambda: False):
        self.stt = transcriber
        self.idle_unload_s = idle_unload_s
        self.keep_loaded = keep_loaded
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
        self._lock = threading.Lock()
        self._active = 0
        self._last_use = time.monotonic()
        self._timer = None
        self._pending = 0
        self.unloads = 0
        self.submit(self.stt.setup_mlx)

    def submit(self, fn, *args, **kwargs):
        with self._lock:
            self._pending += 1
        future = self._pool.submit(fn, *args, **kwargs)
        # a done callback also fires for a job cancelled before it ran (finish() drops queued
        # live-text segments), so `busy` never sticks
        future.add_done_callback(self._job_done)
        return future

    def _job_done(self, _future):
        with self._lock:
            self._pending -= 1

    @property
    def busy(self):
        with self._lock:
            return self._pending > 0

    # -- RAM policy ------------------------------------------------------------------------
    def preload(self, warm=False):
        """Load Whisper in the background (no-op when resident). Jobs queued after this wait
        for the load automatically, because the queue is FIFO on one thread."""
        return self.submit(self._load, warm)

    def _load(self, warm):
        if warm:
            t = time.time()
            self.stt.warm()
            log(f"Whisper loaded + warmed in {time.time() - t:.2f}s")
        elif not self.stt.loaded:
            took = self.stt.load()
            log(f"Whisper loaded in {took:.2f}s (on hotkey)")

    def begin_take(self):
        with self._lock:
            self._active += 1
            if self._timer:
                self._timer.cancel()
                self._timer = None

    def end_take(self):
        """After every take: give MLX's buffer cache back and restart the idle clock."""
        with self._lock:
            self._active = max(0, self._active - 1)
            self._last_use = time.monotonic()
        self.submit(self.stt.clear_cache)
        self.arm_idle()

    def arm_idle(self):
        with self._lock:
            if self._timer:
                self._timer.cancel()
                self._timer = None
            if not self.stt.unloadable or self.keep_loaded():
                return
            self._timer = threading.Timer(self.idle_unload_s, self._idle_check)
            self._timer.daemon = True
            self._timer.start()

    def _idle_check(self):
        with self._lock:
            self._timer = None
            idle = time.monotonic() - self._last_use
            if self._active or self.keep_loaded():
                return
        if idle + 0.05 < self.idle_unload_s:
            self.arm_idle()
            return
        self.submit(self._unload)

    def _unload(self):
        with self._lock:
            if self._active or self.keep_loaded():
                return
        if not self.stt.loaded:
            return
        before = footprint_mb()
        self.stt.unload()
        self.unloads += 1
        log(f"Whisper unloaded after {self.idle_unload_s / 60:g} min idle "
            f"(footprint {before:.0f} -> {footprint_mb():.0f} MB, drops further within ~2 s)")

    def shutdown(self):
        with self._lock:
            if self._timer:
                self._timer.cancel()
                self._timer = None
        self._pool.shutdown(wait=False, cancel_futures=True)


class _Buffer:
    """Growing float32 buffer written by the audio thread, read by the segmenter."""

    def __init__(self, seconds=60):
        self._a = np.zeros(SR * seconds, dtype=np.float32)
        self.n = 0
        self._lock = threading.Lock()

    def append(self, chunk):
        x = np.asarray(chunk, dtype=np.float32).reshape(-1)
        with self._lock:
            if self.n + x.size > self._a.size:
                grown = np.zeros(max(self._a.size * 2, self.n + x.size), dtype=np.float32)
                grown[:self.n] = self._a[:self.n]
                self._a = grown
            self._a[self.n:self.n + x.size] = x
            self.n += x.size

    def get(self, start, end):
        with self._lock:
            return self._a[start:end].copy()


class _Segment:
    __slots__ = ("start", "end", "audio", "text", "lang", "future", "speech_s")

    def __init__(self, start, end, audio):
        self.start, self.end, self.audio = start, end, audio
        self.text, self.lang, self.future, self.speech_s = "", None, None, 0.0


class TakeResult:
    def __init__(self, text, lang, segments, audio_s, stt_s, partials, previews, speculative=False):
        self.text, self.lang, self.segments = text, lang, segments
        self.audio_s, self.stt_s = audio_s, stt_s
        self.partials, self.previews = partials, previews
        self.speculative = speculative   # the final pass was computed ahead in the last speech pause

    def __repr__(self):
        return (f"TakeResult(lang={self.lang}, segments={self.segments}, audio={self.audio_s:.1f}s, "
                f"stt_after_stop={self.stt_s:.2f}s, partials={self.partials}, text={self.text[:60]!r})")


class Take:
    """One recording. feed() from the audio thread, finish() once after the mic closed.
    stream=False (live text off): no segmenter, no partials, only the final pass at stop."""

    def __init__(self, worker, on_partial=None, preview=False, language=None, context=False, stream=True,
                 speculate=False, on_speculation=None, on_spec_stale=None):
        self.worker = worker
        self.stt = worker.stt
        self.on_partial = on_partial
        self.preview = preview
        self.buf = _Buffer()
        self.commit_pos = 0
        self.segments = []
        self.context = context
        self.forced_lang = language
        self.lang_final = language
        self._speech_acc = []           # trimmed speech of early segments, for detection
        self._speech_acc_s = 0.0
        self._stop = threading.Event()
        self._finishing = False
        self._partials = 0
        self._previews = 0
        self._last_preview = 0.0
        self._preview_text = ""
        self._partial_lock = threading.Lock()
        self._last_partial = None
        self._scanned = 0               # audio position (samples) of the last segmenter scan
        self.streaming = stream
        self._thread = None
        self._spec = None               # the newest speculation (see _watch_pauses)
        self._aborted = False
        self.on_speculation = on_speculation
        self.on_spec_stale = on_spec_stale    # the speculation does not cover the take: stop its LLM run
        self._last_spec_s = 0.0
        if stream:
            self._thread = threading.Thread(target=self._segmenter, name="segmenter", daemon=True)
            self._thread.start()
        elif speculate:
            self._thread = threading.Thread(target=self._watch_pauses, name="pauses", daemon=True)
            self._thread.start()

    def feed(self, chunk):
        self.buf.append(chunk)

    # -- segmentation (segmenter thread) -----------------------------------------------------
    # The open part is scanned at fixed AUDIO positions (every POLL_S of audio since the take
    # started), not at whatever happens to be buffered when the thread wakes up. That makes the
    # cut points a function of the audio alone: the same recording always yields the same
    # segments (before, thread timing moved the cuts and nils-01 WER drifted 0.07-0.12).
    def _segmenter(self):
        while not self._stop.wait(POLL_S):
            self._catch_up(self.buf.n, stoppable=True)

    def _catch_up(self, limit, stoppable=False):
        step = int(POLL_S * SR)
        while self._scanned + step <= limit:
            if stoppable and self._stop.is_set():
                return
            self._scanned += step
            try:
                self._scan(self._scanned)
            except Exception as e:  # never let a VAD hiccup kill streaming; finish() still works
                log(f"segmenter: {e!r}")

    def _scan(self, end):
        start = self.commit_pos
        if end - start < int(COMMIT_SILENCE_S * SR):
            return
        tail = self.buf.get(start, end)
        ts = get_speech_timestamps(tail, SEG_VAD, sampling_rate=SR)
        if not ts:
            if tail.size > 3 * SR:      # only silence so far: forget it, keep a little lead-in
                self.commit_pos = end - int(SILENCE_KEEP_S * SR)
            return
        speech_s = sum(s["end"] - s["start"] for s in ts) / SR
        silence_after = tail.size - ts[-1]["end"]
        if silence_after >= COMMIT_SILENCE_S * SR and speech_s >= MIN_COMMIT_SPEECH_S:
            cut = ts[-1]["end"] + min(silence_after // 2, int(CUT_PAD_S * SR))
            self._commit(start, start + cut)
        elif tail.size > MAX_SEGMENT_S * SR:
            # cut at the longest pause after the first 2 s (sentence ends pause longer than
            # breaths inside a sentence); later pauses win ties
            gaps = [(ts[k + 1]["start"] - ts[k]["end"], ts[k]["end"], ts[k + 1]["start"])
                    for k in range(len(ts) - 1) if ts[k]["end"] >= 2 * SR]
            if gaps:
                _, a, b = max(gaps, key=lambda g: (g[0], g[1]))
                cut = (a + b) // 2
            else:
                cut = _quietest_point(tail[: int(MAX_SEGMENT_S * SR)])
            self._commit(start, start + cut)
        elif self.preview and not self._stop.is_set() and not self.worker.busy and speech_s >= PREVIEW_MIN_S and \
                time.monotonic() - self._last_preview >= PREVIEW_EVERY_S:
            self._last_preview = time.monotonic()
            self.worker.submit(self._preview_job, tail, start)

    def _commit(self, start, end):
        seg = _Segment(start, end, self.buf.get(start, end))
        self.segments.append(seg)
        self.commit_pos = end
        seg.future = self.worker.submit(self._transcribe_job, seg)

    # -- recognition (MLX thread) ------------------------------------------------------------
    def _language(self, seg, trimmed, speech_s):
        """Decide de/en once there are >= 3 s of speech; until then a tentative guess on the
        speech so far (short takes stay German unless English clearly wins)."""
        if self.forced_lang:
            return self.forced_lang          # a fixed dictation language (hub)
        if self.lang_final:
            return self.lang_final
        self._speech_acc.append(trimmed)
        self._speech_acc_s += speech_s
        acc = np.concatenate(self._speech_acc)[: int(DETECT_MAX_S * SR)]
        lang = self.stt.detect_language(acc, self._speech_acc_s)
        if self._speech_acc_s >= SHORT_TAKE_S:
            self.lang_final = lang
            self._speech_acc = []
        return lang

    def _transcribe_job(self, seg):
        speech = speech_stats(seg.audio)
        timestamps, seg.speech_s = speech
        if seg.speech_s < MIN_SPEECH_S:
            return
        trimmed = seg.audio[timestamps[0]["start"]:timestamps[-1]["end"]]
        seg.lang = self._language(seg, trimmed, seg.speech_s)
        seg.text, _ = self.stt.transcribe(seg.audio, language=seg.lang, speech=speech,
                                          prompt=self._context_before(seg))
        self._preview_text = ""
        self._publish()

    def _preview_job(self, tail, start):
        if self._finishing or start != self.commit_pos:
            return
        speech = speech_stats(tail)
        if speech[1] < PREVIEW_MIN_S:
            return
        text, _ = self.stt.transcribe(tail, language=self.forced_lang or self.lang_final or "de", speech=speech)
        if self._finishing or start != self.commit_pos:
            return
        self._previews += 1
        self._preview_text = text
        self._publish()

    def _context_before(self, seg):
        """The last words before `seg`, so Whisper continues a sentence that a pause split
        instead of starting a new one (capital letter, "..." at the cut)."""
        if not self.context:
            return None
        idx = self.segments.index(seg)
        words = " ".join(s.text for s in self.segments[:idx] if s.text).split()
        return " ".join(words[-CONTEXT_WORDS:]) or None

    def committed_text(self):
        return join_segments([s.text for s in self.segments])

    def _publish(self):
        if self.on_partial is None:
            return
        text = " ".join(t for t in (self.committed_text(), self._preview_text) if t)
        with self._partial_lock:
            if not text or text == self._last_partial:
                return
            self._last_partial = text
            self._partials += 1
        try:
            self.on_partial(text)
        except Exception as e:
            log(f"partial callback failed: {e!r}")

    # -- stop --------------------------------------------------------------------------------
    # -- speculation (live text off) -----------------------------------------------------------
    # In a speech pause the final pass is computed ahead over the audio so far. At stop it is used
    # only when the VAD over the WHOLE take finds exactly the same speech: then the trimmed audio,
    # and so Whisper's input, is identical, and the text is the one a fresh pass would give. Any
    # speech after the pause makes the timestamps differ, and the normal pass runs.
    def _watch_pauses(self):
        heard_until = 0                  # absolute end of the speech the last speculation covered
        while not self._stop.wait(POLL_S):
            try:
                n = self.buf.n
                start = max(0, n - int(3 * SR))
                tail = self.buf.get(start, n)
                ts = get_speech_timestamps(tail, SEG_VAD, sampling_rate=SR) if tail.size else []
                if not ts:
                    continue
                speech_end = start + ts[-1]["end"]
                if n - speech_end < SPEC_PAUSE_S * SR or speech_end - heard_until < SPEC_MIN_NEW_S * SR:
                    continue
                if self.worker.busy:     # never queue in front of other GPU work
                    continue
                if self._last_spec_s > 1.0:
                    continue             # a long take (or a slow Mac): a pass costs more than it saves
                audio = self.buf.get(0, n)
                stats = speech_stats(audio)          # the same VAD the final pass uses
                if stats[1] < MIN_SPEECH_S:
                    continue
                heard_until = speech_end
                spec = {"n": n, "ts": stats[0]}
                spec["future"] = self.worker.submit(self._spec_job, audio, stats, spec)
                self._spec = spec
            except Exception as e:      # speculation is an extra: it never breaks a take
                log(f"speculation: {e!r}")

    def _spec_job(self, audio, stats, spec):
        if self._aborted:
            return
        t = time.time()
        text, lang = self.stt.transcribe(audio, language=self.forced_lang, speech=stats, final=True)
        self._last_spec_s = time.time() - t
        spec["text"], spec["lang"] = guards.collapse_repeats(text), lang
        if self.on_speculation is not None and not self._aborted and spec["text"]:
            self.on_speculation(spec["text"], lang)

    def _speculated(self, audio, timeout):
        """The speculation's (text, lang) when it covers this audio exactly, else None. Returns the
        VAD stats of the whole take as well (the normal pass reuses them)."""
        spec = self._spec
        stats = speech_stats(audio)
        if spec is None:
            return None, stats
        if stats[0] != spec["ts"]:
            spec["future"].cancel()      # not started yet: it never runs
            if self.on_spec_stale is not None:
                self.on_spec_stale()
            return None, stats
        try:
            spec["future"].result(timeout=timeout)
        except Exception:
            return None, stats
        if "text" not in spec:
            return None, stats
        return (spec["text"], spec["lang"]), stats

    def finish(self, timeout=None):
        """Close the take and return the text from ONE Whisper pass over the whole take. Segments
        that have not reached the GPU yet only fed the live text and are dropped; a segment that
        is running finishes first (one MLX thread, FIFO). The language decided while streaming is
        reused; short takes (no decision yet) detect it like a plain transcription."""
        t0 = time.time()
        self._stop.set()
        self._finishing = True
        if self._thread is not None:
            self._thread.join()
        end = self.buf.n
        for seg in self.segments:
            if seg.future is not None:
                seg.future.cancel()
        lang = self.forced_lang or self.lang_final
        audio = self.buf.get(0, end)
        # the wait grows with the take; a fixed 120 s gave up on hour-long takes and lost them. 10.10.:
        # an M1 runs Whisper's encoder up to ~13x slower than the M5 Pro's 11 ms per audio second
        # (no neural accelerators), so 0.1 s per second could still lose a 20-min take there
        timeout = timeout or max(120.0, end / SR * 0.5)
        if not self.streaming:
            ahead, stats = self._speculated(audio, timeout)
            if self._spec is not None and not self._spec["future"].done():
                timeout *= 2             # a stale pass still runs in front of this one on the one GPU thread
            if ahead is not None:
                text, detected = ahead
                return TakeResult(text, (lang or detected) if text else None, 0, end / SR,
                                  time.time() - t0, 0, 0, speculative=True)
            text, detected = self.worker.submit(self.stt.transcribe, audio, language=lang, speech=stats,
                                                final=True).result(timeout=timeout)
        else:
            text, detected = self.worker.submit(self.stt.transcribe, audio, language=lang,
                                                final=True).result(timeout=timeout)
        text = guards.collapse_repeats(text)
        return TakeResult(text, (lang or detected) if text else None, len(self.segments), end / SR,
                          time.time() - t0, self._partials, self._previews)

    def abort(self):
        self._stop.set()
        self._finishing = True
        self._aborted = True
