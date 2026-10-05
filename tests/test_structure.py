import unittest

import _util  # noqa: F401
from structure import apply_commands, style_for, tidy


class CommandsTest(unittest.TestCase):
    def test_layout_commands(self):
        self.assertEqual(apply_commands("Hallo zusammen, neuer Absatz, anbei die Zahlen für das dritte Quartal."),
                         "Hallo zusammen,\n\nanbei die Zahlen für das dritte Quartal.")
        self.assertEqual(apply_commands("Einkaufen neue Zeile Wäsche waschen neue Zeile Steuer machen"),
                         "Einkaufen\nWäsche waschen\nSteuer machen")
        self.assertEqual(apply_commands("Das Budget ist freigegeben. Neuer Absatz. Zur Messe: wir planen."),
                         "Das Budget ist freigegeben.\n\nZur Messe: wir planen.")
        # a salutation with more after it is no salutation line: the sentence ends
        self.assertEqual(apply_commands("Hallo Frau Becker, vielen Dank, neuer Absatz, ich schicke es morgen."),
                         "Hallo Frau Becker, vielen Dank.\n\nIch schicke es morgen.")

    def test_punctuation_commands(self):
        self.assertEqual(apply_commands("Hast du die Datei bekommen Fragezeichen"), "Hast du die Datei bekommen?")
        self.assertEqual(apply_commands("Hast du die Datei bekommen, Fragezeichen. Ich warte."),
                         "Hast du die Datei bekommen? Ich warte.")
        self.assertEqual(apply_commands("Super gemacht Ausrufezeichen"), "Super gemacht!")
        self.assertEqual(apply_commands("Wir brauchen Doppelpunkt Milch, Brot und Eier."),
                         "Wir brauchen: Milch, Brot und Eier.")
        self.assertEqual(apply_commands("Did you get it question mark", "en"), "Did you get it?")

    def test_nouns_stay(self):
        for s in ["Da steht ein Fragezeichen hinter dem Projekt.",
                  "Das ist ein neuer Absatz im Gesetz.",
                  "Fragezeichen setzen wir später.",
                  "Da setzen wir Fragezeichen hin.",
                  "Die neue Zeile im Vertrag ist falsch.",
                  "Ich schreibe einen neuen Absatz.",
                  "Die Doppelpunkte fehlen."]:
            with self.subTest(s=s):
                self.assertEqual(apply_commands(s), s)


class TidyTest(unittest.TestCase):
    def test_tidy(self):
        self.assertEqual(tidy("Das Meeting ist um 09:15 Uhr."), "Das Meeting ist um 9:15 Uhr.")
        self.assertEqual(tidy("Das sind 7,0 % mehr."), "Das sind 7 % mehr.")
        self.assertEqual(tidy("Das sind 7,05 % mehr."), "Das sind 7,05 % mehr.")
        self.assertEqual(tidy("Hallo,  \nvielen Dank\n\n\n\nGrüße"), "Hallo,\nvielen Dank\n\nGrüße")
        self.assertEqual(tidy("Zimmer 09:15"), "Zimmer 09:15")


class StyleTest(unittest.TestCase):
    def test_style_for(self):
        self.assertEqual(style_for("com.apple.mail"), "mail")
        self.assertEqual(style_for("com.microsoft.Outlook"), "mail")
        self.assertEqual(style_for("net.whatsapp.WhatsApp"), "chat")
        self.assertEqual(style_for("com.anthropic.claudefordesktop"), "doc")
        self.assertEqual(style_for(None), "doc")
        self.assertEqual(style_for("com.apple.mail", {"com.apple.mail": "doc"}), "doc")
        self.assertEqual(style_for("com.apple.mail", {"com.apple.mail": "quatsch"}), "mail")


if __name__ == "__main__":
    unittest.main()
