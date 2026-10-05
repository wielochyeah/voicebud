"""Formula renditions (formula.py): what Notizen, Word and the chat apps get from one answer."""
import unittest

import _util  # noqa: F401  (project on the path)

import formula as f

BLOCK = """Angenommen, eine Rendite $R$ ist zufällig:

$$
R \\sim N(9, 18^2)
$$

Das bedeutet:
- $\\mu = 9\\% =$ Erwartungswert
- $\\sigma^2 = 18^2 =$ Varianz

**Fall 1: $P(X < a)$**"""


class FormulaTests(unittest.TestCase):
    def test_readable_characters(self):
        cases = {
            r"\sigma^2 = 18^2": "σ² = 18²",
            r"R \sim N(\mu, \sigma^2)": "R ∼ N(μ, σ²)",
            r"z_a = \frac{a - \mu}{\sigma}": "zₐ = (a − μ)/σ",
            r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}": "x = (−b ± √(b² − 4ac))/(2a)",
            r"\int_{0}^{1} x^2 \, dx = \frac{1}{3}": "∫₀¹ x² dx = ⅓",
            r"P(X > a) = 1 - \Phi(z_a)": "P(X > a) = 1 − Φ(zₐ)",
            r"x^2 + \sqrt{x + 1} = \frac{1}{2}": "x² + √(x + 1) = ½",
            r"\left( \frac{a}{b} \right)^{n+1}": "(a/b)ⁿ⁺¹",
            r"\sqrt[3]{8} \cdot \bar{x}": "∛8 · x̄",
            r"\mathbb{R}^n": "ℝⁿ",
        }
        for tex, want in cases.items():
            self.assertEqual(f.latex_to_text(tex), want, tex)

    def test_what_has_no_unicode_stays_readable(self):
        self.assertEqual(f.latex_to_text(r"e^{i\pi}"), "e^(iπ)")      # no superscript π
        self.assertEqual(f.latex_to_text(r"\frobnicate{x}"), "frobnicatex")   # unknown: name kept, no crash

    def test_plain_takes_out_markdown_and_dollars(self):
        text = f.plain(BLOCK)
        self.assertIn("eine Rendite R ist zufällig", text)
        self.assertIn("\nR ∼ N(9, 18²)\n", text)
        self.assertIn("- μ = 9% = Erwartungswert", text)
        self.assertIn("Fall 1: P(X < a)", text)
        self.assertNotIn("$", text)
        self.assertNotIn("**", text)

    def test_html_has_one_math_per_formula_for_word(self):
        h = f.html(BLOCK)
        self.assertEqual(h.count("<math"), 5)
        self.assertEqual(h.count('display="block"'), 1)
        self.assertIn("<ul><li>", h)
        self.assertIn("<b>Fall 1: <math", h)
        self.assertNotIn("$", h)

    def test_markdown_is_tidied(self):
        self.assertEqual(f.markdown("```markdown\n$x^2$\n```"), "$x^2$")
        self.assertEqual(f.markdown(r"\[ x \] and \( y \)"), "$$ x $$ and $ y $")
        self.assertTrue(f.has_math("a $b$ c"))
        self.assertFalse(f.has_math("costs 5 \\$ and 6 \\$"))

    def test_renditions(self):
        r = f.renditions(BLOCK)
        self.assertEqual(set(r), {"markdown", "plain", "html"})
        self.assertIn("$R$", r["markdown"])


if __name__ == "__main__":
    unittest.main()
