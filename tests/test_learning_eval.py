"""The learning quality check (eval_learning.py) as a test: misrecognitions the user corrects fix
the next dictation, content edits teach nothing. 04.10.: 10 of 11 and 11 of 11 (before: 4 of 11)."""
import unittest

import _util  # noqa: F401


class LearningEvalTest(unittest.TestCase):
    def test_learns_names_and_never_content_edits(self):
        import eval_learning
        rows = eval_learning.run(old=False)
        learned = sum(ok for kind, *_rest, ok in rows if kind == "lernen")
        kept = sum(ok for kind, *_rest, ok in rows if kind != "lernen")
        self.assertEqual(kept, len(eval_learning.KEEP), "a content edit was learned")
        self.assertGreaterEqual(learned, 10)


if __name__ == "__main__":
    unittest.main()
