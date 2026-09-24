#!/usr/bin/env bash
# Report tool usage for a Claude Code session:
#   per-tool counts, files read / written / edited, bash commands, grep patterns.
#
# Usage:
#   ./session-tools.sh <session-id-or-prefix>
#   ./session-tools.sh <path/to/session.jsonl>
#   ./session-tools.sh <id> --commands   # include full bash command list
#
# Requires: jq

set -euo pipefail

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Shared jq helpers (dedup_events): after /compact the transcript holds exact
# copies of earlier lines, which would count every tool call again.
[[ -f "$HERE/pricing.json" && -f "$HERE/pricing.jq" ]] \
  || { echo "pricing.json / pricing.jq missing next to $0" >&2; exit 1; }
JQ_DEFS=$(jq -r '"def pricing: \(tojson);"' "$HERE/pricing.json"; cat "$HERE/pricing.jq")

resolve_session() {
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

FILE=$(resolve_session "${1:?session id or path required}")
SHOW_COMMANDS=0
[[ "${2:-}" == "--commands" ]] && SHOW_COMMANDS=1

# Pull every tool_use block into a compact line: "name\t<json-input>".
# Lines replayed after /compact are dropped first (same uuid → counted once).
TOOL_USES=$(jq -cs "$JQ_DEFS"'
  [ .[] | select(.type=="assistant") ] | dedup_events | .[]
  | .message.content[]?
  | select(.type=="tool_use")
  | {name, input}
' "$FILE")

echo "session: $(basename "$FILE" .jsonl)"
echo

echo "tool counts:"
echo "$TOOL_USES" | jq -r '.name' | sort | uniq -c | sort -rn | sed 's/^/  /'
echo

print_paths() {
  local label="$1" tool="$2"
  local paths
  paths=$(echo "$TOOL_USES" | jq -r --arg t "$tool" \
    'select(.name==$t) | .input.file_path // empty' | sort -u)
  if [[ -n "$paths" ]]; then
    echo "$label:"
    echo "$paths" | sed 's/^/  /'
    echo
  fi
}

print_paths "files read"    "Read"
print_paths "files written" "Write"
print_paths "files edited"  "Edit"

# Grep patterns
PATTERNS=$(echo "$TOOL_USES" | jq -r 'select(.name=="Grep") | .input.pattern' | sort -u)
if [[ -n "$PATTERNS" ]]; then
  echo "grep patterns:"
  echo "$PATTERNS" | sed 's/^/  /'
  echo
fi

# Glob patterns
GLOBS=$(echo "$TOOL_USES" | jq -r 'select(.name=="Glob") | .input.pattern' | sort -u)
if [[ -n "$GLOBS" ]]; then
  echo "glob patterns:"
  echo "$GLOBS" | sed 's/^/  /'
  echo
fi

# WebFetch URLs
URLS=$(echo "$TOOL_USES" | jq -r 'select(.name=="WebFetch") | .input.url' | sort -u)
if [[ -n "$URLS" ]]; then
  echo "web fetches:"
  echo "$URLS" | sed 's/^/  /'
  echo
fi

# Bash commands: count (always); full list only with --commands.
# Count records (not lines) — multi-line commands still count as one.
CMD_COUNT=$(echo "$TOOL_USES" | jq -c 'select(.name=="Bash")' | grep -c . || true)
if [[ "$CMD_COUNT" -gt 0 ]]; then
  echo "bash commands: $CMD_COUNT (pass --commands to list them)"
  if [[ $SHOW_COMMANDS -eq 1 ]]; then
    # One block per command, with a divider so multi-line commands
    # (heredocs, && chains with embedded newlines) don't run together.
    echo "$TOOL_USES" | jq -rs '
      [.[] | select(.name=="Bash")]
      | to_entries[]
      | "\n  ── [\(.key+1)] ───────────────────────────────────────\n\(.value.input.command)"
    '
  fi
fi
