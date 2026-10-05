"""Local STT via faster-whisper (CTranslate2) or mlx-whisper (Apple GPU via MLX).
Silero VAD gates both: no speech -> no transcript, and silence is trimmed off
before decoding, because trailing silence is what sends Whisper into loops.

MLX is not re-entrant and keeps per-thread streams: every method that touches MLX
(load, warm, unload, transcribe, detect_language) must run on the ONE worker thread that
stream.SttWorker owns."""
import ctypes
import gc
import sys
import time
import types
from pathlib import Path

import numpy as np


def _lean_imports():
    """Keep library code VoiceBud never runs out of the resident footprint (measured with
    phys_footprint: VAD + mlx_whisper imports 249 MB -> 61 MB).
    - `faster_whisper.vad` (only the Silero ONNX VAD is used) imports the whole faster_whisper
      package; ctranslate2's model converters then import torch inside a try/except ImportError.
      VoiceBud never converts models, so torch is blocked and the converters skip it.
    - `mlx_whisper.timing` (word timestamps, never requested) imports numba and scipy.signal;
      a stub with the one imported name takes its place."""
    sys.modules.setdefault("torch", None)
    if "mlx_whisper.timing" not in sys.modules:
        stub = types.ModuleType("mlx_whisper.timing")

        def add_word_timestamps(*_args, **_kwargs):
            raise RuntimeError("word timestamps are not available in VoiceBud (mlx_whisper.timing is stubbed)")
        stub.add_word_timestamps = add_word_timestamps
        sys.modules["mlx_whisper.timing"] = stub


_lean_imports()
from faster_whisper.vad import VadOptions, get_speech_timestamps  # noqa: E402  (after _lean_imports)

import guards
import settings


SAMPLE_RATE = 16000
MIN_SPEECH_S = 0.2  # less than this is a click or a breath, not a word
VAD = VadOptions(min_silence_duration_ms=300, speech_pad_ms=200)
# Language guessing on a one-word take is unreliable ("Ja" came out as "Yeah"), so
# English must clearly beat German on short takes and simply win on longer ones.
SHORT_TAKE_S = 3.0
EN_MARGIN_SHORT = 3.0
SINGLE_WORD_S = 1.0  # below this the guess is noise: always German
MLX_CACHE_LIMIT = 64 * 1024 * 1024  # freed buffers MLX may keep around for reuse


class _MissingModel(RuntimeError):
    pass


def _local_model_dir(repo, download=True):
    """mlx_whisper only loads config.json + weights.safetensors|npz, but some quantized
    repos ship model.safetensors — link those into the expected layout. Prefers the
    local cache so VoiceBud starts offline; with download=False a missing model gives None
    (the onboarding downloads it, never the start of the app)."""
    from huggingface_hub import snapshot_download

    patterns = ["config.json", "*.safetensors", "*.npz"]
    try:
        path = Path(snapshot_download(repo_id=repo, allow_patterns=patterns, local_files_only=True))
    except Exception:
        if not download:
            return None
        path = Path(snapshot_download(repo_id=repo, allow_patterns=patterns))
    if (path / "weights.safetensors").exists() or (path / "weights.npz").exists():
        return str(path)
    shim = model_dir() / repo.replace("/", "--")
    shim.mkdir(parents=True, exist_ok=True)
    for name, target in (("config.json", path / "config.json"),
                         ("weights.safetensors", path / "model.safetensors")):
        link = shim / name
        target = target.resolve()
        if link.is_symlink() and link.resolve() == target:
            continue  # already right: no unlink/relink window for a running instance
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target)
    return str(shim)


def model_dir():
    """Shim folder for re-linked model files; follows VOICEBUD_DATA_DIR like settings.json,
    so tests never write into the real data folder."""
    return settings.data_dir() / "models"


class _RusageInfoV2(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups",
        "ri_pageins", "ri_wired_size", "ri_resident_size", "ri_phys_footprint",
        "ri_proc_start_abstime", "ri_proc_exit_abstime", "ri_child_user_time",
        "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
        "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
        "ri_diskio_byteswritten")]


def footprint_mb(pid=None):
    """Physical footprint in MB — the number Activity Monitor shows as "Memory"
    (includes the Metal buffers that hold the Whisper weights)."""
    import os
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        info = _RusageInfoV2()
        if libc.proc_pid_rusage(pid or os.getpid(), 2, ctypes.byref(info)) == 0:
            return info.ri_phys_footprint / 2**20
    except Exception:
        pass
    return float("nan")


def speech_stats(audio):
    """(speech timestamps, seconds of speech) from Silero VAD."""
    if audio.size == 0:
        return [], 0.0
    speech = get_speech_timestamps(audio, VAD, sampling_rate=SAMPLE_RATE)
    return speech, sum(s["end"] - s["start"] for s in speech) / SAMPLE_RATE


class Transcriber:
    repo_id = ""
    _mlx_dir = None

    @property
    def _mlx_repo(self):
        """Local Whisper folder, looked up again once the onboarding has downloaded it."""
        if self._mlx_dir is None:
            self._mlx_dir = _local_model_dir(self.repo_id, download=False)
            if self._mlx_dir is None:
                raise _MissingModel("Spracherkennung fehlt, bitte unter Einrichtung laden")
        return self._mlx_dir

    def __init__(self, cfg):
        self.cfg = cfg
        engine = cfg.get("engine", "faster-whisper")
        self.last_load_s = 0.0
        if engine == "mlx-whisper":
            import mlx_whisper  # optional GPU path
            self._mlx = mlx_whisper
            self._model = None
            # map faster-whisper style model names to MLX community repos;
            # unknown names pass through as full HF repo paths
            mlx_repos = {
                "tiny": "mlx-community/whisper-tiny",
                "base": "mlx-community/whisper-base-mlx",
                "small": "mlx-community/whisper-small-mlx",
                "medium": "mlx-community/whisper-medium-mlx",
                "large-v3": "mlx-community/whisper-large-v3-mlx",
                "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
                "large-v3-turbo-q8": "mlx-community/whisper-large-v3-turbo-8bit",
            }
            name = cfg.get("model", "small")
            self.repo_id = mlx_repos.get(name, name)
            self._mlx_dir = _local_model_dir(self.repo_id, download=False)
        else:
            from faster_whisper import WhisperModel
            self._mlx = None
            self._model = WhisperModel(
                cfg.get("model", "base"),
                device="cpu",
                compute_type=cfg.get("compute_type", "int8"),
            )

    # -- model lifetime (MLX worker thread only) ---------------------------------------------
    @property
    def unloadable(self):
        return self._mlx is not None

    @property
    def loaded(self):
        if self._mlx is None:
            return True
        from mlx_whisper.transcribe import ModelHolder
        return ModelHolder.model is not None and ModelHolder.model_path == self._mlx_dir

    def setup_mlx(self):
        if self._mlx is not None:
            import mlx.core as mx
            mx.set_cache_limit(MLX_CACHE_LIMIT)

    def load(self):
        """Load the weights if they are not resident. Returns seconds spent (0 if loaded)."""
        if self._mlx is None or self.loaded:
            return 0.0
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder
        t = time.time()
        model = ModelHolder.get_model(self._mlx_repo, mx.float16)
        mx.eval(model.parameters())  # materialise now, not lazily inside the first take
        self.last_load_s = time.time() - t
        return self.last_load_s

    def warm(self):
        """Load and run one tiny decode so the first take pays no kernel compilation."""
        if self._mlx is None:
            return  # faster-whisper loads its model in __init__
        self.load()
        noise = (np.random.randn(SAMPLE_RATE) * 0.01).astype(np.float32)
        self._mlx.transcribe(noise, path_or_hf_repo=self._mlx_repo, language="de")
        self.clear_cache()

    def unload(self):
        """Drop the Whisper weights and give the memory back to macOS."""
        if self._mlx is None:
            return
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder
        ModelHolder.model = None
        ModelHolder.model_path = None
        gc.collect()
        mx.clear_cache()

    def clear_cache(self):
        if self._mlx is not None:
            import mlx.core as mx
            mx.clear_cache()

    def memory_mb(self):
        """(active, cache) MLX memory in MB."""
        if self._mlx is None:
            return 0.0, 0.0
        import mlx.core as mx
        return mx.get_active_memory() / 2**20, mx.get_cache_memory() / 2**20

    # -- recognition (MLX worker thread only) ------------------------------------------------
    def detect_language(self, audio, speech_s):
        """Choose between German and English only, with German as the default."""
        if self._mlx is None or speech_s < SINGLE_WORD_S:
            return "de"
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
        from mlx_whisper.transcribe import ModelHolder

        model = ModelHolder.get_model(self._mlx_repo, mx.float16)
        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        _, probs = model.detect_language(pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16))
        margin = EN_MARGIN_SHORT if speech_s < SHORT_TAKE_S else 1.0
        return "en" if probs.get("en", 0.0) > margin * probs.get("de", 0.0) else "de"

    _detect_de_en = detect_language  # old name

    def transcribe(self, audio, language=None, speech=None, prompt=None, final=False):
        """audio: mono float32 numpy array at 16kHz. Returns (text, language).
        `language` overrides detection (streaming decides it once per take);
        `speech` = precomputed (timestamps, seconds) from speech_stats;
        `prompt` = text said just before (streaming context for the next segment);
        `final` = the whole take after stop: when the speech runs into the stop, a closing
        sentence that only repeats earlier words is dropped (guards.drop_cut_repeat)."""
        self.last_temperature = 0.0
        if audio.size == 0:
            return "", None
        timestamps, speech_s = speech if speech is not None else speech_stats(audio)
        if speech_s < MIN_SPEECH_S:
            return "", None
        cut_mid_speech = timestamps[-1]["end"] >= audio.size - int(0.1 * SAMPLE_RATE)
        audio = audio[timestamps[0]["start"]:timestamps[-1]["end"]]

        language = language or self.cfg.get("language")
        if self._mlx is not None:
            if language is None:
                language = self.detect_language(audio, speech_s)
            # one fallback step instead of five (0.2 ... 1.0): the fallback only fires on very hard
            # audio, where five sampled retries took 4.6 s instead of 2.5 s for the same words
            # (bench 04.10.: identical text everywhere else, WER 0.49 vs 0.50 at -3 dB SNR)
            result = self._mlx.transcribe(
                audio, path_or_hf_repo=self._mlx_repo, language=language,
                condition_on_previous_text=False, initial_prompt=prompt or None,
                temperature=tuple(self.cfg.get("temperatures", (0.0, 0.4))),
            )
            self.last_temperature = max((s.get("temperature", 0.0) for s in result.get("segments", [])),
                                        default=0.0)
            text = result.get("text", "").strip()
            lang = result.get("language")
            no_speech = max((s.get("no_speech_prob", 0.0) for s in result.get("segments", [])),
                            default=0.0)
        else:
            segments, info = self._model.transcribe(
                audio, language=language, beam_size=1, condition_on_previous_text=False,
                initial_prompt=prompt or None,
            )
            segments = list(segments)
            text = " ".join(seg.text.strip() for seg in segments).strip()
            lang = info.language
            no_speech = max((seg.no_speech_prob for seg in segments), default=0.0)

        if guards.is_hallucination(text, speech_s, no_speech):
            return "", None
        text = guards.strip_hums(guards.collapse_repeats(text))
        if final and cut_mid_speech:
            text = guards.drop_cut_repeat(text)
        return text, lang
