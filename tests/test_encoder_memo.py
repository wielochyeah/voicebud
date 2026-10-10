"""The Whisper encoder memo (10.10.): the same input inside one transcription is encoded once, and
what comes back is bit for bit what the encoder gives. Runs on the CPU with a tiny encoder, no model."""
import unittest

import numpy as np

import _util  # noqa: F401
import mlx.core as mx

import transcribe as tr


class EncoderMemoTest(unittest.TestCase):
    def setUp(self):
        self._device = mx.default_device()
        mx.set_default_device(mx.cpu)
        mx.disable_compile()          # no C++ toolchain needed for the CPU kernels

    def tearDown(self):
        mx.enable_compile()
        mx.set_default_device(self._device)
        tr._encoder_memo = None

    def encoder(self):
        from mlx_whisper.whisper import AudioEncoder
        mx.random.seed(3)
        enc = AudioEncoder(n_mels=8, n_ctx=10, n_state=16, n_head=2, n_layer=2, dtype=mx.float16)
        mx.eval(enc.parameters())
        return enc

    def mel(self, seed=1):
        return mx.random.normal((1, 20, 8), key=mx.random.key(seed)).astype(mx.float16)

    def test_memo_class(self):
        memo = tr.EncoderMemo()
        calls = []
        f = lambda x: calls.append(1) or x * 2                                   # noqa: E731
        a = mx.array([1.0, 2.0], dtype=mx.float16)
        memo.encode(a, f)
        memo.encode(mx.array([1.0, 2.0], dtype=mx.float16), f)                   # same bits: reused
        memo.encode(mx.array([1.0, 2.0, 3.0], dtype=mx.float16), f)              # other shape
        memo.encode(mx.array([0.0], dtype=mx.float16), f)
        memo.encode(mx.array([-0.0], dtype=mx.float16), f)                       # -0 is not +0
        self.assertEqual((memo.computed, memo.reused, len(calls)), (4, 1, 4))

    def test_keeps_only_the_last(self):
        memo = tr.EncoderMemo()
        for i in range(6):
            memo.encode(mx.array([float(i)], dtype=mx.float16), lambda x: x)
        self.assertEqual(len(memo.items), memo.MAX)
        memo.encode(mx.array([0.0], dtype=mx.float16), lambda x: x)            # evicted: computed again
        self.assertEqual(memo.reused, 0)

    def test_broken_compare_computes(self):
        memo = tr.EncoderMemo()
        memo.encode(mx.array([1.0], dtype=mx.float16), lambda x: x)
        memo.same = lambda a, b: 1 / 0                                           # any trouble: no guess
        out = memo.encode(mx.array([1.0], dtype=mx.float16), lambda x: x + 1)
        self.assertEqual(out.item(), 2.0)
        self.assertEqual(memo.computed, 2)

    def test_encoder_bits_unchanged(self):
        enc = self.encoder()
        x = self.mel()
        plain = enc(x)
        mx.eval(plain)
        from types import SimpleNamespace
        tr._memo_encoder(SimpleNamespace(encoder=enc))
        tr._memo_encoder(SimpleNamespace(encoder=enc))                           # once only
        self.assertTrue(type(enc).__name__.endswith("Memo"))
        self.assertFalse(type(type(enc).__mro__[1]).__name__.endswith("MemoMemo"))
        self.assertEqual(enc(x).view(mx.uint16).tolist(), plain.view(mx.uint16).tolist())   # no memo running
        tr._encoder_memo = memo = tr.EncoderMemo()
        first = enc(x)
        again = enc(mx.array(np.array(x)))                                      # equal values, new array
        other = enc(self.mel(2))
        tr._encoder_memo = None
        self.assertEqual((memo.computed, memo.reused), (2, 1))
        self.assertEqual(first.view(mx.uint16).tolist(), plain.view(mx.uint16).tolist())
        self.assertEqual(again.view(mx.uint16).tolist(), plain.view(mx.uint16).tolist())
        self.assertNotEqual(other.view(mx.uint16).tolist(), plain.view(mx.uint16).tolist())
        self.assertEqual(len(dict(enc.parameters())), len(dict(self.encoder().parameters())))

    def test_language_pass_and_first_window_match_from_30_s(self):
        """The premise: with 30 s or more the language pass encodes exactly the first window (shorter
        takes differ, and the memo simply misses there)."""
        from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
        rng = np.random.default_rng(5)
        for seconds, same in ((31.0, True), (45.0, True), (12.0, False)):
            audio = (rng.standard_normal(int(seconds * 16000)) * 0.1).astype(np.float32)
            mel = log_mel_spectrogram(audio, n_mels=128, padding=N_SAMPLES)
            detect = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)            # transcribe.detect_language
            window = pad_or_trim(mel[0:min(N_FRAMES, mel.shape[-2] - N_FRAMES)], N_FRAMES, axis=-2).astype(mx.float16)
            self.assertEqual(tr.EncoderMemo.same(detect[None], window[None]), same, seconds)


if __name__ == "__main__":
    unittest.main()
