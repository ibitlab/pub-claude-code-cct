# cct — reference

Detailed reference for `cct` and the scripts it wraps. For installation and a
quick tour, see the [README](../README.md).

## The TUI

`cct` is an arrow-key TUI that wraps every script in this folder so you never type session UUIDs or paths. Pure Python standard library (`curses`) — no pip install.

Flow: **entry menu** → pick scope → **session picker** (arrow keys) → **action menu** (stats / time / tools / prompts / export) → inline output → Esc climbs back. State (last-used menu choice) persists in `~/.cache/cct/state.json` (mode `0600`); merged-project bindings in `~/.config/cct/merges.json` (see [Merged projects](#merged-projects)).

Keys: Up/Down or j/k, PgUp/PgDn, Home/End, Enter selects, Esc or q goes back, Ctrl-C quits. In the **Usage & cost by month** detail view, ←/→ (or `[`/`]`) step to the older/newer month without going back to the picker.

Runs the individual scripts under the hood — they remain authoritative and usable standalone.


## Background: where Claude Code stores sessions

Claude Code writes everything under `~/.claude/`. Relevant paths:

| Path                                     | What's there                                                                                                                              |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `~/.claude/projects/<slug>/<uuid>.jsonl` | Full transcript of a session — one JSON event per line (queue ops, user messages, assistant messages, tool calls + results). Append-only. |
| `~/.claude/sessions/<id>.json`           | Short-lived runtime session state.                                                                                                        |
| `~/.claude/telemetry/`                   | Telemetry spool.                                                                                                                          |
| `~/.claude/file-history/`                | Per-file edit history.                                                                                                                    |
| `~/.claude/plans/`                       | Saved plans from Plan mode.                                                                                                               |
| `~/.claude/settings.json`                | User settings (hooks, permissions, env).                                                                                                  |

### The project slug

The `<slug>` folder name is derived from the absolute project path by replacing **both `/` and `_`** with `-`. Example:

```
/Users/<you>/code/_my_project_/sub-repo
→ -Users-<you>-code--my-project--sub-repo
```

(Two consecutive dashes are not collapsed — they encode the boundary characters.)

### Transcript (`.jsonl`) shape

Each line is an independent JSON object. Common fields:

- `type` — `user`, `assistant`, `tool_use`, `tool_result`, `queue-operation`, `ai-title`, `last-prompt`, `attachment`, `file-history-snapshot`, …
- `timestamp` — ISO 8601 UTC (not present on every line).
- `sessionId` — UUID of the session (matches the filename).
- `message.content` — for `user`/`assistant` lines, either a string or an array of `{type, text}` / `{type: "tool_use", name, input}` / `{type: "tool_result", tool_use_id, content}` blocks.

A few useful specialized event types:

- **`ai-title`** — `{aiTitle: "..."}`: Claude's auto-generated short title for the session (multiple snapshots; the last one wins).
- **`last-prompt`** — `{lastPrompt: "..."}`: the most recent _typed_ user input at that point. Each new user message appends a new `last-prompt` event, so iterating in order gives you the verbatim sequence of user prompts — slash-command wrappers, tool results, and system reminders are **not** here.
- **`file-history-snapshot`** — capture of a file's pre-edit contents, for local undo.

Two traps worth knowing before you write your own pipeline:

- **One API message = several `assistant` lines.** Claude Code writes one line per content block (thinking, text, each `tool_use`), all sharing the same `message.id` (newer versions also carry `apiBlockIndex`), and **every line repeats the whole message's `usage`**. Summing usage over lines overcounts tokens and cost 2–3×. All cct cost scripts keep one line per `message.id` (`msg_id` / `priced` in the jq defs) — the **last** one, because in background-agent transcripts the usage grows from block to block and only the final line has the full figures.
- **`last-prompt` is a clipped snapshot.** `lastPrompt` is cut at 200 characters (then `…`), has newlines flattened, and the same snapshot is re-emitted many times per turn. The verbatim text lives in the timestamped `user` event a few lines earlier, as its own text block next to wrapper blocks (`<ide_selection>`, `<ide_opened_file>`, …); that is where `export-prompts.py` takes it from.
- **Background agents have their own transcripts.** The Agent tool and Workflow runs write `<slug>/<session-id>/subagents/**/*.jsonl` (plus `started` / `result` / `failed` bookkeeping lines). Their `assistant` lines carry their own `usage` that never appears in the main transcript, so a session that fans out work costs more than its main file says. Every cct cost view reads those files too; `time-report.py` shows their runtime as `agents`.
- **After `/compact` the history is written again.** Each compaction re-appends the earlier `user`/`assistant` lines as exact copies — same `uuid`, same `timestamp` — so a long session can hold every event three or four times. Anything that counts events (tool calls, file touches, time between events) must keep the first line per `uuid`; cct does (`dedup_events` in `pricing.jq`, the same rule in `cct_lib.py`). Cost is already safe because it keeps one line per `message.id`.

Since it's append-only JSONL, any `jq` / `awk` pipeline works against it.

## Scripts

The bash scripts require `jq`; `time-report.py` and `export-prompts.py` need only `python3` (they share `cct_lib.py` with the TUI). All of them read only from `~/.claude/` — nothing there is written or deleted. The only files cct writes are its own: `~/.cache/cct/state.json`, `~/.config/cct/merges.json`, and whatever you export.

### `status.sh`

One-screen overview, rolled up from the other scripts: active sessions (count + per-project), token cost for today / this week / last 30 days, and cleanup signals (dead projects, stale session markers). No options.

```bash
./status.sh
```

### `active-sessions.sh`

Lists the Claude Code sessions running *right now*. Each live `claude` process drops a marker at `~/.claude/sessions/<PID>.json`; the script keeps the markers whose PID is still alive and joins them against the transcript to show project, session id, title and recent activity. Markers whose process is gone are only listed — cct never deletes anything under `~/.claude/`.

```bash
./active-sessions.sh              # one row per live session
./active-sessions.sh -v           # also list stale markers (process gone)
./active-sessions.sh --stale-only # only the stale section (or an OK banner)
```

### `list-sessions.sh`

Lists Claude Code sessions for a project directory, newest first. Each row shows session id, first→last timestamp, event count, Claude's auto-generated `ai-title`, and the first/last real user prompts (taken from `last-prompt` events — the snapshot mechanism Claude Code uses to remember the typed user input, so this skips slash-command wrappers and system noise).

Requires `jq`.

```bash
# Sessions for the current directory
./list-sessions.sh

# Sessions for a specific project path
./list-sessions.sh ~/path/to/some-project

# List every project folder Claude Code knows about
./list-sessions.sh --all
```

Example output:

```
# ~/path/to/some-project
<uuid-1>  2026-04-17T15:26:32Z → 2026-04-17T15:53:53Z  (224 events)
    last:          today  (2026-04-17T15:53:53Z)
    title:         Implement commit substitution feature
    first prompt:  add correct gitignore, this where tut it, in project level or root…
    last prompt:   list sessions shows command wrapper, not real prompt
<uuid-2>  2026-03-28T15:22:15Z → 2026-03-28T15:33:27Z  (65 events)
    last:          19 days ago  (2026-03-28T15:33:27Z)
    title:         ESP32-C3 communication distance limitations
    first prompt:  add details for "Range / LR mode" section to the readme
```

### Why this script exists

Claude Code has **no CLI subcommand** to list sessions — only interactive pickers (`claude --resume`, `claude -c`, `claude -r <id>`). This script is the minimum viable substitute, and a handy starting point for building more scripts on top of the transcript format.

### `session-stats.sh`

Aggregate stats for one session: start/end timestamps, elapsed wall time, event-type counts, models used, stop-reason breakdown, total token usage (input, output, cache read, cache created, web-search/fetch counts), and an **estimated USD cost** computed at current list prices (Claude 5 family and older).

Accepts a full `.jsonl` path, a full session UUID, or any unique UUID prefix. Searches across every project under `~/.claude/projects/`.

```bash
./session-stats.sh 5d35e607           # UUID prefix
./session-stats.sh <full-uuid>        # full UUID
./session-stats.sh path/to/session.jsonl
```

Example output:

```
session: <uuid>
started: 2026-04-17T15:26:32Z
ended:   2026-04-17T16:04:50Z
elapsed: 0h 38m 18s

events by type:
   120 assistant
    81 user
    36 queue-operation
    …

models:
   120 claude-opus-4-7

stop reasons:
   102 tool_use
    18 end_turn

tokens:
  turns: 120
  input: 274
  output: 57165
  cache_read: 5531306
  cache_created: 93615
  web_searches: 0
  web_fetches: 0

cost (estimate, list prices):
  model:        claude-opus-4-7
  input:        $0.0041
  output:       $4.2874
  cache 5m:     $0.0000
  cache 1h:     $2.8085
  cache read:   $8.2970
  ─ total ─     $15.3970
  (list prices; actual billing may differ)
```

#### Cost model

Prices are list USD per 1M tokens (as of 2026-09) and live in **one file, `pricing.json`**, read by every cost script and by `cct_lib.py`; `pricing.jq` holds the shared jq helpers (`price`, `cost_of`, `priced`) that use it. Each rule is a regex on the model id, tried top to bottom; the last rule (empty regex) prices unknown models. To change prices, edit `pricing.json` only (cache write 5m = 1.25× input, 1h = 2× input, cache read = 0.1× input):

| Family                    | Input | Output | Cache write 5m | Cache write 1h | Cache read |
| ------------------------- | ----- | ------ | -------------- | -------------- | ---------- |
| Fable 5 / Mythos 5        | $10   | $50    | $12.50         | $20            | $1.00      |
| Opus 5, 4.8–4.5           | $5    | $25    | $6.25          | $10            | $0.50      |
| Opus 4.1 and older        | $15   | $75    | $18.75         | $30            | $1.50      |
| Sonnet 5                  | $2    | $10    | $2.50          | $4             | $0.20      |
| Sonnet 4.6 and older      | $3    | $15    | $3.75          | $6             | $0.30      |
| Haiku 4.5                 | $1    | $5     | $1.25          | $2             | $0.10      |
| Haiku 4 and older         | $0.80 | $4     | $1.00          | $1.60          | $0.08      |

Unknown model ids are costed at current Opus rates.

If a session used multiple models, cost is split and summed per model. Background-agent transcripts of the session (`<session-id>/subagents/`) are included and reported on an `agents:` line. Actual billing may differ (contract rates, batch API discounts, server-tool fees for web search/fetch are not included).

### `session-tools.sh`

Tool-usage report for one session: per-tool call counts, files read / written / edited, grep patterns, glob patterns, web-fetch URLs, and bash command count. Pass `--commands` to also list every bash command the session ran. Lines replayed after `/compact` are counted once.

```bash
./session-tools.sh 5d35e607
./session-tools.sh 5d35e607 --commands
```

Example output:

```
tool counts:
    38 Bash
     8 Write
     8 Edit
     4 Read
     1 Grep
     1 Agent

files read:
  …
files written:
  …
bash commands: 38 (pass --commands to list them)
```

### `session-questions.sh`

Lists the user's typed prompts (questions) in a session, in chronological order. Reads `last-prompt` events — Claude Code's verbatim snapshot of each typed user input — so slash-command wrappers, tool results, and system reminders are excluded. Embedded newlines inside a prompt are collapsed to ` / ` so each prompt prints on one line; consecutive duplicate snapshots are deduped.

```bash
./session-questions.sh 5d35e607
```

Example output:

```
session: 5d35e607-…

  1. add correct gitignore, this where tut it, in project level or root…
  2. list sessions shows command wrapper, not real prompt
  3. /commit-sub commit just already staged
```

### `dead-sessions.sh`

Lists project folders under `~/.claude/projects/` whose original project directory no longer exists — i.e. the project was removed, moved, or renamed. Session transcripts record the absolute `cwd` on every event, so the check is unambiguous (no lossy slug reversal).

```bash
./dead-sessions.sh         # one block per dead project folder
./dead-sessions.sh -v      # also list each session inside
```

Example output:

```
dead: /Users/<you>/projects/old-thing
    slug:     -Users-<you>-projects-old-thing
    sessions: 3  (1.2M)
dead: /Users/<you>/projects/_sandbox_/renamed-away
    slug:     -Users-<you>-projects--sandbox--renamed-away
    sessions: 1  (48K)

summary: 2 dead, 0 unknown
```

`unknown` means the slug has no transcripts with a `cwd` field (very old or empty folder) — can't be classified either way.

### `cost-report.sh`

Aggregates estimated token cost across every transcript — sessions and their background-agent transcripts — using the same pricing table as `session-stats.sh` (see [Cost model](#cost-model)).

![Cost report, extended](images/cost-report-extended.png)

```bash
./cost-report.sh                 # rolling windows: today / yesterday / week / 30 days
./cost-report.sh -v              # …with per-model breakdown
./cost-report.sh --months        # one row per calendar month (local time), newest first
./cost-report.sh --months -v     # …with per-model breakdown per month
./cost-report.sh --month 2026-08 # single-month detail: turns, sessions, token totals, per-model cost
```

In the TUI, **Usage & cost by month** shows the `--months` summary and a per-month detail view navigable with ←/→.

### `project-costs.sh`

Aggregates estimated token cost by project, with an optional per-day breakdown for a single project.

![Cost by project](images/cost-by-project.png)

`--dates <project>` with `-v` gives the daily trend split per model — the view the TUI reaches via **Cost by project** → pick a project → `v`:

![Daily cost per project, per model](images/project-daily-extended.png)

```bash
./project-costs.sh                          # total cost per project, sorted desc
./project-costs.sh -v                       # …with per-model breakdown
./project-costs.sh --dates <project>        # daily cost trend for one project
./project-costs.sh --dates <project> -v     # …with per-model daily breakdown
./project-costs.sh --list                   # project roots, one per line (scripts/TUI)

./project-costs.sh --merged                 # total cost per merged project
./project-costs.sh --merged -v              # …with one row per member folder
./project-costs.sh --merged --dates <name>  # daily trend for a merged project (-v: per model)
./project-costs.sh --merged --list          # merged project names, one per line
```

Example output:

```
Cost by project (estimate at list prices)
==================================================

~/code/webapp                                  2 sess   $   85.45
…code/_my_project_/tools/cli-tool              1 sess   $   35.36
~/code/_my_project_                            1 sess   $    4.36

total                                                   $  125.17
```

`<project>` accepts the full path (`~/…` or absolute) or any unambiguous trailing segment (`webapp`); an ambiguous argument lists the candidates and exits non-zero rather than silently picking one.

#### What counts as one project

A project is **one folder under `~/.claude/projects/`** — the directory Claude Code was *opened in*. That is Claude Code's own unit of grouping, and it is neither of the two things you might reasonably assume:

| Not this | Why it's wrong |
| --- | --- |
| The **git repo root** | One repo can hold several separately-opened projects. `_my_project_/tools/cli-tool` sits inside the `_my_project_` repo but was opened on its own, so it gets its own folder — rolling up to the repo would merge unrelated work. |
| The per-event **`cwd`** | `cwd` records where the shell stood at that moment and drifts as a session `cd`s around, so grouping on it invents a phantom project for every subdirectory visited (`webapp/assets`, `webapp/assets/build`, `.claude/skills` all belong to the project containing them). |

Each project is labelled with the shortest `cwd` recorded inside it, which is the folder that was opened. Long paths are clipped from the left, keeping the distinctive tail.

In the TUI, **Cost by project** ranks all projects by total cost; pick one to see its daily trend. `v` toggles the per-model breakdown in either view.

#### Merged projects

Sometimes one folder per project is the wrong unit the other way round: a project that moved or was renamed keeps its old transcripts under the old slug (the folder is *dead*, but the history is real), and a repo you opened from two subfolders shows up as two projects. A **merged project** binds such folders to one *primary* (the project as it is today) so they are counted together. Nothing under `~/.claude/projects/` is touched; the plain per-folder views keep working unchanged.

Bindings live in `~/.config/cct/merges.json` (`$XDG_CONFIG_HOME` is honoured):

```json
{
  "version": 1,
  "groups": [
    { "name": "webapp",
      "primary": "-Users-me-code-webapp",
      "members": [ "-Users-me-old-code-webapp",
                   "-Users-me-code-webapp-tools" ] }
  ]
}
```

`primary` and `members` are slugs — folder names under `~/.claude/projects/`. Members that no longer exist there are skipped. Edit the file by hand or use the TUI: **Merged projects → New merged project** walks you through picking the primary and adding folders (dead ones are listed as *(gone)*); each merged project then has cost (summary + daily), sessions across all folders, time analytics, export, add/remove folders, rename and delete (which removes only that entry from the file). `uninstall.sh` leaves the file in place and tells you where it is.

`<name>` matches a merged project exactly, or by a unique case-insensitive substring.

### `time-report.py`

Where the hours went. Only timestamped `user`/`assistant` events on the main thread count; every gap between two consecutive ones is attributed to whoever was busy during it, decided by the event that *ends* the gap:

| Gap ends in | Bucket | Meaning |
| --- | --- | --- |
| assistant output | **claude working** | generating, including thinking (reported separately when the transcript has per-block lines) |
| a tool result | **tools running** | tool execution, including the permission dialog in front of it. `AskUserQuestion`, `ExitPlanMode` and declined calls go to *waiting* instead. An instant tool (Read, Edit, Glob, …) that took longer than `--approve-secs` (15) is flagged as a likely permission prompt |
| a typed prompt | **you** | Claude was done, you were reading or typing. A prompt you answered with Esc while a tool call was pending counts as *waiting*. If a background agent or workflow (transcripts under `<session-id>/subagents/`) was running during the gap, that part is **agents** instead |
| Claude's next reply, with no prompt from you | *(as a `you` gap)* | Claude resumed by itself: auto-continue after a usage limit ("Continue from where you left off"), a background-task notification. Nothing was generating, so the gap is split into agents / you / break like an idle gap |

Any gap longer than `--break-min` (30) that was waiting on a person — an idle gap, a question, a pending tool call — is a **break** and leaves active time: a permission dialog left open overnight is not tool time. (A tool that genuinely ran longer than the threshold lands there too; rare, and the threshold is yours to set.) Only Claude's own generation is never capped.

`active = working + tools + agents + waiting + you`; `wall = active + breaks`. Lines replayed after `/compact` are ignored (first line per `uuid`). A gap is attributed to the local calendar date it starts on — a session that crosses midnight is split between the two dates. If you would rather count a day from a later hour, `--day-start H` (or `CCT_DAY_START=H`) does that; it is off by default.

#### Columns

The by-project, by-date and per-session tables share these columns. Durations print as `12h03m`, `3m12s` or `12s`.

| Column | What it counts |
| --- | --- |
| `sess` | Sessions that contributed to the row. In the by-date table a session that spans two dates counts on both, so the `total` row shows *distinct* sessions rather than the column sum. |
| `active` | `working + tools + waiting + you`. Everything except breaks — the time somebody (Claude, a tool, or you) was actually busy in the session. |
| `working` | Gaps that end in Claude's output: from your prompt to its first block, between its blocks, from a tool result to its next block. Thinking is inside this number; the single-session view breaks it out as *of which thinking* when the transcript has per-block lines. Never capped — Claude does not take breaks. |
| `tools` | Gaps that end in a tool result: the tool running, plus the permission dialog in front of it, which the transcript cannot tell apart. Instant tools (Read, Edit, Write, Glob, Grep, …) slower than `--approve-secs` are counted here but flagged as *likely permission prompts* in the single-session view. |
| `agents` | Time a background agent or workflow was running while the main thread had nothing to do (otherwise a `you` gap or a break). Overlapping agents count once. The single-session view also shows the number of runs, their total runtime and their cost. |
| `waiting` | Claude blocked on you: `AskUserQuestion`, `ExitPlanMode` (plan approval), a tool call you declined, or a permission prompt you left with Esc. |
| `you` | Gaps that end in your next typed prompt after Claude finished: reading the answer, thinking, typing, poking around the IDE. |
| `breaks` | Any gap longer than `--break-min` (30) that was waiting on a person — a `you` gap, a `waiting` gap, or a pending tool call. Left out of `active`; the single-session view shows how many there were. Attributed to the date the gap *starts* on. |

Per-session table adds `started` (local time of the first event), `id` (first 8 characters of the session UUID), `prompts` (distinct typed prompts) and `title` (Claude's auto-title, else the first prompt).

The single-session view (`--session`) shows the same buckets with their share of `active`, plus `wall` (first event → last event, equals `active + breaks`), the median and slowest *reply* (prompt → Claude's last output of that turn, tools and waiting included), the longest single tool call, and cost (main transcript + background agents) and models. Its per-turn table (`-v`) has one row per prompt: `reply` as above, `working` (Claude generation only, within that turn), `tools` (number of tool calls), `cost`, and the prompt's first line (`⏎` marks a turn you interrupted).

Two caveats when reading sums: sessions running side by side each count in full, so a date's total across projects can exceed the clock; and a session that crosses midnight is split between the two dates. A live session is counted up to its last written event, so the turn still in progress is not in yet.

Two things the transcript cannot show, so neither can this report: time you spend on the project without talking to Claude (editing, testing, reading) — it looks like a break — and, when the same project was opened under two folder names (renamed, moved), the sessions filed under the old name. Bind the old folder as a [merged project](#merged-projects) to see both together.

```bash
./time-report.py                         # accumulated time per project (active-sorted)
./time-report.py --dates                 # per local day, all projects
./time-report.py --dates <project>       # per day, one project
./time-report.py --sessions <project>    # one row per session
./time-report.py --session <id> [-v]     # one session; -v adds a per-turn table
./time-report.py --merged                # per merged project
./time-report.py --merged --dates <name>
./time-report.py --merged --sessions <name>
./time-report.py … --json                # machine-readable
./time-report.py … --break-min 60        # longer pauses still count as active
./time-report.py … --day-start 4         # night sessions stay on one date
```

`<project>` is the project path, an unambiguous trailing segment, or the transcript folder under `~/.claude/projects/` (full path — a bare slug starts with `-` and would be read as an option).

Example (`--session … -v`):

```
session: <uuid>
title:   Implement commit substitution feature
project: ~/path/to/some-project
started: 2026-04-17 15:26:32  (local time)
ended:   2026-04-17 18:04:50
wall:    2h 38m 18s
active:  1h 51m 40s   (1 break(s) > 30m excluded: 46m 38s)

  claude working                40m 12s   36%  ████████████
    of which thinking           14m 03s
  tools running                 39m 05s   35%  ███████████
  waiting on you                 2m 10s    2%  ▌             questions / plan approval / declined prompts
  you (reading, typing)         30m 13s   27%  █████████

turns:         6 prompts   claude reply: median 4m 12s · max 21m 03s
longest tool:  Bash 9m 41s
cost:          $15.40 (list prices)   models: claude-opus-4-7

  #  prompt (local)      reply  working tools    cost  prompt
  1  2026-04-17 15:26   21m03s   11m40s    31 $  5.94  add correct gitignore, this where tut it, in…
  2  2026-04-17 15:51    8m14s    5m02s    12 $  2.18  list sessions shows command wrapper, not rea…
```

In the TUI: **Time analytics** (all projects, `v` for by-date; a project or merged project, `v` for per-session) and, inside a session, **Time breakdown** (`v` for the per-turn table).

### `export-prompts.py`

Writes the prompts you typed. Default: one text file per session in `~/cct-export/<project>/` (override with `-o DIR` or `$CCT_EXPORT_DIR`), named `YYYY-MM-DD_HHMM_<shortid>.txt` from the session's local start time. Nothing is ever overwritten: if any target file already exists, the export stops before writing anything, lists the files in the way and exits 3 — pick another folder or move the old files yourself.

```bash
./export-prompts.py <project> [-o DIR] [--json]
./export-prompts.py --merged <name> [-o DIR] [--json]
./export-prompts.py --session <id> [-o DIR] [--json]
```

Text file:

```
session:  <uuid>
title:    Implement commit substitution feature
project:  ~/path/to/some-project
started:  2026-04-17 15:26:32  (UTC+02:00)
ended:    2026-04-17 18:04:50
prompts:  6

[1] 2026-04-17 15:26:32  (reply 21m03s · 31 tool calls · $5.94)
add correct gitignore, this where tut it, in project level or root?

[2] 2026-04-17 15:51:10  (reply 8m14s · 12 tool calls · $2.18)
list sessions shows command wrapper, not real prompt
```

`--json` puts everything in one file (`<project>.prompts.json`, or `<start>_<shortid>.json` for `--session`), schema `cct-prompts/1`:

```json
{ "schema": "cct-prompts/1", "exported_at": "…Z", "tz": "UTC+02:00",
  "project": { "name": "some-project", "root": "/path/to/some-project",
               "slugs": ["-path-to-some-project"], "merged": false },
  "session_count": 1, "prompt_count": 6, "cost_usd": 15.40,
  "sessions": [
    { "id": "<uuid>", "short_id": "5d35e607", "title": "Implement commit substitution feature",
      "slug": "-path-to-some-project", "cwd": "/path/to/some-project",
      "started": "2026-04-17T13:26:32.000Z", "ended": "2026-04-17T16:04:50.000Z",
      "started_local": "2026-04-17 15:26:32", "ended_local": "2026-04-17 18:04:50",
      "prompt_count": 6, "cost_usd": 15.40, "cost_main_usd": 15.40, "cost_agents_usd": 0,
      "agent_runs": 0, "models": { "claude-opus-4-7": 120 },
      "time": { "wall": 9498, "active": 6700, "working": 2412, "thinking": 843,
                "tools": 2345, "approval": 0, "approval_calls": 0, "agents": 0,
                "waiting": 130, "idle": 1813, "breaks": 2798, "break_count": 1 },
      "prompts": [
        { "n": 1, "ts": "2026-04-17T13:26:32.000Z", "local": "2026-04-17 15:26:32",
          "ts_approx": false,
          "text": "add correct gitignore, this where tut it, in project level or root?",
          "chars": 67, "words": 13, "lines": 1,
          "response_seconds": 1263, "working_seconds": 700,
          "tool_calls": 31, "tools": { "Bash": 12, "Read": 8, "Edit": 7, "Write": 3, "Grep": 1 },
          "cost_usd": 5.94, "cost_agents_usd": 0, "models": ["claude-opus-4-7"],
          "interrupted": false } ] } ] }
```

`ts_approx` is true when no typed user event preceded the snapshot (the timestamp is then the nearest earlier event). Times in seconds; `response_seconds` is prompt → Claude's last output of that turn. `cost_usd` includes the background agents started during that turn (`cost_agents_usd` is that part alone).

In the TUI: **Export prompts** (pick a project or merged project → format → folder), the same inside a merged project, and **Export prompts of this session** in the session action menu.

### `stack-report.sh`

Aggregates which **languages and ecosystems** you worked on, bucketed by time window (`today` / `week` / `30 days`) — same windows as `cost-report.sh`. Signal comes from `file_path` arguments of Read/Write/Edit tool calls across every transcript: file extensions map to languages (`.py` → Python, `.ino` → Arduino, …) and marker basenames map to ecosystems (`platformio.ini` → PlatformIO, `Cargo.toml` → Rust/Cargo, `Dockerfile` → Docker, …). Marker matches take precedence so `platformio.ini` doesn't also get counted as "INI".

```bash
./stack-report.sh          # summary (drops language entries with <2 touches)
./stack-report.sh -v       # extended (include every classified touch)
```

Example output:

Each row shows two numbers plus a bar scaled to the section's top entry: `touches` (Read/Write/Edit activity volume), `files` (distinct file paths — breadth), then the bar for instant magnitude comparison.

```
today — 2026-04-17
  318 touches across 102 files  (54 unknown)

    touches    files
  ecosystems:
          6        6   ██████████  Git
          4        3   ██████▌     PlatformIO
          1        1   █▌          Node.js

  languages:
         81       14   ██████████  Bash
         80       45   █████████▌  TypeScript
         66       17   ████████    Markdown
         11        4   █           C++
```

High touches with low files = heavy iteration on a small set (e.g. `Bash 81/14`). Similar touches with many files = broader coverage (`TypeScript 80/45`). Bars are scaled per section so `ecosystems` and `languages` don't share a ruler (their magnitudes differ by an order).

## Ideas for more scripts

- **`session-summary.sh <id>`** — print only user/assistant text from a session, stripping tool noise.
- **`session-grep.sh <pattern>`** — full-text search across every transcript for a pattern.
- **`tool-usage-all.sh`** — tally tool usage across _every_ session (useful for tuning the `less-permission-prompts` allowlist).
- **Time by hour of day / weekday** — the buckets in `cct_lib.analyze_session` are keyed by gap start, so a heat map of when you actually work is one `group_by` away.
- **Per-agent view** — `session-tools.sh` reports the main thread only; the tool calls of each background agent (`<session>/subagents/`) are there for a per-workflow breakdown.
