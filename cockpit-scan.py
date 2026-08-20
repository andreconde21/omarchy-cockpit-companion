#!/usr/bin/env python3
"""Cockpit companion vault scanner (READ-ONLY).

Scans the Obsidian Cockpit vault's Tasks/Active folder — one file per task
with YAML frontmatter (title/status/due/time/project/labels, plus the
cockpit-board plugin's `pomodoros` completed-count and `time_spent` minutes)
— and prints a single JSON document on stdout for the Quickshell panel.

Usage: cockpit-scan.py [vault-dir] [checklist-patterns]
  vault-dir           vault root (default $COCKPIT_VAULT or ~/Obsidian)
  checklist-patterns  comma-separated filename glob patterns, relative to
                      Tasks/Active (".md" is appended to a pattern that does
                      not already end in ".md"); each contributes one
                      checklist meter. Empty/missing → no meters.

Emits:
  today         ISO date the scan ran on
  overdue       overdue tasks (capped), overdueCount = true total
  todayTasks    tasks due today
  agenda        {"YYYY-MM-DD": [task, ...]} for every dated open task,
                in cockpit-board card order — feeds the schedule + day list
  followups     [{"label", "open", "done", "file"}, ...] — one checkbox
                progress meter per configured pattern (newest-mtime match)
  pomodoro      cockpit-board's own pomodoro settings (work/short/long/interval)
                read from .obsidian/plugins/cockpit-board/data.json

Each task: title, due, time, project, file, order (int or null), pomodoros,
timeSpent, body (markdown stripped to plain text, truncated).

This script NEVER writes to the vault. It only reads files.
"""

import datetime
import glob
import json
import os
import re
import sys

DEFAULT_VAULT = "~/Obsidian"
VAULT = os.path.expanduser(
    sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].strip() else os.environ.get("COCKPIT_VAULT", DEFAULT_VAULT)
)
ACTIVE = os.path.join(VAULT, "Tasks", "Active")
CHECKLIST_PATTERNS = sys.argv[2] if len(sys.argv) > 2 else ""
BOARD_DATA = os.path.join(VAULT, ".obsidian", "plugins", "cockpit-board", "data.json")

FM_RE = re.compile(r"^---\r?\n(.*?)\r?\n---\r?\n?", re.S)
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

OVERDUE_CAP = 15
AGENDA_DAY_CAP = 12
BODY_CAP = 600


def fm_value(frontmatter, key):
    m = re.search(r"^%s:[ \t]*(.*)$" % re.escape(key), frontmatter, re.M)
    if not m:
        return ""
    return m.group(1).strip().strip('"').strip("'")


def fm_int(frontmatter, key):
    raw = fm_value(frontmatter, key)
    try:
        return int(float(raw))
    except (TypeError, ValueError):
        return 0


def fm_order(frontmatter):
    """Board card `order:` — None when absent (absent sorts after present)."""
    m = re.search(r"^order:\s*(\d+)", frontmatter, re.M)
    return int(m.group(1)) if m else None


def strip_markdown(body, title):
    """Reduce markdown body to readable plain text, truncated to BODY_CAP."""
    lines = []
    in_code = False
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            lines.append(line.rstrip())
            continue
        # Drop a leading heading that merely repeats the title.
        m = re.match(r"^#{1,6}\s+(.*)$", stripped)
        if m:
            if m.group(1).strip() == title.strip():
                continue
            stripped = m.group(1).strip()
        # Checkboxes become glyphs, bullets stay readable.
        stripped = re.sub(r"^[-*+]\s+\[[xX]\]\s*", "☑ ", stripped)
        stripped = re.sub(r"^[-*+]\s+\[ \]\s*", "☐ ", stripped)
        stripped = re.sub(r"^[-*+]\s+", "• ", stripped)
        # Inline markdown: images, links, emphasis, code.
        stripped = re.sub(r"!\[\[([^\]]*)\]\]", "", stripped)          # embeds
        stripped = re.sub(r"\[\[([^\]|]*)\|?([^\]]*)\]\]", lambda m: m.group(2) or m.group(1), stripped)
        stripped = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", stripped)       # images
        stripped = re.sub(r"\[([^\]]+)\]\(([^)]*)\)", r"\1", stripped)  # links
        stripped = re.sub(r"(\*\*|__)(.*?)\1", r"\2", stripped)
        stripped = re.sub(r"(\*|_)(.*?)\1", r"\2", stripped)
        stripped = re.sub(r"`([^`]*)`", r"\1", stripped)
        stripped = re.sub(r"^>\s?", "", stripped)                       # quotes
        lines.append(stripped)

    # Collapse runs of blank lines and trim.
    out, blank = [], True
    for ln in lines:
        if ln == "":
            if not blank:
                out.append("")
            blank = True
        else:
            out.append(ln)
            blank = False
    text = "\n".join(out).strip()

    if len(text) > BODY_CAP:
        cut = text[:BODY_CAP]
        # Prefer to break at the last line/word boundary.
        brk = max(cut.rfind("\n"), cut.rfind(" "))
        if brk > BODY_CAP * 0.6:
            cut = cut[:brk]
        text = cut.rstrip() + " …"
    return text


def pomodoro_settings():
    """cockpit-board's own pomodoro config, so both timers agree (read-only)."""
    defaults = {"enabled": True, "work": 25, "shortBreak": 5, "longBreak": 15, "longBreakInterval": 4}
    try:
        with open(BOARD_DATA, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return defaults
    return {
        "enabled": bool(data.get("pomodoroEnabled", defaults["enabled"])),
        "work": int(data.get("pomodoroWork", defaults["work"]) or defaults["work"]),
        "shortBreak": int(data.get("pomodoroShortBreak", defaults["shortBreak"]) or defaults["shortBreak"]),
        "longBreak": int(data.get("pomodoroLongBreak", defaults["longBreak"]) or defaults["longBreak"]),
        "longBreakInterval": int(data.get("pomodoroLongBreakInterval", defaults["longBreakInterval"])
                                 or defaults["longBreakInterval"]),
    }


def scan():
    today = datetime.date.today()
    overdue, today_tasks = [], []
    agenda = {}

    for path in glob.glob(os.path.join(ACTIVE, "*.md")):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read(32768)
        except OSError:
            continue
        m = FM_RE.match(text)
        if not m:
            continue
        fm = m.group(1)
        status = fm_value(fm, "status")
        if status == "done":
            continue
        due = fm_value(fm, "due")
        if not DATE_RE.match(due):
            continue
        try:
            due_date = datetime.date.fromisoformat(due)
        except ValueError:
            continue

        title = fm_value(fm, "title") or os.path.splitext(os.path.basename(path))[0]
        task = {
            "title": title,
            "due": due,
            "time": fm_value(fm, "time"),
            "project": fm_value(fm, "project"),
            "file": os.path.basename(path),
            "order": fm_order(fm),
            "pomodoros": fm_int(fm, "pomodoros"),
            "timeSpent": fm_int(fm, "time_spent"),
            "body": strip_markdown(text[m.end():], title),
        }
        agenda.setdefault(due, []).append(task)
        if due_date < today:
            overdue.append(task)
        elif due_date == today:
            today_tasks.append(task)

    # Mirror the cockpit-board plugin's custom card order within a date
    # column: `order:` ascending with ordered tasks before unordered ones,
    # then the "[project] title" display string.
    def board_key(t):
        display = ("[%s] %s" % (t["project"], t["title"])) if t["project"] else t["title"]
        return (t["order"] is None, t["order"] if t["order"] is not None else 0, display)

    for day in agenda:
        agenda[day].sort(key=board_key)
        agenda[day] = agenda[day][:AGENDA_DAY_CAP]
    overdue.sort(key=lambda t: (t["due"],) + board_key(t))
    today_tasks.sort(key=board_key)

    return {
        "today": today.isoformat(),
        "overdueCount": len(overdue),
        "todayCount": len(today_tasks),
        "overdue": overdue[:OVERDUE_CAP],
        "todayTasks": today_tasks,
        "agenda": agenda,
        "followups": checklist_meters(CHECKLIST_PATTERNS),
        "pomodoro": pomodoro_settings(),
    }


def checklist_meters(patterns_arg):
    """One checkbox-progress meter per configured filename pattern.

    Each comma-separated pattern (relative to Tasks/Active, ".md" appended
    when missing) contributes its newest-mtime match: frontmatter `title`
    (filename stem fallback) plus open/done checkbox counts over the whole
    file. Patterns with no match — or whose file has no checkboxes at all —
    are skipped, and a file matched by two patterns appears only once
    (first pattern wins).
    """
    meters, seen = [], set()
    for raw in patterns_arg.split(","):
        pattern = raw.strip()
        if not pattern:
            continue
        if not pattern.endswith(".md"):
            pattern += ".md"
        candidates = glob.glob(os.path.join(ACTIVE, pattern))
        if not candidates:
            continue
        path = max(candidates, key=os.path.getmtime)
        if path in seen:
            continue
        seen.add(path)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        open_count = len(re.findall(r"^\s*[-*] \[ \]", text, re.M))
        done_count = len(re.findall(r"^\s*[-*] \[[xX]\]", text, re.M))
        if open_count + done_count == 0:
            continue
        m = FM_RE.match(text)
        title = (fm_value(m.group(1), "title") if m else "") \
            or os.path.splitext(os.path.basename(path))[0]
        meters.append({"label": title, "open": open_count, "done": done_count,
                       "file": os.path.basename(path),
                       "body": strip_markdown(text[m.end():] if m else text, title)})
    return meters


if __name__ == "__main__":
    try:
        print(json.dumps(scan()))
    except Exception as exc:  # never crash the panel; emit an error record
        print(json.dumps({"error": str(exc)}))
        sys.exit(0)
