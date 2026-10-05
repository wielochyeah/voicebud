"""Formulas from the screen (05.10., Nils): ⇧⌘2, then a tap on ⌥, reads the region with the vision
part of the local model (llm_worker op "formula"), which writes Markdown with LaTeX ($…$ inline,
$$…$$ on its own line). One answer, three renditions, chosen by the app the text is pasted into:

  markdown(): as the model wrote it: chat apps, browsers, Notion, editors render or keep LaTeX
  html():     paragraphs and lists with MathML: Word (and the other Office apps) turn every
              <math> into a real, editable equation when pasting (tested on Word 16.113)
  plain():    readable characters for Notizen, Mail and the like, which have no formulas at all:
              σ², √(x + 1), (a − μ)/σ, ∫₀¹ x² dx = ⅓

Everything here is plain string work, no model: it is tested in tests/test_formula.py."""
import html as _html
import re


# -- the model's answer ----------------------------------------------------------------------------

_FENCE = re.compile(r"^```[a-zA-Z]*\n(.*?)\n```$", re.S)


def markdown(answer):
    """The model's answer, tidied: no code fence around it, \\[ \\] and \\( \\) as $$ and $."""
    text = (answer or "").strip()
    m = _FENCE.match(text)
    if m:
        text = m.group(1).strip()
    text = re.sub(r"\\\[(.+?)\\\]", lambda m: "$$" + m.group(1).strip() + "$$", text, flags=re.S)
    text = re.sub(r"\\\((.+?)\\\)", lambda m: "$" + m.group(1).strip() + "$", text, flags=re.S)
    return text


# $$…$$ (may span lines) or $…$ on one line, opened before and closed after a non-space and not
# followed by a digit (the rule of pandoc and the chat apps: "5 $ und 6 $" is no formula); a "\$"
# is a dollar sign
_MATH = re.compile(r"\$\$((?s:.+?))\$\$|(?<![\\$])\$(?=[^\s$])((?:\\[^\n]|[^\n$\\])*?(?:\\\S|[^\s\\$]))\$(?![\d$])")


def _split(text):
    """[(kind, content)] with kind "text", "inline" or "display"."""
    out, pos = [], 0
    for m in _MATH.finditer(text):
        if m.start() > pos:
            out.append(("text", text[pos:m.start()].replace("\\$", "$")))
        if m.group(1) is not None:
            out.append(("display", m.group(1).strip()))
        else:
            out.append(("inline", m.group(2).strip()))
        pos = m.end()
    if pos < len(text):
        out.append(("text", text[pos:].replace("\\$", "$")))
    return out


def has_math(text):
    return any(kind != "text" for kind, _ in _split(text))


# -- readable characters ---------------------------------------------------------------------------

_SYMBOLS = {
    # Greek
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
    "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
    "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ",
    "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
    "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
    "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    # operators and relations
    "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘",
    "bullet": "•", "sim": "∼", "simeq": "≃", "approx": "≈", "cong": "≅", "equiv": "≡", "propto": "∝",
    "neq": "≠", "ne": "≠", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ll": "≪", "gg": "≫",
    "lt": "<", "gt": ">", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆",
    "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩", "setminus": "∖", "emptyset": "∅",
    "varnothing": "∅", "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
    "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "oplus": "⊕", "otimes": "⊗", "perp": "⊥",
    "parallel": "∥", "mid": "|", "vert": "|", "Vert": "‖", "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖",
    "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
    "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔", "Rightarrow": "⇒",
    "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⇒", "iff": "⇔", "mapsto": "↦",
    "uparrow": "↑", "downarrow": "↓", "infty": "∞", "partial": "∂", "nabla": "∇", "prime": "′",
    "degree": "°", "angle": "∠", "triangle": "△", "therefore": "∴", "because": "∵",
    "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "ell": "ℓ", "hbar": "ℏ",
    "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
    # big operators
    "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
    "bigcup": "⋃", "bigcap": "⋂",
    # spacing
    ",": " ", ";": " ", ":": " ", ">": " ", "!": "", "quad": "  ", "qquad": "    ", " ": " ",
    # escaped characters
    "%": "%", "$": "$", "{": "{", "}": "}", "&": "&", "_": "_", "#": "#", "|": "‖", "\\": "\n",
}
_FUNCTIONS = {"sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
              "log", "ln", "lg", "exp", "max", "min", "sup", "inf", "lim", "liminf", "limsup", "det", "dim",
              "ker", "deg", "gcd", "arg", "Pr", "mod", "bmod"}
_ACCENTS = {"bar": "̄", "overline": "̅", "hat": "̂", "widehat": "̂", "tilde": "̃",
            "widetilde": "̃", "vec": "⃗", "dot": "̇", "ddot": "̈", "acute": "́",
            "grave": "̀", "check": "̌", "breve": "̆", "underline": "̲"}
_FONTS = {"text", "textrm", "textit", "textbf", "textsf", "texttt", "mathrm", "mathit", "mathbf", "mathsf",
          "mathtt", "mathcal", "mathscr", "mathfrak", "boldsymbol", "bm", "operatorname", "mbox", "emph",
          "displaystyle", "textstyle", "scriptstyle"}
_BLACKBOARD = {"N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ", "C": "ℂ", "P": "ℙ", "E": "𝔼", "1": "𝟙"}
_SUP = dict(zip("0123456789+-−=()niaeoxyhkmprstuvwbcdfgjlzABDEGHIJKLMNOPRTUVW",
                "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁻⁼⁽⁾ⁿⁱᵃᵉᵒˣʸʰᵏᵐᵖʳˢᵗᵘᵛʷᵇᶜᵈᶠᵍʲˡᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂ"))
_SUP.update({"′": "′", "*": "*", "∗": "*", "T": "ᵀ", "α": "ᵅ", "β": "ᵝ", "γ": "ᵞ", "δ": "ᵟ", "θ": "ᶿ", "φ": "ᵠ", "ϕ": "ᵠ", "χ": "ᵡ"})
_SUB = dict(zip("0123456789+-−=()aehijklmnoprstuvx",
                "₀₁₂₃₄₅₆₇₈₉₊₋₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ"))
_SUB.update({"β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "ϕ": "ᵩ", "χ": "ᵪ"})
_VULGAR = {("1", "2"): "½", ("1", "3"): "⅓", ("2", "3"): "⅔", ("1", "4"): "¼", ("3", "4"): "¾",
           ("1", "5"): "⅕", ("2", "5"): "⅖", ("3", "5"): "⅗", ("4", "5"): "⅘", ("1", "6"): "⅙",
           ("5", "6"): "⅚", ("1", "7"): "⅐", ("1", "8"): "⅛", ("3", "8"): "⅜", ("5", "8"): "⅝",
           ("7", "8"): "⅞", ("1", "9"): "⅑", ("1", "10"): "⅒"}


class _Reader:
    """A small recursive reader for the LaTeX a model writes for printed formulas. What it does
    not know it keeps readable (the command name without its backslash) instead of failing."""

    def __init__(self, tex):
        self.s, self.i = tex, 0

    def peek(self):
        return self.s[self.i] if self.i < len(self.s) else ""

    def command(self):
        """after a backslash: a name of letters, or one other character"""
        self.i += 1
        start = self.i
        while self.i < len(self.s) and self.s[self.i].isalpha():
            self.i += 1
        if self.i == start and self.i < len(self.s):
            self.i += 1
        return self.s[start:self.i]

    def skip_spaces(self):
        while self.peek().isspace():
            self.i += 1

    def group(self):
        """one argument: {…} read whole, else the next single item"""
        self.skip_spaces()
        if self.peek() == "{":
            self.i += 1
            out = self.sequence(stop="}")
            self.i += 1
            return out
        return self.item()

    def optional(self):
        self.skip_spaces()
        if self.peek() != "[":
            return None
        self.i += 1
        out = self.sequence(stop="]")
        self.i += 1
        return out

    def sequence(self, stop=""):
        parts = []
        while self.i < len(self.s) and not (stop and self.peek() in stop):
            parts.append(self.item())
        return "".join(parts)

    def item(self):
        c = self.peek()
        if c == "":
            return ""
        if c == "{":
            return self.group()
        if c in "^_":
            self.i += 1
            return _script(self.group(), up=(c == "^"))
        if c == "~":
            self.i += 1
            return " "
        if c == "&":
            self.i += 1
            return ", "
        if c == "-":
            self.i += 1
            return "−"
        if c == "'":
            self.i += 1
            return "′"
        if c == "\\":
            return self.macro(self.command())
        if c.isspace():
            self.skip_spaces()
            return " "
        self.i += 1
        return c

    def macro(self, name):
        if name in ("frac", "dfrac", "tfrac", "cfrac"):
            num, den = self.group().strip(), self.group().strip()
            if (num, den) in _VULGAR:
                return _VULGAR[(num, den)]
            return _wrap(num) + "/" + _wrap(den)
        if name == "binom":
            n, k = self.group().strip(), self.group().strip()
            return f"C({n}, {k})"
        if name == "sqrt":
            index = self.optional()
            body = self.group().strip()
            sign = {"3": "∛", "4": "∜"}.get((index or "").strip(), "√")
            if index and sign == "√":
                sign = _script(index, up=True) + "√"
            return sign + (body if _atomic(body) else f"({body})")
        if name in _ACCENTS:
            body = self.group()
            return "".join(ch + _ACCENTS[name] if not ch.isspace() else ch for ch in body)
        if name == "mathbb":
            body = self.group()
            return "".join(_BLACKBOARD.get(ch, ch) for ch in body)
        if name in _FONTS:
            return self.group() if self.peek_group() else ""
        if name in ("left", "right", "bigl", "bigr", "Bigl", "Bigr", "big", "Big", "bigg", "Bigg"):
            self.skip_spaces()
            if self.peek() == ".":
                self.i += 1
                return ""
            return ""             # the delimiter that follows is read as it is
        if name == "begin":
            self.group()          # the environment's name: its rows follow (& and \\ read as , and ;)
            return "["
        if name == "end":
            self.group()
            return "]"
        if name in _FUNCTIONS:
            return name
        if name in _SYMBOLS:
            return _SYMBOLS[name]
        return name               # unknown: the name stays readable

    def peek_group(self):
        self.skip_spaces()
        return self.peek() != ""


def _atomic(s):
    """one symbol, one number, or already bracketed: needs no brackets of its own"""
    s = s.strip()
    if len(s) <= 1 or re.fullmatch(r"[0-9.,]+|[A-Za-zα-ωΑ-Ω]\S?", s):
        return True
    return s[0] in "([{" and s[-1] in ")]}" and s.count("(") <= 1


def _wrap(s):
    return s if _atomic(s) else f"({s})"


def _script(s, up):
    table = _SUP if up else _SUB
    s = s.strip()
    if s and all(ch in table for ch in s):
        return "".join(table[ch] for ch in s)
    return ("^" if up else "_") + (s if len(s) == 1 else f"({s})")


def latex_to_text(tex):
    """One formula in readable characters."""
    out = _Reader(tex).sequence()
    out = out.replace("\n", "; ")
    out = re.sub(r"([(\[{⟨])\s+", r"\1", out)        # \left( x \right) -> (x)
    out = re.sub(r"\s+([)\]}⟩])", r"\1", out)
    out = re.sub(r"[ \t]{2,}", lambda m: m.group(0) if len(m.group(0)) >= 4 else " ", out)
    return out.strip()


def plain(md):
    """For apps without formulas: readable characters, Markdown marks taken out."""
    md = re.sub(r"\*\*(.+?)\*\*", r"\1", md, flags=re.S)
    md = re.sub(r"(?m)^#{1,6}\s+", "", md)
    text = "".join(content if kind == "text" else latex_to_text(content) for kind, content in _split(md))
    return re.sub(r"\n{3,}", "\n\n", text).strip()


# -- HTML with MathML (Word) -----------------------------------------------------------------------

def _mathml(tex, display):
    try:      # imported on first use: the core's idle RAM stays where it was
        from latex2mathml.converter import convert
    except ImportError:      # an install without it: Word gets the readable characters instead
        return None
    # latex2mathml reads aligned/split/gathered as plain rows with a literal & (Word showed it)
    tex = re.sub(r"\\(begin|end)\{(aligned|split)\}", lambda m: f"\\{m.group(1)}{{align*}}", tex)
    tex = tex.replace("\\begin{gathered}", "\\begin{array}{c}").replace("\\end{gathered}", "\\end{array}")
    try:
        out = convert(tex, display="block" if display else "inline")
    except Exception:         # a construct it does not know: that formula as readable characters
        return None
    return None if "<mi>&</mi>" in out or "<mo>&</mo>" in out else out


_BULLET = re.compile(r"^\s*[-*•]\s+")


def _inline_html(text):
    """one line: text escaped, **bold** (also around formulas), every formula as MathML"""
    maths, out = [], []
    for kind, content in _split(text):
        if kind == "text":
            out.append(_html.escape(content))
        else:
            m = _mathml(content, display=False)
            maths.append(m if m else _html.escape(latex_to_text(content)))
            out.append(f"\x00{len(maths) - 1}\x00")
    line = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", "".join(out))
    return re.sub(r"\x00(\d+)\x00", lambda m: maths[int(m.group(1))], line)


def html(md):
    """Paragraphs, headings, lists and bold, every formula as MathML (display ones on their own)."""
    blocks = []
    # display formulas become blocks of their own, wherever they stood
    pieces = re.split(r"(\$\$.+?\$\$)", md, flags=re.S)
    for piece in pieces:
        if piece.startswith("$$") and piece.endswith("$$") and len(piece) > 4:
            tex = piece[2:-2].strip()
            m = _mathml(tex, display=True)
            blocks.append(m if m else f'<p class="MsoNormal">{_html.escape(latex_to_text(tex))}</p>')
            continue
        for para in re.split(r"\n\s*\n", piece):
            lines = [l for l in para.strip("\n").split("\n") if l.strip()]
            run, bullets = [], None
            for line in lines + [None]:            # None closes the last run
                is_bullet = line is not None and bool(_BULLET.match(line))
                if run and (line is None or is_bullet != bullets):
                    if bullets:
                        blocks.append("<ul>" + "".join('<li class="MsoNormal">' + _inline_html(_BULLET.sub("", l)) + "</li>"
                                                        for l in run) + "</ul>")
                    elif len(run) == 1 and re.match(r"#{1,6}\s+", run[0]):
                        h = re.match(r"(#{1,6})\s+(.*)", run[0])
                        level = min(len(h.group(1)) + 1, 4)
                        blocks.append(f"<h{level}>{_inline_html(h.group(2))}</h{level}>")
                    else:
                        blocks.append('<p class="MsoNormal">' + "<br>".join(_inline_html(l) for l in run) + "</p>")
                    run = []
                if line is not None:
                    run.append(line)
                    bullets = is_bullet
    body = "".join(blocks)
    # paragraphs as Word's own "Normal" style: the text takes the document's font (without it Word
    # set pasted HTML in Times New Roman, 05.10. Nils; a fixed font ignored the document; tested)
    return f'<html><head><meta charset="utf-8"></head><body>{body}</body></html>'


def renditions(answer):
    """The three versions of one model answer (see the module comment)."""
    md = markdown(answer)
    return {"markdown": md, "plain": plain(md), "html": html(md)}
