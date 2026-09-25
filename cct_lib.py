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
    """Seconds per state. `active` excludes breaks.

    Two of these are weaker than they look, and every view that prints them
    has to say so:

    `tools` holds the time you spent answering a permission dialog. The
    transcript has no event for a dialog — only `tool_use` and `tool_result`
    timestamps — so the answer time and the tool's own runtime are one number
    that cannot be split. For a tool that normally returns instantly the
    excess is almost certainly the dialog (see `approval`); for Bash and other
    genuinely slow tools nothing in the log tells the two apart.

    `idle` is a gap, not an observation. It is the span from Claude's last
    output to your next prompt, and nothing records what happened in it: you
    may have been reading, working in another session, or away from the desk.
    Gaps above the break threshold are moved to `breaks`; below it they stay
    here and are counted as active time.
    """
    working: float = 0.0     # Claude generating (incl. thinking)
    thinking: float = 0.0    # of working: gaps that ended in a thinking-only block
    tools: float = 0.0       # tool_use → tool_result (execution + permission dialogs, inseparable)
    approval: float = 0.0    # of tools: instant tools that stalled → likely permission prompt
    approval_n: int = 0
    agents: float = 0.0      # background agents / workflows running while the main thread waited
    waiting: float = 0.0     # blocked on you: question / plan approval / declined prompt
                             # — NOT permission dialogs, which land in `tools`
    idle: float = 0.0        # Claude done → your next prompt; unattended time is
                             # indistinguishable from reading (≤ break threshold)
    breaks: float = 0.0      # idle gaps above the threshold — excluded from active
    breaks_n: int = 0

    @property
    def active(self) -> float:
        return self.working + self.tools + self.agents + self.waiting + self.idle

    @property
    def wall(self) -> float:
        return self.active + self.breaks

    def add(self, o: "Buckets") -> None:
        self.working += o.working
        self.thinking += o.thinking
        self.tools += o.tools
        self.approval += o.approval
        self.approval_n += o.approval_n
        self.agents += o.agents
        self.waiting += o.waiting
        self.idle += o.idle
        self.breaks += o.breaks
        self.breaks_n += o.breaks_n

    def to_json(self) -> dict:
        return {
            "active": round(self.active), "working": round(self.working),
            "thinking": round(self.thinking), "tools": round(self.tools),
            "approval": round(self.approval), "approval_calls": self.approval_n,
            "agents": round(self.agents),
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
    cost: float = 0.0         # main transcript
    cost_agents: float = 0.0  # background agents started during this turn
    models: set = field(default_factory=set)
    interrupted: bool = False


@dataclass
class _Actor:
    ts: float
    kind: str                 # "U" typed prompt, "A" assistant, "R" tool result
    mid: str | None = None    # API message id (all blocks of one reply share it)
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


def agent_files(main: Path) -> list:
    """Transcripts of the background agents (Agent tool, Workflow) of a
    session: <folder>/<session-id>/subagents/**/*.jsonl."""
    sub = main.parent / main.stem / "subagents"
    return sorted(sub.rglob("*.jsonl")) if sub.is_dir() else []


def _agent_runs(main: Path) -> list:
    """[(start, end, cost, api_messages)] per background-agent transcript.
    Their usage is not in the main transcript, so it is priced here."""
    runs = []
    for f in agent_files(main):
        first = last = None
        msg_cost: dict = {}
        for ev in iter_events(f):
            ts = parse_ts(ev.get("timestamp"))
            if ts is not None:
                first = ts if first is None or ts < first else first
                last = ts if last is None or ts > last else last
            if ev.get("type") == "assistant":
                msg = ev.get("message") or {}
                if msg.get("usage"):
                    # Usage grows across the block lines of one streamed
                    # reply; the last line carries the final figures.
                    mid = msg.get("id") or ev.get("uuid")
                    msg_cost[mid] = cost_of(msg["usage"], msg.get("model"))
        if first is not None:
            runs.append((first, last, sum(msg_cost.values()), len(msg_cost)))
    return runs


def _merge_intervals(spans) -> list:
    out: list = []
    for s, e in sorted(spans):
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


def _overlap(s: float, e: float, intervals) -> float:
    """Seconds of [s, e] covered by the (merged) intervals."""
    if e <= s:
        return 0.0
    total = 0.0
    for a, b in intervals:
        if b <= s:
            continue
        if a >= e:
            break
        total += min(b, e) - max(a, s)
    return total


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
    cost: float             # main transcript only
    models: Counter
    has_block_events: bool  # per-block assistant lines → thinking time is measurable
    agent_runs: int = 0     # background-agent transcripts (Agent tool, Workflow)
    agent_runtime: float = 0.0   # their wall time, overlaps merged
    cost_agents: float = 0.0

    @property
    def cost_total(self) -> float:
        return self.cost + self.cost_agents

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
      ends in a typed prompt    → Claude was done and nothing else
                                  is recorded until you answer     → idle

    Neither `tools` nor `idle` is as precise as it reads — see `Buckets`.
    A permission dialog you answered with "yes" leaves no trace of its own
    in the transcript, so the seconds you spent on it stay inside `tools`
    and `waiting` can be zero in a session where you did wait; and `idle`
    is the bare gap until your next prompt, whatever you were doing in it.

    Any gap longer than `break_secs` that was waiting on a person — an idle
    gap, a question, a pending tool call (a permission dialog left open
    overnight is not tool time) — is a break and leaves active time. Only
    Claude's own generation is never capped.

    Background agents (Agent tool, Workflow) write their own transcripts
    under <session-id>/subagents/. The main thread just waits for them, so
    the part of an idle gap during which such an agent ran is `agents`, not
    `you` or a break. Their usage is priced into `cost_agents`. When Claude
    resumes without a prompt from you (auto-continue after a usage limit,
    a background-task notification) the gap before it is treated the same
    way as an idle gap — nothing was generating.

    `day_start_secs` shifts the by-date bucketing: 4*3600 makes a day run
    from 04:00 to 04:00 local, so a session that crosses midnight stays on
    one date.
    """
    actors: list[_Actor] = []
    prompts: list[Prompt] = []
    tool_names: dict = {}
    seen_uuids: set = set()
    msg_cost: dict = {}      # message id → cost from its LAST line (usage grows per block)
    msg_model: dict = {}
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
            model = msg.get("model")
            if msg.get("usage"):
                # One reply spans several lines and its usage grows from
                # block to block; the last line has the final figures.
                msg_cost[mid] = cost_of(msg["usage"], model)
                msg_model[mid] = model
            actors.append(_Actor(ts=ts, kind="A", mid=mid,
                                 thinking_only=bool(kinds) and all(k == "thinking" for k in kinds),
                                 tool_uses=uses, stop=msg.get("stop_reason"), model=model))
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

    runs = _agent_runs(path)
    agent_iv = _merge_intervals([(s, e) for s, e, _, _ in runs])

    def put(day: Buckets, what: str, secs: float) -> None:
        setattr(total, what, getattr(total, what) + secs)
        setattr(day, what, getattr(day, what) + secs)

    def pause(day: Buckets, s: float, e: float) -> None:
        """Nobody on the main thread was generating between s and e. Time a
        background agent was running is `agents`; the rest is you reading /
        typing, or a break once it exceeds the threshold."""
        ov = _overlap(s, e, agent_iv)
        if ov:
            put(day, "agents", ov)
        rest = max(0.0, e - s) - ov
        if rest > break_secs:
            put(day, "breaks", rest)
            total.breaks_n += 1
            day.breaks_n += 1
        elif rest > 0:
            put(day, "idle", rest)

    for i in range(1, len(actors)):
        a, b = actors[i - 1], actors[i]
        d = max(0.0, b.ts - a.ts)
        day = by_date[local_date(a.ts - day_start_secs)]
        if b.kind == "A":
            if a.kind == "A" and a.mid != b.mid:
                # Claude started a new reply with no prompt from you in
                # between: auto-continue after a usage limit ("Continue from
                # where you left off"), a background-task notification.
                # Nothing was generating during the gap.
                pause(day, a.ts, b.ts)
                continue
            put(day, "working", d)
            working_gap[i] = d
            if b.thinking_only:
                put(day, "thinking", d)
        elif b.kind == "R":
            user_side = any(n in ASK_TOOLS for n in b.tools) or b.denied
            suspect = bool(b.tools) and all(n in INSTANT_TOOLS for n in b.tools) and d > approve_secs
            if d > break_secs:
                # Whatever was pending — a question, a permission dialog, a
                # tool call — a gap this long means you were away: a Bash
                # prompt left open overnight is not tool time. (A tool that
                # genuinely ran longer than the threshold lands here too;
                # rare, and the threshold is adjustable.)
                put(day, "breaks", d)
                total.breaks_n += 1
                day.breaks_n += 1
            elif user_side:
                put(day, "waiting", d)
            else:
                put(day, "tools", d)
                if suspect:
                    put(day, "approval", d)
                    total.approval_n += 1
                    day.approval_n += 1
                if d > longest_tool[1]:
                    longest_tool = ("+".join(dict.fromkeys(b.tools)) or "?", d)
        else:  # your typed prompt ends the gap
            if b.interrupted and a.kind == "A" and a.stop == "tool_use":
                # you sat at a permission prompt, then hit Esc
                if d > break_secs:
                    put(day, "breaks", d)
                    total.breaks_n += 1
                    day.breaks_n += 1
                else:
                    put(day, "waiting", d)
            elif b.interrupted:
                put(day, "working", d)      # Claude was mid-generation when you hit Esc
                working_gap[i] = d
            else:
                pause(day, a.ts, b.ts)

    # Background agents started during a turn are billed to that turn.
    timed = [p for p in prompts if p.ts is not None]
    for s, _e, c, _n in runs:
        owner = None
        for p in timed:
            if p.ts <= s:
                owner = p
            else:
                break
        if owner is not None:
            owner.cost_agents += c

    cost = sum(msg_cost.values())
    models: Counter = Counter(
        (m or "unknown") for m in msg_model.values()
        if not (m or "").startswith("<"))            # "<synthetic>" placeholders

    # Per-turn stats.
    for p in prompts:
        span = actors[p.start:p.end]
        last_a = None
        turn_mids: set = set()
        for j, ac in enumerate(span):
            idx = p.start + j
            if ac.kind == "A":
                last_a = ac.ts
                if ac.mid not in turn_mids:
                    turn_mids.add(ac.mid)
                    p.cost += msg_cost.get(ac.mid, 0.0)
                if ac.model and not ac.model.startswith("<"):
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
        agent_runs=len(runs),
        agent_runtime=sum(e - s for s, e in agent_iv),
        cost_agents=sum(c for _, _, c, _ in runs),
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
