#!/usr/bin/env python3
"""Regenerate the screenshots in docs/images.

    python shots.py                 # list the catalogue
    python shots.py menu status     # render those shots
    python shots.py --all
    python shots.py --dry time-by-project    # capture and print the screen, render nothing

Every shot is one walk through the real TUI: keystrokes in, one screen out.
What the screen shows is your own data, so RULES below decide which cell ranges
are private; those ranges are replaced with filler letters and blurred before
the PNG is written (see shoot.render).

Two shots depend on which sessions exist on this machine:
CCT_SHOT_PROJECT and CCT_SHOT_SESSION are typed into the picker's `/` filter
(empty = take the top row). Pick a session with background agents and a dozen
turns, and set CCT_EXPORT_DIR to a scratch folder before running `export-prompts`
— it writes files for real.
"""
import os, re, sys

from shoot import Term, render

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(ROOT, "docs", "images")
CCT = os.path.join(ROOT, "cct")
PROJECT_FILTER = os.environ.get("CCT_SHOT_PROJECT", "")
SESSION_FILTER = os.environ.get("CCT_SHOT_SESSION", "")

# ---------- what counts as private -------------------------------------------
# (regex over one screen line, group number) — the group's cells get blurred.
RULES = [
    (re.compile(r"~/projects/(\S+)"), 1),                      # project path tail
    (re.compile(r"(/Users/[^\s\)\]]+)"), 1),                   # absolute path
    (re.compile(r"…(\S+)"), 1),                                # left-truncated path
    (re.compile(r"(-Users-\S+)"), 1),                          # raw project slug
    (re.compile(r"~/cct-export/([^/\s]+)"), 1),                # export folder
    (re.compile(r"\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"), 1),
    (re.compile(r"\b([0-9a-f]{8})\b"), 1),                     # short session id
    (re.compile(r"\d{4}-\d{2}-\d{2}_\d{4}_([0-9a-f]{8})\."), 1),   # …in an export file name
    (re.compile(r"([0-9a-f][0-9a-f-]{3,}\.jsonl)"), 1),        # transcript file name
    (re.compile(r"\d+ msgs\s+(\S.*?)\s*$"), 1),                # title in the picker
    (re.compile(r"· [0-9a-f]{8} · (.+?)\s*$"), 1),             # title in a view header
    (re.compile(r"→ \d\d-\d\d \d\d:\d\d\s+\|\s+(\S.*?)\s*$"), 1),   # action-menu subtitle
    (re.compile(r"^title:\s+(\S.*?)\s*$"), 1),
    (re.compile(r"^Exporting:\s+(\S.*?)\s*$"), 1),
    (re.compile(r"Export prompts · (.+?)\s*$"), 1),
    (re.compile(r"^⊕ (.+?)\s\s+\("), 1),                       # merged project name
    (re.compile(r"^\s*\d+\s+\d{4}-\d{2}-\d{2} \d\d:\d\d.*?\$\s*[\d.]+\s\s+(\S.*?)\s*$"), 1),
    # ^ per-turn table: the first line of your prompt
]


def boxes(lines):
    out = []
    for y, line in enumerate(lines):
        for rx, g in RULES:
            for m in rx.finditer(line):
                x0, x1 = m.span(g)
                if x1 > x0:
                    out.append((y, x0, x1))
    return out


# ---------- the catalogue ----------------------------------------------------
# keys: a name from shoot.KEYS, literal text to type, or a number = wait that long.
# Digits jump straight to a menu row, "/" opens the filter, "v" toggles the
# extended view. rows = terminal height = image height; size it so the footer
# lands one or two lines above the bottom edge.
SHOTS = {
    "menu":        dict(keys=["9"], cols=100, rows=23),
    "status":      dict(keys=["1", "enter"], rows=34),
    "sessions":    dict(keys=["3", "enter"], rows=34),
    "session-stats": dict(keys=["3", "enter", 4.0, "/" + SESSION_FILTER, 1.5,
                                "enter", 2.0, "1", "enter"], rows=52),
    "cost-report-extended": dict(keys=["5", "enter", 6.0, "v"], rows=40),
    "cost-by-project":      dict(keys=["7", "enter", 6.0], rows=30),
    "project-daily-extended": dict(keys=["7", "enter", 6.0, "enter", 6.0, "v"], rows=40),
    "merged-projects":  dict(keys=["8", "enter", 1.5, "down", "enter", 4.0, "v"], rows=22),
    # The time views carry a five-line "read with care" note under every table
    # and a longer one under the single-session view — hence the tall rows.
    "time-by-project":  dict(keys=["9", "enter", 2.0, "enter"], rows=48, settle=10.0),
    "time-by-date":     dict(keys=["9", "enter", 2.0, "enter", 10.0, "v"], rows=48, settle=10.0),
    "time-session": dict(keys=["3", "enter", 4.0, "/" + SESSION_FILTER, 1.5,
                               "enter", 2.0, "2", "enter"], rows=41, settle=10.0),
    "time-session-turns": dict(keys=["3", "enter", 4.0, "/" + SESSION_FILTER, 1.5,
                                     "enter", 2.0, "2", "enter", 10.0, "v"],
                               rows=53, settle=10.0),
    "export-prompts": dict(keys=["10", 1.5, "enter", 4.0, "/" + PROJECT_FILTER, 1.5,
                                 "enter", 2.0, "enter", 2.0, "enter"], rows=20, settle=8.0),
}


def shoot(name, dry=False):
    spec = SHOTS[name]
    t = Term([CCT], ROOT, spec.get("cols", 118), spec["rows"])
    t.pump(spec.get("boot", 2.0))
    for k in spec["keys"]:
        t.send(k, spec.get("step", 0.8))
    t.pump(spec.get("settle", 6.0))
    lines = t.lines()
    for y, line in enumerate(lines):
        print(f"{y:3d}|{line.rstrip()}")
    if not dry:
        path = os.path.join(OUT, name + ".png")
        w, h = render(t, path, boxes(lines))
        print(f"{name}: {w}x{h} -> {path}")
    t.close()


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry" in sys.argv
    if "--all" in sys.argv:
        args = list(SHOTS)
    if not args:
        print(__doc__)
        print("shots:", ", ".join(SHOTS))
        sys.exit(0)
    for name in args:
        shoot(name, dry)
