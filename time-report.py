#!/usr/bin/env python3
"""time-report.py — where the hours went: Claude working, tools, waiting, you.

Every gap between two consecutive timestamped events of a session is
attributed to whoever was busy during it:

  claude working   prompt / tool result → Claude's next output (incl. thinking)
  tools running    tool call → its result (execution + permission dialogs)
  agents           background agents / workflows running while the main
                   thread waited (their transcripts live under
                   <session-id>/subagents/ and are priced from there)
  waiting on you   AskUserQuestion, plan approval, a declined tool call, or a
                   permission prompt you answered with Esc
  you              Claude finished → your next prompt
  breaks           "you" gaps longer than --break-min — walked away; excluded
                   from active time

Two caveats, repeated under every table: the time you spend answering a
permission dialog stays in "tools running" (the transcript has no event for a
dialog, so it cannot be told apart from the tool's own runtime) — "waiting on
you" therefore counts only questions, plan approval, declined calls and Esc;
and "you" is the bare gap until your next prompt, with nothing recording
whether you were reading, in another session, or away from the desk.

Usage:
  ./time-report.py                         # accumulated time per project
  ./time-report.py --dates                 # per local day, all projects
  ./time-report.py --dates <project>       # per day, one project
  ./time-report.py --sessions <project>    # one row per session
  ./time-report.py --session <id> [-v]     # one session; -v adds a per-turn table
  ./time-report.py --merged                # per merged project (see cct → Merged projects)
  ./time-report.py --merged --dates <name>
  ./time-report.py --merged --sessions <name>

Options:
  --break-min N      any gap above N minutes that waited on you (idle, a
                     question, a pending tool call) is a break (default 30)
  --approve-secs N   an instant tool (Read/Edit/…) slower than N seconds counts
                     as a permission prompt (default 15)
  --day-start H      a "day" runs from H o'clock local to H o'clock next day
                     (default 0; env CCT_DAY_START). With 4, a session that
                     runs 22:15 → 03:40 stays on one date.
  --json             machine-readable output instead of tables

<project> is the project path (~/… or absolute), an unambiguous trailing
segment of it, or its transcript folder (~/.claude/projects/<slug> — pass the
full folder path, a bare slug starts with '-'). Requires python3 only.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cct_lib as L  # noqa: E402

COLS = ("active", "working", "tools", "agents", "waiting", "idle", "breaks")
HEAD = ("active", "working", "tools", "agents", "waiting", "you", "breaks")
def legend(args) -> str:
    """Printed under every table: what each column counts."""
    lines = [
        "  working   Claude generating (thinking included)",
        "  tools     tool calls running, permission dialogs included",
        "  agents    background agents / workflows running while the main thread waited",
        "  waiting   Claude blocked on you: question, plan approval, declined call",
        "  you       from Claude's answer to your next prompt",
        "  active    working + tools + agents + waiting + you",
        f"  breaks    pauses over {args.break_min:g}m while waiting on you; not part of active",
        "",
        "  read with care: answering a permission dialog counts as tools, not",
        "  waiting — the transcript has no event for a dialog, so it cannot be",
        "  told apart from the tool's own runtime, and waiting = 0 does not mean",
        "  you never waited.  you is a gap, not an observation: nothing records",
        "  whether you read the answer, worked in another session, or were away.",
    ]
    if args.day_start:
        lines.append(f"  days start at {int(args.day_start):02d}:00 local")
    return "\n".join(lines)


def durcols(b: L.Buckets) -> str:
    return " ".join(f"{L.fmt_dur(getattr(b, c)):>8}" for c in COLS)


def header_cols() -> str:
    return " ".join(f"{h:>8}" for h in HEAD)


def analyze_one(f, args):
    return L.analyze_session(f, args.break_min * 60, args.approve_secs,
                             day_start_secs=args.day_start * 3600)


def analyze_many(files, args) -> list[L.SessionAnalysis]:
    out = []
    for f in files:
        a = analyze_one(f, args)
        if a and a.buckets.wall > 0:
            out.append(a)
    return out


def sum_buckets(analyses) -> L.Buckets:
    t = L.Buckets()
    for a in analyses:
        t.add(a.buckets)
    return t


def by_date(analyses):
    """date → (Buckets, set of session ids), newest first."""
    acc: dict = defaultdict(lambda: (L.Buckets(), set()))
    for a in analyses:
        for d, b in a.by_date.items():
            acc[d][0].add(b)
            acc[d][1].add(a.id)
    return sorted(acc.items(), reverse=True)


# ---------------------------------------------------------------- printers

def print_table(title: str, rows, args, label_width=44, total_sessions=None):
    """rows: [(label, sessions, Buckets)] already sorted. `total_sessions`
    overrides the summed count when rows overlap (a session spans days)."""
    print(title)
    print("=" * 60)
    print()
    if not rows:
        print("  (no activity recorded)")
        return
    print(f"{'':{label_width}} {'sess':>4} {header_cols()}")
    total = L.Buckets()
    nsess = 0
    for label, n, b in rows:
        print(f"{L.clip_left(label, label_width):{label_width}} {n:>4} {durcols(b)}")
        total.add(b)
        nsess += n
    if total_sessions is not None:
        nsess = total_sessions
    print()
    print(f"{'total':{label_width}} {nsess:>4} {durcols(total)}")
    print()
    print(legend(args))


def print_projects(args):
    projects = L.discover_projects()
    rows = []
    for p in projects:
        an = analyze_many(p.jsonls, args)
        if not an:
            continue
        rows.append((p.label + ("  (gone)" if not p.alive else ""), len(an), sum_buckets(an)))
    rows.sort(key=lambda r: r[2].active, reverse=True)
    if args.json:
        print(json.dumps([{"project": l, "sessions": n, **b.to_json()} for l, n, b in rows], indent=1))
        return
    print_table("Time by project", rows, args)


def print_merged(args):
    groups = L.load_groups()
    if not groups:
        print("No merged projects yet.  cct → Merged projects → New merged project.")
        return
    rows = []
    for g in groups:
        an = analyze_many(L.group_jsonls(g), args)
        rows.append((f"⊕ {g.name}  ({len(L.group_dirs(g))} folders)", len(an), sum_buckets(an)))
    rows.sort(key=lambda r: r[2].active, reverse=True)
    if args.json:
        print(json.dumps([{"group": l, "sessions": n, **b.to_json()} for l, n, b in rows], indent=1))
        return
    print_table("Time by merged project", rows, args)


def print_dates(files, label: str, args):
    an = analyze_many(files, args)
    rows = [(d, len(sids), b) for d, (b, sids) in by_date(an)]
    if args.json:
        print(json.dumps([{"date": d, "sessions": n, **b.to_json()} for d, n, b in rows], indent=1))
        return
    print_table(f"Time by date — {label}", rows, args, label_width=12, total_sessions=len(an))


def print_sessions(files, label: str, args):
    an = analyze_many(files, args)
    an.sort(key=lambda a: a.first or 0, reverse=True)
    if args.json:
        print(json.dumps([{
            "id": a.id, "started": L.fmt_utc(a.first), "ended": L.fmt_utc(a.last),
            "title": a.headline, "prompts": len(a.prompts), **a.buckets.to_json()}
            for a in an], indent=1))
        return
    print(f"Sessions — {label}")
    print("=" * 60)
    print()
    if not an:
        print("  (no activity recorded)")
        return
    print(f"{'started':16} {'id':8} {header_cols()} {'prompts':>7}  title")
    total = L.Buckets()
    for a in an:
        print(f"{L.fmt_local(a.first):16} {a.short_id:8} {durcols(a.buckets)} {len(a.prompts):>7}  "
              f"{a.headline[:40]}")
        total.add(a.buckets)
    print()
    print(f"{'total':16} {len(an):>8} {durcols(total)}")
    print()
    print(legend(args))


def print_session(a: L.SessionAnalysis, args):
    b = a.buckets
    if args.json:
        out = {
            "id": a.id, "title": a.title, "cwd": a.cwd,
            "started": L.fmt_utc(a.first), "ended": L.fmt_utc(a.last),
            "wall": round(b.wall), **b.to_json(),
            "cost_usd": round(a.cost_total, 4), "cost_main_usd": round(a.cost, 4),
            "cost_agents_usd": round(a.cost_agents, 4), "models": dict(a.models),
            "agent_runs": a.agent_runs, "agent_runtime": round(a.agent_runtime),
            "longest_tool": {"name": a.longest_tool[0], "seconds": round(a.longest_tool[1])},
            "turns": [{
                "n": p.n, "ts": L.fmt_utc(p.ts) if p.ts else None,
                "response_seconds": round(p.response_secs) if p.response_secs is not None else None,
                "working_seconds": round(p.working_secs), "tool_calls": sum(p.tools.values()),
                "tools": dict(p.tools), "cost_usd": round(p.cost + p.cost_agents, 4),
                "cost_agents_usd": round(p.cost_agents, 4),
                "interrupted": p.interrupted, "prompt": p.text,
            } for p in a.prompts],
        }
        print(json.dumps(out, indent=1, ensure_ascii=False))
        return

    print(f"session: {a.id}")
    if a.title:
        print(f"title:   {a.title}")
    print(f"project: {L.home_rel(a.cwd)}")
    print(f"started: {L.fmt_local(a.first, True)}  (local time)")
    print(f"ended:   {L.fmt_local(a.last, True)}")
    print(f"wall:    {L.fmt_dur_long(b.wall)}")
    excl = (f"   ({b.breaks_n} break(s) > {args.break_min:g}m excluded: {L.fmt_dur_long(b.breaks)})"
            if b.breaks_n else "")
    print(f"active:  {L.fmt_dur_long(b.active)}{excl}")
    print()

    act = b.active or 1.0
    mx = max(b.working, b.tools, b.agents, b.waiting, b.idle, 1.0)

    def line(label, secs, note=""):
        pct = 100.0 * secs / act
        print(f"  {label:24} {L.fmt_dur_long(secs):>12}  {pct:3.0f}%  {L.bar(secs, mx)}  {note}".rstrip())

    line("claude working", b.working)
    if a.has_block_events and b.thinking:
        print(f"    of which thinking      {L.fmt_dur_long(b.thinking):>12}")
    line("tools running", b.tools, "execution + permission dialogs, inseparable")
    if b.approval_n:
        print(f"    likely permission prompts {L.fmt_dur_long(b.approval):>9}  ({b.approval_n} instant tool(s) > {args.approve_secs}s)")
    if a.agent_runs:
        line("background agents", b.agents, "workflows / Agent tool while the main thread waited")
        print(f"    {a.agent_runs} run(s), {L.fmt_dur_long(a.agent_runtime)} of agent time in total, ${a.cost_agents:.2f}")
    line("waiting on you", b.waiting, "questions / plan approval / declined prompts only")
    line("you (gap to next prompt)", b.idle, "not observed — see the note below")
    print()

    rt = a.response_times
    if rt:
        print(f"turns:         {len(a.prompts)} prompts   claude reply: median {L.fmt_dur_long(statistics.median(rt))}"
              f" · max {L.fmt_dur_long(max(rt))}")
    else:
        print(f"turns:         {len(a.prompts)} prompts")
    if a.longest_tool[0]:
        print(f"longest tool:  {a.longest_tool[0]} {L.fmt_dur_long(a.longest_tool[1])}")
    models = ", ".join(sorted(a.models))
    agents = f" = ${a.cost:.2f} main + ${a.cost_agents:.2f} agents" if a.agent_runs else ""
    print(f"cost:          ${a.cost_total:.2f} (list prices){agents}   models: {models or '?'}")

    if args.verbose and a.prompts:
        print()
        print(f"{'#':>3}  {'prompt (local)':16} {'reply':>8} {'working':>8} {'tools':>5} {'cost':>7}  prompt")
        for p in a.prompts:
            when = L.fmt_local(p.ts) if p.ts else "?"
            reply = L.fmt_dur(p.response_secs) if p.response_secs is not None else "-"
            flag = " ⏎" if p.interrupted else ""
            text = p.text.split("\n", 1)[0]
            print(f"{p.n:>3}  {when:16} {reply:>8} {L.fmt_dur(p.working_secs):>8} {sum(p.tools.values()):>5}"
                  f" ${p.cost + p.cost_agents:6.2f}  {text[:44]}{flag}")
    print()
    print("  Times come from event timestamps, and two of these numbers are weaker")
    print("  than they look:")
    print("   · the seconds you spend answering a permission dialog are inside")
    print("     \"tools running\".  The transcript writes no event for a dialog, only")
    print("     the tool call and its result, so the dialog cannot be told apart from")
    print("     the tool's own runtime — for Bash and other slow tools not at all.")
    print("     \"waiting on you\" counts only questions, plan approval, declined calls")
    print("     and Esc, so a 0 there does not mean you never waited.")
    print("   · \"you\" is the bare gap until your next prompt.  Nothing records whether")
    print("     you read the answer, worked in another session, or left the desk; only")
    print(f"     gaps over {args.break_min:g}m drop out of active time as breaks.")
    print("  (background agents are priced from their own transcripts)")


# ---------------------------------------------------------------- main

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("-h", "--help", action="store_true")
    ap.add_argument("--dates", nargs="?", const="", default=None)
    ap.add_argument("--sessions", default=None)
    ap.add_argument("--session", default=None)
    ap.add_argument("--merged", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--break-min", type=float, default=L.DEFAULT_BREAK_SECS / 60)
    ap.add_argument("--approve-secs", type=float, default=L.DEFAULT_APPROVE_SECS)
    ap.add_argument("--day-start", type=float,
                    default=float(os.environ.get("CCT_DAY_START") or 0))
    try:
        args = ap.parse_args(argv)
    except SystemExit:
        return 2
    if args.help:
        print(__doc__.strip())
        return 0
    if not (0 <= args.day_start < 24):
        print("--day-start must be an hour from 0 to 23", file=sys.stderr)
        return 2

    try:
        if args.session:
            a = analyze_one(L.find_session(args.session), args)
            if a is None:
                print("empty transcript", file=sys.stderr)
                return 1
            print_session(a, args)
            return 0

        if args.merged:
            groups = L.load_groups()
            target = args.sessions if args.sessions is not None else args.dates
            if target:
                g = L.resolve_group(target, groups)
                files = L.group_jsonls(g)
                label = f"⊕ {g.name}"
                if args.sessions is not None:
                    print_sessions(files, label, args)
                else:
                    print_dates(files, label, args)
            elif args.dates == "" or args.sessions == "":
                print("--merged --dates / --sessions need a merged project name", file=sys.stderr)
                return 2
            else:
                print_merged(args)
            return 0

        projects = L.discover_projects()
        if args.sessions is not None:
            p = L.resolve_project(args.sessions, projects)
            print_sessions(p.jsonls, p.label, args)
        elif args.dates is not None:
            if args.dates == "":
                files = [f for p in projects for f in p.jsonls]
                print_dates(files, "all projects", args)
            else:
                p = L.resolve_project(args.dates, projects)
                print_dates(p.jsonls, p.label, args)
        else:
            print_projects(args)
        return 0
    except L.ResolveError as e:
        print(e, file=sys.stderr)
        if e.candidates:
            print("Candidates:", file=sys.stderr)
            for c in e.candidates:
                print(f"  {c}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
