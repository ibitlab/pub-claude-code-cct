#!/usr/bin/env bash
# status.sh — one-screen Claude Code status overview.
#
# Rolls up the other scripts into a single "what's going on?" dashboard:
#   * active sessions (count + per-project)
#   * token cost for today / this week / last 30 days
#   * cleanup signals (dead projects, stale session markers)
#
# Usage: ./status.sh

set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
SESSIONS_DIR="$HOME/.claude/sessions"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Prices: pricing.json (the table) + pricing.jq (the helpers), shared by
# every cost script.
[[ -f "$HERE/pricing.json" && -f "$HERE/pricing.jq" ]] \
  || { echo "pricing.json / pricing.jq missing next to $0" >&2; exit 1; }
JQ_DEFS=$(jq -r '"def pricing: \(tojson);"' "$HERE/pricing.json"; cat "$HERE/pricing.jq")

# ---------- active sessions (live PIDs in ~/.claude/sessions/*.json) ----------

alive=0
stale=0
# Mac bash is 3.2 (no assoc arrays) — accumulate cwds in a newline-separated
# string, then `sort | uniq -c` in the print section.
active_cwds=""

if [[ -d "$SESSIONS_DIR" ]]; then
  for f in "$SESSIONS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    pid=$(jq -r .pid "$f" 2>/dev/null || echo "")
    cwd=$(jq -r .cwd "$f" 2>/dev/null || echo "")
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      alive=$((alive+1))
      # Accumulate in a newline-separated string (bash 3.2 friendly).
      active_cwds+="$cwd"$'\n'
    else
      stale=$((stale+1))
    fi
  done
fi

# ---------- cost aggregation (local-time windows, UTC ISO comparison) ----------

today_local=$(date +%Y-%m-%d)
today_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)
yesterday_epoch=$(( today_epoch - 86400 ))
dow=$(date +%u)
monday_epoch=$(date -v-$((dow-1))d -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)
month_epoch=$(date -v-30d   -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)

to_utc_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
TODAY_ISO=$(to_utc_iso "$today_epoch")
YESTERDAY_ISO=$(to_utc_iso "$yesterday_epoch")
WEEK_ISO=$(to_utc_iso "$monday_epoch")
MONTH_ISO=$(to_utc_iso "$month_epoch")

# Main transcripts plus background-agent transcripts (<session>/subagents/).
AGG=$({ find "$ROOT" -maxdepth 2 -name "*.jsonl" -print0
        find "$ROOT" -path "*/subagents/*" -name "*.jsonl" -print0; } 2>/dev/null \
  | xargs -0 cat 2>/dev/null \
  | jq -sr --arg d "$TODAY_ISO" --arg y "$YESTERDAY_ISO" \
           --arg w "$WEEK_ISO" --arg m "$MONTH_ISO" "$JQ_DEFS"'
    # start..end_excl window; end_excl="" means open-ended (now).
    def window(start; end_excl; records):
      ([ records[]
         | select(.ts >= start)
         | select(end_excl == "" or .ts < end_excl) ]) as $ae
      | { cost:     ([$ae[].cost] | add // 0),
          sessions: ([$ae[].sid] | unique | length),
          turns:    ([$ae[] | select(.end)] | length) };

    [ priced[]
      | select(.timestamp)
      | { ts:   .timestamp,
          sid:  .sessionId,
          cost: cost_of(.message.usage; price(.message.model)),
          end:  (.message.stop_reason == "end_turn") }
    ] as $a |
    { today:     window($d; "";   $a),
      yesterday: window($y; $d;   $a),
      week:      window($w; "";   $a),
      month:     window($m; "";   $a) }
  ')

# ---------- dead projects (cwd no longer exists) ----------

dead=0
if [[ -d "$ROOT" ]]; then
  for d in "$ROOT"/*/; do
    cwd=""
    for f in "$d"*.jsonl; do
      [[ -f "$f" ]] || continue
      # tail -1 (not head) avoids jq SIGPIPE under pipefail on big transcripts.
      cwd=$(jq -r 'select(.cwd) | .cwd' "$f" 2>/dev/null | tail -1)
      [[ -n "$cwd" ]] && break
    done
    [[ -n "$cwd" && ! -d "$cwd" ]] && dead=$((dead+1))
  done
fi

# ---------- print ----------

home="$HOME"
echo "Claude Code — status @ $(date '+%Y-%m-%d %H:%M')"
printf '%s\n' "===================================================="
echo

# active
printf '  active:   %d session(s) running\n' "$alive"
if [[ $alive -gt 0 ]]; then
  # One row per unique cwd with count.
  printf '%s' "$active_cwds" | sort | uniq -c | sort -rn | while read -r n cwd; do
    [[ -z "$cwd" ]] && continue
    short="${cwd/#$home/~}"
    printf '            %2d × %s\n' "$n" "$short"
  done
fi

echo

# cost
fmt() {
  # key
  local k="$1" cost turns sess
  cost=$( echo "$AGG" | jq -r ".$k.cost")
  turns=$(echo "$AGG" | jq -r ".$k.turns")
  sess=$( echo "$AGG" | jq -r ".$k.sessions")
  printf '%4d turns  %2d sessions  $%8.2f' "$turns" "$sess" "$cost"
}
printf '  today:      %s\n' "$(fmt today)"
printf '  yesterday:  %s\n' "$(fmt yesterday)"
printf '  week:       %s\n' "$(fmt week)"
printf '  30 days:    %s\n' "$(fmt month)"

echo

# cleanup
printf '  cleanup:  %2d dead project(s)           (cct → Troubleshooting → Dead projects)\n' "$dead"
printf '            %2d stale session marker(s)' "$stale"
[[ $stale -gt 0 ]] && printf "   (cct → Troubleshooting → Stale session markers)"
echo
