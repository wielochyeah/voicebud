import re
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import _util  # noqa: F401
import oscheck


def macho(minos=None, platform=oscheck.PLATFORM_MACOS, magic=oscheck.MH_MAGIC_64):
    """A minimal 64-bit Mach-O header: an unrelated load command, then LC_BUILD_VERSION."""
    cmds = struct.pack("<2I16x", 0x1B, 24)                       # LC_UUID, 24 bytes
    if minos is not None:
        packed = (minos[0] << 16) | (minos[1] << 8) | minos[2]
        cmds += struct.pack("<6I", oscheck.LC_BUILD_VERSION, 24, platform, packed, 0, 0)
    ncmds = 2 if minos is not None else 1
    return struct.pack("<8I", magic, 0x0100000C, 0, 6, ncmds, len(cmds), 0, 0) + cmds


class VersionTest(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(oscheck.parse_version("26.2"), (26, 2, 0))
        self.assertEqual(oscheck.parse_version("15.7.1"), (15, 7, 1))
        self.assertEqual(oscheck.parse_version("26"), (26, 0, 0))
        self.assertIsNone(oscheck.parse_version(""))
        self.assertIsNone(oscheck.parse_version(None))
        self.assertIsNone(oscheck.parse_version("beta"))

    def test_text(self):
        self.assertEqual(oscheck.version_text((26, 2, 0)), "26.2")
        self.assertEqual(oscheck.version_text((15, 7, 1)), "15.7.1")

    def test_running_is_real(self):
        v = oscheck.running_macos()
        self.assertIsNotNone(v)
        self.assertGreaterEqual(v, (11, 0, 0))     # never the 10.16 compatibility answer


class RequiredMacOSTest(unittest.TestCase):
    def write(self, data):
        f = tempfile.NamedTemporaryFile(delete=False, suffix=".dylib")
        f.write(data)
        f.close()
        self.addCleanup(Path(f.name).unlink)
        return f.name

    def test_reads_minos(self):
        self.assertEqual(oscheck.required_macos(self.write(macho((26, 2, 0)))), (26, 2, 0))
        self.assertEqual(oscheck.required_macos(self.write(macho((15, 0, 0)))), (15, 0, 0))

    def test_unreadable_is_none(self):
        self.assertIsNone(oscheck.required_macos(self.write(macho(None))))          # no build version
        self.assertIsNone(oscheck.required_macos(self.write(macho((26, 2, 0), platform=2))))  # iOS
        self.assertIsNone(oscheck.required_macos(self.write(macho((26, 2, 0), magic=0xCAFEBABE))))
        self.assertIsNone(oscheck.required_macos(self.write(b"\xcf\xfa\xed\xfe")))   # cut off
        self.assertIsNone(oscheck.required_macos("/nonexistent/libmlx.dylib"))

    def test_bundled_mlx_matches_otool(self):
        lib = oscheck.mlx_library()
        if lib is None:
            self.skipTest("no MLX installed")
        out = subprocess.run(["otool", "-l", str(lib)], capture_output=True, text=True).stdout
        minos = re.search(r"cmd LC_BUILD_VERSION\n.*\n\s*platform 1\n\s*minos (\S+)", out)
        if minos is None:
            self.skipTest("otool unavailable")
        self.assertEqual(oscheck.required_macos(lib), oscheck.parse_version(minos.group(1)))


class UnsupportedTest(unittest.TestCase):
    def check(self, needed, running):
        with mock.patch.object(oscheck, "mlx_library", return_value=Path("/x/libmlx.dylib")), \
             mock.patch.object(oscheck, "required_macos", return_value=needed), \
             mock.patch.object(oscheck, "running_macos", return_value=running):
            return oscheck.unsupported()

    def test_older_macos_is_refused(self):
        self.assertEqual(self.check((26, 2, 0), (15, 7, 1)), ("26.2", "15.7.1"))
        self.assertEqual(self.check((26, 2, 0), (26, 1, 0)), ("26.2", "26.1"))

    def test_same_or_newer_runs(self):
        self.assertIsNone(self.check((26, 2, 0), (26, 2, 0)))
        self.assertIsNone(self.check((26, 2, 0), (26, 6, 0)))
        self.assertIsNone(self.check((15, 0, 0), (15, 0, 0)))

    def test_unknown_runs_as_before(self):
        self.assertIsNone(self.check(None, (15, 0, 0)))
        self.assertIsNone(self.check((26, 2, 0), None))
        with mock.patch.object(oscheck, "mlx_library", side_effect=RuntimeError("boom")):
            self.assertIsNone(oscheck.unsupported())

    def test_this_mac_runs(self):
        self.assertIsNone(oscheck.unsupported())


class LanguageTest(unittest.TestCase):
    def test_setting_wins(self):
        self.assertEqual(oscheck.language("de"), "de")
        self.assertEqual(oscheck.language("en"), "en")

    def test_system_is_de_or_en(self):
        self.assertIn(oscheck.language("system"), ("de", "en"))

    def test_texts_fill_in(self):
        for title, body, update, quit_ in oscheck.TEXTS.values():
            self.assertIn("26.2", title.format(needed="26.2"))
            text = body.format(needed="26.2", running="15.7.1")
            self.assertIn("15.7.1", text)
            self.assertNotIn("·", title + text + update + quit_)


if __name__ == "__main__":
    unittest.main()
