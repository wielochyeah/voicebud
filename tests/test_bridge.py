import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

import _util
from ui_bridge import UIBridge

# Stand-in for VoiceBudUI: logs every line it receives, answers test commands.
FAKE_UI = r'''#!{python}
import json, os, sys, time
log = open(os.environ["FAKE_UI_LOG"], "a", buffering=1)
log.write(json.dumps({{"type": "_spawned", "pid": os.getpid()}}) + "\n")
print(json.dumps({{"type": "ready"}}), flush=True)
for line in sys.stdin:
    log.write(line)
    msg = json.loads(line)
    cmd = msg.get("cmd") if msg.get("type") == "_test" else None
    if cmd == "settings":
        print(json.dumps({{"type": "settings_changed"}}), flush=True)
    elif cmd == "sleep":
        time.sleep(msg["s"])
    elif cmd == "crash":
        sys.exit(3)
    elif cmd == "quit":
        print(json.dumps({{"type": "quit"}}), flush=True)
        time.sleep(0.2)
        sys.exit(0)
'''


def wait_for(cond, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="vb-ui-"))
        self.exe = self.dir / "FakeUI"
        self.exe.write_text(FAKE_UI.format(python=sys.executable))
        self.exe.chmod(self.exe.stat().st_mode | stat.S_IEXEC)
        self.log = self.dir / "log.jsonl"
        self.env = dict(os.environ, FAKE_UI_LOG=str(self.log))
        self.quit = threading.Event()
        self.settings = threading.Event()
        self.bridge = UIBridge({"version": 1, "hotkeys": {"dictate": "ctrl+shift", "prompt": "ctrl+alt"},
                                "dataDir": "~/x"}, on_quit=self.quit.set,
                               on_settings_changed=self.settings.set, path=self.exe, env=self.env)

    def tearDown(self):
        self.bridge.close()

    def received(self):
        if not self.log.exists():
            return []
        return [json.loads(l) for l in self.log.read_text().splitlines() if l.strip()]

    def test_hello_states_and_settings(self):
        self.bridge.start()
        self.assertTrue(self.bridge.ready.wait(5))
        self.bridge.state("recording", "dictate")
        self.bridge.partial("Hallo Welt")
        self.bridge.state("done", "dictate", app="Mail", words=2, seconds=0.4, preview="Hallo Welt",
                          target="pasted")
        self.bridge.history_changed()
        self.bridge.send({"type": "_test", "cmd": "settings"})
        self.assertTrue(self.settings.wait(5))
        msgs = [m for m in self.received() if m["type"] != "_spawned"]
        self.assertEqual(msgs[0], {"type": "hello", "version": 1, "dataDir": "~/x",
                                   "hotkeys": {"dictate": "ctrl+shift", "prompt": "ctrl+alt"}})
        self.assertEqual([m["type"] for m in msgs[1:5]], ["state", "partial", "state", "history_changed"])
        self.assertEqual(msgs[3]["target"], "pasted")

    def test_levels_dropped_when_backed_up_but_states_kept(self):
        self.bridge.start()
        self.assertTrue(self.bridge.ready.wait(5))
        self.bridge.send({"type": "_test", "cmd": "sleep", "s": 0.6})
        time.sleep(0.1)
        self.bridge.state("recording", "dictate")
        for i in range(300):
            self.bridge.level([0.1 * (i % 10)] * 7, 0.2)
        self.bridge.state("processing", "dictate")
        self.assertTrue(wait_for(lambda: any(m.get("phase") == "processing" for m in self.received())))
        got = self.received()
        levels = [m for m in got if m["type"] == "level"]
        phases = [m["phase"] for m in got if m["type"] == "state"]
        self.assertGreater(self.bridge.dropped_levels, 250)
        self.assertLess(len(levels), 50)
        self.assertEqual(phases, ["recording", "processing"])

    def test_partials_coalesce_to_newest(self):
        self.bridge.start()
        self.assertTrue(self.bridge.ready.wait(5))
        self.bridge.send({"type": "_test", "cmd": "sleep", "s": 0.5})
        time.sleep(0.1)
        self.bridge.state("recording", "dictate")
        for i in range(50):
            self.bridge.partial(" ".join(["wort"] * (i + 1)))
        self.bridge.state("processing", "dictate")
        self.assertTrue(wait_for(lambda: any(m.get("phase") == "processing" for m in self.received())))
        partials = [m["text"] for m in self.received() if m["type"] == "partial"]
        self.assertLessEqual(len(partials), 2)
        self.assertEqual(partials[-1], " ".join(["wort"] * 50))

    def test_close_does_not_hang_on_a_stopped_child(self):
        import signal
        self.bridge.start()
        self.assertTrue(self.bridge.ready.wait(5))
        proc = self.bridge._proc
        os.kill(proc.pid, signal.SIGSTOP)
        try:
            for i in range(120):   # ~240 KB: more than the pipe holds, the writer blocks in flush
                self.bridge.state("done", "dictate", app="Mail", words=1, seconds=0.1,
                                  preview="x" * 2000, target="pasted")
            time.sleep(0.3)
            t = time.time()
            self.bridge.close()
            self.assertLess(time.time() - t, 4.0)
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                os.kill(proc.pid, signal.SIGKILL)

    def test_crash_keeps_respawning_with_backoff(self):
        """04.10.: after a second crash the core used to go on without any UI (recording with no
        island, no menu bar item). Now it always comes back, with growing waits."""
        import ui_bridge
        old = ui_bridge.RESPAWN_DELAYS
        ui_bridge.RESPAWN_DELAYS = (0.0, 0.3, 0.3)
        lost = []
        self.bridge.on_lost = lambda: lost.append(1)
        try:
            self.bridge.start()
            self.assertTrue(self.bridge.ready.wait(5))
            self.bridge.state("recording", "prompt")
            self.bridge.send({"type": "_test", "cmd": "crash"})
            self.assertTrue(wait_for(lambda: sum(m["type"] == "_spawned" for m in self.received()) == 2))
            self.assertTrue(wait_for(lambda: sum(m["type"] == "hello" for m in self.received()) == 2))
            # the transient state is replayed to the new UI
            self.assertTrue(wait_for(lambda: [m.get("mode") for m in self.received() if m["type"] == "state"]
                                     == ["prompt", "prompt"]))
            self.assertTrue(wait_for(lambda: self.bridge.alive))
            self.bridge.send({"type": "_test", "cmd": "crash"})
            self.assertTrue(wait_for(lambda: sum(m["type"] == "_spawned" for m in self.received()) == 3))
            self.assertEqual(len(lost), 2)
        finally:
            ui_bridge.RESPAWN_DELAYS = old

    def test_bad_message_does_not_end_the_writer(self):
        self.bridge.start()
        self.assertTrue(self.bridge.ready.wait(5))
        self.bridge.send({"type": "level", "bands": [float("nan")] * 7, "rms": float("inf")})
        self.bridge.send({"type": "_probe_text", "text": "kaputt \ud800 ende"})   # lone surrogate
        self.bridge.state("idle")
        self.assertTrue(wait_for(lambda: any(m["type"] == "state" and m.get("phase") == "idle"
                                             for m in self.received())))

    def test_respawn_budget_returns_after_a_long_run(self):
        import ui_bridge
        old = ui_bridge.RESPAWN_RESET_S
        ui_bridge.RESPAWN_RESET_S = 0.6
        try:
            self.bridge.start()
            self.assertTrue(self.bridge.ready.wait(5))
            for n in (2, 3):        # each UI lived longer than the reset time before crashing
                time.sleep(0.8)
                self.bridge.send({"type": "_test", "cmd": "crash"})
                self.assertTrue(wait_for(lambda: sum(m["type"] == "_spawned" for m in self.received()) == n))
                self.assertTrue(wait_for(lambda: self.bridge.alive))
        finally:
            ui_bridge.RESPAWN_RESET_S = old

    def test_quit_calls_back_without_respawn(self):
        self.bridge.start()
        self.assertTrue(self.bridge.ready.wait(5))
        self.bridge.send({"type": "_test", "cmd": "quit"})
        self.assertTrue(self.quit.wait(5))
        time.sleep(0.5)
        self.assertEqual(sum(m["type"] == "_spawned" for m in self.received()), 1)

    def test_close_terminates_child(self):
        self.bridge.start()
        self.assertTrue(self.bridge.ready.wait(5))
        proc = self.bridge._proc
        self.bridge.close()
        self.assertIsNotNone(proc.poll())

    def test_missing_binary_runs_headless(self):
        b = UIBridge({"version": 1, "hotkeys": {}}, path=self.dir / "nope")
        b.start()
        self.assertTrue(b.headless)
        b.state("recording", "dictate")
        b.level([0] * 7, 0)
        b.close()


REAL_UI = Path(os.environ.get("VOICEBUD_UI_TEST_BIN") or _util.ROOT / "ui/build/VoiceBudUI")


@unittest.skipUnless(REAL_UI.exists(), f"{REAL_UI} not built")
class RealUITest(unittest.TestCase):
    """Protocol check against the real Swift helper (headless: it never orders windows front)."""

    def test_roundtrip(self):
        env = dict(os.environ, VOICEBUD_UI_HEADLESS="1")
        b = UIBridge({"version": 1, "hotkeys": {"dictate": "ctrl+shift", "prompt": "ctrl+alt"},
                      "dataDir": "~/Library/Application Support/VoiceBud"}, path=REAL_UI, env=env)
        b.start()
        try:
            self.assertTrue(b.ready.wait(10), "VoiceBudUI never sent ready")
            long_text = "Hallo Frau Becker,\n\n" + "Ein ganzer Absatz mit Text. " * 120 + "\n\nViele Grüße"
            for phase, extra in [("recording", {}), ("processing", {}),
                                 ("done", dict(app="Mail", words=3, seconds=0.5, preview="a b c",
                                               target="clipboard", text=long_text)), ("idle", {})]:
                b.state(phase, "dictate", **extra)
                if phase == "recording":
                    for _ in range(30):
                        b.level([0.3] * 7, 0.3)
                    b.partial("Hallo")
                time.sleep(0.2)
            self.assertTrue(b.alive)
        finally:
            proc = b._proc
            b.close()
        self.assertIsNotNone(proc.poll(), "VoiceBudUI did not exit after stdin closed")


if __name__ == "__main__":
    unittest.main()
