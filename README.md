# Clawdpanion

A beautifully crafted macOS menubar companion for **Claude Code**.

Clawdpanion shows **Claw'd**, an orange pixel-art mascot in your menu bar, who reacts dynamically to your Claude Code activities:
- **Idle**: Sits quietly, blinking occasionally so he feels alive.
- **Coding**: Plays a looping typing animation while a Claude Code session is active.
- **Attention**: Waves a hand when a session is waiting for your input.
- **Done**: Celebrates with a two-handed triumph dance when a task finishes.

Additionally, Clawdpanion lists all your live Claude Code sessions in its dropdown menu and lets you focus a session's specific Terminal tab with a single click.

---

## Key Features

- **Dynamic Animations**: Hand-crafted pixel-art animations representing different task states (Idle, Coding, Attention, and Done/Celebration).
- **Idle Blinking**: Subtly blinks every few seconds while resting to look natural and alive.
- **Single vs. Per-Session Mode**: 
  - **Single Mascot**: A single Claw'd shows the aggregate state across all sessions.
  - **Per-Session Mascot**: Shows one Claw'd in the menubar for each active Claude session.
- **Interactive Focusing**: Left-clicking a session's mascot immediately focuses its corresponding Terminal.app tab using AppleScript.
- **Monotone Support**: A toggle to switch between the classic orange Claw'd and a macOS native Monotone theme (using template icons that adapt to light/dark menubars).
- **Process Scanner**: Under the hood, a Python script scans for running `claude` processes, ensuring Clawdpanion reflects actual live terminal instances.

---

## Directory & Codebase Structure

```
.
├── Clawdpanion/
│   ├── main.swift         # AppKit menubar application logic & UI
│   ├── gen_frames.py      # Python script to procedurally render pixel-art frames
│   ├── Frames/            # Pre-generated color and monochrome frame PNGs
│   └── Info.plist         # macOS App configuration
├── Scripts/
│   ├── list_sessions.py   # Scans for running Claude processes and JSON metadata
│   ├── record.sh          # Hook wrapper to write/clear session marker files
│   ├── notify.sh          # Hook wrapper to trigger attention waves and system alerts
│   └── focus.scpt         # AppleScript to focus a Terminal.app tab by its TTY
├── Clawdpanion.xcodeproj  # Xcode project files
├── install.sh             # End-to-end installer script
└── README.md              # Project documentation
```

---

## Installation & Setup

Clawdpanion has a self-contained installer script that sets up everything end-to-end.

```sh
./install.sh
```

### What the installer does:
1. Installs the helper scripts to `~/.claude/claw-mascot/`.
2. Builds the `Clawdpanion.app` binary and places it in your `~/Applications/` directory.
3. Installs and loads a LaunchAgent plist so the application automatically starts when you log in.
4. Idempotently merges the necessary Claude Code hooks into your `~/.claude/settings.json` file (saving a backup to `.bak` first).

*Note: After installing, run `/hooks` in any active Claude Code session to ensure it begins reporting activity.*

### Requirements
- **macOS** with a **full Xcode installation** (not just Command Line Tools) — required only for building the Swift binary.
- Python 3 (comes pre-bundled with Xcode/macOS developer tools).
- No Homebrew, `jq`, or Pillow dependencies are needed to install and run the app.

---

## How it works: State & Claude Code Hooks

Clawdpanion's state transitions are driven by standard Claude Code hooks configured in `~/.claude/settings.json`:

- **`UserPromptSubmit`** runs `record.sh coding`:
  - Touches an active marker file in `~/.claude/claw-mascot/active/`.
  - Clears attention and done markers.
  - Instructs Claw'd to start typing.
- **`Stop`** runs `record.sh idle` and `notify.sh done`:
  - Clears the active and attention markers.
  - Touches a done marker in `~/.claude/claw-mascot/done/` to trigger a brief celebration animation.
- **`Notification`** runs `notify.sh attention`:
  - Touches a marker in `~/.claude/claw-mascot/attention/`.
  - Instructs Claw'd to wave for attention (only while the session is actually mid-task).

The main Swift application polls these directories every `0.4` seconds to update the mascot animations accordingly.

---

## Customizing and Regenerating Claw'd Art

All frames are pre-generated PNGs stored in `Clawdpanion/Frames/`. If you want to customize the look of Claw'd, edit `Clawdpanion/gen_frames.py` and run it to regenerate the asset frames.

Regeneration requires the **Pillow** library:

```sh
pip3 install Pillow
python3 Clawdpanion/gen_frames.py Clawdpanion/Frames
xattr -cr Clawdpanion/Frames   # Strips extended attributes so codesign doesn't break
```

The script generates:
- Standard color frames (orange body, black eyes).
- Monotone frames (`mono_` prefix) where the body is solid grey/black and eyes are transparent holes, making them suitable as macOS template images.
- Retina-resolution versions (`@2x.png` suffixes) for high-DPI displays.

---

## Manual Building

To build the project from the command line without using the installer script:

```sh
xcodebuild -project Clawdpanion.xcodeproj -scheme Clawdpanion \
  -configuration Release -derivedDataPath /tmp/clawd_dd build
```

*Note: Building to a temporary directory outside the repository folder is recommended if your workspace lives in a cloud-synced directory (like iCloud Drive), as extended syncing attributes can interfere with code-signing.*
