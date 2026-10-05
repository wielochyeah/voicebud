"""Headless pipeline test with real models, no microphone, no paste.

1. streaming: every bench wav is pushed through Recorder.feed -> Take chunk by chunk at real-time
   speed (VOICEBUD_TEST_SPEED=2 for twice as fast), as if it were being recorded. Checks partial
   updates, that the final text IS the one-pass transcript of the whole take (SPEC §0: streaming
   only feeds the live text), and the time from stop to final text. With live text off the take
   does not stream at all.
2. end to end: main.VoiceBud with a stand-in UI process and a captured inject() — state sequence,
   levels, partials, done info, history rows, cleanup timing.
3. RAM: idle unload with a shortened timeout; footprint before/after, reload time; keep-loaded.
Numbers are printed as JSON at the end."""
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

import numpy as np
import yaml

import _util
import guards
from _util import WAVS, load_wav, wer

SPEED = float(os.environ.get("VOICEBUD_TEST_SPEED", "1"))
BLOCK = 320  # 20 ms, the recorder's block size
RESULTS = {"speed": SPEED, "streaming": {}, "end_to_end": {}, "ram": {}}
CFG = yaml.safe_load((_util.ROOT / "config.yaml").read_text())
REF = _util.NILS_REF.read_text().strip() if _util.NILS_REF.exists() else None


def setUpModule():
    if not all((_util.BENCH / f"{n}.wav").exists() for n in WAVS):
        raise unittest.SkipTest(f"bench wavs missing in {_util.BENCH}")
    global STT, WORKER, BATCH
    from stream import SttWorker
    from transcribe import Transcriber, footprint_mb
    RESULTS["ram"]["process_start_mb"] = round(footprint_mb())
    STT = Transcriber(CFG["stt"])
    WORKER = SttWorker(STT, idle_unload_s=3600)
    t = time.time()
    WORKER.preload(warm=True).result()
    RESULTS["ram"]["warm_s"] = round(time.time() - t, 2)
    RESULTS["ram"]["loaded_mb"] = round(footprint_mb())
    BATCH = {}
    for name in WAVS:
        audio = load_wav(name)
        t = time.time()
        text, lang = WORKER.submit(STT.transcribe, audio).result()
        BATCH[name] = {"text": text, "lang": lang, "seconds": round(time.time() - t, 3)}


def tearDownModule():
    WORKER.shutdown()
    print("\nPIPELINE_RESULTS " + json.dumps(RESULTS, ensure_ascii=False, indent=1))


def push_realtime(feed, audio, on_block=None):
    t0 = time.time()
    for i in range(0, audio.size, BLOCK):
        feed(audio[i:i + BLOCK])
        if on_block:
            on_block(i)
        delay = t0 + (i + BLOCK) / 16000 / SPEED - time.time()
        if delay > 0:
            time.sleep(delay)
    return t0


class PipelineTest(unittest.TestCase):
    def test_1_streaming_vs_batch(self):
        from audio import Recorder
        from stream import Take
        for name in WAVS:
            audio = load_wav(name)
            partials = []
            rec = Recorder()
            WORKER.begin_take()
            take = Take(WORKER, on_partial=lambda text: partials.append((time.time(), text)))
            rec.on_chunk = take.feed
            rec.start(open_stream=False)
            band_log = []

            def sample_bands(i):
                if i % (BLOCK * 5) == 0:  # ~every 100 ms
                    band_log.append(rec.bands()[0])
            t0 = push_realtime(rec.feed, audio, sample_bands)
            t_stop = time.time()
            rec.stop()
            res = take.finish()
            t_final = time.time()
            WORKER.end_take()
            batch = BATCH[name]
            row = {
                "audio_s": round(audio.size / 16000, 1),
                "stop_to_text_s": round(t_final - t_stop, 3),
                "batch_transcribe_s": batch["seconds"],
                "segments": res.segments,
                "partials": len(partials),
                "first_partial_at_s": round((partials[0][0] - t0) * SPEED, 1) if partials else None,
                "wer_vs_batch": round(wer(batch["text"], res.text), 3),
                "lang": res.lang, "batch_lang": batch["lang"],
                "max_band_level": round(float(np.max(band_log)) if band_log else 0, 2),
                "text": res.text,
            }
            if name == "nils-01" and REF:
                row["wer_vs_reference"] = round(wer(REF, res.text), 3)
                row["batch_wer_vs_reference"] = round(wer(REF, batch["text"]), 3)
            RESULTS["streaming"][name] = row
            with self.subTest(name=name):
                # one pass over the whole take after stop: about the batch time, plus a running
                # live-text segment that finishes first
                self.assertLess(row["stop_to_text_s"], batch["seconds"] + 0.8, "stop -> text too slow")
                self.assertEqual(bool(res.text), bool(batch["text"]))
                if not batch["text"]:
                    self.assertEqual(row["partials"], 0)
                    continue
                self.assertEqual(res.lang, batch["lang"])
                self.assertEqual(res.text, guards.collapse_repeats(batch["text"]))
                self.assertGreater(row["max_band_level"], 0.3, "level meter stays flat on speech")
                if row["audio_s"] > 5:
                    self.assertGreaterEqual(row["partials"], 1, "no partial text before stop")
                if name == "nils-01":
                    self.assertGreaterEqual(row["partials"], 6)
                    self.assertLess(row["first_partial_at_s"], 10)
                    if REF:
                        self.assertEqual(row["wer_vs_reference"], row["batch_wer_vs_reference"])

    def test_2_end_to_end(self):
        import main
        import settings
        from audio import Recorder
        from history import History
        from test_bridge import FAKE_UI

        tmp = Path(tempfile.mkdtemp(prefix="vb-e2e-"))
        exe = tmp / "FakeUI"
        exe.write_text(FAKE_UI.format(python=sys.executable))
        exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
        log = tmp / "ui.jsonl"
        os.environ["FAKE_UI_LOG"] = str(log)
        os.environ["VOICEBUD_UI"] = str(exe)
        (settings.data_dir() / "dictionary.json").write_text(json.dumps(
            {"terms": ["AI-Slop", "shadcn", "FS-SC", "Repo", "Slides", "Excel-Sheet", "To-do-Liste"]}))

        pasted = []
        main.inject.inject = lambda text, cfg: pasted.append((time.time(), text))
        vb = main.VoiceBud(CFG, recorder=Recorder(), open_mic=False)
        vb.start()
        try:
            self.assertTrue(vb.ui.ready.wait(10))
            for name in ["de", "ja-real", "stille-1s", "nils-01"]:
                audio = load_wav(name)
                live = name == "nils-01"
                vb.settings["liveText"] = live    # what settings_changed would load
                n_before = len(pasted)
                offset = len(log.read_text().splitlines()) if log.exists() else 0
                vb.start_rec("dictate")
                push_realtime(vb.rec.feed, audio)
                t_stop = time.time()
                vb.stop_rec("dictate")

                def finished():
                    msgs = [json.loads(l) for l in log.read_text().splitlines()[offset:]]
                    return [m for m in msgs if m.get("phase") in ("done", "empty", "error")]
                end = time.time() + 60
                while not finished() and time.time() < end:
                    time.sleep(0.01)
                t_end = time.time()
                time.sleep(0.2)
                msgs = [json.loads(l) for l in log.read_text().splitlines()[offset:]]
                kinds = [m["type"] if m["type"] != "state" else m["phase"] for m in msgs]
                final = finished()[0]
                row = {"stop_to_island_s": round(t_end - t_stop, 3), "phase": final["phase"], "live": live,
                       "levels": kinds.count("level"), "partials": kinds.count("partial"),
                       "kinds": [k for k in dict.fromkeys(kinds)], "llm": dict(vb.cleaner.last_stats)}
                if final["phase"] == "done":
                    row.update(words=final["words"], seconds=final["seconds"], preview=final["preview"],
                               target=final["target"], app=final.get("app"),
                               pasted=pasted[-1][1], stop_to_paste_s=round(pasted[-1][0] - t_stop, 3))
                RESULTS["end_to_end"][name] = row
                with self.subTest(name=name):
                    self.assertEqual(kinds[0], "recording")
                    self.assertIn("processing", kinds)
                    self.assertGreater(row["levels"], 0.6 * 30 * audio.size / 16000 / SPEED,
                                       "levels should arrive at ~30 Hz")
                    if not live:
                        self.assertEqual(row["partials"], 0, "live text off: no streaming")
                    if name == "stille-1s":
                        # 04.10.: a silent take says so instead of vanishing (room noise: "Nichts verstanden")
                        self.assertEqual(final["phase"], "error")
                        self.assertEqual(final.get("message"), "Nichts verstanden")
                        self.assertEqual(len(pasted), n_before)
                        continue
                    self.assertEqual(final["phase"], "done")
                    self.assertEqual(final["words"], len(pasted[-1][1].split()))
                    self.assertLessEqual(len(final["preview"]), 242 if live else 82)
                    if not live:
                        self.assertNotIn("\n", final["preview"])
                    self.assertIn(final["target"], ("pasted", "clipboard"))
                    self.assertIn("history_changed", kinds)
                    if name == "nils-01":
                        self.assertGreaterEqual(row["partials"], 6, "live text on: partials while speaking")
                        text = pasted[-1][1]
                        for term in ("AI-Slop", "shadcn", "FS-SC"):
                            self.assertIn(term, text)
                        self.assertNotIn("Großbuchstaben", text)  # no LLM rewording survives
            rows = History(settings.data_dir() / "history.sqlite").search("Projekt")
            self.assertTrue(rows, "take missing from history")
            # the hub changes settings + dictionary and tells us via settings_changed
            (settings.data_dir() / "settings.json").write_text(json.dumps(
                {"keepModelsLoaded": True, "islandStyle": "live", "unknownKey": 1}))
            (settings.data_dir() / "dictionary.json").write_text(json.dumps({"terms": ["Becker"]}))
            vb.ui.send({"type": "_test", "cmd": "settings"})
            self.assertTrue(_wait(lambda: vb.dictionary.terms == ["Becker"], 5))
            self.assertTrue(vb.settings["keepModelsLoaded"])
            self.assertEqual(vb.dictionary.correct("Frau Bäcker"), "Frau Bäcker")  # real word stays
            self.assertTrue(vb.cleaner.keep_loaded, "keepModelsLoaded must keep the LLM resident too")
            (settings.data_dir() / "settings.json").unlink()
        finally:
            # the LLM process must not outlive the test (keepModelsLoaded pinned it)
            vb.cleaner.keep_loaded = False
            vb.cleaner.shutdown()
            vb.worker.shutdown()
            vb.ui.close()
            vb.history.close()

    def test_3_live_preview(self):
        """liveText on: the open part is decoded speculatively while the GPU is idle."""
        from stream import Take
        audio = load_wav("de")
        partials = []
        WORKER.begin_take()
        take = Take(WORKER, on_partial=lambda text: partials.append(text), preview=True)
        push_realtime(take.feed, audio)
        t = time.time()
        res = take.finish()
        stop_to_text = time.time() - t
        WORKER.end_take()
        RESULTS["streaming"]["de (live preview)"] = {
            "partials": len(partials), "previews": res.previews,
            "stop_to_text_s": round(stop_to_text, 3), "wer_vs_batch": round(wer(BATCH["de"]["text"], res.text), 3)}
        self.assertGreater(res.previews, 3)
        self.assertGreater(len(partials), RESULTS["streaming"]["de"]["partials"])
        self.assertLess(stop_to_text, BATCH["de"]["seconds"] + 0.8)
        self.assertEqual(res.text, guards.collapse_repeats(BATCH["de"]["text"]))

    def test_3b_live_text_off_does_not_stream(self):
        """liveText off: no segmenter, no partials, no GPU work while recording; the final
        text is the same one-pass transcript."""
        from stream import Take
        for name in ["de", "ja-real", "stille-1s"]:
            audio = load_wav(name)
            partials = []
            WORKER.begin_take()
            take = Take(WORKER, on_partial=lambda text: partials.append(text), stream=False)
            busy = []
            push_realtime(take.feed, audio,
                          lambda i: busy.append(WORKER.busy) if i and i % (BLOCK * 25) == 0 else None)
            t = time.time()
            res = take.finish()
            stop_to_text = time.time() - t
            WORKER.end_take()
            RESULTS["streaming"][f"{name} (live text off)"] = {
                "partials": len(partials), "segments": res.segments, "stop_to_text_s": round(stop_to_text, 3)}
            with self.subTest(name=name):
                self.assertEqual(partials, [])
                self.assertEqual(res.segments, 0)
                self.assertFalse(any(busy), "the GPU worked while recording")
                self.assertEqual(res.text, guards.collapse_repeats(BATCH[name]["text"]))
                self.assertLess(stop_to_text, BATCH[name]["seconds"] + 0.5)

    def test_3c_speculation_gives_the_one_pass_text(self):
        """Live text off, speculation on (04.10.): in the final pause the pass is computed ahead
        and used only when the whole take's VAD equals the speculation's, so the text is exactly
        the one-pass text. Speech after the pause makes it unused, and the text is still right."""
        from stream import Take
        rng = np.random.default_rng(3)

        def quiet(s):
            return (rng.standard_normal(int(s * 16000)) * 0.001).astype(np.float32)

        def run(parts, wait_spec_after=None):
            WORKER.begin_take()
            take = Take(WORKER, stream=False, speculate=True)
            fed = 0
            for k, part in enumerate(parts):
                push_realtime(take.feed, part)
                fed += part.size
                if k == wait_spec_after:
                    end = time.time() + 15
                    while time.time() < end and not (take._spec and take._spec["n"] >= fed - 8000
                                                     and take._spec["future"].done()):
                        time.sleep(0.05)
            res = take.finish()
            WORKER.end_take()
            audio = np.concatenate(parts)
            fresh = guards.collapse_repeats(WORKER.submit(STT.transcribe, audio, final=True).result()[0])
            return res, fresh

        for name in ["de", "denglisch", "satz-stille"]:
            res, fresh = run([load_wav(name), quiet(1.2)], wait_spec_after=1)
            with self.subTest(name=name):
                self.assertTrue(res.speculative, "the final pause was not used")
                self.assertEqual(res.text, fresh)
        # speech after the pause, stopped mid-sentence: only the stale speculation exists
        res, fresh = run([load_wav("denglisch"), quiet(1.2), load_wav("en")[:int(3.5 * 16000)]], wait_spec_after=1)
        self.assertFalse(res.speculative, "speech after the pause must not reuse the speculation")
        self.assertEqual(res.text, fresh)

    def test_4_idle_unload_frees_ram(self):
        from transcribe import footprint_mb
        WORKER.preload().result()
        WORKER.begin_take()
        WORKER.submit(STT.transcribe, load_wav("de")).result()
        WORKER.end_take()
        WORKER.submit(lambda: None).result()  # clear_cache done
        before = footprint_mb()
        mlx_before = WORKER.submit(STT.memory_mb).result()
        WORKER.idle_unload_s = 2.0
        t = time.time()
        WORKER.arm_idle()
        self.assertTrue(_wait(lambda: WORKER.submit(lambda: STT.loaded).result() is False, 10))
        unload_after = time.time() - t
        time.sleep(3)  # Metal hands pages back asynchronously
        after = footprint_mb()
        mlx_after = WORKER.submit(STT.memory_mb).result()
        t = time.time()
        WORKER.preload().result()
        reload_s = time.time() - t
        t = time.time()
        text, _ = WORKER.submit(STT.transcribe, load_wav("de")).result()
        first_after_reload = time.time() - t
        reloaded = footprint_mb()
        # keepModelsLoaded: the idle timer must not unload
        WORKER.keep_loaded = lambda: True
        WORKER.idle_unload_s = 0.5
        WORKER.arm_idle()
        time.sleep(1.5)
        still_loaded = WORKER.submit(lambda: STT.loaded).result()
        WORKER.keep_loaded = lambda: False
        RESULTS["ram"].update(
            loaded_footprint_mb=round(before), unloaded_footprint_mb=round(after),
            freed_mb=round(before - after), mlx_active_mb_before=round(mlx_before[0]),
            mlx_active_mb_after=round(mlx_after[0], 1), mlx_cache_mb_after_take=round(mlx_before[1], 1),
            unload_fired_after_s=round(unload_after, 2), reload_s=round(reload_s, 3),
            first_transcribe_after_reload_s=round(first_after_reload, 3),
            footprint_after_reload_mb=round(reloaded), keep_loaded_respected=still_loaded)
        self.assertGreater(before - after, 500)
        self.assertLess(mlx_after[0], 20)
        self.assertLess(mlx_before[1], 70, "MLX cache above the 64 MB limit after clear_cache")
        self.assertIn("Projekt", text)
        self.assertTrue(still_loaded)


def _wait(cond, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return False


if __name__ == "__main__":
    unittest.main()
