import unittest

import _util  # noqa: F401
import guards
from guards import restore_substitutions as restore

TERMS = ["AI-Slop", "shadcn", "FS-SC"]


class RestoreSubstitutionsTest(unittest.TestCase):
    def check(self, raw, cleaned, expected, terms=TERMS):
        self.assertEqual(restore(raw, cleaned, terms=terms), expected)

    # --- the three failure classes from the task ---
    def test_typo_is_reverted(self):
        self.check("Trotzdem sollten wir halt nochmal über die Details reden.",
                   "Trotdem sollten wir nochmal über die Details reden.",
                   "Trotzdem sollten wir nochmal über die Details reden.")

    def test_rewording_wollte_moechte(self):
        self.check("Also ich wollte nochmal kurz über das Projekt sprechen.",
                   "Ich möchte nochmal kurz über das Projekt sprechen.",
                   "Ich wollte nochmal kurz über das Projekt sprechen.")

    def test_rewording_ungefaehr_etwa(self):
        self.check("Ungefähr 70% der Teilnehmer sind zufrieden.",
                   "Etwa 70 Prozent der Teilnehmer sind zufrieden.",
                   "Ungefähr 70% der Teilnehmer sind zufrieden.")

    # --- allowed edits stay ---
    def test_fillers_punctuation_capitalisation(self):
        self.check("ähm also ich glaube das ist halt so ne gute Idee",
                   "Ich glaube, das ist so ne gute Idee.",
                   "Ich glaube, das ist so ne gute Idee.")

    def test_repeated_words(self):
        self.check("das das wäre ganz cool ja", "Das wäre ganz cool.", "Das wäre ganz cool.")

    def test_self_repetition_of_a_phrase(self):
        raw = "das wäre eigentlich ganz cool genau also das das wäre ganz cool ja und schau auch mal"
        self.check(raw, "Das wäre eigentlich ganz cool. Schau auch.", "Das wäre eigentlich ganz cool. Schau auch.")

    def test_number_formatting(self):
        self.check("ähm siebzig Prozent sind zufrieden", "70 % sind zufrieden.", "70 % sind zufrieden.")
        self.check("Ungefähr 70% der Leute", "Ungefähr 70 Prozent der Leute", "Ungefähr 70 Prozent der Leute")
        self.check("wir treffen uns um vierzehn Uhr dreißig am dritten Oktober",
                   "Wir treffen uns um 14:30 Uhr am 3. Oktober.",
                   "Wir treffen uns um 14:30 Uhr am 3. Oktober.")
        self.check("das kostet zwei tausend Euro", "Das kostet 2.000 €.", "Das kostet 2.000 €.")
        self.check("zwei Komma fünf Millionen", "2,5 Millionen", "2,5 Millionen")

    def test_lists_and_line_breaks(self):
        self.check("erstens Milch zweitens Brot drittens Eier", "1. Milch\n2. Brot\n3. Eier",
                   "1. Milch\n2. Brot\n3. Eier")
        self.check("wir brauchen Milch Brot und Eier", "Wir brauchen:\n- Milch\n- Brot\n- Eier",
                   "Wir brauchen:\n- Milch\n- Brot\n- Eier")

    def test_compound_and_dictionary_spelling(self):
        self.check("die To Do Liste ist fertig", "Die To-do-Liste ist fertig.", "Die To-do-Liste ist fertig.")
        self.check("wir nehmen nur Schatz CN Komponenten", "Wir nehmen nur shadcn-Komponenten.",
                   "Wir nehmen nur shadcn-Komponenten.")

    def test_das_dass(self):
        self.check("ich glaube das das klappt", "Ich glaube, dass das klappt.", "Ich glaube, dass das klappt.")

    # --- other changes are put back ---
    def test_dropped_content_word_is_reinserted(self):
        self.check("Ich schicke dir das noch heute, und dann deployen wir am Freitag.",
                   "Ich schicke dir das noch heute und deployen wir am Freitag.",
                   "Ich schicke dir das noch heute und dann deployen wir am Freitag.")
        # "und" may go where the LLM starts a sentence; "immer" may not
        self.check("und achte immer darauf", "Achte darauf.", "Achte immer darauf.")

    def test_parallel_structure_is_not_compressed(self):
        self.check("und schau auch mal dass du geile Slides machst dass du ein Excel-Sheet machst",
                   "Schau auch, dass du geile Slides machst, ein Excel-Sheet machst.",
                   "Schau auch, dass du geile Slides machst, dass du ein Excel-Sheet machst.")

    def test_reordering_is_reverted(self):
        self.check("Und das halt für in dem FS-SC-Design nur. Dafür schau dir alles an.",
                   "Und das nur für das FS-SC-Design. Dafür schau dir alles an.",
                   "Und das für in dem FS-SC-Design nur. Dafür schau dir alles an.")
        self.check("Schau logischerweise, dass du nur shadcn-Komponenten nimmst, nichts anderes.",
                   "Nimm nur shadcn-Komponenten, nichts anderes.",
                   "Schau logischerweise, dass du nur shadcn-Komponenten nimmst, nichts anderes.")

    def test_invented_words_are_dropped(self):
        self.check("das ist halt gut", "Das ist sehr gut.", "Das ist gut.")
        self.check("Und zwar wäre es halt ganz cool, wenn wir in dem Repo schauen",
                   "Es wäre ganz cool, wenn wir im Repo schauen",
                   "Und zwar wäre es ganz cool, wenn wir in dem Repo schauen")

    def test_unchanged_and_english(self):
        s = "Let's move the deadline to next Wednesday because the client hasn't sent the files yet."
        self.check("Let's move the deadline to next Wednesday, because the client hasn't sent the files yet.", s, s)
        self.check("um so I think we should like ship it", "I think we should ship it.", "I think we should ship it.")

    def test_stats(self):
        stats = {}
        restore("Also ich wollte das", "Ich möchte das.", stats=stats)
        self.assertEqual(stats["reverted"], 1)


    def test_llm_may_respell_a_term_but_not_swap_one_in(self):
        terms = ["AI-Slop", "shadcn", "FS-SC", "Repo", "Slides", "Deadline", "Feedback"]
        self.check("kein AI-Slog drin", "kein AI-Slop drin", "kein AI-Slop drin", terms=terms)
        for raw, llm in [("wir müssen das Projekt fertig machen", "wir müssen das Repo fertig machen"),
                         ("die Folien sind fertig", "die Slides sind fertig"),
                         ("Die Frist ist morgen", "Die Deadline ist morgen"),
                         ("Die Rückmeldung kam spät", "Das Feedback kam spät")]:
            with self.subTest(raw=raw):
                self.assertEqual(restore(raw, llm, terms=terms), raw)

    # --- structuring (LLM eval 2026-10-03): the guard must keep these edits ---
    def test_self_correction(self):
        self.check("Der Termin ist am Dienstag, nein, sorry, am Mittwoch um zehn.",
                   "Der Termin ist am Mittwoch um 10.", "Der Termin ist am Mittwoch um 10.")
        self.check("Wir brauchen fünf, äh, ich meine sechs Stühle.", "Wir brauchen sechs Stühle.",
                   "Wir brauchen sechs Stühle.")
        self.check("Um, so I think we should, uh, move the meeting to Thursday, no, I mean Friday.",
                   "I think we should move the meeting to Friday.",
                   "I think we should move the meeting to Friday.")

    def test_no_correction_without_taken_back_words(self):
        # nothing before the cue: "Nein, ich meine" is the content, not a correction
        self.check("Nein, ich meine das ernst, das Projekt ist wichtig.",
                   "Das ernst, das Projekt ist wichtig.",
                   "Nein, ich meine das ernst, das Projekt ist wichtig.")
        # too much taken back for one correction: the content comes back
        self.check("Wir fahren morgen früh mit dem Zug nach Hamburg, nein, Berlin.",
                   "Berlin.",
                   "Wir fahren morgen früh mit dem Zug nach Hamburg, nein, Berlin.")
        # a cue word with no repair after it
        self.check("Das ist teuer, nein", "Das ist teuer", "Das ist teuer, nein")

    def test_list_conjunction_and_enumerators(self):
        self.check("Für morgen brauche ich erstens die Folien, zweitens das Budget und drittens die Teilnehmerliste.",
                   "Für morgen brauche ich:\n1. die Folien\n2. das Budget\n3. die Teilnehmerliste",
                   "Für morgen brauche ich:\n1. die Folien\n2. das Budget\n3. die Teilnehmerliste")
        self.check("We need three things: first the slides, second the budget, and third the guest list.",
                   "We need three things:\n1. The slides\n2. The budget\n3. The guest list",
                   "We need three things:\n1. The slides\n2. The budget\n3. The guest list")
        # outside a list item "second" is a word like any other
        self.check("wait a second please", "Wait please.", "Wait a second please.")

    def test_spoken_layout_survives(self):
        self.check("Hallo zusammen,\n\nanbei die Zahlen.", "Hallo zusammen, anbei die Zahlen.",
                   "Hallo zusammen,\n\nanbei die Zahlen.")
        self.check("Einkaufen\nWäsche waschen", "Einkaufen Wäsche waschen", "Einkaufen\nWäsche waschen")
        # a list marker the LLM put in front keeps its own line
        self.check("erstens Milch\nzweitens Brot", "1. Milch\n2. Brot", "1. Milch\n2. Brot")

    def test_review_regressions(self):
        # the repair after the cue stays, even when the LLM wrote it as digits
        self.check("Der Termin ist um zehn, nein, um elf Uhr.", "Der Termin ist um 11 Uhr.", "Der Termin ist um 11 Uhr.")
        self.check("Das Angebot liegt bei zwölftausend, Korrektur, bei vierzehntausendfünfhundert Euro netto.",
                   "Das Angebot liegt bei 14.500 Euro netto.", "Das Angebot liegt bei 14.500 Euro netto.")
        # chained corrections
        self.check("Schick die Rechnung an Herrn Weber, nein, an Frau Weber, also nein, eigentlich an die Buchhaltung.",
                   "Schick die Rechnung an die Buchhaltung.", "Schick die Rechnung an die Buchhaltung.")
        # German amounts and dates never crash the guard
        self.check("Es kostet eintausendzweihundertfünfzig Euro fünfzig.", "Es kostet 1.250,50 €.", "Es kostet 1.250,50 €.")
        self.assertIsInstance(restore("am ersten zwölften", "am 1.12.2026"), str)
        # a repeated number is content, not a stutter
        self.check("um drei, nicht um vier", "um 3, nicht um 4", "um 3, nicht um 4")
        # "Punkt eins" before a list item, spoken "Punkt" where the LLM put the period
        self.check("Drei Sachen. Punkt eins, die Folien. Punkt zwei, der Raum.",
                   "Drei Sachen:\n1. Die Folien.\n2. Der Raum.", "Drei Sachen:\n1. Die Folien.\n2. Der Raum.")
        self.check("Das Budget ist freigegeben Punkt wir starten am Montag Punkt",
                   "Das Budget ist freigegeben. Wir starten am Montag.", "Das Budget ist freigegeben. Wir starten am Montag.")
        # "Punkt" as a word stays
        self.check("Das ist ein wichtiger Punkt für uns", "Das ist ein wichtiger für uns.", "Das ist ein wichtiger Punkt für uns.")

    def test_fuzz_never_crashes_or_invents(self):
        """Random LLM damage (drops, inserts, swaps, list markers): the result may only contain
        words from the raw text or the LLM output, and restoring never raises."""
        import random
        from test_dictionary import BENCH_SENTENCES, NILS_RAW, NORMAL_GERMAN
        rnd = random.Random(1)
        texts = [NILS_RAW] + BENCH_SENTENCES + NORMAL_GERMAN
        vocab = "der die das und möchte etwa sehr 70 % - • 1. \n Prozent ja also halt nicht".split(" ")
        for _ in range(1500):
            raw = rnd.choice(texts)
            out = raw.split()
            for _ in range(rnd.randint(0, 12)):
                op, i = rnd.random(), rnd.randrange(len(out)) if out else 0
                if op < 0.3 and out:
                    del out[i]
                elif op < 0.6:
                    out.insert(i, rnd.choice(vocab))
                elif op < 0.8 and out:
                    out[i] = rnd.choice(vocab)
                elif out:
                    j = rnd.randrange(len(out))
                    out[i], out[j] = out[j], out[i]
            cleaned = " ".join(out)
            res = restore(raw, cleaned, terms=TERMS)
            known = {t.norm for t in guards._tokens(raw)} | {t.norm for t in guards._tokens(cleaned)}
            self.assertEqual([t.text for t in guards._tokens(res) if t.norm and t.norm not in known], [],
                             msg=f"{cleaned!r} -> {res!r}")


class OtherGuardsTest(unittest.TestCase):
    def test_dates_numbers_addresses_survive(self):
        # Challenge 04.10.: the date was deleted ("Bis zum. Brauche ich das."), the rest reverted
        ok = [("Bis zum fünften elften brauche ich das", "Bis zum 5.11. brauche ich das."),
              ("Die Abgabe ist am zwölften dritten", "Die Abgabe ist am 12.3."),
              ("Das kostet zwölfhundertfünfzig Euro", "Das kostet 1.250 €."),
              ("Das war neunzehnhundertneunundachtzig", "Das war 1989."),
              ("Im Jahr zwanzig sechsundzwanzig", "Im Jahr 2026."),
              ("Am ersten zwölften zwanzig sechsundzwanzig", "Am 1.12.2026."),
              ("Schreib an nils at alvantiq punkt com", "Schreib an nils@alvantiq.com."),
              ("Das Budget sind zwei Komma fünf Millionen Euro", "Das Budget sind 2,5 Mio. €.")]
        for raw, llm in ok:
            self.assertEqual(guards.restore_substitutions(raw, llm), llm, raw)
        # a wrong number still goes back to what was said
        self.assertEqual(guards.restore_substitutions("Bis zum fünften elften", "Bis zum 6.11."),
                         "Bis zum fünften elften.")

    def test_drop_cut_repeat_keeps_parallel_sentences(self):
        t = ("Bitte schick mir bis morgen die Unterlagen für den Kunden Meier. "
             "Bitte schick mir bis morgen die Unterlagen für den Kunden Schulz.")
        self.assertEqual(guards.drop_cut_repeat(t), t)

    def test_drop_cut_repeat(self):
        # de.wav cut at 15.16 s: Whisper closed the take with sentence 2 again
        said = ("Wir haben jetzt die ersten Ergebnisse aus der Umfrage und die sehen eigentlich ganz gut "
                "aus. Ungefähr 70% der Teilnehmer sind zufrieden mit dem neuen Prozess.")
        self.assertEqual(guards.drop_cut_repeat(
            said + " Trotzdem sollten wir die ersten Ergebnisse aus der Umfrage und die sehen eigentlich "
                   "ganz gut aus."), said)
        for text in [said,
                     said + " Trotzdem sind die Teilnehmer in der Umfrage.",          # new words stay
                     "Bitte bis Freitag die Zahlen schicken. Ich wiederhole: bitte bis Freitag die "
                     "Zahlen schicken.",                                                # short repeat stays
                     "Das ist gut das ist gut."]:
            self.assertEqual(guards.drop_cut_repeat(text), text)

    def test_collapse_repeats(self):
        self.assertEqual(guards.collapse_repeats("ja ja ja ja ja genau"), "ja genau")
        self.assertEqual(guards.collapse_repeats("das ist gut das ist gut das ist gut das ist gut das"),
                         "das ist gut")
        self.assertEqual(guards.collapse_repeats("das das wäre"), "das das wäre")  # real speech
        self.assertEqual(guards.collapse_repeats("Rolle: Coach\n\nAufgabe: Plan\n- eins\n- zwei"),
                         "Rolle: Coach\n\nAufgabe: Plan\n- eins\n- zwei")
        self.assertEqual(guards.collapse_repeats("Hallo,\n\nja ja ja ja gut"), "Hallo,\n\nja gut")

    def test_llm_output_keeps_layout(self):
        src = "Hallo Frau Becker vielen Dank für Ihre schnelle Rückmeldung Viele Grüße Nils"
        out = "Hallo Frau Becker,\n\nvielen Dank für Ihre schnelle Rückmeldung.\n\nViele Grüße,\nNils"
        self.assertEqual(guards.clean_llm_output(out, src), out)

    def test_hallucination(self):
        self.assertTrue(guards.is_hallucination("Untertitel im Auftrag des ZDF", 1.0, 0.1))
        self.assertTrue(guards.is_hallucination("Thank you.", 0.2, 0.1))
        self.assertTrue(guards.is_hallucination("Vielen Dank.", 2.0, 0.8))
        self.assertFalse(guards.is_hallucination("Thank you so much.", 1.5, 0.1))
        self.assertFalse(guards.is_hallucination("Danke.", 0.8, 0.1))

    def test_llm_output_checks(self):
        src = "also das meeting ist morgen um zehn"
        self.assertEqual(guards.clean_llm_output("Hier ist der bereinigte Text: Das Meeting ist morgen um zehn.", src),
                         "Das Meeting ist morgen um zehn.")
        self.assertIsNone(guards.clean_llm_output("Kopiere den folgenden Text exakt", src))
        self.assertIsNone(guards.clean_llm_output("Bekannte Begriffe (Schreibweise übernehmen): AI-Slop", src))
        self.assertIsNone(guards.clean_llm_output("ok", src))  # far too short

    def test_strip_hums(self):
        self.assertEqual(guards.strip_hums("Also M, ich wollte und M, die sehen"), "Also ich wollte und die sehen")
        self.assertEqual(guards.strip_hums("Mh, ich weiß nicht."), "Ich weiß nicht.")
        self.assertEqual(guards.strip_hums("Ich brauche Größe M."), "Ich brauche Größe M.")

    def test_number_words(self):
        for word, value in [("siebzig", 70), ("einundzwanzig", 21), ("zweitausenddreihundert", 2300),
                            ("hundertfünf", 105), ("dritten", 3), ("zwanzigste", 20), ("twenty-one", 21),
                            ("third", 3), ("Prozent", None), ("Acht", 8), ("Haus", None)]:
            with self.subTest(word=word):
                self.assertEqual(guards.number_value(word), value)


if __name__ == "__main__":
    unittest.main()
