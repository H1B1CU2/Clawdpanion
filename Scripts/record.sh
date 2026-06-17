#!/bin/bash
# Records Claude Code session metadata for the Clawdpanion menubar app and
# drives the active/done marker dirs it polls.
# Usage: record.sh <status>     where status = coding | idle
# Reads the hook JSON (session_id, cwd) on stdin.
#
# Self-contained: uses /usr/bin/python3 (always present with the Xcode/Command
# Line Tools that build this app) for JSON instead of requiring `jq`.
status="$1"
base="$HOME/.claude/claw-mascot"
adir="$base/active"
sdir="$base/sessions"
attdir="$base/attention"
donedir="$base/done"
mkdir -p "$adir" "$sdir" "$attdir" "$donedir"

json="$(cat)"
fields="$(printf '%s' "$json" | /usr/bin/python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get('session_id','') or '')
print(d.get('cwd','') or '')")"
{ IFS= read -r sid; IFS= read -r cwd; } <<EOF
$fields
EOF
[ -z "$sid" ] && exit 0

# The hook process itself usually has NO controlling terminal, so walk up the
# parent chain (claude spawns the hook) to find the first ancestor that does.
# That tty (e.g. /dev/ttys004) matches Terminal.app's `tty of tab` for focusing.
tty=""
p=$$
for _ in 1 2 3 4 5 6 7 8; do
  [ -z "$p" ] || [ "$p" -le 1 ] 2>/dev/null && break
  tn="$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')"
  if [ -n "$tn" ] && [ "$tn" != "??" ]; then tty="/dev/${tn#/dev/}"; break; fi
  p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
done

now="$(date +%s)"
/usr/bin/python3 -c "import json,sys
obj={'session_id':sys.argv[1],'cwd':sys.argv[2],'tty':sys.argv[3],
     'term_program':sys.argv[4],'term_session_id':sys.argv[5],
     'status':sys.argv[6],'updated':int(sys.argv[7])}
open(sys.argv[8],'w').write(json.dumps(obj))" \
  "$sid" "$cwd" "$tty" "${TERM_PROGRAM:-}" "${TERM_SESSION_ID:-}" "$status" "$now" \
  "$sdir/$sid.json" 2>/dev/null

# Marker state machine:
#   coding:  typing active; clear attention & done
#   idle:    task done; raise done briefly, then nothing
if [ "$status" = "coding" ]; then
  touch "$adir/$sid"
  rm -f "$attdir/$sid" "$donedir/$sid"   # user responded -> hands lowered
else
  rm -f "$adir/$sid" "$attdir/$sid"
  touch "$donedir/$sid"                  # task complete -> brief two-hand "done" pose
fi
exit 0
