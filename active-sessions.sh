#!/usr/bin/env bash
# active-sessions.sh — list Claude Code sessions that are running right now.
#
# Each live `claude` process drops a marker at ~/.claude/sessions/<PID>.json
# with its session id and cwd. We scan those files, keep the ones whose PID
# is still alive, and join against the transcript to show useful short info.
#
# Usage:
#   ./active-sessions.sh              # one row per live session
#   ./active-sessions.sh -v           # also list stale marker files (process gone)
#   ./active-sessions.sh --stale-only # only the stale section (or an OK banner)

set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

SESSIONS_DIR="$HOME/.claude/sessions"
PROJECTS_ROOT="$HOME/.claude/projects"
VERBOSE=0
STALE_ONLY=0
case "${1:-}" in
  -v|--verbose)    VERBOSE=1 ;;
  --stale-only)    STALE_ONLY=1; VERBOSE=1 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

[[ -d "$SESSIONS_DIR" ]] || { echo "no sessions dir: $SESSIONS_DIR" >&2; exit 0; }

# Mirror the slug rule from list-sessions.sh: '/' and '_' → '-'.
slugify() { printf '%s' "$1" | tr '/_' '--'; }

# Relative "ago" from epoch-seconds (for e.g. "startedAt").
now=$(date +%s)
ago() {
  local e="$1"
  local d=$(( now - e ))
  if   (( d < 60 ));     then printf 'just now'
  elif (( d < 3600 ));   then printf '%dm ago' $(( d / 60 ))
  elif (( d < 86400 ));  then printf '%dh%02dm ago' $(( d / 3600 )) $(( (d % 3600) / 60 ))
  else                        printf '%dd ago' $(( d / 86400 ))
  fi
}

# Same as ago() but without the trailing " ago" — for table cells where the
# column header (AGE / IDLE) already carries the meaning.
ago_short() { local s; s=$(ago "$1"); printf '%s' "${s% ago}"; }

# Short headline from a jsonl: ai-title (latest) → last last-prompt → first-prompt.
headline_for() {
  local jsonl="$1"
  local t
  t=$(jq -r 'select(.type=="ai-title") | .aiTitle // empty' "$jsonl" 2>/dev/null | tail -1)
  [[ -n "$t" ]] && { printf '%s' "$t"; return; }
  t=$(jq -r 'select(.type=="last-prompt") | .lastPrompt // empty' "$jsonl" 2>/dev/null | tail -1)
  [[ -n "$t" ]] && { printf '%s' "$t"; return; }
  printf '<no prompt>'
}

# Count user round trips via `last-prompt` snapshots.
turns_for() {
  jq -r 'select(.type=="last-prompt")' "$1" 2>/dev/null | grep -c . || true
}

# Short "Tool: summary" describing the latest pending tool_use — shown in the
# TITLE column when the session is sitting at a permission prompt, so the
# reader can see what they're being asked to approve without switching
# terminals. Falls back gracefully when fields are missing.
pending_tool_for() {
  local jsonl="$1"
  jq -rn '
    last(inputs | select(.type=="assistant")) as $a
    | ($a.message.content // [] | map(select(.type=="tool_use")) | last) as $t
    | if $t == null then ""
      else
        ($t.input // {}) as $i
        | ($i.description
           // ($i.command | if type=="string" then split("\n")[0] | sub("^#\\s*"; "") else null end)
           // ($i.file_path | if type=="string" then sub(".*/"; "") else null end)
           // $i.pattern
           // "") as $s
        | if $s == "" then $t.name else "\($t.name): \($s)" end
      end' "$jsonl" 2>/dev/null
}

# File mtime (seconds since epoch) — proxy for "last activity".
mtime_of() { stat -f '%m' "$1" 2>/dev/null || echo 0; }

# How long a pending tool_use must sit before we call it "awaiting permission"
# rather than "tool running." Typical tool calls either finish or write a
# tool_result (streaming / partial) within a couple of seconds; a silent
# pause past this threshold is almost always the permission dialog.
APPROVE_STALL_SECS=15

# Session status inferred from the tail of the transcript + how stale it is:
#   asking   — last assistant turn ended with end_turn AND the final text block
#              ends in '?' (clarifying question; Claude is waiting on an answer)
#   idle     — last assistant turn ended with end_turn, no trailing question
#   tool     — assistant emitted a tool_use and the transcript is still being
#              updated (tool is running)
#   approve  — tool_use emitted but the transcript has been silent past the
#              stall threshold, so Claude is sitting at "Allow this command?"
#   working  — user msg (typed prompt or tool_result) queued for assistant
#   ?        — can't tell (no user/assistant events yet)
# Only user/assistant events are considered; queue-operation / last-prompt /
# ai-title / file-history-snapshot are bookkeeping and don't indicate state.
status_for() {
  local jsonl="$1" last_epoch="$2" row last_type last_stop
  row=$(jq -rc 'select(.type=="assistant" or .type=="user")
                | [.type, (.message.stop_reason // "")] | @tsv' \
        "$jsonl" 2>/dev/null | tail -1)
  IFS=$'\t' read -r last_type last_stop <<< "$row"
  case "$last_type" in
    assistant)
      case "$last_stop" in
        end_turn)
          # Look at the last text block of the latest assistant message.
          # A trailing '?' (allowing closing punctuation / whitespace after it)
          # means Claude asked something and is waiting on an answer.
          local tail_text
          tail_text=$(jq -rn '
            last(inputs | select(.type=="assistant")) as $a
            | ($a.message.content // []
               | map(select(.type=="text") | .text)) | last // ""' \
            "$jsonl" 2>/dev/null)
          if [[ "$tail_text" =~ \?[[:space:][:punct:]]*$ ]]; then
            echo "asking"
          else
            echo "idle"
          fi ;;
        tool_use)
          if (( last_epoch > 0 && now - last_epoch >= APPROVE_STALL_SECS )); then
            echo "approve"
          else
            echo "tool"
          fi ;;
        *)        echo "working" ;;
      esac ;;
    user) echo "working" ;;
    *)    echo "?" ;;
  esac
}

# Truncate for the headline column.
trunc60() { awk '{ if (length($0) > 60) print substr($0,1,57)"…"; else print $0 }'; }

# ---------- scan markers ----------

alive_count=0
stale_count=0
alive_rows=()        # TSV: cwd\tpid\tage\tidle\tsid\tstatus\tturns\ttitle — grouped/printed later
stale_rows=()
status_counts=""     # newline-separated statuses, for the per-status summary

for f in "$SESSIONS_DIR"/*.json; do
  [[ -f "$f" ]] || continue
  pid=$(jq -r .pid "$f" 2>/dev/null || echo "")
  sid=$(jq -r .sessionId "$f" 2>/dev/null || echo "")
  cwd=$(jq -r .cwd "$f" 2>/dev/null || echo "")
  started_ms=$(jq -r '.startedAt // 0' "$f" 2>/dev/null)
  entry=$(jq -r '.entrypoint // ""' "$f" 2>/dev/null)
  started_s=$(( started_ms / 1000 ))
  [[ -z "$pid" || -z "$sid" ]] && continue

  if kill -0 "$pid" 2>/dev/null; then
    # Process exists → active
    alive_count=$((alive_count+1))
    # Find the session's jsonl to pull title / turns / last activity.
    slug=$(slugify "$cwd")
    jsonl="$PROJECTS_ROOT/$slug/$sid.jsonl"
    age_str=$(ago_short "$started_s")
    if [[ -f "$jsonl" ]]; then
      title=$(headline_for "$jsonl" | trunc60)
      turns=$(turns_for "$jsonl")
      last_epoch=$(mtime_of "$jsonl")
      idle_str=$(ago_short "$last_epoch")
      status=$(status_for "$jsonl" "$last_epoch")
      # When a session is stuck on a permission prompt, the headline
      # describes the whole conversation — not useful. Replace it with a
      # summary of the pending tool call so the user sees WHAT needs
      # approving.
      if [[ "$status" == "approve" ]]; then
        pending=$(pending_tool_for "$jsonl" | trunc60)
        [[ -n "$pending" ]] && title="$pending"
      fi
    else
      title="<no transcript yet>"
      turns=0
      idle_str="-"
      status="unknown"
    fi
    # Map the internal "?" sentinel to a word the reader can act on.
    [[ "$status" == "?" ]] && status="unknown"
    # When the relative time is indistinguishable from the session's age,
    # the IDLE column would duplicate AGE — show a dash instead. ASCII
    # hyphen (not "—") because awk's %-Ns pads bytes, not display width.
    [[ "$idle_str" == "$age_str" ]] && idle_str="-"
    status_counts+="$status"$'\n'
    alive_rows+=("$cwd"$'\t'"$pid"$'\t'"$age_str"$'\t'"$idle_str"$'\t'"${sid:0:8}"$'\t'"$status"$'\t'"$turns"$'\t'"$title")
  else
    stale_count=$((stale_count+1))
    stale_rows+=("$(printf '%-6s  pid gone  %s  (%s)' "$pid" "${sid:0:8}" "$(basename "$f")")")
  fi
done

# ---------- print ----------

if [[ $STALE_ONLY -eq 1 ]]; then
  echo "Stale session markers"
  echo "====================="
  echo
  if (( stale_count == 0 )); then
    echo "  OK — no stale markers. ($alive_count live session(s) in ~/.claude/sessions/)"
  else
    echo "Leftover marker files whose Claude Code process no longer exists."
    echo "Safe to delete — Claude Code ignores stale markers on next scan."
    echo
    for r in "${stale_rows[@]}"; do
      printf '  %s\n' "$r"
    done
    echo
    printf 'summary: %d stale marker(s)  (%d live session(s) still running)\n' \
      "$stale_count" "$alive_count"
    echo
    echo 'To delete them all at once:'
    echo '  for f in ~/.claude/sessions/*.json; do'
    echo '    pid=$(jq -r .pid "$f"); kill -0 "$pid" 2>/dev/null || rm -f "$f"'
    echo '  done'
  fi
  exit 0
fi

if (( alive_count == 0 )); then
  echo "Active Claude Code sessions — 0 running"
  (( stale_count > 0 )) && printf '  (%d stale marker(s))\n' "$stale_count"
else
  home="$HOME"
  # Per-status breakdown, e.g. "1 working, 5 idle, 2 unknown".
  status_line=$(printf '%s' "$status_counts" | sort | uniq -c \
    | awk '{printf "%s%d %s", (NR>1?", ":""), $1, $2} END {print ""}')
  printf 'Active Claude Code sessions — %d running' "$alive_count"
  [[ -n "$status_line" ]] && printf ' (%s)' "$status_line"
  printf '\n'
  (( stale_count > 0 )) && printf '  (%d stale marker(s))\n' "$stale_count"
  echo

  # Column widths — AGE/IDLE are 6 chars ("11h02m") but "just now" is 8, so 8.
  # STATUS max is "working"/"unknown" (7). MSGS right-aligned in 4 cols.
  printf '%-6s  %-8s  %-8s  %-8s  %-7s  %4s  %s\n' \
    "PID" "AGE" "IDLE" "ID" "STATUS" "MSGS" "TITLE"
  printf '%s\n' "────────────────────────────────────────────────────────────────────────"

  # Sort rows by cwd for contiguous groups, then let awk count per-cwd and emit
  # a group subheader each time the cwd changes. Done in awk because macOS
  # bash 3.2 has no associative arrays.
  printf '%s\n' "${alive_rows[@]}" \
    | sort -t$'\t' -k1,1 -s \
    | awk -F'\t' -v home="$home" '
      { rows[NR] = $0; cnt[$1]++ }
      END {
        fmt = "%-6s  %-8s  %-8s  %-8s  %-7s  %4s  %s\n"
        current = ""
        for (i = 1; i <= NR; i++) {
          n = split(rows[i], f, "\t")
          cwd = f[1]
          if (cwd != current) {
            short = cwd
            if (home != "" && substr(cwd, 1, length(home)) == home)
              short = "~" substr(cwd, length(home) + 1)
            print ""
            printf "%s  (%d)\n", short, cnt[cwd]
            current = cwd
          }
          printf fmt, f[2], f[3], f[4], f[5], f[6], f[7], f[8]
        }
      }
    '
fi

if [[ $VERBOSE -eq 1 && $stale_count -gt 0 ]]; then
  echo
  echo "Stale markers (process no longer running — safe to delete):"
  for r in "${stale_rows[@]}"; do
    printf '  %s\n' "$r"
  done
fi
