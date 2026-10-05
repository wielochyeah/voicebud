"""Stop-to-text latency of the real pipeline (Whisper + LLM), fed with the bench recordings in real
time, as a user would speak them. Not a unit test: run it before and after a speed change.

    .venv/bin/python tests/bench_latency.py [label] [--runs N]

Writes tests/bench-results/<label>.json (timings and the final texts, so a change can be checked
for identical output) and prints a table. No screen context, no paste, no real history (the test
data dir from _util)."""
import json
import statistics
import sys
import threading
import time
from pathlib import Path

import numpy as np
import yaml

import _util
from _util import load_wav

ROOT = _util.ROOT
CLIPS = ["de", "de-laut", "denglisch", "en", "satz-stille", "nils-01"]
if "--clips" in sys.argv:
    CLIPS = sys.argv[sys.argv.index("--clips") + 1].split(",")
TAIL_S = 0.8          # quiet room noise between the last word and the key press
OUT = ROOT / "tests" / "bench-results"


def push_realtime(feed, audio, block=320):
    t0 = time.perf_counter()
    for i in range(0, audio.size, block):
        feed(audio[i:i + block])
        target = t0 + (i + block) / 16000
        delay = target - time.perf_counter()
        if delay > 0:
            time.sleep(delay)


def main():
    label = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "run"
    runs = int(sys.argv[sys.argv.index("--runs") + 1]) if "--runs" in sys.argv else 2
    import os
    os.environ["VOICEBUD_UI"] = "/nonexistent"           # headless: no island
    os.chdir(ROOT)
    import main as vbmain
    from audio import Recorder
    cfg = yaml.safe_load((ROOT / "config.yaml").read_text())
    vb = vbmain.VoiceBud(cfg, recorder=Recorder(), open_mic=False)
    vb.settings["contextLevel"] = 0                       # never read the screen in a benchmark
    vb.settings["liveText"] = False
    vbmain.frontmost_app = lambda own=(): ("Notizen", "com.apple.Notes", 0)
    pasted = []
    vbmain.inject.inject = lambda text, c: pasted.append(text)
    vbmain.inject.copy_only = lambda text: pasted.append(text)
    vb.learner.watch = lambda *a, **k: None
    done = threading.Event()
    events = []

    def state(phase, mode=None, **kw):
        events.append((time.perf_counter(), phase, kw))
        if phase in ("done", "error", "empty"):
            done.set()
    vb.ui.state = state
    vb.start()
    rng = np.random.default_rng(0)
    rows = {}
    for name in CLIPS:
        audio = load_wav(name)
        tail = (rng.standard_normal(int(TAIL_S * 16000)) * 0.001).astype(np.float32)
        audio = np.concatenate([audio, tail])
        rows[name] = []
        for r in range(runs):
            done.clear()
            vb.start_rec("dictate")
            push_realtime(vb.rec.feed, audio)
            t_stop = time.perf_counter()
            vb.stop_rec("dictate")
            if not done.wait(180):
                print(f"{name}: no result after 180 s")
                continue
            t_end, phase, kw = events[-1]
            stats = dict(vb.cleaner.last_stats)
            rows[name].append({"stop_to_text_s": round(t_end - t_stop, 3), "phase": phase,
                               "text": kw.get("text") or "", "llm": stats})
            time.sleep(0.5)
    summary = {}
    print(f"\n{label}: stop to text (median of {runs}), seconds")
    for name, rs in rows.items():
        times = [x["stop_to_text_s"] for x in rs]
        summary[name] = statistics.median(times) if times else None
        same = len({x["text"] for x in rs}) == 1
        print(f"  {name:12s} {summary[name]:.2f}   runs {times}   same text every run: {same}")
    OUT.mkdir(exist_ok=True)
    (OUT / f"{label}.json").write_text(json.dumps({"label": label, "tail_s": TAIL_S, "summary": summary,
                                                    "rows": rows}, ensure_ascii=False, indent=1))
    vb.worker.shutdown()
    vb.cleaner.shutdown()
    sys.stdout.flush()
    os._exit(0)


if __name__ == "__main__":
    main()
