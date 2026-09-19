# cct — reference

Detailed reference for `cct` and the scripts it wraps. For installation and a
quick tour, see the [README](../README.md).

## The TUI

`cct` is an arrow-key TUI that wraps every script in this folder so you never type session UUIDs or paths. Pure Python standard library (`curses`) — no pip install.

Flow: **entry menu** → pick scope → **session picker** (arrow keys) → **action menu** (stats / tools / bash commands) → inline output → Esc climbs back. State (last-used menu choice) persists in `~/.cache/cct/state.json` (mode `0600`).

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

Since it's append-only JSONL, any `jq` / `awk` pipeline works against it.

## Scripts

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

Prices are list USD per 1M tokens (as of 2026-09), hard-coded in the script (cache write 5m = 1.25× input, 1h = 2× input, cache read = 0.1× input):

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

If a session used multiple models, cost is split and summed per model. Actual billing may differ (contract rates, batch API discounts, server-tool fees for web search/fetch are not included).

### `session-tools.sh`

Tool-usage report for one session: per-tool call counts, files read / written / edited, grep patterns, glob patterns, web-fetch URLs, and bash command count. Pass `--commands` to also list every bash command the session ran.

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

Aggregates estimated token cost across every transcript, using the same pricing table as `session-stats.sh` (see [Cost model](#cost-model)).

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

```bash
./project-costs.sh                          # total cost per project, sorted desc
./project-costs.sh -v                       # …with per-model breakdown
./project-costs.sh --dates <project>        # daily cost trend for one project
./project-costs.sh --dates <project> -v     # …with per-model daily breakdown
./project-costs.sh --list                   # project roots, one per line (scripts/TUI)
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
