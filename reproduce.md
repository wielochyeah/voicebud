# Run VoiceBud on your MacBook

VoiceBud is a fully offline dictation app for **macOS on Apple Silicon** (M1–M4).
Press `ctrl+shift` anywhere → speak → press again → clean text appears at your cursor.
No cloud, no subscription. Everything runs on your machine.

## 1. Prerequisites

```bash
# Install Homebrew if you don't have it (macOS package manager)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Python 3.12 (the version this project uses)
brew install python@3.12
```

Both models run through MLX inside the app: Whisper large-v3-turbo for speech and
`mlx-community/Qwen3.5-4B-MLX-4bit` (~3 GB) for the cleanup, prompts, commands and formulas.
The setup window downloads them on the first start; after that VoiceBud needs no internet.

## 2. Set up the project

```bash
# Clone the repository from GitHub and enter it
git clone https://github.com/anesriad/VoiceBud-Local-Riad.git
cd VoiceBud-Local-Riad

# Create an isolated Python environment inside the project
python3.12 -m venv .venv

# Activate it (your terminal now uses the project's own Python)
source .venv/bin/activate

# Install all Python libraries the app needs
pip install -r requirements.txt

# The formula reader (shift+cmd+2, then option): only the package itself, its optional
# extras (servers, audio, video) are not needed
pip install --no-deps mlx-vlm==0.7.4
```

## 3. Build the interface and run it

The island, the hub and the setup window are a small Swift app (`ui/`). It needs Apple's command
line tools once (`xcode-select --install`, if you do not have them yet):

```bash
# Build the Swift interface (ui/build/VoiceBudUI)
zsh ui/build.sh

# Start the app: the setup window opens and downloads the speech model (~0.9 GB)
# and the language model (~3 GB) once
python main.py
```

Or build the whole `VoiceBud.app` into /Applications with `zsh make-app.sh`.

## 4. Grant permissions (one time)

macOS will block the app until you allow it. In **System Settings → Privacy & Security**, add your Python binary to:

- **Input Monitoring** — lets the app see the global hotkey
- **Accessibility** — lets it paste text into other apps and read the screen context
- **Microphone** — macOS asks automatically on your first recording; click Allow

The setup window walks you through these. Two more are asked when you first need them:

- **Screen Recording** — for the text recognition (`shift+cmd+2`); the image never leaves your Mac and is deleted right away
- **Automation for Microsoft Word** (optional) — when you paste formulas into Word, VoiceBud asks Word for the font name and size at your cursor, nothing else; it can be switched off in the hub under Text Recognition

Tip: the settings file picker hides dot-folders. Press `⌘⇧G` in the picker and paste the path printed by `readlink -f .venv/bin/python`, or reveal it with `open -R "$(readlink -f .venv/bin/python)"` and drag the file into the list. Restart the app after granting.

## 5. Use it

Click into any text field (Notes, browser, Slack, anywhere):

1. Press `ctrl+shift` → the island grows out of the notch (or a capsule appears below the menu bar) and records
2. Speak naturally — ums and uhs are fine, they get removed
3. Press `ctrl+shift` again → your cleaned text is pasted at the cursor

## Customize (edit `config.yaml`, then restart)

- **Hotkey**: `hotkey.key` (e.g. `alt_r`, `ctrl+alt`) — `fn` is not possible on macOS
- **Hold vs toggle**: `hotkey.mode: hold | toggle`
- **LLM**: `llm.model` — another mlx-community repo works too (download it once, restart); the formula reader needs a Qwen3.5 checkpoint with its vision part
- **Accuracy vs speed**: `stt.model: tiny.en | base | small | medium | large-v3`

## Optional: start automatically at login

```bash
# Edit com.riadanas.whisperflow.plist first: replace the two absolute paths with YOUR project path.
# Then install and load it — VoiceBud now starts at every login, no terminal needed.
cp com.riadanas.whisperflow.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.riadanas.whisperflow.plist

# Logs live here if something misbehaves:
tail -f ~/Library/Logs/whisperflow.log
```
