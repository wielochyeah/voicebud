"""One end-to-end proof run: wav -> STT -> Ollama cleanup -> clipboard injection round-trip."""
import sys
import time
import wave

import numpy as np
import yaml

from cleanup import Cleaner
from transcribe import Transcriber

with open("config.yaml") as f:
    cfg = yaml.safe_load(f)

# 1) load audio as the Recorder would produce it (mono float32 @16k)
with wave.open(sys.argv[1]) as w:
    assert w.getframerate() == 16000 and w.getnchannels() == 1
    audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
print(f"[1/4] audio loaded: {len(audio)/16000:.1f}s")

# 2) STT
t0 = time.time()
stt = Transcriber(cfg["stt"])
raw, lang = stt.transcribe(audio)
print(f'[2/4] STT ({time.time()-t0:.2f}s incl. model load, language={lang}): "{raw}"')

# 3) LLM cleanup
t0 = time.time()
cleaner = Cleaner(cfg["llm"])
cleaned = cleaner.clean(raw, lang)
print(f'[3/4] cleanup via {cfg["llm"]["model"]} ({time.time()-t0:.2f}s): "{cleaned}"')

# 4) injection: clipboard set + save/restore round-trip (keystroke needs a focused app)
import inject
before = inject._get_clipboard()
inject._set_clipboard(cleaned)
assert inject._get_clipboard() == cleaned
if before is not None:
    inject._set_clipboard(before)
    assert inject._get_clipboard() == before
print("[4/4] clipboard injection round-trip OK (original clipboard restored)")
