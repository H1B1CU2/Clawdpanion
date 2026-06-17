#!/bin/bash
# Raises Clawdpanion's hands (attention / done) and — if the optional notifier
# app is installed — posts a clickable banner that focuses the session's tab.
# Usage: notify.sh [attention|done]   (reads hook JSON on stdin)
#
# Self-contained: uses /usr/bin/python3 for JSON (no `jq`), and the marker
# touches happen BEFORE the notifier check so the animations work even without
# the notifier app installed.
base="$HOME/.claude/claw-mascot"
mode="${1:-attention}"

json="$(cat)"
fields="$(printf '%s' "$json" | /usr/bin/python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get('session_id','') or '')
print(d.get('cwd','') or '')
print(d.get('message','') or '')")"
{ IFS= read -r sid; IFS= read -r cwd; IFS= read -r msg; } <<EOF
$fields
EOF

# Raise Claw'd's hands first — independent of whether a notifier is present.
if [ -n "$sid" ]; then
  if [ "$mode" = "done" ]; then
    mkdir -p "$base/done" && touch "$base/done/$sid"
  elif [ -e "$base/active/$sid" ]; then
    # Only wave while Claude is mid-task. The "waiting for your input"
    # notification fires ~a minute after a session goes idle (once Stop has
    # removed the active marker); waving then would leave Claw'd raising a hand
    # while nothing is happening.
    mkdir -p "$base/attention" && touch "$base/attention/$sid"
  fi
fi

# Banner is optional: only if the notifier bundle exists.
notifier="$HOME/.claude/ClaudeNotifierDark.app/Contents/MacOS/terminal-notifier"
[ -x "$notifier" ] || exit 0

if [ "$mode" = "done" ]; then
  default_msg="Task complete"; sound="default"
else
  default_msg="Claude needs your attention"; sound="Ping"
fi
[ -z "$msg" ] && msg="$default_msg"

# session label = project folder (or ~ for home)
if [ -z "$cwd" ] || [ "$cwd" = "$HOME" ]; then label="~"; else label="$(basename "$cwd")"; fi

# Terminal tab to focus on click: hook has no tty, so walk up to the ancestor
# (claude) that owns the controlling terminal.
tty=""
p=$$
for _ in 1 2 3 4 5 6 7 8; do
  [ -z "$p" ] || [ "$p" -le 1 ] 2>/dev/null && break
  tn="$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')"
  if [ -n "$tn" ] && [ "$tn" != "??" ]; then tty="/dev/${tn#/dev/}"; break; fi
  p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
done

args=(-title "Claude Code — $label" -message "$msg" -sound "$sound")
[ -n "$sid" ] && args+=(-group "claw-$sid")
[ -n "$tty" ] && args+=(-execute "/usr/bin/osascript '$base/focus.scpt' '$tty'")

timeout 5 "$notifier" "${args[@]}" >/dev/null 2>&1 || true
exit 0
