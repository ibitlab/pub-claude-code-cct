#!/usr/bin/env bash
# List Claude Code project folders whose original cwd no longer exists
# (project removed, moved, or renamed). Reads the `cwd` field that Claude
# Code writes on every transcript event, so no lossy slug reversal.
#
# Usage:
#   ./dead-sessions.sh         # one block per dead project folder
#   ./dead-sessions.sh -v      # also list each session inside
#
# Requires: jq

set -euo pipefail

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

dead=0
unknown=0
now=$(date +%s)

# "N days ago" from an epoch timestamp.
ago() {
  local epoch="$1" days
  days=$(( (now - epoch) / 86400 ))
  case "$days" in
    0) echo "today" ;;
    1) echo "1 day ago" ;;
    *) echo "$days days ago" ;;
  esac
}

for d in "$ROOT"/*/; do
  slug=$(basename "$d")
  cwd=""
  # Any event with a cwd field works — every event in a session carries the
  # same cwd, so we can bail as soon as we see one.
  for f in "$d"*.jsonl; do
    [[ -f "$f" ]] || continue
    cwd=$(jq -rn 'first(inputs | select(.cwd) | .cwd) // empty' "$f" 2>/dev/null)
    [[ -n "$cwd" ]] && break
  done

  if [[ -z "$cwd" ]]; then
    unknown=$((unknown+1))
    printf 'unknown: %s  (no cwd recorded in any transcript)\n' "$slug"
    continue
  fi

  [[ -d "$cwd" ]] && continue

  dead=$((dead+1))
  sess_count=$(ls "$d"*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
  # Last write across any transcript = last time Claude Code touched this project.
  last_epoch=$(ls -t "$d"*.jsonl 2>/dev/null | head -1 \
    | xargs stat -f '%m' 2>/dev/null || echo 0)
  printf 'dead: %s\n' "$cwd"
  printf '    slug:     %s\n' "$slug"
  printf '    sessions: %s  (%s)\n' "$sess_count" "$size"
  last_iso=$(date -r "$last_epoch" -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')
  printf '    last:     %s  (%s)\n' "$(ago "$last_epoch")" "$last_iso"
  if [[ $VERBOSE -eq 1 ]]; then
    while IFS= read -r f; do
      id=$(basename "$f" .jsonl)
      first=$(jq -rn 'first(inputs | select(.timestamp) | .timestamp) // empty' "$f" 2>/dev/null)
      last=$(jq -r 'select(.timestamp) | .timestamp' "$f" 2>/dev/null | tail -1)
      msgs=$(wc -l < "$f" | tr -d ' ')
      printf '      %s  %s → %s  (%s events)\n' "$id" "${first:-?}" "${last:-?}" "$msgs"
    done < <(ls -t "$d"*.jsonl 2>/dev/null)
  fi
done

echo
printf 'summary: %s dead, %s unknown\n' "$dead" "$unknown"
