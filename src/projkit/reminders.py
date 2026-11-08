"""Apple Reminders bridge for the CLI and web UI (macOS only): creates a reminder in the
"Projects Tasks" list through the Reminders app (JavaScript for Automation via `osascript`).
The apps use EventKit instead (ios/App/Reminders.swift); both use the same list name.

The first run asks for permission to control Reminders (System Settings › Privacy & Security ›
Automation). Recording the reminder in the task is `ops.set_task_reminder`.
"""
from __future__ import annotations

import datetime as dt
import subprocess
import sys

from .project import ProjectError

REMINDER_LIST = "Projects Tasks"

# argv: list name, title, notes, ISO local time "YYYY-MM-DDTHH:MM" (passed as data, never spliced into code).
_JXA = r"""
function run(argv) {
  const [listName, title, notes, when] = argv;
  const app = Application("Reminders");
  let list = app.lists.whose({name: listName})();
  if (list.length) { list = list[0]; } else { list = app.List({name: listName}); app.lists.push(list); }
  const [d, t] = when.split("T"); const [y, mo, da] = d.split("-").map(Number); const [h, mi] = t.split(":").map(Number);
  const date = new Date(y, mo - 1, da, h, mi, 0);
  const props = {name: title, dueDate: date, remindMeDate: date};
  if (notes) props.body = notes;
  const r = app.Reminder(props);
  list.reminders.push(r);
  return r.id();
}
"""


class ReminderError(ProjectError):
    pass


def parse_when(raw: str) -> str:
    """Normalises "YYYY-MM-DD HH:MM" / "YYYY-MM-DDTHH:MM" (or just a date, 09:00) to "YYYY-MM-DDTHH:MM"."""
    raw = raw.strip().replace(" ", "T", 1)
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            d = dt.datetime.strptime(raw, fmt)
        except ValueError:
            continue
        if fmt == "%Y-%m-%d":
            d = d.replace(hour=9)
        return d.strftime("%Y-%m-%dT%H:%M")
    raise ReminderError(f"can't read '{raw}' as a date and time (use YYYY-MM-DD HH:MM)")


def create_reminder(title: str, when: str, notes: str = "") -> str:
    """Creates the reminder; returns its Reminders id. `when` is local "YYYY-MM-DDTHH:MM"."""
    title = " ".join(title.split())
    if not title:
        raise ReminderError("reminder text is empty")
    when = parse_when(when)
    if sys.platform != "darwin":
        raise ReminderError("Apple Reminders is only available on macOS")
    try:
        out = subprocess.run(["osascript", "-l", "JavaScript", "-e", _JXA, REMINDER_LIST, title, notes, when],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ReminderError(f"couldn't reach Reminders: {e}") from e
    if out.returncode != 0:
        msg = out.stderr.strip() or "unknown error"
        if "-1743" in msg or "not allowed" in msg.lower():
            msg = "not allowed to control Reminders (System Settings › Privacy & Security › Automation)"
        raise ReminderError(f"couldn't create the reminder: {msg}")
    return out.stdout.strip()


def reminder_label(when: str | None) -> str:
    """Short display form of a recorded reminder time: "Tue Nov 10, 09:00" (year added when not this year)."""
    if not when:
        return ""
    try:
        d = dt.datetime.strptime(when, "%Y-%m-%dT%H:%M")
    except ValueError:
        return when
    day = d.strftime("%a %b ") + str(d.day) + (f" {d.year}" if d.year != dt.date.today().year else "")
    return f"{day}, {d:%H:%M}"


def schedule_task_reminder(p, ref: str, when: str, text: str | None = None) -> dict:
    """Creates an Apple Reminder for task `ref` of project `p` (text defaults to the task's text, notes name
    the project), then records it in the task. Returns the task."""
    from . import ops
    t = p.tasks[ops._task_index(p, ref)]
    when = parse_when(when)
    create_reminder(text if text and text.strip() else t["text"], when, notes=f"Project: {p.title}")
    return ops.set_task_reminder(p, ref, when)
