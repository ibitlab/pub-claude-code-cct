#!/usr/bin/env bash
# List Claude Code sessions for a project directory, newest first.
#
# Usage:
#   ./list-sessions.sh            # sessions for $PWD
#   ./list-sessions.sh <path>     # sessions for another project dir
#   ./list-sessions.sh --all      # every project known to Claude Code
#
# Requires: jq

set -euo pipefail

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
NOW=$(date +%s)

# "N days ago" from an epoch timestamp.
ago() {
  local epoch="$1" days
  days=$(( (NOW - epoch) / 86400 ))
  case "$days" in
    0) echo "today" ;;
    1) echo "1 day ago" ;;
    *) echo "$days days ago" ;;
  esac
}

slug() {
  # Claude Code slugifies an absolute path by replacing both '/' and '_' with '-'.
  # e.g. /Users/<you>/code/_my_project_/sub-repo
  #   -> -Users-<you>-code--my-project--sub-repo
  printf '%s' "$1" | tr '/_' '--'
}

print_session() {
  local file="$1"
  local id first last msgs ai_title first_prompt last_prompt
  id=$(basename "$file" .jsonl)
  # `first(inputs|…)` instead of `jq | head -1` avoids SIGPIPE (exit 141)
  # on large transcripts under `set -o pipefail`.
  first=$(jq -rn 'first(inputs | select(.timestamp) | .timestamp) // empty' "$file" 2>/dev/null)
  last=$(jq -r 'select(.timestamp) | .timestamp' "$file" 2>/dev/null | tail -1)
  msgs=$(wc -l < "$file" | tr -d ' ')

  # Claude's auto-generated title (latest wins).
  ai_title=$(jq -r 'select(.type=="ai-title") | .aiTitle // empty' "$file" 2>/dev/null | tail -1)

  # Real typed user prompts are captured verbatim in `last-prompt` events.
  # Each event is a snapshot of the then-most-recent user input, so the
  # sequence across the file is first-typed → last-typed.
  first_prompt=$(jq -rn 'first(inputs | select(.type=="last-prompt") | .lastPrompt) // empty' \
    "$file" 2>/dev/null | tr '\n' ' ' | cut -c1-80)
  last_prompt=$(jq -r 'select(.type=="last-prompt") | .lastPrompt // empty' "$file" 2>/dev/null \
    | tail -1 | tr '\n' ' ' | cut -c1-80)

  # File mtime = when Claude Code last wrote to this transcript.
  local mtime
  mtime=$(stat -f '%m' "$file" 2>/dev/null || echo 0)
  local last_iso
  last_iso=$(date -r "$mtime" -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')

  printf '%s  %s → %s  (%s events)\n' "$id" "${first:-?}" "${last:-?}" "$msgs"
  printf '    last:          %s  (%s)\n' "$(ago "$mtime")" "$last_iso"
  [[ -n "$ai_title" ]]     && printf '    title:         %s\n' "$ai_title"
  [[ -n "$first_prompt" ]] && printf '    first prompt:  %s\n' "$first_prompt"
  if [[ -n "$last_prompt" && "$last_prompt" != "$first_prompt" ]]; then
    printf '    last prompt:   %s\n' "$last_prompt"
  fi
}

list_project() {
  local dir="$1"
  local proj_dir="$ROOT/$(slug "$dir")"
  if [[ ! -d "$proj_dir" ]]; then
    echo "No Claude Code sessions for: $dir" >&2
    return 1
  fi
  echo "# $dir"
  # ls -t sorts by mtime, newest first; ignore jsonl-less subdirs.
  local had_any=0
  while IFS= read -r f; do
    had_any=1
    print_session "$f"
  done < <(ls -t "$proj_dir"/*.jsonl 2>/dev/null)
  [[ $had_any -eq 1 ]] || echo "  (no .jsonl transcripts)"
}

if [[ "${1:-}" == "--all" ]]; then
  for d in "$ROOT"/*/; do
    # unslugify: the folder name already encodes the path; just show it.
    echo "${d%/}"
  done
  exit 0
fi

list_project "${1:-$PWD}"
