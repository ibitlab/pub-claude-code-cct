#!/usr/bin/env bash
# cost-report.sh — aggregate Claude Code token cost across time windows.
#
# Windows (all in local time; boundaries compared to UTC timestamps in jsonl):
#   day    — 00:00 local today → now
#   week   — most recent Monday 00:00 local → now
#   month  — rolling last 30 days → now
#
# Usage:
#   ./cost-report.sh                 # short — one row per window
#   ./cost-report.sh -v              # extended — adds per-model breakdown
#   ./cost-report.sh --months        # one row per calendar month (local time)
#   ./cost-report.sh --months -v     # …with per-model breakdown per month
#   ./cost-report.sh --month YYYY-MM # single-month detail (tokens + per-model)
#
# Prices come from pricing.json next to this script (shared by every cost
# script). Estimates only — actual billing depends on your plan.

set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
HERE="$(cd "$(dirname "$0")" && pwd)"
EXTENDED=0
MODE=windows
MONTH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--extended) EXTENDED=1; shift ;;
    --months)      MODE=months; shift ;;
    --month)
      MODE=month
      MONTH="${2:-}"
      [[ "$MONTH" =~ ^[0-9]{4}-[0-9]{2}$ ]] || { echo "--month needs YYYY-MM" >&2; exit 1; }
      shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------- pricing (shared: pricing.json = the table, pricing.jq = the helpers) ----------
[[ -f "$HERE/pricing.json" && -f "$HERE/pricing.jq" ]] \
  || { echo "pricing.json / pricing.jq missing next to $0" >&2; exit 1; }
JQ_DEFS=$(jq -r '"def pricing: \(tojson);"' "$HERE/pricing.json"; cat "$HERE/pricing.jq")

# ---------- print helpers ----------

# Per-model color so the cost sub-rows are scannable. Respect NO_COLOR.
# https://no-color.org
if [[ -z "${NO_COLOR:-}" ]]; then
  RST=$'\e[0m'
else
  RST=""
fi
color_for() {
  [[ -n "${NO_COLOR:-}" ]] && return 0
  case "$1" in
    claude-fable*|claude-mythos*) printf '\e[95m' ;;  # bright magenta — Fable/Mythos tier
    claude-opus*)                 printf '\e[94m' ;;  # bright blue
    claude-sonnet*)               printf '\e[92m' ;;  # bright green
    claude-haiku*)                printf '\e[93m' ;;  # bright yellow
    *)                            ;;
  esac
}

fmt_num() {
  # thousand-separate an integer, portable enough for bash
  printf "%'d" "$1" 2>/dev/null || printf '%s' "$1"
}

# printf's %-Ns pads by BYTES; the `→` in date spans is 3 bytes but 1
# display column, which shifted the columns right of it to the left. Pad
# by character count instead.  We force a UTF-8 locale on `wc -m` because
# the default shell env often has LC_CTYPE empty, making wc -m fall back
# to byte counting.
pad_chars() {
  local s="$1" w="$2"
  local n p
  n=$(printf '%s' "$s" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  p=$(( w - n )); (( p < 0 )) && p=0
  printf '%s%*s' "$s" "$p" ""
}

collect_events() {
  find "$ROOT" -maxdepth 2 -name "*.jsonl" -print0 2>/dev/null \
    | xargs -0 cat 2>/dev/null
}

# ==================================================================
# Mode: calendar months (--months / --month YYYY-MM)
# ==================================================================
if [[ "$MODE" == months || "$MODE" == month ]]; then
  # Local UTC offset in seconds — used to bucket UTC timestamps into local
  # calendar months. Uses the *current* offset for all months (a DST boundary
  # can shift an event within ±1h of local midnight into the wrong month —
  # negligible for a cost estimate).
  OFF=$(date +%z | awk '{ s = (substr($0,1,1)=="-") ? -1 : 1
                          print s * (substr($0,2,2)*3600 + substr($0,4,2)*60) }')

  AGG=$(collect_events | jq -sr --argjson off "$OFF" --arg month "$MONTH" "$JQ_DEFS"'
    # Assistant messages with usage → one record per message, bucketed by
    # local calendar month. Timestamps missing fractional seconds fall back
    # to the UTC YYYY-MM prefix.
    [ priced[]
      | select(.timestamp)
      | { mo: (.timestamp
               | (try (sub("\\.[0-9]+Z$"; "Z")
                       | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime + $off
                       | strftime("%Y-%m"))
                  catch .[0:7])),
          sid:   .sessionId,
          model: (.message.model // "unknown"),
          cost:  cost_of(.message.usage; price(.message.model)),
          end:   (.message.stop_reason == "end_turn"),
          tin:   (.message.usage.input_tokens // 0),
          tout:  (.message.usage.output_tokens // 0),
          trd:   (.message.usage.cache_read_input_tokens // 0),
          tcw:   ((.message.usage.cache_creation.ephemeral_5m_input_tokens // 0)
                 + (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0)) }
    ] as $a |
    if $month == "" then
      # All months, newest first: M|month|turns|sessions|cost then S| subrows.
      $a | group_by(.mo)
         | map({ mo: .[0].mo,
                 cost:     ([.[].cost] | add // 0),
                 sessions: ([.[].sid] | unique | length),
                 turns:    ([.[] | select(.end)] | length),
                 by_model: (group_by(.model)
                            | map({model: .[0].model, cost: ([.[].cost] | add)})
                            | map(select(.cost > 0))
                            | sort_by(-.cost)) })
         | sort_by(.mo) | reverse | .[]
         | ( "M|\(.mo)|\(.turns)|\(.sessions)|\(.cost)"
           , (.by_model[] | "S|\(.model)|\(.cost)") )
    else
      # Single month detail.
      ([ $a[] | select(.mo == $month) ]) as $mm |
      { cost:     ([$mm[].cost] | add // 0),
        sessions: ([$mm[].sid] | unique | length),
        turns:    ([$mm[] | select(.end)] | length),
        tin:  ([$mm[].tin]  | add // 0),
        tout: ([$mm[].tout] | add // 0),
        trd:  ([$mm[].trd]  | add // 0),
        tcw:  ([$mm[].tcw]  | add // 0),
        by_model: ($mm | group_by(.model)
                       | map({model: .[0].model, cost: ([.[].cost] | add)})
                       | map(select(.cost > 0))
                       | sort_by(-.cost)) }
      | ( "T|\(.turns)|\(.sessions)|\(.tin)|\(.tout)|\(.trd)|\(.tcw)|\(.cost)"
        , (.by_model[] | "S|\(.model)|\(.cost)") )
    end
  ')

  if [[ "$MODE" == months ]]; then
    printf '%s\n' "Usage & cost by month (estimate at list prices)"
    printf '%s\n' "================================================"
    printf '\n'
    if [[ -z "$AGG" ]]; then
      printf '  (no usage recorded)\n'
    else
      while IFS='|' read -r kind a b c d; do
        if [[ "$kind" == M ]]; then
          printf '%-9s %5s turns   %3s sessions   $%8.2f\n' "$a" "$b" "$c" "$d"
        elif [[ "$kind" == S && $EXTENDED -eq 1 ]]; then
          color=$(color_for "$a")
          printf '  %s%-58s $%8.2f%s\n' "$color" "$a" "$b" "$RST"
        fi
      done <<< "$AGG"
    fi
    printf '\n'
    printf '  (list prices; subscription plans pay the plan, not this amount)\n'
    exit 0
  fi

  # Single month.
  printf 'Usage & cost — %s (estimate at list prices)\n' "$MONTH"
  printf '%s\n' "================================================"
  printf '\n'
  TOTALS=$(grep '^T|' <<< "$AGG" || true)
  IFS='|' read -r _ turns sess tin tout trd tcw cost <<< "$TOTALS"
  if [[ -z "$TOTALS" || "$sess" == 0 ]]; then
    printf '  (no usage recorded for %s)\n' "$MONTH"
    exit 0
  fi
  printf '  turns:         %s\n' "$(fmt_num "$turns")"
  printf '  sessions:      %s\n' "$(fmt_num "$sess")"
  printf '\n'
  printf '  input tokens:  %s\n' "$(fmt_num "$tin")"
  printf '  output tokens: %s\n' "$(fmt_num "$tout")"
  printf '  cache read:    %s\n' "$(fmt_num "$trd")"
  printf '  cache write:   %s\n' "$(fmt_num "$tcw")"
  printf '\n'
  printf '  by model:\n'
  grep '^S|' <<< "$AGG" | while IFS='|' read -r _ mdl mcost; do
    color=$(color_for "$mdl")
    printf '    %s%-56s $%8.2f%s\n' "$color" "$mdl" "$mcost" "$RST"
  done
  printf '    %s $%8.2f\n' "$(pad_chars '─ total ─' 56)" "$cost"
  printf '\n'
  printf '  (list prices; subscription plans pay the plan, not this amount)\n'
  exit 0
fi

# ==================================================================
# Mode: rolling windows (default)
# ==================================================================

# ---------- window start timestamps (UTC ISO 8601) ----------

# macOS `date`. Local midnight today → epoch → UTC ISO.
to_utc_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

today_local=$(date +%Y-%m-%d)
today_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)

# Yesterday: the 24 hours *before* today_start (so it's a bounded window,
# not "last 24 hours rolling"). ts must satisfy yesterday <= ts < today.
yesterday_epoch=$(( today_epoch - 86400 ))

# Monday of the current week (1=Mon…7=Sun).
dow=$(date +%u)
monday_epoch=$(date -v-$((dow-1))d -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)

# Rolling 30-day window — from 30 days ago at local midnight.
month_epoch=$(date -v-30d -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)

TODAY_ISO=$(to_utc_iso "$today_epoch")
YESTERDAY_ISO=$(to_utc_iso "$yesterday_epoch")
WEEK_ISO=$(to_utc_iso "$monday_epoch")
MONTH_ISO=$(to_utc_iso "$month_epoch")

TODAY_LABEL=$(date -r "$today_epoch" +%Y-%m-%d)
YESTERDAY_LABEL=$(date -r "$yesterday_epoch" +%Y-%m-%d)
WEEK_LABEL="$(date -r "$monday_epoch" +%Y-%m-%d) → $(date -v+6d -r "$monday_epoch" +%Y-%m-%d)"
MONTH_LABEL="$(date -r "$month_epoch" +%Y-%m-%d) → $today_local"

# ---------- aggregate via jq streaming across all jsonl files ----------

AGG=$(collect_events \
  | jq -sr --arg d "$TODAY_ISO" --arg y "$YESTERDAY_ISO" \
           --arg w "$WEEK_ISO" --arg m "$MONTH_ISO" "$JQ_DEFS"'
    # start..end-exclusive window; end="" means open-ended (now).
    def window(start; end_excl; records):
      ([ records[]
         | select(.ts >= start)
         | select(end_excl == "" or .ts < end_excl) ]) as $ae
      | { cost:     ([$ae[].cost] | add // 0),
          sessions: ([$ae[].sid] | unique | length),
          turns:    ([$ae[] | select(.end)] | length),
          by_model: ([$ae[] | {model, cost}]
                     | group_by(.model)
                     | map({model: .[0].model, cost: ([.[].cost] | add)})
                     | map(select(.cost > 0))
                     | sort_by(-.cost)) };

    # Assistant messages with usage → {ts, sid, model, cost, end}. `end` flags
    # the end_turn stop reason — equals one user round trip (last-prompt
    # events have no timestamps, so we count end_turn instead).
    [ priced[]
      | select(.timestamp)
      | { ts:    .timestamp,
          sid:   .sessionId,
          model: (.message.model // "unknown"),
          cost:  cost_of(.message.usage; price(.message.model)),
          end:   (.message.stop_reason == "end_turn") }
    ] as $a |

    { today:     window($d; "";   $a),
      yesterday: window($y; $d;   $a),
      week:      window($w; "";   $a),
      month:     window($m; "";   $a) }
  ')

# ---------- print ----------

printf '%s\n' "Usage & cost (estimate at current list prices)"
printf '%s\n' "=================================================="
printf '\n'

row() {
  # label, span, turns, sessions, cost
  printf '%-10s %s %5s turns   %3s sessions   $%8.2f\n' \
    "$1" "$(pad_chars "$2" 30)" "$3" "$4" "$5"
}

print_window() {
  # $1=label  $2=span  $3=window-key (today|week|month)
  local label="$1" span="$2" key="$3"
  local cost turns sess
  cost=$(  echo "$AGG" | jq -r ".$key.cost")
  turns=$( echo "$AGG" | jq -r ".$key.turns")
  sess=$(  echo "$AGG" | jq -r ".$key.sessions")
  row "$label" "$span" "$turns" "$sess" "$cost"
  # Per-model sub-rows only in extended mode (sorted desc by cost in jq).
  if [[ $EXTENDED -eq 1 ]]; then
    echo "$AGG" | jq -r ".$key.by_model[] | \"\\(.model)|\\(.cost)\"" \
      | while IFS='|' read -r mdl mcost; do
          color=$(color_for "$mdl")
          printf '  %s%-68s $%8.2f%s\n' "$color" "$mdl" "$mcost" "$RST"
        done
  fi
}

print_window "today"     "$TODAY_LABEL"      today
print_window "yesterday" "$YESTERDAY_LABEL"  yesterday
print_window "week"      "$WEEK_LABEL"       week
print_window "30 days"   "$MONTH_LABEL"      month

printf '\n'
printf '  (list prices; subscription plans pay the plan, not this amount)\n'
