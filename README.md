# VoiceBud

Fully offline voice dictation for macOS (Apple Silicon) — a free, local alternative to Wispr Flow.

Press `ctrl+shift` in any app → speak → press again → clean text appears at your cursor. Speech-to-text runs on-device (Whisper large-v3-turbo via MLX), and the structuring (fillers, self-corrections, lists, paragraphs, punctuation) runs through a local LLM (Qwen3.5-4B via MLX). No cloud, no subscription, no audio leaving your Mac.

- **Want to run it?** Follow [reproduce.md](reproduce.md) — setup in ~10 minutes.
- **Want to build it yourself with AI?** [steps.md](steps.md) has the exact Claude Code prompts that created this app.

Built with Claude Code (planned with Opus 4.8, built with Fable 5).
