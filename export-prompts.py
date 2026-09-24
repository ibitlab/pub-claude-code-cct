#!/usr/bin/env python3
"""export-prompts.py — write the prompts you typed in a project's sessions to files.

Default: one plain-text file per session, named after the session's local
start time plus its short id — 2026-04-17_1526_5d35e607.txt — each prompt
verbatim under a timestamped header.

--json: everything in one JSON file instead, with per-prompt properties for
your own analytics: timestamp (UTC + local), text size, how long Claude took
to reply, working seconds, tool calls by name, estimated cost, models,
whether you interrupted it; plus per-session time buckets and totals.

Usage:
  ./export-prompts.py <project> [-o DIR] [--json]
  ./export-prompts.py --merged <name> [-o DIR] [--json]
  ./export-prompts.py --session <id> [-o DIR] [--json]

Output directory defaults to $CCT_EXPORT_DIR/<project name> or
~/cct-export/<project name>. Nothing is ever overwritten: if any target file
already exists the export stops before writing and lists the files in the way
— pick another folder, or move the old files yourself.

<project> is the project path (~/… or absolute), an unambiguous trailing
segment of it, or its transcript folder (~/.claude/projects/<slug> — pass the
full folder path, a bare slug starts with '-'). Requires python3 only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cct_lib as L  # noqa: E402

SCHEMA = "cct-prompts/1"


def tz_label() -> str:
    off = datetime.now().astimezone().strftime("%z")
    return f"UTC{off[:3]}:{off[3:]}" if off else "local"


def prompt_json(p: L.Prompt) -> dict:
    return {
        "n": p.n,
        "ts": L.fmt_utc(p.ts) if p.ts else None,
        "local": L.fmt_local(p.ts, True) if p.ts else None,
        "ts_approx": p.ts_approx,
        "text": p.text,
        "chars": len(p.text),
        "words": len(p.text.split()),
        "lines": p.text.count("\n") + 1,
        "response_seconds": round(p.response_secs) if p.response_secs is not None else None,
        "working_seconds": round(p.working_secs),
        "tool_calls": sum(p.tools.values()),
        "tools": dict(p.tools),
        "cost_usd": round(p.cost, 4),
        "models": sorted(p.models),
        "interrupted": p.interrupted,
    }


def session_json(a: L.SessionAnalysis) -> dict:
    return {
        "id": a.id,
        "short_id": a.short_id,
        "title": a.title,
        "slug": a.slug,
        "cwd": a.cwd,
        "started": L.fmt_utc(a.first),
        "ended": L.fmt_utc(a.last),
        "started_local": L.fmt_local(a.first, True),
        "ended_local": L.fmt_local(a.last, True),
        "prompt_count": len(a.prompts),
        "cost_usd": round(a.cost, 4),
        "models": dict(a.models),
        "time": {"wall": round(a.buckets.wall), **a.buckets.to_json()},
        "prompts": [prompt_json(p) for p in a.prompts],
    }


def session_text(a: L.SessionAnalysis) -> str:
    lines = [
        f"session:  {a.id}",
        f"title:    {a.title or '-'}",
        f"project:  {L.home_rel(a.cwd)}",
        f"started:  {L.fmt_local(a.first, True)}  ({tz_label()})",
        f"ended:    {L.fmt_local(a.last, True)}",
        f"prompts:  {len(a.prompts)}",
        "",
    ]
    for p in a.prompts:
        when = (L.fmt_local(p.ts, True) + ("~" if p.ts_approx else "")) if p.ts else "?"
        bits = []
        if p.response_secs is not None:
            bits.append(f"reply {L.fmt_dur(p.response_secs)}")
        calls = sum(p.tools.values())
        if calls:
            bits.append(f"{calls} tool call{'s' if calls != 1 else ''}")
        if p.cost:
            bits.append(f"${p.cost:.2f}")
        if p.interrupted:
            bits.append("interrupted")
        meta = f"  ({' · '.join(bits)})" if bits else ""
        lines.append(f"[{p.n}] {when}{meta}")
        lines.append(p.text.rstrip("\n"))
        lines.append("")
    return "\n".join(lines) + "\n"


def refuse_if_present(paths) -> bool:
    """True (and a message on stderr) when any target already exists. The
    check runs before the first write, so a refusal leaves nothing behind."""
    clash = [p for p in paths if p.exists()]
    if not clash:
        return False
    print("not written — these files already exist (nothing is ever overwritten):",
          file=sys.stderr)
    for p in clash:
        print(f"  {L.home_rel(str(p))}", file=sys.stderr)
    print("Pick another output directory (-o DIR), or move the old files yourself.",
          file=sys.stderr)
    return True


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as f:   # "x": fail rather than overwrite
        f.write(text)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("-h", "--help", action="store_true")
    ap.add_argument("target", nargs="?")
    ap.add_argument("--merged", default=None)
    ap.add_argument("--session", default=None)
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--json", action="store_true")
    try:
        args = ap.parse_args(argv)
    except SystemExit:
        return 2
    if args.help or not (args.target or args.merged or args.session):
        print(__doc__.strip())
        return 0 if args.help else 2

    try:
        if args.session:
            f = L.find_session(args.session)
            files = [f]
            root = L._first_cwd(f)
            name = os.path.basename(root.rstrip("/")) if root else f.parent.name
            meta = {"name": name, "root": root, "slugs": [f.parent.name], "merged": False}
        elif args.merged:
            g = L.resolve_group(args.merged, L.load_groups())
            files = L.group_jsonls(g)
            primary = L.PROJECTS_ROOT / g.primary
            root = None
            for jf in sorted(primary.glob("*.jsonl")):
                root = L._first_cwd(jf)
                if root:
                    break
            name = g.name
            meta = {"name": g.name, "root": root, "slugs": g.slugs, "merged": True}
        else:
            p = L.resolve_project(args.target, L.discover_projects())
            files = p.jsonls
            name = p.name
            meta = {"name": p.name, "root": p.root, "slugs": [p.slug], "merged": False}
    except L.ResolveError as e:
        print(e, file=sys.stderr)
        for c in e.candidates:
            print(f"  {c}", file=sys.stderr)
        return 1

    safe_name = name.replace("/", "-").strip() or "export"
    out_dir = Path(args.out).expanduser() if args.out else \
        Path(os.environ.get("CCT_EXPORT_DIR") or (Path.home() / "cct-export")) / safe_name

    analyses = []
    skipped = 0
    for f in files:
        a = L.analyze_session(f)
        if a is None or not a.prompts:
            skipped += 1
            continue
        analyses.append(a)
    analyses.sort(key=lambda a: a.first or 0)
    total_prompts = sum(len(a.prompts) for a in analyses)

    if not analyses:
        print(f"No typed prompts found in {len(files)} session(s) of {name}.")
        return 1

    if args.json:
        doc = {
            "schema": SCHEMA,
            "exported_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tz": tz_label(),
            "project": meta,
            "session_count": len(analyses),
            "prompt_count": total_prompts,
            "cost_usd": round(sum(a.cost for a in analyses), 4),
            "sessions": [session_json(a) for a in analyses],
        }
        target = out_dir / (f"{L.session_start_stem(analyses[0])}.json" if args.session
                            else f"{safe_name}.prompts.json")
        if refuse_if_present([target]):
            return 3
        write(target, json.dumps(doc, indent=1, ensure_ascii=False) + "\n")
        print(f"wrote {L.home_rel(str(target))}")
        print(f"  {len(analyses)} session(s), {total_prompts} prompt(s)"
              + (f", {skipped} session(s) without prompts skipped" if skipped else ""))
        return 0

    targets = [(a, out_dir / f"{L.session_start_stem(a)}.txt") for a in analyses]
    if refuse_if_present([t for _, t in targets]):
        return 3
    written = []
    for a, target in targets:
        write(target, session_text(a))
        written.append((target, len(a.prompts)))
    print(f"wrote {len(written)} file(s) to {L.home_rel(str(out_dir))}/")
    for t, n in written:
        print(f"  {t.name:32} {n:>4} prompt(s)")
    print()
    print(f"  {total_prompts} prompt(s) in {len(written)} session(s)"
          + (f"; {skipped} session(s) without prompts skipped" if skipped else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
