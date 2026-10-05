"""Shared helpers for the VoiceBud tests. Tests never touch the real data folder, the microphone
or the clipboard: VOICEBUD_DATA_DIR points at a temp dir, audio comes from wav files."""
import os
import re
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
os.environ.setdefault("VOICEBUD_DATA_DIR", tempfile.mkdtemp(prefix="voicebud-test-"))

BENCH = Path(os.environ.get(
    "VOICEBUD_BENCH",
    "/private/tmp/claude-501/-Users-nilswieloch-Claude/a8d8be99-0e31-401d-b1e7-1bcff4e75700/scratchpad/bench"))
NILS_REF = ROOT / "bakeoff/audio/nils-01.txt"
WAVS = ["de", "denglisch", "en", "satz-stille", "ja-real", "thx", "stille-1s", "rauschen-1s", "nils-01"]


def load_wav(name):
    with wave.open(str(BENCH / f"{name}.wav")) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def words(text):
    return re.sub(r"[^\wäöüß\s-]", " ", text.lower()).replace("-", " ").split()


def wer(ref, hyp):
    """Word error rate of hyp against ref (case, punctuation and hyphens ignored)."""
    r, h = words(ref), words(hyp)
    if not r:
        return 0.0 if not h else 1.0
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / len(r)
