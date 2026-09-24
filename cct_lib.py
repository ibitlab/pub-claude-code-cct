"""cct_lib — shared transcript analysis for cct and its Python scripts.

Pure standard library. Imported by `cct` (the TUI), `time-report.py` and
`export-prompts.py`; nothing here touches the terminal.

What lives here:
  * project discovery   — one Project per folder under ~/.claude/projects/
  * merged groups       — user-defined sets of folders counted together,
                          stored in ~/.config/cct/merges.json
  * session analysis    — a single pass over one transcript that yields the
                          typed prompts (with recovered timestamps), the
                          working / tools / waiting / idle time buckets, and
                          per-turn stats (response time, tools, cost)
  * pricing             — the same list-price table as the bash scripts
"""
from __future__ import annotations

import json
import os
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

PROJECTS_ROOT = Path(os.environ.get("CCT_PROJECTS_ROOT") or (Path.home() / ".claude" / "projects"))
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "cct"
MERGES_FILE = CONFIG_DIR / "merges.json"

# Idle gaps longer than this are "breaks" (you walked away) and are excluded
# from a session's active time. Overridable per call.
DEFAULT_BREAK_SECS = 30 * 60
# A tool that normally returns instantly (Read, Edit, …) but whose result took
# longer than this almost certainly sat at a permission prompt.
DEFAULT_APPROVE_SECS = 15

# Tools whose execution is sub-second when auto-approved. A long gap before
# their result means the permission dialog was open.
INSTANT_TOOLS = frozenset({
    "Read", "Edit", "Write", "MultiEdit", "Glob", "Grep", "LS", "TodoWrite",
    "NotebookEdit", "Skill", "ToolSearch", "TodoRead",
})
# Tools whose whole purpose is to block on the user.
ASK_TOOLS = frozenset({"AskUserQuestion", "ExitPlanMode"})


# ---------------------------------------------------------------- helpers

def slug_for(path: str | Path) -> str:
    """Claude Code's folder name for a project path: '/' and '_' → '-'."""
    return str(path).replace("/", "-").replace("_", "-")


def home_rel(path: str | None) -> str:
    """/Users/me/x → ~/x (display only)."""
    if not path:
        return "?"
    home = str(Path.home())
    if path == home or path.startswith(home + "/"):
        return "~" + path[len(home):]
    return path


_TS_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z?$")


def parse_ts(iso: str | None) -> float | None:
    """ISO-8601 UTC ('2026-04-17T15:26:32.334Z') → epoch seconds, or None."""
    if not iso:
        return None
    m = _TS_RE.match(iso)
    if not m:
        try:
            return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    y, mo, d, h, mi, s, frac = m.groups()
    dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(s), tzinfo=timezone.utc)
    t = dt.timestamp()
    if frac:
        t += int(frac[:6].ljust(6, "0")) / 1e6
    return t


def local_dt(epoch: float) -> datetime:
    return datetime.fromtimestamp(epoch).astimezone()


def local_date(epoch: float) -> str:
    return local_dt(epoch).strftime("%Y-%m-%d")


def fmt_local(epoch: float | None, seconds: bool = False) -> str:
    if epoch is None:
        return "?"
    return local_dt(epoch).strftime("%Y-%m-%d %H:%M:%S" if seconds else "%Y-%m-%d %H:%M")


def fmt_utc(epoch: float | None) -> str:
    if epoch is None:
        return ""
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        f"{int((epoch % 1) * 1000):03d}Z"


def fmt_dur(secs: float) -> str:
    """Compact duration: 12h03m / 3m12s / 12s. Always ≤ 7 chars."""
    secs = int(round(secs))
    if secs >= 3600:
        return f"{secs // 3600}h{(secs % 3600) // 60:02d}m"
    if secs >= 60:
        return f"{secs // 60}m{secs % 60:02d}s"
    return f"{secs}s"


def fmt_dur_long(secs: float) -> str:
    """'1h 02m 03s' style for single-session detail views."""
    secs = int(round(secs))
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m {s:02d}s"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def bar(value: float, maximum: float, width: int = 12) -> str:
    """Fixed-width block bar scaled to `maximum`."""
    if maximum <= 0 or value <= 0:
        return " " * width
    units = int(value * width * 2 / maximum)
    full, half = divmod(units, 2)
    if full == 0 and half == 0:
        half = 1
    s = "█" * full + ("▌" if half else "")
    return s + " " * (width - full - half)


def clip_left(s: str, width: int) -> str:
    """Keep the tail of a path — that is what distinguishes it."""
    return s if len(s) <= width else "…" + s[-(width - 1):]


def iter_events(path: Path):
    """Yield each parseable JSON object in a .jsonl transcript."""
    try:
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


# ---------------------------------------------------------------- pricing
# The price table is pricing.json next to this file — the one place prices
# live, shared with the bash/jq scripts. Rules are tried in order; the first
# regex that matches the model id wins; the last (empty regex) is the fallback.
PRICING_FILE = Path(__file__).resolve().parent / "pricing.json"
_rules: list | None = None


def _pricing_rules() -> list:
    global _rules
    if _rules is None:
        data = json.loads(PRICING_FILE.read_text())
        _rules = [
            (re.compile(r["match"]),
             (r["input"], r["output"], r["cache_read"], r["cache_5m"], r["cache_1h"]))
            for r in data["rules"]
        ]
        if not _rules:
            raise ValueError(f"{PRICING_FILE}: no pricing rules")
    return _rules


def price_for(model: str | None):
    """(input, output, cache-read, cache-5m, cache-1h) in USD per 1M tokens."""
    m = model or ""
    rules = _pricing_rules()
    for rx, p in rules:
        if rx.search(m):
            return p
    return rules[-1][1]


def cost_of(usage: dict, model: str | None) -> float:
    inp, out, rd, c5, c1 = price_for(model)
    cc = usage.get("cache_creation") or {}
    return (
        (usage.get("input_tokens") or 0) * inp
        + (usage.get("output_tokens") or 0) * out
        + (usage.get("cache_read_input_tokens") or 0) * rd
        + (cc.get("ephemeral_5m_input_tokens") or 0) * c5
        + (cc.get("ephemeral_1h_input_tokens") or 0) * c1
    ) / 1e6


# ---------------------------------------------------------------- projects

@dataclass
class Project:
    slug: str
    dir: Path
    root: str | None          # the folder Claude Code was opened in (shortest cwd)
    alive: bool               # does that folder still exist?
    sessions: int
    last_mtime: float

    @property
    def label(self) -> str:
        return home_rel(self.root) if self.root else self.slug

    @property
    def name(self) -> str:
        return os.path.basename(self.root.rstrip("/")) if self.root else self.slug

    @property
    def jsonls(self) -> list[Path]:
        return sorted(self.dir.glob("*.jsonl"))


def _first_cwd(path: Path, max_lines: int = 200) -> str | None:
    """Shortest cwd among the first events of a transcript. Cheap: does not
    read the whole file. Every event carries the session's cwd, and the
    opening folder is the shortest one a session records."""
    best = None
    n = 0
    for ev in iter_events(path):
        n += 1
        c = ev.get("cwd")
        if c and (best is None or len(c) < len(best)):
            best = c
        if n >= max_lines and best:
            break
    return best


def discover_projects(include_empty: bool = False) -> list[Project]:
    """One Project per folder under ~/.claude/projects/, newest activity first."""
    out: list[Project] = []
    if not PROJECTS_ROOT.is_dir():
        return out
    for d in sorted(PROJECTS_ROOT.iterdir()):
        if not d.is_dir():
            continue
        files = sorted(d.glob("*.jsonl"))
        if not files and not include_empty:
            continue
        root = None
        last_mtime = 0.0
        for f in files:
            try:
                last_mtime = max(last_mtime, f.stat().st_mtime)
            except OSError:
                pass
            c = _first_cwd(f)
            if c and (root is None or len(c) < len(root)):
                root = c
        out.append(Project(
            slug=d.name, dir=d, root=root,
            alive=bool(root) and os.path.isdir(root),
            sessions=len(files), last_mtime=last_mtime,
        ))
    out.sort(key=lambda p: p.last_mtime, reverse=True)
    return out


class ResolveError(LookupError):
    def __init__(self, msg: str, candidates: list[str] | None = None):
        super().__init__(msg)
        self.candidates = candidates or []


def resolve_project(arg: str, projects: list[Project]) -> Project:
    """Match a root path (~/… or absolute), an unambiguous trailing path
    segment (same rules as project-costs.sh), or the transcript folder itself:
    its slug, or its full path under ~/.claude/projects/. The TUI passes the
    folder path because a slug starts with '-' and argparse would read it as
    an option."""
    home = str(Path.home())
    q = arg
    if q.startswith("~/"):
        q = home + q[1:]
    for p in projects:
        if p.slug == arg or str(p.dir) == q.rstrip("/"):
            return p
    exact = [p for p in projects if p.root == q]
    if len(exact) == 1:
        return exact[0]
    tail = arg[2:] if arg.startswith("~/") else arg
    sfx = [p for p in projects if p.root and p.root.endswith("/" + tail)]
    if len(sfx) == 1:
        return sfx[0]
    if not exact and not sfx:
        raise ResolveError(f"Project not found: {arg}", [p.label for p in projects])
    raise ResolveError(f"Ambiguous project: {arg}", [p.label for p in (exact or sfx)])


# ---------------------------------------------------------------- merged groups

@dataclass
class Group:
    name: str
    primary: str              # slug
    members: list[str] = field(default_factory=list)   # slugs, excluding primary

    @property
    def slugs(self) -> list[str]:
        return [self.primary] + [m for m in self.members if m != self.primary]

    def to_json(self) -> dict:
        return {"name": self.name, "primary": self.primary, "members": list(self.members)}


def load_groups() -> list[Group]:
    try:
        data = json.loads(MERGES_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return []
    out = []
    for g in data.get("groups", []):
        if not isinstance(g, dict) or not g.get("primary"):
            continue
        members = [m for m in g.get("members", []) if isinstance(m, str)]
        out.append(Group(name=str(g.get("name") or g["primary"]), primary=g["primary"], members=members))
    return out


def save_groups(groups: list[Group]) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = MERGES_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"version": 1, "groups": [g.to_json() for g in groups]}, indent=2) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, MERGES_FILE)


def resolve_group(arg: str, groups: list[Group]) -> Group:
    exact = [g for g in groups if g.name == arg]
    if len(exact) == 1:
        return exact[0]
    sub = [g for g in groups if arg.lower() in g.name.lower()]
    if len(sub) == 1:
        return sub[0]
    if not sub:
        raise ResolveError(f"Merged project not found: {arg}", [g.name for g in groups])
    raise ResolveError(f"Ambiguous merged project: {arg}", [g.name for g in sub])


def group_dirs(group: Group) -> list[Path]:
    return [PROJECTS_ROOT / s for s in group.slugs if (PROJECTS_ROOT / s).is_dir()]


def group_jsonls(group: Group) -> list[Path]:
    out: list[Path] = []
    for d in group_dirs(group):
        out.extend(sorted(d.glob("*.jsonl")))
    return out


# ---------------------------------------------------------------- session analysis

@dataclass
class Buckets:
    """Seconds per state. `active` excludes breaks."""
    working: float = 0.0     # Claude generating (incl. thinking)
    thinking: float = 0.0    # of working: gaps that ended in a thinking-only block
    tools: float = 0.0       # tool_use → tool_result (execution + permission dialogs)
    approval: float = 0.0    # of tools: instant tools that stalled → likely permission prompt
    approval_n: int = 0
    waiting: float = 0.0     # blocked on you: question / plan approval / declined prompt
    idle: float = 0.0        # Claude done, you reading / typing (≤ break threshold)
    breaks: float = 0.0      # idle gaps above the threshold — excluded from active
    breaks_n: int = 0

    @property
    def active(self) -> float:
        return self.working + self.tools + self.waiting + self.idle

    @property
    def wall(self) -> float:
        return self.active + self.breaks

    def add(self, o: "Buckets") -> None:
        self.working += o.working
        self.thinking += o.thinking
        self.tools += o.tools
        self.approval += o.approval
        self.approval_n += o.approval_n
        self.waiting += o.waiting
        self.idle += o.idle
        self.breaks += o.breaks
        self.breaks_n += o.breaks_n

    def to_json(self) -> dict:
        return {
            "active": round(self.active), "working": round(self.working),
            "thinking": round(self.thinking), "tools": round(self.tools),
            "approval": round(self.approval), "approval_calls": self.approval_n,
            "waiting": round(self.waiting), "idle": round(self.idle),
            "breaks": round(self.breaks), "break_count": self.breaks_n,
        }


@dataclass
class Prompt:
    n: int
    ts: float | None          # epoch of the typed user event (None if unknown)
    ts_approx: bool
    text: str
    start: int                # index into actors where this turn begins
    end: int = 0              # exclusive
    response_secs: float | None = None   # prompt → Claude's last output of the turn
    working_secs: float = 0.0
    tools: Counter = field(default_factory=Counter)
    cost: float = 0.0
    models: set = field(default_factory=set)
    interrupted: bool = False


@dataclass
class _Actor:
    ts: float
    kind: str                 # "U" typed prompt, "A" assistant, "R" tool result
    thinking_only: bool = False
    tool_uses: list = field(default_factory=list)
    stop: str | None = None
    tools: list = field(default_factory=list)   # names for R
    denied: bool = False
    interrupted: bool = False
    cost: float = 0.0
    model: str | None = None
    texts: list = field(default_factory=list)   # text blocks of a typed event


_WS_RE = re.compile(r"\s+")


def _norm(s: str) -> str:
    return _WS_RE.sub(" ", s).strip()


def _full_prompt_text(snapshot: str, texts: list) -> str:
    """Recover the verbatim prompt.

    The `last-prompt` snapshot is what the user typed, but Claude Code clips it
    to 200 characters (then appends '…') and flattens newlines. The typed
    user event carries the same text untouched as its own text block, next to
    wrapper blocks (<ide_selection>, <ide_opened_file>, <system-reminder>…).
    Pick the block that starts with the snapshot, whitespace-insensitively."""
    key = _norm(snapshot[:-1] if snapshot.endswith("…") else snapshot)
    if not key:
        return snapshot
    for t in texts:
        if isinstance(t, str) and _norm(t).startswith(key):
            return t.strip("\n")
    return snapshot


@dataclass
class SessionAnalysis:
    id: str
    path: Path
    slug: str
    cwd: str | None
    title: str | None
    first: float | None
    last: float | None
    buckets: Buckets
    by_date: dict           # 'YYYY-MM-DD' → Buckets (local dates)
    prompts: list
    longest_tool: tuple     # (name, secs)
    cost: float
    models: Counter
    has_block_events: bool  # per-block assistant lines → thinking time is measurable

    @property
    def short_id(self) -> str:
        return self.id[:8]

    @property
    def headline(self) -> str:
        if self.title:
            return self.title
        if self.prompts:
            return self.prompts[0].text.split("\n", 1)[0]
        return "<no prompt>"

    @property
    def response_times(self) -> list[float]:
        return [p.response_secs for p in self.prompts if p.response_secs is not None]


def _text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def _is_tool_result(ev: dict, content) -> bool:
    if ev.get("toolUseResult") is not None:
        return True
    return isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content)


def analyze_session(path: Path, break_secs: float = DEFAULT_BREAK_SECS,
                    approve_secs: float = DEFAULT_APPROVE_SECS,
                    day_start_secs: float = 0.0) -> SessionAnalysis | None:
    """One pass over a transcript → prompts, time buckets, per-turn stats.

    Time model. Only timestamped user/assistant events on the main thread are
    "actors". Every gap between consecutive actors is attributed to whoever was
    busy during it, decided by the event that ENDS the gap:

      ends in assistant output  → Claude was generating           → working
      ends in a tool result     → a tool ran / a permission dialog → tools
                                  (AskUserQuestion, plan approval or a
                                   declined tool → waiting on you)
      ends in a typed prompt    → Claude was done, you were reading
                                  or typing                        → idle

    Any gap longer than `break_secs` that was waiting on a person — an idle
    gap, a question, a pending tool call (a permission dialog left open
    overnight is not tool time) — is a break and leaves active time. Only
    Claude's own generation is never capped.

    `day_start_secs` shifts the by-date bucketing: 4*3600 makes a day run
    from 04:00 to 04:00 local, so a session that crosses midnight stays on
    one date.
    """
    actors: list[_Actor] = []
    prompts: list[Prompt] = []
    tool_names: dict = {}
    seen_msgs: set = set()
    seen_uuids: set = set()
    models: Counter = Counter()
    cost = 0.0
    title = cwd = None
    first = last = None
    last_seen_ts = None
    pending_prompt_ts = None
    pending_prompt_idx = None   # index of that typed event in `actors`
    last_prompt_text = None
    has_block_events = False

    for ev in iter_events(path):
        t = ev.get("type")
        ts = parse_ts(ev.get("timestamp"))
        if ts is not None:
            first = ts if first is None or ts < first else first
            last = ts if last is None or ts > last else last
            last_seen_ts = ts
        if cwd is None and ev.get("cwd"):
            cwd = ev["cwd"]
        if t == "ai-title":
            title = ev.get("aiTitle") or title
            continue
        if t == "last-prompt":
            p = ev.get("lastPrompt")
            if p and p != last_prompt_text:
                # The snapshot is written a few lines after the typed user
                # event it mirrors (attachments, sometimes Claude's first
                # block, sit in between) — so anchor the prompt to the most
                # recent typed event, not to whatever line came last.
                last_prompt_text = p
                approx = pending_prompt_ts is None
                pts = pending_prompt_ts if pending_prompt_ts is not None else last_seen_ts
                start = pending_prompt_idx if pending_prompt_idx is not None else len(actors)
                texts = actors[pending_prompt_idx].texts if pending_prompt_idx is not None else []
                pending_prompt_ts = pending_prompt_idx = None
                prompts.append(Prompt(n=len(prompts) + 1, ts=pts, ts_approx=approx,
                                      text=_full_prompt_text(p, texts), start=start))
            continue
        if t not in ("user", "assistant") or ts is None or ev.get("isSidechain"):
            continue
        # After /compact Claude Code re-appends the whole conversation: exact
        # copies of earlier lines, same uuid and timestamp. Count each once,
        # or every replayed span is added to the clock again.
        u = ev.get("uuid")
        if u:
            if u in seen_uuids:
                continue
            seen_uuids.add(u)
        msg = ev.get("message") or {}
        content = msg.get("content")
        if t == "assistant":
            if "apiBlockIndex" in ev:
                has_block_events = True
            blocks = [b for b in (content or []) if isinstance(b, dict)] if isinstance(content, list) else []
            kinds = [b.get("type") for b in blocks]
            uses = []
            for b in blocks:
                if b.get("type") == "tool_use":
                    uses.append(b.get("name") or "?")
                    if b.get("id"):
                        tool_names[b["id"]] = b.get("name") or "?"
            mid = msg.get("id") or ev.get("requestId") or ev.get("uuid")
            c = 0.0
            model = msg.get("model")
            if mid not in seen_msgs and msg.get("usage"):
                seen_msgs.add(mid)
                c = cost_of(msg["usage"], model)
                cost += c
                models[model or "unknown"] += 1
            actors.append(_Actor(ts=ts, kind="A",
                                 thinking_only=bool(kinds) and all(k == "thinking" for k in kinds),
                                 tool_uses=uses, stop=msg.get("stop_reason"), cost=c, model=model))
            continue
        # user
        if _is_tool_result(ev, content):
            names = []
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        names.append(tool_names.get(b.get("tool_use_id"), "?"))
            denied = bool(ev.get("toolDenialKind"))
            if not denied and isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        txt = b.get("content")
                        if isinstance(txt, list):
                            txt = " ".join(x.get("text", "") for x in txt if isinstance(x, dict))
                        if isinstance(txt, str) and "doesn't want to proceed" in txt:
                            denied = True
                            break
            actors.append(_Actor(ts=ts, kind="R", tools=names, denied=denied))
            continue
        if ev.get("isMeta"):
            continue
        text = _text_of(content)
        interrupted = text.lstrip().startswith("[Request interrupted")
        if isinstance(content, str):
            texts = [content]
        else:
            texts = [b.get("text", "") for b in (content or [])
                     if isinstance(b, dict) and b.get("type") == "text"]
        actors.append(_Actor(ts=ts, kind="U", interrupted=interrupted, texts=texts))
        if not interrupted:
            pending_prompt_ts = ts
            pending_prompt_idx = len(actors) - 1

    if first is None:
        return None

    # Close the turn spans.
    for i, p in enumerate(prompts):
        p.end = prompts[i + 1].start if i + 1 < len(prompts) else len(actors)

    total = Buckets()
    by_date: dict = defaultdict(Buckets)
    longest_tool = ("", 0.0)
    # gap index → seconds counted as working (for per-turn sums)
    working_gap: dict = {}

    for i in range(1, len(actors)):
        a, b = actors[i - 1], actors[i]
        d = max(0.0, b.ts - a.ts)
        day = by_date[local_date(a.ts - day_start_secs)]
        if b.kind == "A":
            total.working += d
            day.working += d
            working_gap[i] = d
            if b.thinking_only:
                total.thinking += d
                day.thinking += d
        elif b.kind == "R":
            user_side = any(n in ASK_TOOLS for n in b.tools) or b.denied
            suspect = bool(b.tools) and all(n in INSTANT_TOOLS for n in b.tools) and d > approve_secs
            if d > break_secs:
                # Whatever was pending — a question, a permission dialog, a
                # tool call — a gap this long means you were away: a Bash
                # prompt left open overnight is not tool time. (A tool that
                # genuinely ran longer than the threshold lands here too;
                # rare, and the threshold is adjustable.)
                total.breaks += d
                day.breaks += d
                total.breaks_n += 1
                day.breaks_n += 1
            elif user_side:
                total.waiting += d
                day.waiting += d
            else:
                total.tools += d
                day.tools += d
                if suspect:
                    total.approval += d
                    day.approval += d
                    total.approval_n += 1
                    day.approval_n += 1
                if d > longest_tool[1]:
                    longest_tool = ("+".join(dict.fromkeys(b.tools)) or "?", d)
        else:  # typed prompt ends the gap
            if d > break_secs:
                total.breaks += d
                day.breaks += d
                total.breaks_n += 1
                day.breaks_n += 1
            elif b.interrupted and a.kind == "A" and a.stop == "tool_use":
                total.waiting += d          # you sat at a permission prompt, then hit Esc
                day.waiting += d
            elif b.interrupted:
                total.working += d          # Claude was mid-generation when you hit Esc
                day.working += d
                working_gap[i] = d
            else:
                total.idle += d
                day.idle += d

    # Per-turn stats.
    for p in prompts:
        span = actors[p.start:p.end]
        last_a = None
        for j, ac in enumerate(span):
            idx = p.start + j
            if ac.kind == "A":
                last_a = ac.ts
                p.cost += ac.cost
                if ac.model:
                    p.models.add(ac.model)
                for n in ac.tool_uses:
                    p.tools[n] += 1
            if ac.kind == "U" and ac.interrupted:
                p.interrupted = True
            if idx in working_gap:
                p.working_secs += working_gap[idx]
        if p.ts is not None and last_a is not None and last_a >= p.ts:
            p.response_secs = last_a - p.ts

    return SessionAnalysis(
        id=path.stem, path=path, slug=path.parent.name, cwd=cwd, title=title,
        first=first, last=last, buckets=total, by_date=dict(by_date),
        prompts=prompts, longest_tool=longest_tool, cost=cost, models=models,
        has_block_events=has_block_events,
    )


def find_session(arg: str) -> Path:
    """A .jsonl path, a full session UUID or a unique UUID prefix."""
    p = Path(arg)
    if p.is_file():
        return p
    hits = sorted(PROJECTS_ROOT.glob(f"*/{arg}*.jsonl"))
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise ResolveError(f"No session matching: {arg}")
    raise ResolveError(f"Ambiguous prefix '{arg}'", [str(h) for h in hits])


def session_start_stem(a: SessionAnalysis) -> str:
    """File stem for per-session exports: local start time + short id,
    e.g. 2026-04-17_1526_5d35e607."""
    when = local_dt(a.first).strftime("%Y-%m-%d_%H%M") if a.first else "unknown-date"
    return f"{when}_{a.short_id}"
