"""Formulas with the real model (slow, like test_pipeline: run on its own). The vision part reads a
rendered page of formulas, shares the dictation model's weights, and a dictation right after is
as fast as ever."""
import subprocess
import time
import unittest

import yaml

import _util
from cleanup import Cleaner

CFG = yaml.safe_load((_util.ROOT / "config.yaml").read_text())
IMAGE = _util.ROOT / "tests" / "assets" / "formeln.png"


class FormulaModelTest(unittest.TestCase):
    def test_reads_formulas_and_dictation_stays_fast(self):
        c = Cleaner(CFG["llm"])
        try:
            t = time.time()
            text = c.formula(IMAGE)
            cold = time.time() - t
            self.assertIsNotNone(text, "the formula reader did not answer")
            for part in (r"\frac{1}{2}", r"\sqrt{b^2 - 4ac}", r"\sum_{i=1}^{n}", r"\int_{0}^{1}"):
                self.assertIn(part, text)
            t = time.time()
            c.formula(IMAGE)
            warm = time.time() - t
            out = c.clean("ähm also das treffen ist am freitag um zehn", language="de")
            stats = dict(c.last_stats)
            mb = int(subprocess.run(["ps", "-o", "rss=", "-p", str(c._proc.pid)], capture_output=True,
                                    text=True).stdout.strip() or 0) // 1024
            print(f"\nformula cold {cold:.1f}s, warm {warm:.1f}s; dictation after: {stats.get('eval')}s eval; "
                  f"worker {mb} MB")
            self.assertLess(warm, 6.0)
            self.assertTrue(out)
            self.assertLess(stats.get("eval", 9), 1.5)
            self.assertLess(mb, 5000)          # shared weights: a second copy of the language model would be ~6.5 GB
        finally:
            c.shutdown()


if __name__ == "__main__":
    unittest.main()
