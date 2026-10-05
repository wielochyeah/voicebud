"""First-run setup behind the onboarding window (ui/Onboarding.swift): permission status and
requests, model downloads with progress, the mic test, restart and the login item.

The window sends {"type":"onboarding","action":...}; the core answers with
{"type":"onboarding_state","grants":{...},"models":[...],"restart":bool,"tcc":str,"mic":str}."""
import ctypes
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import cleanup

BUNDLE_ID = "app.voicebud.VoiceBud"          # the DMG build (packaging/build-dmg.sh)
STT_PATTERNS = ["config.json", "*.safetensors", "*.npz"]
# download sizes for the progress bar when the hub cannot be asked (MB)
FALLBACK_MB = {"whisper": 820.0, "qwen": 3035.0}


def main_bundle():
    """(bundle id, bundle path) of this process."""
    try:
        from Foundation import NSBundle
        b = NSBundle.mainBundle()
        return str(b.bundleIdentifier() or ""), str(b.bundlePath() or "")
    except Exception:
        return "", ""


def is_bundled():
    return main_bundle()[0] == BUNDLE_ID


def app_path():
    """VoiceBud.app to relaunch: this bundle in the DMG build, else the installed app."""
    bid, path = main_bundle()
    return path if bid == BUNDLE_ID else "/Applications/VoiceBud.app"


# -- permissions --------------------------------------------------------------------------------
_iokit = None


def _hid(fn):
    global _iokit
    if _iokit is None:
        _iokit = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/IOKit.framework/IOKit")
    return getattr(_iokit, fn)


_MIC_CODE = ("import objc; objc.loadBundle('AVFoundation', {}, "
             "bundle_path='/System/Library/Frameworks/AVFoundation.framework'); "
             "print(int(objc.lookUpClass('AVCaptureDevice').authorizationStatusForMediaType_('soun')))")


def mic_status():
    """Microphone permission. AVFoundation costs ~200 MB that would stay in the core for good, so
    a short child process asks (same app, so same permission) and exits."""
    try:
        out = subprocess.run([str(cleanup.Cleaner._python()), "-c", _MIC_CODE], capture_output=True,
                             text=True, timeout=10).stdout.strip()
        return {3: "granted", 2: "denied", 1: "denied"}.get(int(out), "missing")
    except Exception:
        return "missing"


def accessibility_status():
    try:
        from ApplicationServices import AXIsProcessTrusted
        return "granted" if AXIsProcessTrusted() else "missing"
    except Exception:
        return "missing"


def input_status():
    try:
        access = _hid("IOHIDCheckAccess")
        access.restype = ctypes.c_int
        return {0: "granted", 1: "denied"}.get(access(1), "missing")   # kIOHIDRequestTypeListenEvent
    except Exception:
        return "missing"


def grants():
    return {"microphone": mic_status(), "accessibility": accessibility_status(),
            "inputMonitoring": input_status()}


def mic_name():
    try:
        import sounddevice as sd
        from audio import PA_LOCK          # PortAudio is shared with the recorder
        with PA_LOCK:
            return str(sd.query_devices(kind="input")["name"])
    except Exception:
        return ""


class Onboarding:
    def __init__(self, vb):
        self.vb = vb
        self._watch = threading.Event()
        self._downloads = {}                  # id -> {"phase", "received", "total"}
        self._lock = threading.Lock()
        self._initial_input = input_status()
        self._last_sent = None

    # -- what the window shows ----------------------------------------------------------------
    def models(self):
        stt = self.vb.stt.repo_id if hasattr(self.vb.stt, "repo_id") else ""
        return [("whisper", stt, STT_PATTERNS), ("qwen", self.vb.cleaner.model, None)]

    def model_rows(self):
        rows = []
        for mid, repo, _ in self.models():
            with self._lock:
                d = dict(self._downloads.get(mid, {}))
            if repo and cleanup.hf_snapshot(repo) is not None and d.get("phase") != "downloading":
                rows.append({"id": mid, "phase": "ready"})
            else:
                rows.append({"id": mid, "phase": d.get("phase", "paused"), "received": d.get("received", 0),
                             "total": d.get("total", FALLBACK_MB[mid])})
        return rows

    def missing(self):
        """Cheap checks first; the microphone (a child process) only when the rest is in place."""
        if accessibility_status() != "granted" or input_status() != "granted":
            return True
        if any(r["phase"] != "ready" for r in self.model_rows()):
            return True
        return mic_status() != "granted"

    def needed(self):
        """Before the setup was finished: anything missing. After it: a permission that went
        missing (a new DMG build gets a new signature and loses them, or one was revoked); the
        app would otherwise only paste to the clipboard and never say why."""
        if not self.vb.settings.get("onboardingDone"):
            return self.missing()
        lost = [n for n, st in (("accessibility", accessibility_status()), ("input monitoring", input_status()),
                                ("microphone", mic_status())) if st == "denied" or
                (st != "granted" and n != "microphone")]
        if lost:
            print(f"permissions missing after setup: {', '.join(lost)}")
        return bool(lost)

    def state(self):
        g = grants()
        restart = self._initial_input != "granted" and g["inputMonitoring"] == "granted"
        return {"type": "onboarding_state", "grants": g, "models": self.model_rows(), "restart": restart,
                "tcc": "VoiceBud" if is_bundled() else "Python", "mic": mic_name(), "login": self.login_status()}

    def send_state(self, force=True):
        st = self.state()
        if force or st != self._last_sent:
            self._last_sent = st
            self.vb.ui.send(st)

    def show(self):
        self.vb.ui.send({"type": "onboarding", "show": True})
        self.send_state()
        self.download_missing()

    # -- actions from the window --------------------------------------------------------------
    def handle(self, msg):
        action = msg.get("action")
        if action == "status":
            self.send_state()
            self.download_missing()
        elif action == "request":
            self.request(msg.get("which"))
        elif action == "watch":
            self.watch(bool(msg.get("on")))
        elif action == "download":
            self.download(msg.get("id"))
        elif action == "mic":
            self.vb.mic_meter(bool(msg.get("on")))
        elif action == "restart":
            self.restart()
        elif action == "finish":
            # the switch both ways (review 05.10.: off was ignored, VoiceBud still started at login)
            if "login" in msg and bool(msg.get("login")) != self.login_status():
                self.login_item(bool(msg.get("login")))
            self.watch(False)

    def request(self, which):
        if which == "microphone":
            # opening the input once makes macOS ask (with NSMicrophoneUsageDescription)
            def probe():
                try:
                    import sounddevice as sd
                    with sd.InputStream(samplerate=16000, channels=1):
                        time.sleep(0.3)
                except Exception:
                    pass
                self.send_state()
            threading.Thread(target=probe, daemon=True).start()
        elif which == "accessibility":
            try:
                from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
                AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})
            except Exception:
                pass
        elif which == "inputMonitoring":
            try:
                req = _hid("IOHIDRequestAccess")
                req.restype = ctypes.c_bool
                req(1)
            except Exception:
                pass
        self.watch(True)

    def watch(self, on):
        """Poll the permissions every second while a permission step is visible."""
        if not on:
            self._watch.clear()
            return
        if self._watch.is_set():
            return
        self._watch.set()

        def loop():
            while self._watch.is_set():
                self.send_state(force=False)
                time.sleep(1.0)
        threading.Thread(target=loop, name="onboarding-watch", daemon=True).start()

    # -- model downloads (one at a time, in a child process) ---------------------------------
    def download_missing(self):
        for mid, repo, _ in self.models():
            if repo and cleanup.hf_snapshot(repo) is None:
                self.download(mid)

    def download(self, mid):
        entry = next((m for m in self.models() if m[0] == mid), None)
        if entry is None or not entry[1]:
            return
        with self._lock:
            if self._downloads.get(mid, {}).get("phase") in ("downloading", "queued"):
                return
            self._downloads[mid] = {"phase": "queued", "received": 0, "total": FALLBACK_MB[mid]}
        threading.Thread(target=self._download, args=entry, name=f"download-{mid}", daemon=True).start()

    _queue_lock = threading.Lock()

    def _download(self, mid, repo, patterns):
        with self._queue_lock:                # one download at a time: the progress stays honest
            total = self._repo_mb(repo, patterns) or FALLBACK_MB[mid]
            with self._lock:
                self._downloads[mid] = {"phase": "downloading", "received": 0, "total": total}
            python = cleanup.Cleaner._python()
            code = ("import sys; from huggingface_hub import snapshot_download as s; "
                    "s(repo_id=sys.argv[1], allow_patterns=(sys.argv[2].split(',') if sys.argv[2] else None))")
            env = dict(os.environ, HF_HUB_DISABLE_XET="1", HF_HUB_DISABLE_PROGRESS_BARS="1")
            before = self._hub_bytes()
            proc = subprocess.Popen([str(python), "-c", code, repo, ",".join(patterns or [])], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            while proc.poll() is None:
                got = max(0.0, (self._hub_bytes() - before) / 1e6)
                with self._lock:
                    self._downloads[mid]["received"] = min(got, total)
                self.send_state(force=False)
                time.sleep(0.5)
            ok = proc.returncode == 0 and cleanup.hf_snapshot(repo) is not None
            with self._lock:
                self._downloads[mid] = {"phase": "ready" if ok else "paused",
                                        "received": total if ok else self._downloads[mid]["received"],
                                        "total": total}
            self.send_state()

    @staticmethod
    def _hub_bytes():
        """Bytes in the Hugging Face cache, finished and partial files alike."""
        hub = Path(os.environ.get("HF_HUB_CACHE") or Path(os.environ.get("HF_HOME") or
                   Path.home() / ".cache" / "huggingface") / "hub")
        total = 0
        for root, _, files in os.walk(hub):
            for f in files:
                try:
                    p = os.path.join(root, f)
                    if not os.path.islink(p):
                        total += os.path.getsize(p)
                except OSError:
                    pass
        return total

    @staticmethod
    def _repo_mb(repo, patterns):
        try:
            from fnmatch import fnmatch
            from huggingface_hub import HfApi
            info = HfApi().model_info(repo, files_metadata=True, timeout=10)
            size = sum(s.size or 0 for s in info.siblings
                       if not patterns or any(fnmatch(s.rfilename, p) for p in patterns))
            return size / 1e6 if size else None
        except Exception:
            return None

    # -- restart and login item ---------------------------------------------------------------
    def restart(self):
        # wait until this process is gone (its lock too): a fixed pause let the new instance hit
        # the lock and quit when shutting down took longer
        subprocess.Popen(["/bin/sh", "-c", f'while kill -0 {os.getpid()} 2>/dev/null; do sleep 0.2; done; '
                          f'/usr/bin/open "{app_path()}"'], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.vb.request_quit()

    @staticmethod
    def login_status():
        """Whether VoiceBud starts at login now (SMAppService; the dev run never does)."""
        if not is_bundled():
            return False
        try:
            import objc
            objc.loadBundle("ServiceManagement", {}, bundle_path="/System/Library/Frameworks/ServiceManagement.framework")
            return int(objc.lookUpClass("SMAppService").mainAppService().status()) == 1   # enabled
        except Exception:
            return False

    @staticmethod
    def login_item(on):
        """Start at login via SMAppService (only the DMG build is a real app process)."""
        if not is_bundled():
            print("login item: only available in the VoiceBud.app build")
            return False
        try:
            import objc
            objc.loadBundle("ServiceManagement", {}, bundle_path="/System/Library/Frameworks/ServiceManagement.framework")
            service = objc.lookUpClass("SMAppService").mainAppService()
            # without ServiceManagement metadata PyObjC returns a plain bool, with it (ok, error)
            result = (service.registerAndReturnError_ if on else service.unregisterAndReturnError_)(None)
            ok = bool(result[0]) if isinstance(result, tuple) else bool(result)
            print(f"login item {'on' if on else 'off'}: {'ok' if ok else 'failed'}, status {int(service.status())}")
            return ok
        except Exception as e:
            print(f"login item failed: {e!r}")
            return False
