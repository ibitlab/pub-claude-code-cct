#!/usr/bin/env bash
# List the user's typed prompts (questions) in a session, in chronological
# order. Uses `last-prompt` events — Claude Code's verbatim snapshot of each
# typed user input — so slash-command wrappers, tool results, and system
# reminders are excluded.
#
# Usage:
#   ./session-questions.sh <id-or-prefix-or-path>
#
# Requires: jq

set -euo pipefail

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"

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

echo "session: $(basename "$FILE" .jsonl)"
echo

# Walk last-prompt events in file order. Each snapshot captures the then-most-
# recent typed user input, so the sequence = chronological prompt list.
# Internal newlines are collapsed to ' / ' so each prompt prints on one line.
# Consecutive duplicates are deduped — Claude Code sometimes re-emits the same
# snapshot without a new user turn.
jq -r 'select(.type=="last-prompt") | .lastPrompt // empty | gsub("\n"; " / ")' "$FILE" \
  | awk 'NF && $0 != prev { print; prev=$0 }' \
  | nl -ba -w3 -s'. '
