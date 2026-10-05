"""VoiceBud: press a hotkey, speak, press again — the text lands at your cursor. Fully offline.

Python owns hotkeys, microphone, speech recognition, LLM cleanup, paste and every macOS
permission. The native helper ui/build/VoiceBudUI (spawned by ui_bridge) owns all UI: menu bar
item, notch island, history and settings. Without the helper VoiceBud runs headless.

Setup:
  python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
  Grant: Microphone, Accessibility, Input Monitoring (System Settings -> Privacy & Security)
  .venv/bin/python main.py
"""
import fcntl
import json
import math
import statistics
import os
import re
import signal
import sys
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor

import objc
import yaml
from Foundation import NSObject

import context
import inject
import learn
import onboarding
import snippets
import settings
import structure
import guards
import dictionary
from audio import Recorder
from cleanup import Cleaner
from dictionary import Dictionary
from history import History
from hotkey import PushToTalk
from stream import SttWorker, Take
from transcribe import Transcriber, footprint_mb
from ui_bridge import UIBridge

APP_NAME = "VoiceBud"
LEVEL_HZ = 30
PREVIEW_CHARS = 80
PREVIEW_CHARS_LIVE = 240  # the live done card shows up to five lines with their own breaks
# The LLM process (~3 GB) is started only once the take has this much speech-level audio:
# a one-word "Ja" never reaches the cleanup threshold and should not load it.
SPEECH_RMS = 0.25         # recorder rms level (0..1 after dB scaling), about -42 dBFS
WARM_LLM_AFTER_S = 1.5


def check_permissions():
    """Best-effort permission probes; print one-time setup guidance if missing."""
    import Quartz
    msgs = []
    try:
        if not Quartz.CGPreflightListenEventAccess():
            msgs.append("Input Monitoring (for the global hotkey)")
    except AttributeError:
        pass
    try:
        from ApplicationServices import AXIsProcessTrusted
        if not AXIsProcessTrusted():
            msgs.append("Accessibility (to paste text into other apps)")
    except Exception:
        pass
    if msgs:
        print("SETUP NEEDED — grant your terminal these permissions in")
        print("System Settings -> Privacy & Security, then restart this app:")
        for m in msgs:
            print(f"  - {m}")
        print("  - Microphone (macOS will prompt on first recording)")


def rename_app():
    """Best-effort: show 'VoiceBud' instead of 'Python' where macOS reads the bundle name."""
    try:
        from Foundation import NSBundle, NSProcessInfo
        NSProcessInfo.processInfo().setProcessName_(APP_NAME)
        info = NSBundle.mainBundle().infoDictionary()
        if info is not None:
            info["CFBundleName"] = APP_NAME
    except Exception:
        pass


def acquire_single_instance_lock():
    """Refuse to run twice — a second instance would double-register hotkeys. One lock per user
    (a shared /tmp file made by one user kept every other user of the Mac from starting)."""
    try:
        lock = open(settings.data_dir() / "voicebud.lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("VoiceBud is already running — this second instance exits.")
        raise SystemExit(0)
    return lock


class _Speed:
    """How long processing usually takes on this Mac: the last 20 takes (computed ahead ones left
    out) as a factor on the M5 Pro's measured 1.1 s + 0.04 s per audio second. Kept in speed.json,
    so it is known right after a restart; before 3 takes a cautious 1.5 (an M1 is about 4x)."""

    def __init__(self, path):
        self.path = path
        try:
            self.ratios = [float(x) for x in json.loads(path.read_text())["ratios"]][-20:]
        except Exception:
            self.ratios = []

    @staticmethod
    def _base(audio_s):
        return 1.1 + 0.04 * max(0.0, audio_s)

    def expected(self, audio_s):
        k = statistics.median(self.ratios) if len(self.ratios) >= 3 else 1.5
        return k * self._base(audio_s)

    def add(self, audio_s, processing_s):
        if processing_s <= 0:
            return
        self.ratios = (self.ratios + [round(processing_s / self._base(audio_s), 3)])[-20:]
        try:
            self.path.write_text(json.dumps({"ratios": self.ratios}))
        except OSError:
            pass


class _SystemEvents(NSObject):
    """Sleep, screen lock and a switched user session end a running take (VoiceBud.system_event)."""

    def initWithVoiceBud_(self, vb):
        self = objc.super(_SystemEvents, self).init()
        if self is None:
            return None
        self.vb = vb
        from AppKit import NSWorkspace
        from Foundation import NSDistributedNotificationCenter
        nc = NSWorkspace.sharedWorkspace().notificationCenter()
        for name in ("NSWorkspaceWillSleepNotification", "NSWorkspaceSessionDidResignActiveNotification"):
            nc.addObserver_selector_name_object_(self, "event:", name, None)
        NSDistributedNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "event:", "com.apple.screenIsLocked", None)
        return self

    def event_(self, note):
        try:
            self.vb.system_event(str(note.name()))
        except Exception:
            traceback.print_exc()


def frontmost_app(own_pids=()):
    """(name, bundle id, pid) of the app in front, ("", "", 0) when it is VoiceBud or unknown."""
    app = context.frontmost(own_pids)
    return (app["name"], app["bundle"], app["pid"]) if app else ("", "", 0)


# prompt mode: the speaker points at something on screen ("fass diese Mail zusammen")
DEICTIC = re.compile(
    r"\b(diese[nmrs]?|dieses)\s+(mail|e-mail|nachricht|text|absatz|abschnitt|dokument|seite|webseite|"
    r"code|funktion|datei|artikel|antwort|chat|verlauf|tabelle|liste)\b|\bdas hier\b|\bhier oben\b|"
    r"\bmarkierten?\b|\bthis (email|e-mail|mail|message|text|page|code|document|article|thread)\b", re.I)
MAX_MATERIAL = 12000
SLOW_HINT_MIN_S = 10.0     # "Dauert länger" (and cancel by hotkey) never before this, and only past
                           # twice the usual processing time for the take's length on this Mac
MAX_RECORDING_S = 20 * 60  # a take that long ends on its own (a forgotten toggle, a locked screen)
MAX_COMMAND_CHARS = 4000   # Befehlsmodus: selection and answer share the model's window
PROOFREAD = re.compile(r"rechtschreib|tippfehler|korrigier|fehler|proofread|spelling|typo", re.I)


def paste_target(own_pids=()):
    """'pasted' or 'clipboard' for the island; see context.paste_state."""
    return context.paste_state(own_pids)


def preview_of(text, limit=PREVIEW_CHARS, keep_lines=False):
    """One line for the island, or (keep_lines, live done card) the text's own lines with blank
    lines dropped, cut at a word boundary."""
    if keep_lines:
        line = "\n".join(l for l in (" ".join(raw.split()) for raw in text.splitlines()) if l)
    else:
        line = " ".join(text.split())
    if len(line) <= limit:
        return line
    head = line[:limit]
    edge = max(head.rfind(" "), head.rfind("\n"))
    cut = head[:edge] if edge > 0 else head
    return cut.rstrip(",;: \n") + " …"


class VoiceBud:
    def __init__(self, cfg, recorder=None, open_mic=True):
        self.cfg = cfg
        self.settings = settings.load()
        self.dictionary = Dictionary.load()
        self.history = History()
        print(f"STT model: {cfg['stt']['model']} ({cfg['stt'].get('engine', 'faster-whisper')})")
        self.stt = Transcriber(cfg["stt"])
        self.worker = SttWorker(
            self.stt, idle_unload_s=float(cfg["stt"].get("idle_unload_minutes", 10)) * 60,
            keep_loaded=lambda: bool(self.settings.get("keepModelsLoaded")))
        self.cleaner = Cleaner(cfg["llm"])
        self.rec = recorder or Recorder(sample_rate=cfg["audio"]["sample_rate"],
                                        channels=cfg["audio"]["channels"])
        self.rec.on_chunk = self._on_chunk
        self.open_mic = open_mic  # False: tests push audio via rec.feed(), no microphone
        hotkeys = {"dictate": cfg["hotkey"]["key"]}
        if cfg.get("prompt_hotkey"):
            hotkeys["prompt"] = cfg["prompt_hotkey"]["key"]
        if cfg.get("command_hotkey"):
            hotkeys["command"] = cfg["command_hotkey"]["key"]
        data = str(settings.data_dir()).replace(os.path.expanduser("~"), "~", 1)
        self.ui = UIBridge({"version": 1, "hotkeys": hotkeys, "dataDir": data},
                           on_quit=self.request_quit, on_settings_changed=self.reload_settings,
                           on_probe=self.run_probe, on_onboarding=self._on_onboarding,
                           on_lost=self._ui_lost, on_slow_hint=self._slow_hint_shown,
                           on_ocr_result=self._ocr_result)
        self.onboarding = onboarding.Onboarding(self)
        self.snippets = snippets.load()
        self.learner = learn.Learner(self._learned, allowed=self._may_learn, own_pids=self._own_pids)
        self._metering = False     # onboarding mic test: levels without a recording
        self.electron = context.ElectronAX(
            enabled=lambda: self.settings.get("contextLevel", 2) >= context.CURSOR
            and self.settings.get("contextElectron", True))
        self.owner = None      # mode of the running recording ("dictate" / "prompt")
        # owner changes and the island updates of finished takes go through this lock, so the last
        # update of an old take can never land after the "recording" of the next one
        self._ui_lock = threading.Lock()
        self.take = None       # Take that receives the mic chunks
        self.live = False      # live text for the running take (settings liveText at its start)
        self.seq = 0           # bumped per recording; stale takes do not touch the island
        self._ctx = {}         # seq -> context.Snapshot taken at that take's hotkey press, RAM only
        self._ctx_threads = {}
        # takes are processed and pasted one after the other, in the order they were spoken
        self._takes = ThreadPoolExecutor(max_workers=1, thread_name_prefix="take")
        self._recording = threading.Event()
        self._closing = False
        self.ptts = {}         # mode -> PushToTalk (set by main): hold-mode release check
        self._rec_started = 0.0
        self._busy = 0         # takes stopped but not finished: notices wait while one runs
        self._busy_lock = threading.Lock()
        self._perm_warned = False
        self._spec_llm = {}    # seq -> the cleanup computed ahead in a speech pause (see _speculate_llm)
        self._processing = {}  # seq -> (monotonic time the take stopped, mode, seconds until "Dauert länger")
        self._raw = {}         # seq -> transcript, once known (a cancel puts it on the clipboard)
        self._shown_seq = None   # the take whose processing the island shows
        self._hint_seq = None    # ... once the island says "Dauert länger, ⌃⇧ bricht ab" for it
        self._queued = set()     # takes that waited behind another (not a measure of speed)
        self.speed = _Speed(settings.data_dir() / "speed.json")
        self._cancelled = set()  # seqs cancelled by the user while processing: nothing is pasted

    # -- startup / shutdown -------------------------------------------------------------------
    def start(self):
        self.ui.start()
        context.set_timeout()
        who = context.identity()
        print(f"permissions: responsible={who['responsible']} accessibility={who['trusted']}")
        self.electron.start()
        threading.Thread(target=self._first_run, name="first-run", daemon=True).start()
        self.cleaner.keep_loaded = bool(self.settings.get("keepModelsLoaded"))
        if self.settings.get("keepModelsLoaded"):
            print("keepModelsLoaded: loading Whisper and the LLM now")
            self.worker.preload(warm=True)
            if self.cleaner.usable:
                threading.Thread(target=self.cleaner.warm, daemon=True).start()
        else:
            print("Models load on the first hotkey press and unload after "
                  f"{self.worker.idle_unload_s / 60:g} min idle (keepModelsLoaded=false).")
        threading.Thread(target=self._level_loop, name="levels", daemon=True).start()
        self._system_events = _SystemEvents.alloc().initWithVoiceBud_(self)

    def request_quit(self):
        from PyObjCTools import AppHelper
        AppHelper.callAfter(self.shutdown)

    def shutdown(self, *_):
        if self._closing:
            return
        self._closing = True
        print("VoiceBud shutting down.")
        try:
            self._recording.clear()
            self._awake(False)
            if self.take is not None:
                self.take.abort()
            self._takes.shutdown(wait=False, cancel_futures=True)
            self.rec.close()
            self.worker.shutdown()
            self.cleaner.shutdown()
            self.ui.close()
            self.history.close()
        finally:
            from PyObjCTools import AppHelper
            AppHelper.stopEventLoop()

    def reload_settings(self):
        old_keep = bool(self.settings.get("keepModelsLoaded"))
        self.settings = settings.load()
        keep = bool(self.settings.get("keepModelsLoaded"))
        self.cleaner.keep_loaded = keep
        self.dictionary.reload()
        self.snippets = snippets.load()
        print(f"settings reloaded ({len(self.dictionary.terms)} dictionary terms, keepModelsLoaded={keep}, "
              f"liveText={bool(self.settings.get('liveText'))})")
        if keep and not old_keep:
            self.worker.preload()
            if self.cleaner.usable:
                threading.Thread(target=self.cleaner.warm, daemon=True).start()
        elif old_keep and not keep:
            self.worker.arm_idle()
            if self.cleaner.usable:
                threading.Thread(target=self.cleaner.release, daemon=True).start()

    # -- recording ------------------------------------------------------------------------------
    def _on_chunk(self, chunk):
        take = self.take
        if take is not None:
            take.feed(chunk)

    def _level_loop(self):
        from PyObjCTools import AppHelper
        while True:
            self._recording.wait()
            speech_frames, warmed, touched, released = 0, False, 0.0, 0
            while self._recording.is_set():
                try:
                    bands, rms = self.rec.bands()
                    self.ui.level(bands, rms)
                    now = time.monotonic()
                    if not warmed and not self._metering and rms >= SPEECH_RMS:
                        speech_frames += 1
                        if speech_frames >= WARM_LLM_AFTER_S * LEVEL_HZ:
                            warmed, touched = True, now
                            self._warm_llm()
                    elif warmed and now - touched >= 60:
                        touched = now     # a long take: the LLM must not reach its idle exit meanwhile
                        self._warm_llm()
                    owner = self.owner
                    if owner is not None and not self._metering:
                        if now - self._rec_started > MAX_RECORDING_S:
                            print(f"recording reached {MAX_RECORDING_S // 60} min, stopping it")
                            self._rec_started = now           # once
                            AppHelper.callAfter(self.stop_rec, owner)
                        # a hold-mode release the monitor missed (screen locked while holding):
                        # the keys are up, so the take ends as if released
                        ptt = self.ptts.get(owner)
                        released = released + 1 if ptt is not None and ptt.mode == "hold" \
                            and not ptt.held_now() else 0
                        if released >= LEVEL_HZ // 2:
                            released = 0
                            AppHelper.callAfter(self.stop_rec, owner)
                except Exception:
                    traceback.print_exc()
                    time.sleep(0.5)
                time.sleep(1 / LEVEL_HZ)

    def _warm_llm(self):
        """Reload the LLM while the user is still speaking (keep_alive may have expired). Not
        needed while keepModelsLoaded keeps it resident."""
        if self.cleaner.usable and not self.cleaner.keep_loaded:
            threading.Thread(target=self.cleaner.warm, daemon=True).start()

    def start_rec(self, mode):
        if self.owner is not None or self._closing:
            return  # the other hotkey is recording — ignore
        ptt = self.ptts.get(mode)
        if (ptt is None or ptt.mode == "toggle") and self._cancel_slow():
            return  # this press cancelled the take the island offered to cancel
        if self._metering:
            self.mic_meter(False)  # the test dictation takes over the microphone
        self.learner.cancel()      # the last paste is being worked on (command mode) or left behind
        with self._ui_lock:
            self.owner = mode
            self.seq += 1
        self._rec_started = time.monotonic()
        if not self._perm_warned and not context.ax().trusted():
            # permissions can go missing after the setup (a new DMG build, revoked by hand)
            self._perm_warned = True
            print("accessibility missing: showing the setup")
            threading.Thread(target=self.onboarding.show, daemon=True).start()
        self.worker.begin_take()
        self.worker.preload()  # hidden behind speaking; transcription waits for it if needed
        # SPEC §0: live text is its own switch; with it off Python does not stream at all
        self.live = bool(self.settings.get("liveText"))
        seq = self.seq
        speculate = not self.live and bool(self.cfg["stt"].get("speculate", True)) and mode == "dictate"
        self.take = Take(self.worker, on_partial=self._partial_sender(self.seq) if self.live else None,
                         preview=self.live, stream=self.live,
                         language=self.cfg["stt"].get("language"), speculate=speculate,
                         on_speculation=lambda text, lang: threading.Thread(
                             target=self._speculate_llm, args=(seq, text, lang), name="spec-llm",
                             daemon=True).start(),
                         on_spec_stale=lambda: self._drop_spec_llm(seq))
        try:
            self.rec.start(open_stream=self.open_mic)
        except Exception as e:
            print(f"Microphone failed: {e}")
            self.rec.stop()
            self.take.abort()
            with self._ui_lock:
                self.take, self.owner = None, None
            self.worker.end_take()
            self.ui.state("error", mode, message="Mikrofon nicht verfügbar")
            return
        self.ui.state("recording", mode)
        self._recording.set()
        self._awake(True)
        if mode != "dictate":
            self._warm_llm()          # prompt and command mode always need the model
        if mode == "command" or self.settings.get("contextLevel", 2) > context.OFF:
            thread = threading.Thread(target=self._capture_context_pooled, args=(self.seq, mode),
                                      name="context", daemon=True)
            self._ctx_threads[self.seq] = thread
            thread.start()

    def _capture_context_pooled(self, seq, mode):
        import objc
        with objc.autorelease_pool():
            self._capture_context(seq, mode)

    def _capture_context(self, seq, mode="dictate"):
        """Snapshot while the user speaks: field text, names and register (KONTEXT-PLAN.md). The
        Befehlsmodus reads the selection even with context off (the user points at it), and
        stops right away when nothing is selected."""
        try:
            if mode == "command":
                snap = context.capture(context.CURSOR, self._own_pids())
            else:
                snap = context.capture(self.settings.get("contextLevel", 2), self._own_pids(),
                                       self.settings.get("contextApps"))
            if snap is not None and snap.withheld is None:
                snap.names = context.names_from(snap)
                snap.register = context.register_of(snap)
            self._ctx[seq] = snap
            if seq not in self._ctx_threads:      # the take was already collected or dropped
                self._ctx.pop(seq, None)
                if snap is not None:
                    snap.clear()
                return
            if mode == "command" and (snap is None or not snap.selected.strip()):
                reason = context.withheld_label(snap.withheld) if snap is not None and snap.withheld else None
                from PyObjCTools import AppHelper
                AppHelper.callAfter(self._abort_command, seq, reason)
        except Exception:
            traceback.print_exc()

    def _abort_command(self, seq, reason=None):
        if seq != self.seq or self.owner != "command":
            return
        with self._ui_lock:
            self.owner = None
        self._recording.clear()
        self._awake(False)
        self.rec.stop()
        take, self.take = self.take, None
        if take is not None:
            take.abort()
        self.worker.end_take()
        self._drop_ctx(seq)
        self._show(seq, "error", "command",
                   message=f"Befehl: {reason}" if reason else "Erst Text markieren, dann halten und sprechen")

    def stop_rec(self, mode, to_clipboard=False):
        """End the recording and hand the take to the take thread. Every step after the owner is
        cleared is guarded: the island must get "processing" and the take must be submitted, or
        the user is left with a recording island while nothing records."""
        if self.owner != mode:
            return  # release of a chord that doesn't own this recording
        t_stop = time.time()
        with self._ui_lock:
            self.owner = None
        self._recording.clear()
        self._awake(False)
        take, self.take = self.take, None
        peak = getattr(self.rec, "peak", 1.0)
        try:
            self.rec.stop()
        except Exception:
            traceback.print_exc()
        app, bundle, pid, style = "", "", 0, "doc"
        try:
            app, bundle, pid = frontmost_app(self._own_pids())
            style = structure.style_for(bundle, self.settings.get("appStyles"))
        except Exception:
            traceback.print_exc()
        audio_s = take.buf.n / 16000 if take is not None and hasattr(take, "buf") else 0.0
        hint_after = max(SLOW_HINT_MIN_S, 2 * self.speed.expected(audio_s))
        with self._busy_lock:
            if self._busy:
                self._queued.add(self.seq)
            self._busy += 1
            self._processing[self.seq] = (time.monotonic(), mode, hint_after)
            self._shown_seq, self._hint_seq = self.seq, None
        self.ui.state("processing", mode, hint_after=round(hint_after, 1))
        self._takes.submit(self._process, take, mode, t_stop, app, self.seq, self.live, style, pid,
                           to_clipboard, peak)

    def _awake(self, on):
        """While recording, the display stays on (like a video player): an idle display sleep or
        screen lock in the middle of a long dictation must not end it."""
        try:
            from Foundation import NSProcessInfo
            info = NSProcessInfo.processInfo()
            if on and getattr(self, "_activity", None) is None:
                # NSActivityIdleDisplaySleepDisabled | NSActivityUserInitiated
                self._activity = info.beginActivityWithOptions_reason_((1 << 40) | 0x00FFFFFF | (1 << 20),
                                                                      "VoiceBud nimmt auf")
            elif not on and getattr(self, "_activity", None) is not None:
                info.endActivity_(self._activity)
                self._activity = None
        except Exception:
            traceback.print_exc()

    def cancel_rec(self, mode):
        """The chord was part of another shortcut (ctrl+shift+Tab, ctrl+cmd+F): drop the take,
        paste nothing, close the island quietly."""
        if self.owner != mode:
            return
        with self._ui_lock:
            self.owner = None
            seq = self.seq
        self._recording.clear()
        self._awake(False)
        try:
            self.rec.stop()
        except Exception:
            traceback.print_exc()
        take, self.take = self.take, None
        if take is not None:
            take.abort()
        self.worker.end_take()
        self._drop_ctx(seq)
        self.ui.state("idle")
        print(f"(take dropped: the {mode} keys were part of another shortcut)")

    def system_event(self, what):
        """Sleep, screen lock or a switched user session: a running take ends, its text goes to
        the clipboard only (never pasted into whatever is in front after the lock)."""
        if self.owner is not None:
            print(f"{what}: ending the running take, text to the clipboard")
            self.stop_rec(self.owner, to_clipboard=True)

    def _llm_inputs(self, text, lang, snap, pid, style):
        """Everything the cleanup of a dictation depends on, from the transcript: the text after
        the fixed rules and (lang, terms, style, register). The same function feeds the
        speculation and the final pass, so equal inputs mean an equal result."""
        usable = snap is not None and snap.withheld is None and (not pid or snap.pid == pid)
        names = snap.names if usable else []
        terms = self.dictionary.terms + names
        fixed, fixes = dictionary.correct_names(self.dictionary.correct(text), names)
        fixed = structure.apply_commands(fixed, lang)
        register = snap.register if usable else None
        return fixed, fixes, (fixed, lang, tuple(terms), style, register)

    def _speculate_llm(self, seq, text, lang):
        """Speech pause, the transcript computed ahead: the cleanup runs ahead too (low priority,
        cancelled by any real request). Used at stop only when its inputs are exactly the final
        ones."""
        try:
            if seq != self.seq or self.owner != "dictate":
                return
            if seq in self._ctx_threads and seq not in self._ctx:
                return                    # the screen context is still being read
            snap = self._ctx.get(seq)
            app, bundle, pid = frontmost_app(self._own_pids())
            style = structure.style_for(bundle, self.settings.get("appStyles"))
            fixed, _, key = self._llm_inputs(text, lang, snap, pid, style)
            ticket = {"done": threading.Event()}
            old = self._spec_llm.get(seq)
            if old is not None:
                self.cleaner.cancel(old["ticket"])
            self._spec_llm[seq] = {"key": key, "ticket": ticket}
            _, _, terms, style, register = key
            ticket["result"] = self.cleaner.clean(fixed, lang, terms=list(terms), style=style,
                                                  register=register, ticket=ticket)
        except Exception:
            traceback.print_exc()
        finally:
            if "ticket" in locals():
                ticket["done"].set()

    def _drop_spec_llm(self, seq):
        entry = self._spec_llm.pop(seq, None)
        if entry is not None:
            self.cleaner.cancel(entry["ticket"])

    def _speculated_clean(self, seq, key, timeout):
        """The cleanup computed ahead, when its inputs equal `key`; else None (and it stops)."""
        entry = self._spec_llm.pop(seq, None)
        if entry is None:
            return None
        ticket = entry["ticket"]
        if entry["key"] != key:
            self.cleaner.cancel(ticket)
            return None
        if not ticket["done"].wait(timeout) or ticket.get("cancelled") or not ticket.get("ran"):
            return None                   # it never reached the model (short, not loaded): run normally
        self.cleaner.last_stats = dict(ticket.get("stats", {}), speculative=True)
        return ticket.get("result")

    def _ocr_result(self, msg):
        """Texterkennung (the UI recognised a screen region): the text goes to its own history
        (mode "ocr", the Hub shows it apart from the dictations), never from an app VoiceBud
        keeps out of everything (password managers and the like)."""
        if not self.settings.get("screenTextHistory", True):
            return
        if str(msg.get("bundle") or "").lower() in context.ALWAYS_EXCLUDED:
            return
        text = str(msg.get("text") or "").strip()
        if not text:
            return
        seconds = float(msg.get("seconds") or 0.0)
        try:
            self.history.add(ts=time.time(), mode="ocr", app=str(msg.get("app") or "") or None, raw=text, final=text,
                             lang=None, audio_s=0.0, stt_s=round(seconds, 3), llm_s=0.0, total_s=round(seconds, 3),
                             words=sum(1 for w in text.split() if any(c.isalnum() for c in w)))  # not "|" or "---"
            self.ui.history_changed()
        except Exception:
            traceback.print_exc()

    def _slow_hint_shown(self):
        """The island now offers to cancel the take it shows (UI message slow_hint)."""
        self._hint_seq = self._shown_seq

    def _cancel_slow(self):
        """A press of the dictation hotkey while the island says "Dauert länger, ⌃⇧ bricht ab"
        cancels exactly that take: nothing is pasted, its LLM request stops, and the rest of its
        work is skipped. A transcript that is already there goes to the clipboard now (never later:
        it could overwrite a newer copy); the take lands in the history either way."""
        # the island says so (headless, e.g. in tests: the take shown, by the same clock)
        seq = self._shown_seq if self.ui.headless else self._hint_seq
        with self._busy_lock:
            entry = self._processing.get(seq) if seq is not None else None
        if entry is None or time.monotonic() - entry[0] < entry[2] - 0.5:
            return False
        mode = entry[1]
        self._cancelled.add(seq)
        raw = self._raw.get(seq)
        print(f"take {seq} cancelled by the user after {time.monotonic() - entry[0]:.0f} s")
        self.cleaner.cancel_take(seq)
        message = "Abgebrochen, nichts eingefügt"
        if raw:
            try:
                inject.copy_only(raw)
                message = "Abgebrochen, Rohtext in der Zwischenablage"
            except Exception:
                traceback.print_exc()
        with self._ui_lock:
            if self.owner is None:
                self.ui.state("error", mode, message=message, tone="ok")
        return True

    def _drop_ctx(self, seq):
        """The take's screen context leaves RAM (empty, failed and cancelled takes too), and a
        cleanup still computing ahead for it stops."""
        entry = self._spec_llm.pop(seq, None)
        if entry is not None:
            self.cleaner.cancel(entry["ticket"])
        self._ctx_threads.pop(seq, None)
        snap = self._ctx.pop(seq, None)
        if snap is not None:
            snap.clear()

    def _idle_for_notice(self):
        """A notice (learned word, Kontext-Probe) may use the island: nothing records or runs."""
        return self.owner is None and self._busy == 0

    def _learned(self, heard, corrected, heard_phrase, corrected_phrase, exact=False):
        """The user corrected a word right after the paste. An unknown word becomes a dictionary term
        (its sound-alikes get fixed too); an ordinary heard word ("Clout") or a term the dictionary
        already has becomes a learned fix with its neighbour ("Clout Code" -> "Claude Code"). A name
        that is not spelled like what was heard ("USB-Flow" -> "WhisperFlow") becomes an exact fix
        of that wording, and the name a term (its near spellings get fixed too)."""
        if exact:
            if not self.dictionary.add_replacement(heard, corrected):
                return
            if not dictionary.is_word(corrected):
                self.dictionary.add_term(corrected)
            notice = f"Gelernt: {heard} wird {corrected}"
            print("learned a correction (exact)")
            self.ui.send({"type": "dictionary_changed"})
            if self._idle_for_notice():
                self._show(self.seq, "error", "dictate", message=notice, tone="ok")
            return
        first = heard.split()[0]
        # a new name macOS does not know at all ("Tiingo") that sounds like what was heard: the
        # heard word ("Tingo", which macOS lists as a name) is a misrecognition of it, not a word
        novel = not dictionary.is_word(corrected) and not dictionary.is_word(corrected.lower())
        a, b = dictionary.phonetic(heard.replace(" ", "")), dictionary.phonetic(corrected.replace(" ", ""))
        respelled = novel and bool(a and b) and dictionary._lev(a, b) <= 1
        # an ordinary word ("Clout", "Bäcker") gets a fix bound to its neighbour
        ordinary = (dictionary.is_word(first) and not respelled) or corrected in self.dictionary.terms
        if ordinary:
            if not self.dictionary.add_replacement(heard_phrase, corrected_phrase):
                return
            notice = f"Gelernt: {heard_phrase} wird {corrected_phrase}"
        else:
            added = self.dictionary.add_term(corrected)
            # self-check: the term must really fix what was heard next time; when the fuzzy match
            # does not reach it ("Fickma", "Schimanska") and the heard word is no word at all, that
            # exact wording becomes a fix too (it occurs nowhere else)
            fixes_it = corrected in self.dictionary.correct(heard)
            if not fixes_it and (respelled or (not dictionary.is_word(first) and not dictionary.is_word(first.lower()))):
                added = self.dictionary.add_replacement(heard, corrected) or added
            if not added:
                return
            notice = f"Gelernt: {corrected}"
        print("learned a correction")
        self.ui.send({"type": "dictionary_changed"})
        if self._idle_for_notice():
            self._show(self.seq, "error", "dictate", message=notice, tone="ok")

    def _may_learn(self, app):
        """The learner reads the focused field only where the context settings allow it."""
        level, _ = context.effective_level(self.settings.get("contextLevel", 2), app,
                                           self.settings.get("contextApps"))
        return level >= context.CURSOR

    def _deliver(self, text, pid):
        """Paste into the app that was in front at the stop. When another app is in front by
        now, the text only goes to the clipboard (the card says so) instead of landing there."""
        front = context.frontmost(self._own_pids())
        if pid and front is not None and front["pid"] != pid:
            inject.copy_only(text)
            return "clipboard"
        target = paste_target(self._own_pids())
        inject.inject(text, self.cfg["inject"])
        return target

    def _take_context(self, seq, pid):
        """The snapshot of this take, or None. Dropped when another app is in front by now."""
        thread = self._ctx_threads.pop(seq, None)
        if thread is not None:
            thread.join(0.5)
        snap = self._ctx.pop(seq, None)
        if snap is None:
            return None
        if pid and snap.pid != pid:
            snap.clear()
            snap.withheld = "app_changed"
        return snap

    def _own_pids(self):
        pids = {os.getpid()}
        proc = getattr(self.ui, "_proc", None)
        if proc is not None:
            pids.add(proc.pid)
        return pids

    def _first_run(self):
        if self.onboarding.needed():
            print("first-run setup: something is missing, showing the onboarding")
            self.onboarding.show()

    def _ui_lost(self):
        """The UI died: what only its messages would end ends here (mic test, permission polling).
        The restarted UI gives the sound back itself (OutputMute marker)."""
        self.onboarding.watch(False)
        from PyObjCTools import AppHelper
        AppHelper.callAfter(self.mic_meter, False)

    def _on_onboarding(self, msg):
        """Status checks start child processes (up to 10 s): never on the main thread, where they
        would hold up the hotkeys. The mic test touches the recorder and stays there."""
        if msg.get("action") == "mic":
            from PyObjCTools import AppHelper
            AppHelper.callAfter(self.onboarding.handle, msg)
        else:
            threading.Thread(target=self.onboarding.handle, args=(msg,), name="onboarding", daemon=True).start()

    def mic_meter(self, on):
        """Onboarding mic test: stream levels while no take runs."""
        if on and not self._metering and self.owner is None and not self._closing:
            try:
                self.rec.start(open_stream=self.open_mic)
            except Exception as e:
                print(f"mic test failed: {e}")
                self.rec.stop()
                return
            self._metering = True
            self._recording.set()
        elif not on and self._metering:
            self._metering = False
            if self.owner is None:
                self._recording.clear()
                self.rec.stop()

    def run_probe(self):
        """Kontext-Probe (menu, hold ⌥): one redacted snapshot of the app in front, logged to
        ~/Library/Logs/voicebud-context.jsonl and shown on the island."""
        def go():
            time.sleep(0.35)          # the menu closes, the app in front keeps its focus
            ok, summary = context.probe(self.settings.get("contextLevel", 2), self._own_pids(),
                                        self.settings.get("contextApps"), self.electron)
            print(f"context probe: {summary}")
            if self._idle_for_notice():
                self._show(self.seq, "error", "dictate", message=summary, tone="ok" if ok else "warn")
        threading.Thread(target=go, name="probe", daemon=True).start()

    def _partial_sender(self, seq):
        def send(text):
            if seq == self.seq and not self._closing:
                self.ui.partial(self.dictionary.correct(text))
        return send

    def _show(self, seq, phase, mode, **extra):
        """Island update for a finished take, unless a newer recording already owns it."""
        with self._ui_lock:
            if seq != self.seq or self.owner is not None:
                return
            self.ui.state(phase, mode, **extra)
        hold = {"done": float(self.settings.get("confirmSeconds", 3.0)), "error": 2.5}.get(phase, 0.5)

        def back_to_idle():
            with self._ui_lock:
                if seq == self.seq and self.owner is None:
                    self.ui.state("idle")
        timer = threading.Timer(hold + 0.4, back_to_idle)
        timer.daemon = True
        timer.start()

    # -- processing (one thread per take) ------------------------------------------------------
    def _process(self, take, mode, t_stop, app, seq, live=False, style="doc", pid=0, to_clipboard=False,
                 peak=1.0):
        """One take on the take thread. Its screen context leaves RAM afterwards whatever happened,
        and Cocoa objects made on this long-lived thread are released per take."""
        import objc
        try:
            with objc.autorelease_pool():
                self._process_take(take, mode, t_stop, app, seq, live, style, pid, to_clipboard, peak)
        finally:
            self._drop_ctx(seq)
            self._cancelled.discard(seq)
            self._raw.pop(seq, None)
            self._queued.discard(seq)
            if self._hint_seq == seq:
                self._hint_seq = None
            with self._busy_lock:
                self._busy = max(0, self._busy - 1)
                self._processing.pop(seq, None)

    def _keep_cancelled(self, seq, mode, app, t_stop, res, final=None):
        """A cancelled take is not pasted, but its words stay in the history (Hub)."""
        print("(cancelled take: nothing pasted, kept in the history)")
        if not res.text:
            return
        try:
            text = final or res.text
            self.history.add(ts=t_stop, mode=mode, app=app or None, raw=res.text, final=text, lang=res.lang,
                             audio_s=round(res.audio_s, 2), stt_s=0.0, llm_s=0.0,
                             total_s=round(time.time() - t_stop, 3), words=len(text.split()))
            self.ui.history_changed()
        except Exception:
            traceback.print_exc()

    def _process_take(self, take, mode, t_stop, app, seq, live, style, pid, to_clipboard, peak):
        raw = None
        self.cleaner.tag(seq)
        try:
            res = take.finish()
            t_stt = time.time()
            raw = res.text
            if raw:
                self._raw[seq] = raw
            if seq in self._cancelled:           # cancelled while transcribing: skip the rest
                self._keep_cancelled(seq, mode, app, t_stop, res)
                return
            if not res.text:
                db = 20 * math.log10(max(peak, 1e-9))
                print(f"{time.strftime('%H:%M:%S')} (no speech detected, {res.audio_s:.1f} s audio, "
                      f"peak {db:.0f} dB)")
                if res.audio_s < 0.6:
                    self._show(seq, "empty", mode)        # a tap, not a take
                elif peak < 0.0005:
                    self._show(seq, "error", mode, message="Kein Ton vom Mikrofon, Eingang prüfen")
                else:
                    self._show(seq, "error", mode, message="Nichts verstanden")
                return
            snap = self._take_context(seq, pid)
            usable = snap is not None and snap.withheld is None
            names = snap.names if usable else []
            terms = self.dictionary.terms + names
            # fixed rules first (spelling, names from the screen, spoken commands), so short takes
            # without the LLM get them too; the LLM then structures the text, the guards keep it
            # faithful
            text, fixes, llm_key = self._llm_inputs(res.text, res.lang, snap if usable else None, pid, style)
            material = None
            if mode == "command":
                self._run_command(res, text, snap if usable else None, app, seq, t_stop, t_stt, pid, to_clipboard)
                return
            if mode == "dictate":
                refined = self._speculated_clean(seq, llm_key, timeout=300)
                if refined is None:
                    refined = self.cleaner.clean(text, res.lang, terms=terms, style=style,
                                                 register=snap.register if usable else None)
            else:
                material = self._material(snap, text) if usable else None
                desc = (f"{material[0]}, " + f"{len(material[1]):,}".replace(",", ".") + " Zeichen") if material else None
                refined = self.cleaner.promptify(text, res.lang, terms=terms, material=desc)
                refined = guards.drop_unsupported(refined, text, material[1] if material else "")
            final = structure.tidy(dictionary.correct_names(self.dictionary.correct(refined), names)[0], res.lang)
            if mode == "dictate" and usable and snap.has_text:
                final = structure.fit_to_cursor(final, snap.before, snap.after, res.lang)
            if mode == "dictate" and self.snippets:
                final, _used = snippets.apply(final, self.snippets)
            stored = final
            if material:
                final = f"{final}\n\n<material quelle=\"{material[0]}\">\n{material[1]}\n</material>"
                stored = f"{stored}\n\n[Material: {len(material[1])} Zeichen aus {material[0]}, nicht gespeichert]"
            ctx_card = self._context_card(snap, fixes, material)
            if snap is not None:
                snap.clear()
            t_llm = time.time()
            if seq in self._cancelled:
                self._keep_cancelled(seq, mode, app, t_stop, res, final=stored)
                return
            if to_clipboard or self._closing:
                inject.copy_only(final)       # screen locked or quitting: never paste blind
                target = "clipboard"
            else:
                target = self._deliver(final, pid)
            # the learner checks the app it reads itself (the start snapshot may be of another app:
            # the user switched apps while speaking); a field withheld for privacy stays unread
            private = snap is not None and snap.withheld not in (None, "app_changed")
            if mode == "dictate" and pid and target in ("pasted", "clipboard") and not private:
                self.learner.watch(pid if target == "pasted" else None, final)
            t_done = time.time()
            words = len(final.split())
            preview = (preview_of(final, PREVIEW_CHARS_LIVE, keep_lines=True) if live else preview_of(final))
            # "text": the whole final text; the confirmation unfolds to it on hover (SPEC §0)
            self._show(seq, "done", mode, app=app, words=words, seconds=round(t_done - t_stop, 2),
                       preview=preview, target=target, text=final, context=ctx_card)
            # the text is pasted: a failure from here on must not turn the take into an error
            # on the island (the user would dictate again and paste twice)
            try:
                self.history.add(ts=t_stop, mode=mode, app=app or None, raw=res.text, final=stored,
                                 lang=res.lang, audio_s=round(res.audio_s, 2),
                                 stt_s=round(t_stt - t_stop, 3), llm_s=round(t_llm - t_stt, 3),
                                 total_s=round(t_done - t_stop, 3), words=words)
                self.ui.history_changed()
            except Exception:
                traceback.print_exc()
            try:
                self._log(res, t_stop, t_stt, t_llm, t_done, target)
                print(f"→ {mode}: {len(final)} Zeichen")
                # what is usual on this Mac: takes that went through the LLM and did not wait in line
                stats = self.cleaner.last_stats
                if not res.speculative and not stats.get("speculative") and stats.get("tokens") \
                        and seq not in self._queued:
                    self.speed.add(res.audio_s, t_done - t_stop)
            except Exception:
                traceback.print_exc()
        except Exception as e:
            traceback.print_exc()
            if type(e).__name__ == "_MissingModel":
                message = str(e)
            elif isinstance(e, TimeoutError):
                message = "Spracherkennung hat zu lange gebraucht"
            else:
                message = f"Fehler: {type(e).__name__}"
            if raw:
                # whatever failed after the transcription, the words are not lost
                try:
                    inject.copy_only(raw)
                    message = "Fehler bei der Aufbereitung, Rohtext in der Zwischenablage"
                except Exception:
                    traceback.print_exc()
            self._show(seq, "error", mode, message=message)
        finally:
            self.worker.end_take()

    def _run_command(self, res, instruction, snap, app, seq, t_stop, t_stt, pid, to_clipboard=False):
        """Befehlsmodus: the selected text, edited as said, replaces the selection."""
        selection = snap.selected if snap is not None else ""
        if not selection.strip():
            self._show(seq, "error", "command", message="Keine Markierung gefunden")
            return
        # the snapshot keeps 4000 characters; the full length decides (a longer selection would be
        # replaced by the edited first 4000 characters, the rest lost)
        if max(len(selection), getattr(snap, "selected_len", 0)) > MAX_COMMAND_CHARS:
            self._show(seq, "error", "command", message="Markierung zu lang, höchstens 4.000 Zeichen")
            return
        source = dictionary.spell_fix(selection) if PROOFREAD.search(instruction) else selection
        result = self.cleaner.command(instruction, source, res.lang)
        snap.clear()
        if not result:
            self._show(seq, "error", "command", message="Befehl nicht ausgeführt, Text unverändert")
            return
        t_llm = time.time()
        if seq in self._cancelled:
            print("(cancelled take: nothing pasted)")
            return
        if to_clipboard or self._closing:
            inject.copy_only(result)
            target = "clipboard"
        else:
            target = self._deliver(result, pid)
        t_done = time.time()
        card = {"app": app, "bundle": snap.bundle, "used": True, "label": f"Kontext aus {app}",
                "rows": [["Markierung", f"{len(selection):,} Zeichen".replace(",", ".")]]}
        self._show(seq, "done", "command", app=app, words=len(result.split()), seconds=round(t_done - t_stop, 2),
                   preview=preview_of(result), target=target, text=result, context=card)
        try:
            self.history.add(ts=t_stop, mode="command", app=app or None, raw=instruction, final=result,
                             lang=res.lang, audio_s=round(res.audio_s, 2), stt_s=round(t_stt - t_stop, 3),
                             llm_s=round(t_llm - t_stt, 3), total_s=round(t_done - t_stop, 3),
                             words=len(result.split()))
            self.ui.history_changed()
            self._log(res, t_stop, t_stt, t_llm, t_done, target)
            print(f"✎ Befehl: {len(selection)} -> {len(result)} Zeichen")
        except Exception:
            traceback.print_exc()

    def _material(self, snap, instruction):
        """Prompt mode: (source, text) to append verbatim, or None. A selection always counts;
        otherwise only when the speaker points at it ("diese Mail"), and then the whole window
        is read once, unless the app is capped at "Text am Cursor" (no private-window signal)."""
        if snap.selected.strip():
            text, source = snap.selected, "Markierter Text"
        elif DEICTIC.search(instruction):
            app = {"bundle": snap.bundle, "path": ""}
            window_ok = context.effective_level(context.WINDOW, app, self.settings.get("contextApps"))[0] >= context.WINDOW
            # the open mail or page first, not the inbox list around it
            text = (context.main_text(snap.pid) or snap.window or context.window_text(snap.pid)) if window_ok else ""
            source = "Fenstertext"
            if not text.strip():
                text, source = (snap.before + snap.after), "Text aus dem Eingabefeld"
        else:
            return None
        text = text.strip()[:MAX_MATERIAL]
        if not text:
            return None
        title = f" („{snap.title[:80]}“)" if snap.title else ""
        return (f"{source} aus {snap.app}{title}", text)

    def _context_card(self, snap, fixes, material):
        """What the confirmation shows about the context of this take (never the text itself)."""
        if snap is None:
            return None
        info = {"app": snap.app, "bundle": snap.bundle, "used": snap.withheld is None, "rows": []}
        if snap.withheld:
            info["label"] = f"Ohne Kontext, {context.withheld_label(snap.withheld)}"
            return info
        info["label"] = f"Kontext aus {snap.app}"
        rows = info["rows"]
        cursor = len(snap.before) + len(snap.after) + len(snap.selected)
        if cursor:
            rows.append(["Text am Cursor", f"{cursor:,} Zeichen".replace(",", ".")])
        if snap.window:
            rows.append(["Ganzes Fenster", f"{len(snap.window):,} Zeichen".replace(",", ".")])
        elif snap.header:
            rows.append(["Fenster", "Empfänger und Betreff"])
        if snap.names:
            rows.append(["Namen", ", ".join(snap.names[:6])])
        if fixes:
            rows.append(["Korrigiert", ", ".join(f"{a} zu {b}" for a, b in fixes[:4])])
        if snap.register:
            rows.append(["Anrede", snap.register])
        if material:
            rows.append(["Im Prompt", material[0]])
            info["warning"] = ("Der Prompt enthält Text vom Bildschirm. Er geht mit, wenn du den Prompt "
                               "in einen Cloud-Chat einfügst.")
        return info

    def _log(self, res, t_stop, t_stt, t_llm, t_done, target):
        s = self.cleaner.last_stats
        if s:
            restored = s.get("reverted", 0) + s.get("reinserted", 0) + s.get("dropped", 0)
            llm = (f"LLM{' ahead' if s.get('speculative') else ''} {t_llm - t_stt:.2f}s (load {s.get('load', 0):.2f}, prompt {s.get('prompt', 0):.2f}, "
                   f"eval {s.get('eval', 0):.2f}, {s.get('tokens', 0)} tok, {restored} words restored)")
        else:
            llm = f"LLM skipped {t_llm - t_stt:.2f}s"
        temp = getattr(self.stt, "last_temperature", 0.0)
        fallback = f", fallback T{temp:.1f}" if temp else ""
        if getattr(res, "speculative", False):
            fallback += ", ahead"

        print(f"{time.strftime('%H:%M:%S')} ⏱ audio {res.audio_s:.1f}s | STT after stop {t_stt - t_stop:.2f}s "
              f"({res.segments} segments, {res.partials} partials{fallback}) | {llm} | "
              f"paste {t_done - t_llm:.2f}s ({target}) | total {t_done - t_stop:.2f}s | "
              f"RAM {footprint_mb():.0f} MB", flush=True)


LOG = os.path.expanduser("~/Library/Logs/voicebud.log")
LOG_MAX = 5 * 1024 * 1024


def protect_files():
    """Log and history are for this user only, and the log does not grow forever (it holds
    timings and errors, never dictated text)."""
    paths = [LOG] + [str(settings.data_dir() / f"history.sqlite{x}") for x in ("", "-wal", "-shm")]
    for path in paths:
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    try:
        if os.path.getsize(LOG) > LOG_MAX:
            with open(LOG, "r+b") as f:
                f.seek(-512 * 1024, os.SEEK_END)
                tail = f.read()
                f.seek(0)
                f.write(tail)
                f.truncate()
    except OSError:
        pass


def main():
    _lock = acquire_single_instance_lock()  # keep reference for the process lifetime
    protect_files()
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    with open("config.yaml") as f:
        cfg = yaml.safe_load(f)

    check_permissions()

    from AppKit import NSApplication
    from PyObjCTools import AppHelper, MachSignals

    rename_app()
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(1)  # accessory: no Dock icon; the Swift helper owns the menu bar

    vb = VoiceBud(cfg)
    vb.start()

    key = cfg["hotkey"]["key"]
    mode = cfg["hotkey"].get("mode", "hold")
    vb.ptts["dictate"] = PushToTalk(key, lambda: vb.start_rec("dictate"), lambda: vb.stop_rec("dictate"),
               active=lambda: vb.owner == "dictate", on_cancel=lambda: vb.cancel_rec("dictate"), mode=mode).start()
    action = "Press" if mode == "toggle" else "Hold"
    print(f"{APP_NAME} ready. {action} [{key}] to dictate ({mode} mode).")

    pcfg = cfg.get("prompt_hotkey")
    if pcfg:
        pmode = pcfg.get("mode", "hold")
        vb.ptts["prompt"] = PushToTalk(pcfg["key"], lambda: vb.start_rec("prompt"), lambda: vb.stop_rec("prompt"),
               active=lambda: vb.owner == "prompt", on_cancel=lambda: vb.cancel_rec("prompt"),
                   mode=pmode).start()
        paction = "Press" if pmode == "toggle" else "Hold"
        print(f"{paction} [{pcfg['key']}] to turn speech into a structured AI prompt.")

    ccfg = cfg.get("command_hotkey")
    if ccfg:
        cmode = ccfg.get("mode", "hold")
        vb.ptts["command"] = PushToTalk(ccfg["key"], lambda: vb.start_rec("command"), lambda: vb.stop_rec("command"),
               active=lambda: vb.owner == "command", on_cancel=lambda: vb.cancel_rec("command"),
                   mode=cmode).start()
        print(f"{'Press' if cmode == 'toggle' else 'Hold'} [{ccfg['key']}] over selected text to edit it by voice.")

    # SIGTERM from the app launcher / Ctrl+C: shut the UI child down cleanly, too
    MachSignals.signal(signal.SIGTERM, vb.shutdown)
    MachSignals.signal(signal.SIGINT, vb.shutdown)
    try:
        AppHelper.runEventLoop()
    finally:
        vb.rec.close()
        vb.ui.close()
        # a take still on the take thread would keep the process (and its lock) alive and paste
        # after quitting: leave now
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(0)


if __name__ == "__main__":
    main()
