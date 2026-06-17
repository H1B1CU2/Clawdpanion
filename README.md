# Clawdpanion

Clawdpanion is a macOS menu bar companion for **Claude Code**. It presents **Claw'd**, a pixel-art mascot that reflects the current state of your Claude Code sessions directly within the system menu bar.

## Overview

Claw'd communicates session activity through a small set of distinct states:

- **Idle** — Remains at rest, with an occasional blink.
- **Coding** — Displays a looping typing animation while a Claude Code session is active.
- **Attention** — Raises a hand when a session is awaiting your input.
- **Done** — Briefly indicates completion when a task finishes.

In addition, Clawdpanion enumerates all active Claude Code sessions in its menu and allows you to bring a session's Terminal tab to the foreground with a single action.

---

## Features

- **State-driven animations** — Procedurally generated pixel-art frames represent each session state (Idle, Coding, Attention, and Done).
- **Idle animation** — A periodic blink while at rest provides a subtle sense of activity.
- **Single and per-session modes**
  - *Single*: A single mascot represents the aggregate state across all sessions.
  - *Per-session*: A dedicated mascot is displayed for each active session.
- **Terminal focus** — A left-click on a session's mascot brings the corresponding Terminal.app tab to the foreground via AppleScript; a right-click (or Control-click) opens the menu.
- **Monochrome theme** — A toggle switches between the standard orange mascot and a monochrome template theme that adapts to light and dark menu bars.
- **Session discovery** — A Python helper scans for running `claude` processes so that the displayed state corresponds to live terminal sessions.

---

## Project Structure

```
.
├── Clawdpanion/
│   ├── main.swift         # AppKit menu bar application logic and UI
│   ├── gen_frames.py      # Procedurally renders the pixel-art frames
│   ├── Frames/            # Pre-generated color and monochrome frame PNGs
│   └── Info.plist         # macOS application configuration
├── Scripts/
│   ├── list_sessions.py   # Discovers running Claude processes and JSON metadata
│   ├── record.sh          # Hook wrapper that writes and clears session markers
│   ├── notify.sh          # Hook wrapper for attention waves and system alerts
│   └── focus.scpt         # AppleScript that focuses a Terminal.app tab by its TTY
├── Clawdpanion.xcodeproj  # Xcode project files
├── install.sh             # End-to-end installer
└── README.md              # Project documentation
```

---

## Installation

Clawdpanion provides a self-contained installer that configures the application end to end.

```sh
./install.sh
```

The installer performs the following steps:

1. Installs the helper scripts to `~/.claude/claw-mascot/`.
2. Builds `Clawdpanion.app` and installs it to `~/Applications/`.
3. Installs and loads a LaunchAgent so that the application starts automatically at login.
4. Idempotently merges the required Claude Code hooks into `~/.claude/settings.json`, retaining a backup at `~/.claude/settings.json.bak`.

After installation, run `/hooks` in any active Claude Code session to reload the configuration so that the session begins reporting activity.

### Requirements

- **macOS** with a **full Xcode installation** (not Command Line Tools alone); required only to build the Swift binary.
- **Python 3**, which is included with the Xcode and macOS developer tools.
- No Homebrew, `jq`, or Pillow dependencies are required to install and run the application.

---

## State Model and Claude Code Hooks

Clawdpanion's state transitions are driven by Claude Code hooks defined in `~/.claude/settings.json`. Each hook writes or clears marker files beneath `~/.claude/claw-mascot/`, which the application polls.

- **`UserPromptSubmit`** runs `record.sh coding`: creates an active marker, clears the attention and done markers, and initiates the typing animation.
- **`PostToolUse`** runs `record.sh resume`: refreshes the active marker and clears the attention marker whenever a tool executes. This ensures the raised hand is lowered as soon as a session resumes — for example, after a mid-task permission prompt is approved.
- **`Notification`** runs `notify.sh attention`: creates an attention marker so that Claw'd signals for input, but only while the session is genuinely mid-task.
- **`Stop`** runs `record.sh idle` and `notify.sh done`: clears the active and attention markers and creates a done marker to trigger a brief completion animation.

The application polls these directories approximately every 0.4 seconds and updates the mascot accordingly.

---

## Regenerating Claw'd's Artwork

All frames are pre-generated PNGs stored in `Clawdpanion/Frames/`. To modify the mascot's appearance, edit `Clawdpanion/gen_frames.py` and regenerate the assets.

Regeneration requires the **Pillow** library:

```sh
pip3 install Pillow
python3 Clawdpanion/gen_frames.py Clawdpanion/Frames
xattr -cr Clawdpanion/Frames   # Removes extended attributes that can interfere with code signing
```

The script produces:

- Standard color frames (orange body, black eyes).
- Monochrome frames (`mono_` prefix), in which the body is a solid grey or black and the eyes are transparent, suitable for use as macOS template images.
- Retina-resolution variants (`@2x.png` suffix) for high-DPI displays.

---

## Building Manually

To build the project from the command line without the installer:

```sh
xcodebuild -project Clawdpanion.xcodeproj -scheme Clawdpanion \
  -configuration Release -derivedDataPath /tmp/clawd_dd build
```

Building to a temporary directory outside the repository is recommended when the workspace resides in a cloud-synced location (such as iCloud Drive), as synchronization attributes can interfere with code signing.
