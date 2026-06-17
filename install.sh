#!/bin/bash
# Clawdpanion installer — makes the menubar mascot work end-to-end on a fresh
# Mac. Idempotent: safe to re-run.
#
#   1. installs the helper scripts into ~/.claude/claw-mascot/
#   2. builds Clawdpanion.app and installs it to ~/Applications/
#   3. installs + loads a LaunchAgent (autostart at login, manual Quit sticks)
#   4. merges the Claude Code hooks into ~/.claude/settings.json
#
# Requirements: a full Xcode install (not just Command Line Tools) and the
# python3 that ships with it. No Homebrew, no `jq`, no Pillow needed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CLAW="$HOME/.claude/claw-mascot"
APPDIR="$HOME/Applications"
PLIST="$HOME/Library/LaunchAgents/com.claudecode.clawdmascot.plist"
APP_NAME="Clawdpanion.app"

echo "==> 1/4  Installing helper scripts to $CLAW"
mkdir -p "$CLAW/active" "$CLAW/attention" "$CLAW/done" "$CLAW/sessions"
cp "$REPO/Scripts/record.sh" "$REPO/Scripts/notify.sh" \
   "$REPO/Scripts/list_sessions.py" "$REPO/Scripts/focus.scpt" "$CLAW/"
chmod +x "$CLAW/record.sh" "$CLAW/notify.sh"

echo "==> 2/4  Building $APP_NAME"
DEV="$(xcode-select -p 2>/dev/null || true)"
if [ "${DEV%/}" = "/Library/Developer/CommandLineTools" ] || [ -z "$DEV" ]; then
  if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "ERROR: full Xcode is required to build (only Command Line Tools found)." >&2
    echo "Install Xcode from the App Store, or run: sudo xcode-select -s /path/to/Xcode.app" >&2
    exit 1
  fi
fi
# Build to a temp DerivedData OUTSIDE this folder: if the repo lives in a
# cloud-synced dir (iCloud Drive), its extended attributes break codesign.
DD="$(mktemp -d)"
xcodebuild -project "$REPO/Clawdpanion.xcodeproj" -scheme Clawdpanion \
  -configuration Release -derivedDataPath "$DD" build >/dev/null
BUILT="$DD/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || { echo "ERROR: build produced no app at $BUILT" >&2; exit 1; }

echo "==> 2/4  Installing to $APPDIR/$APP_NAME"
mkdir -p "$APPDIR"
# Stop a running instance so we can replace the bundle cleanly.
launchctl bootout "gui/$(id -u)/com.claudecode.clawdmascot" 2>/dev/null || true
rm -rf "$APPDIR/$APP_NAME"
ditto "$BUILT" "$APPDIR/$APP_NAME"
rm -rf "$DD"

echo "==> 3/4  Installing + loading LaunchAgent"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudecode.clawdmascot</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APPDIR/$APP_NAME/Contents/MacOS/Clawdpanion</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLISTEOF
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || \
  launchctl kickstart -k "gui/$(id -u)/com.claudecode.clawdmascot" 2>/dev/null || true

echo "==> 4/4  Merging hooks into ~/.claude/settings.json"
/usr/bin/python3 - <<'PYEOF'
import json, os, shutil
path = os.path.expanduser("~/.claude/settings.json")
data = {}
if os.path.exists(path):
    shutil.copy(path, path + ".bak")
    try:
        with open(path) as f: data = json.load(f)
    except Exception:
        data = {}
hooks = data.setdefault("hooks", {})
managed = [
    ("UserPromptSubmit", 'record.sh" coding'),
    ("PostToolUse",      'record.sh" resume'),
    ("Stop",             'notify.sh" done'),
    ("Stop",             'record.sh" idle'),
    ("Notification",     'notify.sh" attention'),
]
cmd_for = {
    'record.sh" coding':  'bash "$HOME/.claude/claw-mascot/record.sh" coding',
    'record.sh" resume':  'bash "$HOME/.claude/claw-mascot/record.sh" resume',
    'notify.sh" done':    'bash "$HOME/.claude/claw-mascot/notify.sh" done',
    'record.sh" idle':    'bash "$HOME/.claude/claw-mascot/record.sh" idle',
    'notify.sh" attention':'bash "$HOME/.claude/claw-mascot/notify.sh" attention',
}
added = 0
for event, marker in managed:
    groups = hooks.setdefault(event, [])
    exists = any(marker in h.get("command", "")
                 for g in groups for h in g.get("hooks", []))
    if exists:
        continue
    # reuse a group with matcher "*" (or no matcher) if present, else make one
    group = next((g for g in groups if g.get("matcher", "*") == "*"), None)
    if group is None:
        group = {"matcher": "*", "hooks": []}
        groups.append(group)
    group.setdefault("hooks", []).append({"type": "command", "command": cmd_for[marker]})
    added += 1
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f"    {added} hook(s) added ({'backup at '+path+'.bak' if os.path.exists(path+'.bak') else 'new file'})")
PYEOF

echo
echo "Done. Claw'd is installed and running in your menubar."
echo "  • Reload hooks in any open Claude Code session (/hooks) so it starts reporting."
echo "  • First time you click a session in the menu, macOS will ask to allow"
echo "    controlling Terminal — approve it for tab-focusing to work."
echo "  • Desktop banners are optional and need ~/.claude/ClaudeNotifierDark.app;"
echo "    without it, Claw'd still animates (waves / celebrates) — just no banners."
