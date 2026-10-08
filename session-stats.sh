#!/usr/bin/env bash
# Print aggregate stats for a Claude Code session:
#   turns, duration, token usage (input/output/cache), model(s), stop reasons.
#
# Usage:
#   ./session-stats.sh <session-id-or-prefix>
#   ./session-stats.sh <path/to/session.jsonl>
#
# Requires: jq

set -euo pipefail

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Prices: pricing.json (the table) + pricing.jq (the helpers), shared by
# every cost script. `priced` keeps one transcript line per API message —
# Claude Code writes one line per content block, each repeating the whole
# message's usage, so tokens, turns and cost would otherwise be counted
# 2-3 times over.
[[ -f "$HERE/pricing.json" && -f "$HERE/pricing.jq" ]] \
  || { echo "pricing.json / pricing.jq missing next to $0" >&2; exit 1; }
JQ_DEFS=$(jq -r '"def pricing: \(tojson);"' "$HERE/pricing.json"; cat "$HERE/pricing.jq")

resolve_session() {
  # Accepts a full .jsonl path, a full UUID, or a unique UUID prefix.
  local arg="$1"
  if [[ -f "$arg" ]]; then
    printf '%s\n' "$arg"; return
  fi
  local matches=()
  while IFS= read -r line; do matches+=("$line"); done < <(find "$ROOT" -maxdepth 2 -name "${arg}*.jsonl" 2>/dev/null)
  case "${#matches[@]}" in
    0) echo "No session matching: $arg" >&2; exit 1 ;;
    1) printf '%s\n' "${matches[0]}" ;;
    *) echo "Ambiguous prefix '$arg' — matches:" >&2
       printf '  %s\n' "${matches[@]}" >&2
       exit 1 ;;
  esac
}

fmt_num() {
  # thousand-separate an integer, portable enough for bash
  printf "%'d" "$1" 2>/dev/null || printf '%s' "$1"
}

FILE=$(resolve_session "${1:?session id or path required}")
ID=$(basename "$FILE" .jsonl)

# Background agents (Agent tool, Workflow) of this session write their own
# transcripts under <session-id>/subagents/; their usage is real spend, so
# the token and cost blocks read them too.
FILES=("$FILE")
while IFS= read -r f; do
  [[ -n "$f" ]] && FILES+=("$f")
done < <(find "${FILE%.jsonl}/subagents" -name '*.jsonl' 2>/dev/null | sort)

echo "session: $ID"
echo "file:    $FILE"
if (( ${#FILES[@]} > 1 )); then
  echo "agents:  $(( ${#FILES[@]} - 1 )) background-agent transcript(s) included"
fi
echo

# Timestamps — use jq's `first(inputs|…)` instead of `jq | head -1`, which
# triggers SIGPIPE (exit 141) on large transcripts under `set -o pipefail`.
FIRST=$(jq -rn 'first(inputs | select(.timestamp) | .timestamp) // empty' "$FILE" 2>/dev/null)
LAST=$(jq -r 'select(.timestamp) | .timestamp' "$FILE" | tail -1)
echo "started: $FIRST"
echo "ended:   $LAST"

# Duration (macOS date)
if [[ -n "$FIRST" && -n "$LAST" ]]; then
  s1=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${FIRST%.*}" +%s 2>/dev/null || echo 0)
  s2=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${LAST%.*}" +%s 2>/dev/null || echo 0)
  if [[ "$s1" -gt 0 && "$s2" -gt 0 ]]; then
    dur=$((s2 - s1))
    printf 'elapsed: %dh %dm %ds\n' $((dur/3600)) $(((dur%3600)/60)) $((dur%60))
  fi
fi
echo

# Event-type breakdown (raw transcript lines — an API message spans several)
echo "events by type:"
jq -r '.type' "$FILE" | sort | uniq -c | sort -rn | sed 's/^/  /'
echo

# Models used (per API message)
echo "models:"
jq -rs "$JQ_DEFS"'priced[] | .message.model' "${FILES[@]}" | sort | uniq -c | sort -rn | sed 's/^/  /'
echo

# Stop reasons (per API message)
echo "stop reasons:"
jq -rs "$JQ_DEFS"'priced[] | .message.stop_reason // "?"' "${FILES[@]}" | sort | uniq -c | sort -rn | sed 's/^/  /'
echo

# Token usage totals (as JSON, used by both the display block and the cost block)
TOTALS=$(jq -s "$JQ_DEFS"'
  [priced[] | .message.usage] as $u
  | {
      turns: ($u | length),
      input: ($u | map(.input_tokens // 0) | add),
      output: ($u | map(.output_tokens // 0) | add),
      cache_read: ($u | map(.cache_read_input_tokens // 0) | add),
      cache_created: ($u | map(.cache_creation_input_tokens // 0) | add),
      cache_5m: ($u | map(.cache_creation.ephemeral_5m_input_tokens // 0) | add),
      cache_1h: ($u | map(.cache_creation.ephemeral_1h_input_tokens // 0) | add),
      web_searches: ($u | map(.server_tool_use.web_search_requests // 0) | add),
      web_fetches: ($u | map(.server_tool_use.web_fetch_requests // 0) | add)
    }
' "${FILES[@]}")

echo "tokens:"
# Render large numbers with comma thousands separators so they're eyeballable.
echo "$TOTALS" | jq -r '
    to_entries[] | select(.key | test("^(turns|input|output|cache_read|cache_created|web_)"))
    | "\(.key)\t\(.value)"' \
  | awk 'BEGIN{FS="\t"} {
      n=$2
      # Insert commas from the right into integer numbers.
      while (match(n, /^-?[0-9]+[0-9]{3}/)) {
        n = substr(n, 1, RLENGTH-3) "," substr(n, RLENGTH-2)
      }
      printf "  %s: %s\n", $1, n
    }'
echo

# ---------- Cost estimate ----------
# LIST prices from pricing.json — actual billing may differ (contract tiers,
# batch, etc). Costed per API message, not from the totals above: some
# models price a request by its prompt length (long_prompt in pricing.json).
# One line per model: model, then USD for input output cache_5m cache_1h read.
COSTS=$(jq -rs "$JQ_DEFS"'
  [priced[] | .message] | group_by(.model // "")[]
  | (.[0].model // "unknown") as $m | price($m) as $p
  | (map(costs_of(.usage; $p)) | reduce .[] as $c ({};
      reduce ($c | keys[]) as $k (.; .[$k] += $c[$k]))) as $s
  | [$m, $s.input // 0, $s.output // 0, $s.cache_5m // 0, $s.cache_1h // 0,
     $s.cache_read // 0] | @tsv
' "${FILES[@]}")

echo "cost (estimate, list prices):"
if [[ $(echo "$COSTS" | grep -c .) -le 1 ]]; then
  echo "$COSTS" | awk -F'\t' '
    { m=$1; ci=$2; co=$3; cf=$4; ch=$5; cr=$6 }
    END {
      printf "  model:        %s\n", (m == "" ? "unknown" : m);
      printf "  input:        $%.4f\n", ci;
      printf "  output:       $%.4f\n", co;
      printf "  cache 5m:     $%.4f\n", cf;
      printf "  cache 1h:     $%.4f\n", ch;
      printf "  cache read:   $%.4f\n", cr;
      printf "  ─ total ─     $%.4f\n", ci+co+cf+ch+cr;
    }'
else
  echo "$COSTS" | awk -F'\t' '
    { c = $2+$3+$4+$5+$6; t += c; printf "  %-20s $%.4f\n", $1, c }
    END { printf "  ─ total ─           $%.4f\n", t }'
fi
echo "  (list prices; actual billing may differ)"
