"""Readahead of the model's weights (10.10.): only the language tensors, merged and capped, and
nothing at all on any doubt. No model needed."""
import json
import os
import struct
import tempfile
import unittest

import _util  # noqa: F401
import llm_worker


def safetensors(tensors):
    """A file with these (name, size) tensors laid out in order."""
    header, off = {}, 0
    for name, size in tensors:
        header[name] = {"dtype": "U8", "shape": [size], "data_offsets": [off, off + size]}
        off += size
    raw = json.dumps(header).encode()
    path = os.path.join(tempfile.mkdtemp(), "model.safetensors")
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(raw)) + raw + b"\0" * off)
    return path, 8 + len(raw)


class ReadaheadTest(unittest.TestCase):
    def test_language_only_merged(self):
        path, base = safetensors([("language_model.a", 1000), ("language_model.b", 500),
                                  ("vision_tower.x", 3 * 2**20), ("language_model.c", 700)])
        self.assertEqual(llm_worker.readahead_ranges(path),
                         [(base, base + 1500), (base + 1500 + 3 * 2**20, base + 1500 + 3 * 2**20 + 700)])

    def test_small_gaps_merge(self):
        path, base = safetensors([("model.a", 100), ("vision_tower.y", 1000), ("model.b", 100)])
        self.assertEqual(llm_worker.readahead_ranges(path), [(base, base + 1200)])

    def test_nothing_on_doubt(self):
        self.assertEqual(llm_worker.readahead_ranges("/nonexistent"), [])
        bad = os.path.join(tempfile.mkdtemp(), "x.safetensors")
        with open(bad, "wb") as f:
            f.write(b"\xff" * 64)
        self.assertEqual(llm_worker.readahead_ranges(bad), [])
        llm_worker.readahead("/nonexistent")              # never raises


if __name__ == "__main__":
    unittest.main()
