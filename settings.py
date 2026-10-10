"""Shared settings in ~/Library/Application Support/VoiceBud/settings.json.

The Swift UI writes the file and tells us via `settings_changed`; Python only reads it.
VOICEBUD_DATA_DIR overrides the folder (tests use it so they never touch real data)."""
import json
import os
from pathlib import Path

DEFAULTS = {
    "islandStyle": "insel",     # "insel" | "kapsel" (SPEC §0; old "kompakt"/"live" are read)
    "liveText": False,          # live transcript while speaking; off = no streaming at all
    "waveStyle": "fein",
    "waveLive": True,
    "alcove": "auto",
    "confirmSeconds": 3.0,
    "sounds": False,
    "hideInFullscreen": False,
    "keepModelsLoaded": False,
    # screen context (KONTEXT-PLAN.md): 0 Aus, 1 Nur App, 2 Text am Cursor, 3 Ganzes Fenster
    "contextLevel": 2,
    "contextApps": {},          # {bundle id: level} per-app overrides
    "contextElectron": True,    # switch Electron apps' accessibility on when they come to the front
    "onboardingDone": False,    # the first-run setup finished once (written by the UI)
    "muteWhileRecording": True,  # the UI mutes the output while recording, except for these apps
    "muteExceptions": ["com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos", "com.apple.FaceTime"],
    "screenText": True,          # Texterkennung with ⇧⌘2 (the UI owns the shortcut)
    "screenTextHistory": True,   # recognised texts in their own history (mode "ocr")
    "menuBarStyle": "schlicht",  # menu bar symbol while recording: schlicht | farbe | punkt | zeit (UI only)
    "uiLanguage": "system",      # the app's texts: system (German on a German Mac, else English) | de | en
    "dictationLanguage": "auto", # what Whisper listens for: auto (de or en per take, recommended) | de | en
    # the hub's Kurzbefehle over config.yaml: {"dictate"|"prompt"|"command"|"ocr": chord string like "ctrl+alt"
    # (watched by the core) or {"key", "mods", "label"} (a key the UI registers with macOS)}
    "shortcuts": {},
}


def data_dir():
    path = Path(os.environ.get("VOICEBUD_DATA_DIR")
                or Path.home() / "Library/Application Support/VoiceBud")
    path.mkdir(parents=True, exist_ok=True)
    return path


def load():
    """Settings with defaults for every missing or malformed key; unknown keys are kept."""
    out = dict(DEFAULTS)
    try:
        data = json.loads((data_dir() / "settings.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return out
    if isinstance(data, dict):
        for key, value in data.items():
            default = DEFAULTS.get(key)
            if default is None or isinstance(value, type(default)) or (
                    isinstance(default, float) and isinstance(value, int)
                    and not isinstance(value, bool)):
                out[key] = value
        # an install from before the language settings keeps German texts (new installs choose in
        # the first setup step; the defaults are English texts and automatic dictation)
        if "uiLanguage" not in data and data.get("onboardingDone") is True:
            out["uiLanguage"] = "de"
        # old shape values: "kompakt" -> insel without live text, "live" -> insel with live text
        style = out.get("islandStyle")
        if not isinstance(data.get("liveText"), bool):
            out["liveText"] = style == "live"
        if style != "kapsel":
            out["islandStyle"] = "insel"
    return out
