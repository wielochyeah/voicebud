"""Screen context with a fake Accessibility layer: privacy gate (fail closed), caret slices,
names, register, cursor fit, prompt material and its guard. No real app is read."""
import unittest
from unittest import mock

import _util  # noqa: F401
import context
import guards
from dictionary import correct_names
from structure import fit_to_cursor

APP = {"pid": 42, "name": "Mail", "bundle": "com.apple.mail", "path": ""}


class FakeAX:
    """Elements are strings; attrs maps (element, attribute) -> value or error code (int < 0)."""

    def __init__(self, attrs, text="", trusted=True):
        self.attrs, self.text, self._trusted = attrs, text, trusted

    def trusted(self):
        return self._trusted

    def set_timeout(self, s):
        pass

    def app(self, pid):
        return "app"

    def get(self, el, attr):
        v = self.attrs.get((el, attr), -25212)
        return (v, None) if isinstance(v, int) and v < 0 else (0, v)

    def multi(self, el, attrs):
        if (el, "multi") in self.attrs:
            return self.attrs[(el, "multi")], {}
        return 0, {a: self.get(el, a)[1] for a in attrs}

    def range_of(self, v):
        return v

    def string_for_range(self, el, loc, length):
        if (el, "AXStringForRange") in self.attrs:
            return self.attrs[(el, "AXStringForRange")], None
        return 0, self.text[loc:loc + length]

    def set_bool(self, el, attr, value):
        return 0


def field(text, caret, subrole="", extra=None):
    attrs = {("app", "AXFocusedWindow"): "win", ("win", "AXTitle"): "Antwort an Frau Szymańska",
             ("app", "AXFocusedUIElement"): "field", ("field", "AXRole"): "AXTextArea",
             ("field", "AXSubrole"): subrole, ("field", "AXNumberOfCharacters"): len(text),
             ("field", "AXSelectedTextRange"): (caret, 0)}
    attrs.update(extra or {})
    return FakeAX(attrs, text)


class CaptureTest(unittest.TestCase):
    def run_capture(self, fake, level=context.CURSOR, app=APP, secure=False, per_app=None):
        with mock.patch.object(context, "_ax", fake), \
                mock.patch.object(context, "secure_input_active", return_value=secure):
            return context.capture(level, (), per_app, app=dict(app))

    def test_caret_slices(self):
        text = "Hallo Frau Szymańska, vielen Dank für Ihre Nachricht. " + "x" * 10 + " Grüße"
        snap = self.run_capture(field(text, 54))
        self.assertIsNone(snap.withheld)
        self.assertEqual(snap.before, text[:54])
        self.assertEqual(snap.after, text[54:])
        self.assertEqual(snap.title, "Antwort an Frau Szymańska")
        self.assertEqual(snap.via, "range")

    def test_trimmed_at_word_boundaries(self):
        text = ("wort " * 200) + "|" + (" ende" * 200)
        snap = self.run_capture(field(text, 1000))
        self.assertLessEqual(len(snap.before), context.MAX_BEFORE)
        self.assertTrue(snap.before.startswith("wort"))
        self.assertLessEqual(len(snap.after), context.MAX_AFTER)
        self.assertFalse(snap.after.endswith(" en"))

    def test_value_fallback_when_no_string_for_range(self):
        fake = field("Hallo Welt", 5, extra={("field", "AXStringForRange"): -25205, ("field", "AXValue"): "Hallo Welt"})
        snap = self.run_capture(fake)
        self.assertEqual((snap.before, snap.after, snap.via), ("Hallo", " Welt", "value"))

    def test_fail_closed(self):
        # no field text on any error; the app and window title still count (reading a mail
        # with the list in focus is the normal case, not a failure)
        cases = {
            "focus error": ({("app", "AXFocusedUIElement"): -25204}, "no_focus"),
            "attrs error": ({("field", "multi"): -25211}, "ax_error"),
            "no caret": ({("field", "AXSelectedTextRange"): None}, "no_caret"),
            "range and value fail": ({("field", "AXStringForRange"): -25205}, "no_text"),
        }
        for name, (extra, reason) in cases.items():
            with self.subTest(name):
                snap = self.run_capture(field("geheim", 3, extra=extra))
                self.assertEqual((snap.withheld, snap.missing), (None, reason))
                self.assertFalse(snap.has_text)
                self.assertEqual(snap.title, "Antwort an Frau Szymańska")

    def test_hard_rules(self):
        self.assertEqual(self.run_capture(field("pw", 1, subrole="AXSecureTextField")).withheld, "secure_field")
        snap = self.run_capture(field("geheim", 3), secure=True)
        self.assertEqual(snap.withheld, "secure_input")
        self.assertFalse(snap.has_text)
        for bundle in ("com.1password.1password", "com.apple.keychainaccess", "local.voicebud"):
            snap = self.run_capture(field("geheim", 3), app={**APP, "bundle": bundle})
            self.assertEqual(snap.withheld, "excluded")
        fake = field("geheim", 3, extra={("win", "AXTitle"): "Neuer Tab — Privater Modus"})
        snap = self.run_capture(fake, app={**APP, "bundle": "org.mozilla.firefox"})
        self.assertEqual((snap.withheld, snap.title, snap.has_text), ("private_window", "", False))
        self.assertEqual(self.run_capture(FakeAX({}, "", trusted=False)).withheld, "no_permission")

    def test_levels(self):
        snap = self.run_capture(field("Text", 2), level=context.APP)
        self.assertEqual((snap.title != "", snap.has_text), (True, False))
        self.assertEqual(self.run_capture(field("Text", 2), level=context.OFF).withheld, "off")
        snap = self.run_capture(field("Text", 2), per_app={"COM.APPLE.MAIL": 0})
        self.assertEqual(snap.withheld, "off")
        slack = {**APP, "bundle": "com.tinyspeck.slackmacgap"}
        self.assertEqual(context.effective_level(context.CURSOR, slack)[0], context.WINDOW)
        self.assertEqual(context.effective_level(context.APP, slack)[0], context.APP)       # never above the base
        self.assertEqual(context.effective_level(context.CURSOR, slack, {"com.tinyspeck.slackmacgap": 2})[0], context.CURSOR)
        self.assertEqual(context.effective_level(context.CURSOR, APP)[0], context.CURSOR)    # Mail stays
        safari = {**APP, "bundle": "com.apple.Safari"}
        self.assertEqual(context.effective_level(context.WINDOW, safari)[0], context.CURSOR)

    def test_placeholder_is_no_content(self):
        fake = field("Nachricht schreiben", 0, extra={("field", "AXPlaceholderValue"): "Nachricht schreiben"})
        self.assertFalse(self.run_capture(fake).has_text)

    def test_redacted_has_no_text(self):
        snap = self.run_capture(field("Hallo Frau Szymańska", 5))
        flat = str(snap.redacted())
        self.assertNotIn("Szyma", flat)
        self.assertNotIn("Hallo", flat)


class UseTest(unittest.TestCase):
    def snap(self, **kw):
        s = context.Snapshot(APP, context.CURSOR)
        for k, v in kw.items():
            setattr(s, k, v)
        return s

    def test_names(self):
        s = self.snap(title="Re: Angebot", header="Kowalczyk, Anna", before="Hallo Frau Becker, wie besprochen ")
        names = context.names_from(s, is_word=lambda w: w in {"Angebot", "Hallo", "Frau", "Anna", "Becker"})
        self.assertIn("Kowalczyk", names)
        self.assertIn("Becker", names)        # an ordinary-looking word after a cue
        self.assertNotIn("Angebot", names)

    def test_correct_names(self):
        text, fixes = correct_names("Hallo Frau Schimanska, danke.", ["Szymańska"])
        self.assertEqual(text, "Hallo Frau Szymańska, danke.")
        self.assertEqual(fixes, [("Schimanska", "Szymańska")])
        self.assertEqual(correct_names("Wir gehen zum Bäcker.", ["Becker"])[0], "Wir gehen zum Bäcker.")
        # two names with the same sound: no guess
        self.assertEqual(correct_names("Hallo Maier", ["Meyer", "Mayer"])[1], [])

    def test_register(self):
        self.assertEqual(context.register_of(self.snap(before="vielen Dank für Ihre Mail, ich melde mich bei Ihnen")), "Sie")
        self.assertEqual(context.register_of(self.snap(before="hast du kurz Zeit? ich schick dir")), "du")
        self.assertIsNone(context.register_of(self.snap(before="Die Zahlen sind fertig.")))

    def test_fit_to_cursor(self):
        self.assertEqual(fit_to_cursor("Und dann schicke ich es.", "Wir prüfen das", " und melden uns."),
                         " und dann schicke ich es")
        self.assertEqual(fit_to_cursor("Budget ist frei.", "Das", ""), " Budget ist frei.")
        self.assertEqual(fit_to_cursor("Danke.", "Hallo Anna,\n\n", ""), "Danke.")
        self.assertEqual(fit_to_cursor("Sie bekommen es morgen.", "und", ""), " Sie bekommen es morgen.")

    def test_material(self):
        import main
        vb = mock.Mock(settings={"contextApps": {}})
        sel = self.snap(selected="Bitte bis Freitag die Zahlen.", app="Mail", title="Zahlen")
        self.assertEqual(main.VoiceBud._material(vb, sel, "mach das kürzer"),
                         ("Markierter Text aus Mail („Zahlen“)", "Bitte bis Freitag die Zahlen."))
        none = self.snap(app="Mail")
        self.assertIsNone(main.VoiceBud._material(vb, none, "schreib eine Mail an den Vermieter"))
        win = self.snap(app="Mail", window="Von Anna: Treffen am Freitag?")
        self.assertEqual(main.VoiceBud._material(vb, win, "fass diese Mail zusammen")[1],
                         "Von Anna: Treffen am Freitag?")
        safari = self.snap(app="Safari", bundle="com.apple.Safari", before="mein Entwurf")
        with mock.patch.object(context, "window_text", side_effect=AssertionError("must not read")):
            self.assertEqual(main.VoiceBud._material(vb, safari, "fass diese Seite zusammen")[1], "mein Entwurf")

    def test_prompt_guard(self):
        p = "Aufgabe: Plan über 12 Wochen.\n- Halbmarathon (21,0975 km)\n- Mindestens 5 Läufe pro Woche.\n- Quelle: https://x.y"
        out = guards.drop_unsupported(p, "plan für zwölf wochen", "")
        self.assertEqual(out, "Aufgabe: Plan über 12 Wochen.\n- Halbmarathon")
        self.assertEqual(guards.drop_unsupported("Frist: 3. Oktober", "bis zum dritten Oktober"), "Frist: 3. Oktober")


if __name__ == "__main__":
    unittest.main()
