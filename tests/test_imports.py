"""RAM: the resident footprint must not carry library code VoiceBud never runs (torch via
ctranslate2's converters, numba + scipy via mlx_whisper's word timestamps). Runs in a fresh
interpreter, so other tests' imports do not hide a regression."""
import json
import subprocess
import sys
import unittest

import _util

PROBE = r"""
import json, sys
sys.path.insert(0, %r)
import numpy as np
import main            # the whole app's import graph (stream, transcribe, cleanup, ...)
import mlx_whisper     # what Transcriber imports for the MLX engine
from transcribe import footprint_mb, speech_stats
t = np.arange(16000 * 2) / 16000
audio = (0.3 * np.sin(2 * np.pi * 220 * t) * (np.sin(2 * np.pi * 3 * t) > 0)).astype(np.float32)
print(json.dumps({
    "torch": sys.modules.get("torch") is not None,
    "numba": "numba" in sys.modules,
    "scipy_signal": "scipy.signal" in sys.modules,
    "footprint_mb": round(footprint_mb()),
    "vad_runs": isinstance(speech_stats(audio)[1], float),
}))
"""


class LeanImportsTest(unittest.TestCase):
    def test_no_torch_no_numba(self):
        out = subprocess.run([sys.executable, "-c", PROBE % str(_util.ROOT)], capture_output=True,
                             text=True, timeout=120, cwd=str(_util.ROOT))
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        info = json.loads(out.stdout.strip().splitlines()[-1])
        print("\nIMPORT_FOOTPRINT", info)
        self.assertFalse(info["torch"], "torch got imported")
        self.assertFalse(info["numba"], "numba got imported")
        self.assertFalse(info["scipy_signal"], "scipy.signal got imported")
        self.assertTrue(info["vad_runs"])


if __name__ == "__main__":
    unittest.main()
