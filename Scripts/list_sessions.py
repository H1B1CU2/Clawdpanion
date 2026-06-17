#!/usr/bin/env python3
"""Emit a JSON array of live Claude Code sessions for the Claw'd menubar app.

Authoritative source = running `claude` processes (one per terminal tab), keyed
by controlling tty. Status (coding/idle) comes from ~/.claude/claw-mascot/
sessions/*.json written by the hooks, matched to a process by tty -> cwd ->
project label. A tty-less session (e.g. an agent run with no terminal) is only
included if its metadata is fresh, so closed/stale sessions don't linger.
"""
import json, os, glob, time, subprocess

BASE = os.path.expanduser("~/.claude/claw-mascot")
SDIR = os.path.join(BASE, "sessions")
HOME = os.path.expanduser("~")
STALE = 6 * 3600          # prune metadata files older than this
FRESH_NO_TTY = 150        # show tty-less session only if updated within this many s


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""


def norm_tty(tn):
    tn = tn.strip()
    if not tn or tn == "??":
        return ""
    return tn if tn.startswith("/dev/") else "/dev/" + tn


def label_for(cwd, sid):
    if cwd == HOME:
        return "~ (home)"
    if cwd:
        return os.path.basename(cwd.rstrip("/")) or cwd
    return (sid[:8] + "…") if sid else "session"


# --- load hook metadata (prune stale files) ---
metas = []
for f in glob.glob(os.path.join(SDIR, "*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if time.time() - float(d.get("updated", 0)) > STALE:
        try:
            os.remove(f)
        except Exception:
            pass
        continue
    d["_label"] = label_for(d.get("cwd", ""), d.get("session_id", ""))
    metas.append(d)


def best_meta(tty, cwd, label, used):
    """Pick the freshest unused metadata matching by tty, then cwd, then label."""
    for key in (
        lambda m: bool(tty) and m.get("tty") == tty,
        lambda m: bool(cwd) and m.get("cwd") == cwd,
        lambda m: m["_label"] == label,
    ):
        cand = [m for m in metas if id(m) not in used and key(m)]
        if cand:
            return max(cand, key=lambda m: m.get("updated", 0))
    return None


# --- running claude processes (authoritative) ---
result = []
used = set()
seen_tty = set()
proc_labels = set()
for pid in [p for p in run(["pgrep", "-x", "claude"]).split() if p.strip()]:
    tty = norm_tty(run(["ps", "-o", "tty=", "-p", pid]))
    if not tty or tty in seen_tty:
        continue
    seen_tty.add(tty)
    cwd = ""
    for line in run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"]).splitlines():
        if line.startswith("n"):
            cwd = line[1:]
            break
    label = label_for(cwd, "")
    m = best_meta(tty, cwd, label, used)
    if m:
        used.add(id(m))
        label = m["_label"]
    proc_labels.add(label)
    result.append({
        "tty": tty,
        "label": label,
        "status": (m or {}).get("status", "idle"),
        "id": (m or {}).get("session_id", ""),
    })

# --- tty-less sessions with no process (e.g. agent runs): only if fresh ---
now = time.time()
for m in metas:
    if id(m) in used or m.get("tty"):
        continue
    if now - float(m.get("updated", 0)) > FRESH_NO_TTY:
        continue
    if m["_label"] in proc_labels:
        continue
    proc_labels.add(m["_label"])
    result.append({
        "tty": "",
        "label": m["_label"],
        "status": m.get("status", "idle"),
        "id": m.get("session_id", ""),
    })

result.sort(key=lambda r: (0 if r["status"] == "coding" else 1, r["label"].lower()))
print(json.dumps(result))
