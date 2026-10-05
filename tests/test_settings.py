"""settings.load: defaults and installs from before a setting existed."""
import json
import os
import tempfile
import unittest

import _util  # noqa: F401  (temp data dir)

import settings


class LanguageDefaultsTest(unittest.TestCase):
    """05.10.: new installs get English texts and automatic dictation (chosen in the first setup
    step); an install from before keeps German texts and automatic dictation."""

    def load(self, data):
        d = tempfile.mkdtemp(prefix="vb-settings-")
        with open(os.path.join(d, "settings.json"), "w", encoding="utf-8") as f:
            json.dump(data, f)
        old = os.environ.get("VOICEBUD_DATA_DIR")
        os.environ["VOICEBUD_DATA_DIR"] = d
        try:
            return settings.load()
        finally:
            if old is None:
                os.environ.pop("VOICEBUD_DATA_DIR", None)
            else:
                os.environ["VOICEBUD_DATA_DIR"] = old

    def test_new_install(self):
        s = self.load({})
        self.assertEqual((s["uiLanguage"], s["dictationLanguage"]), ("system", "auto"))

    def test_install_from_before_keeps_its_languages(self):
        s = self.load({"onboardingDone": True, "liveText": False})
        self.assertEqual((s["uiLanguage"], s["dictationLanguage"]), ("de", "auto"))

    def test_chosen_values_win(self):
        s = self.load({"onboardingDone": True, "uiLanguage": "en", "dictationLanguage": "en"})
        self.assertEqual((s["uiLanguage"], s["dictationLanguage"]), ("en", "en"))


if __name__ == "__main__":
    unittest.main()
