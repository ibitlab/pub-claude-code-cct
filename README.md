# cct — Claude Code session browser

See what Claude Code has been doing on your machine: which sessions ran, what
they cost, which tools and files they touched, and what you actually typed.

Claude Code stores every session as a transcript under `~/.claude/projects/`,
but gives you no way to list or inspect them outside its own resume picker.
`cct` is an arrow-key terminal UI over those transcripts — no UUIDs, no paths to
type. It reads only; it never modifies or deletes your Claude Code state.

![The cct main menu](docs/images/menu.png)

*(Project names, paths and session titles are blurred in all screenshots.)*

> **Heads-up.** cct is a homegrown tool, written for personal use and shared
> as is. It may contain bugs — including in the numbers. Costs in particular
> are this tool's own estimate: token counts read from transcripts, priced at
> public list prices, with its own idea of what counts as one API call. They
> can be wrong, and they are never a bill. Check your provider's billing page
> for what you actually pay.

## Requirements

- macOS or Linux, `bash`
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq` / `apt install jq`
- `python3` (3.8+) — stdlib only, nothing to `pip install`

## Install

```bash
git clone <this-repo> claude-code-cct
cd claude-code-cct
./install.sh          # symlinks cct into ~/.local/bin
```

Make sure `~/.local/bin` is on your `PATH` (the installer tells you if it isn't).
Because it's a symlink, `git pull` updates the installed command too.

```bash
./install.sh --force     # replace an unrelated cct already in ~/.local/bin
./uninstall.sh           # remove the symlink (its state and config files are
                         # listed for you to delete by hand — nothing else is removed)
```

## Use it

```bash
cct       # from any directory
```

You get a menu:

| Entry | What you see |
| --- | --- |
| **Status** | At-a-glance dashboard: live sessions, today/week/30-day cost, cleanup hints |
| **Sessions in current project** | Sessions for the directory you're standing in |
| **Sessions in all projects** | Every session Claude Code knows about |
| **Active sessions** | Claude Code processes running right now, system-wide |
| **Cost report** | Estimated token spend: today / yesterday / week / 30 days |
| **Usage & cost by month** | Per-month totals, ←/→ to step between months |
| **Cost by project** | Spend ranked by project, with a daily trend per project |
| **Merged projects** | Bind an old location or a split-off folder to a primary project and see cost, sessions, time and exports for them together |
| **Time analytics** | Where the hours went: Claude working, tools running, waiting on you, you reading/typing — per project, per day, per session |
| **Export prompts** | Your typed prompts as one text file per session, or one JSON with per-prompt stats |
| **Stack / tech used** | Languages and ecosystems you worked on, by time window |
| **Troubleshooting / cleanup** | Dead project folders, stale session markers |

**Status** answers "what's going on right now?" — what's running, what today
and this month cost, what needs cleaning up:

![Status dashboard](docs/images/status.png)

The session picker lists every session with its date, message count, title and
project:

![Session picker](docs/images/sessions.png)

Pick a session and you can see its **stats + cost**, its **time breakdown**
(how long Claude worked, how long tools ran, how long it waited on you), its
**tool usage** (files read/written/edited, bash commands), or **your prompts**
— just what you typed, without tool noise — and export those prompts to a file.

![Stats and cost for one session](docs/images/session-stats.png)

### Where the money goes

**Cost report** sums recent spend; press `v` for the extended view, which splits
every window by model (Fable magenta, Opus blue, Sonnet green, Haiku yellow):

![Cost report, extended](docs/images/cost-report-extended.png)

**Cost by project** ranks your projects by total spend:

![Cost by project](docs/images/cost-by-project.png)

Pick the most expensive one and you get its day-by-day trend — `v` again breaks
each day down by model, which is usually where an expensive week explains
itself:

![Daily cost for one project, per model](docs/images/project-daily-extended.png)

### One project, several folders

Claude Code files transcripts by the folder you opened. Move or rename a
project and its history splits in two; open a repo from two subfolders and you
get two "projects". **Merged projects** fixes the bookkeeping without touching
anything on disk: pick the primary folder (the project as it is today), add the
old locations — folders that no longer exist show as *(gone)* — or the split-off
subfolders, and the merged project gets its own cost, session list, time
analytics and export, all counted together. The plain per-folder views stay as
they were; bindings live in `~/.config/cct/merges.json`.

### Where the time goes

**Time analytics** turns the event timestamps of every session into four
buckets: **Claude working** (generating, including thinking), **tools running**
(tool calls incl. permission dialogs), **waiting on you** (questions, plan
approval, declined prompts) and **you** (reading and typing between turns).
Gaps longer than 30 minutes count as breaks and are left out of active time.
You get it per project, per day, per session, and per turn inside one session
(how long each reply took, how many tool calls, what it cost). Days are local
calendar days. What you do on the project without talking to Claude is
invisible to the transcript, so it shows up as a break.

### Export your prompts

**Export prompts** writes what you typed. By default that is one text file per
session, named after the session's start time — `2026-04-17_1526_5d35e607.txt`
— with every prompt verbatim under a timestamped header. Choose JSON instead
and you get one file for the whole project with, per prompt: UTC and local
timestamps, text size, how long Claude took to reply, working seconds, tool
calls by name, estimated cost and models — enough to build your own analytics
on top. Files go to `~/cct-export/<project>/` unless you type another folder;
nothing is ever overwritten — if a file is already there, the export stops
and tells you.

Keys: ↑/↓ or `j`/`k`, PgUp/PgDn, Home/End, Enter selects, Esc or `q` goes back,
`v` toggles the extended view where offered, Ctrl-C quits.

Costs are **estimates** computed from token counts at public list prices; actual
billing may differ. The price table is one file, `pricing.json` — edit it there
when prices change and every view picks it up.

## Scripts on their own

The TUI just drives a set of standalone scripts — `status.sh`,
`list-sessions.sh`, `session-stats.sh`, `session-tools.sh`,
`session-questions.sh`, `cost-report.sh`, `project-costs.sh`, `stack-report.sh`,
`active-sessions.sh`, `dead-sessions.sh`, plus two Python ones,
`time-report.py` and `export-prompts.py` (stdlib only). Run any of them
directly if you'd rather script or pipe the output.

Full options, example output, the pricing table and notes on the transcript
format are in [docs/reference.md](docs/reference.md).
