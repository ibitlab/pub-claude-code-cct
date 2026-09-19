#!/usr/bin/env bash
# Uninstall cct: remove the ~/.local/bin/cct symlink and (optionally) state.
#
# Usage:
#   uninstall.sh                remove the symlink only
#   uninstall.sh --purge        also delete ~/.cache/cct (state file)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/cct"
BIN="$HOME/.local/bin"
LINK="$BIN/cct"
STATE_DIR="$HOME/.cache/cct"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

# Remove the symlink, but only if it points at our cct — don't clobber a
# cct installed from somewhere else.
if [[ -L "$LINK" ]]; then
  existing=$(readlink "$LINK")
  if [[ "$existing" == "$TARGET" ]]; then
    rm -f "$LINK"
    echo "removed: $LINK"
  else
    echo "leaving: $LINK (-> $existing; not ours)"
  fi
elif [[ -e "$LINK" ]]; then
  echo "leaving: $LINK (regular file, not a symlink to our cct)"
else
  echo "not installed: $LINK"
fi

if [[ $PURGE -eq 1 ]]; then
  if [[ -d "$STATE_DIR" ]]; then
    rm -rf "$STATE_DIR"
    echo "purged: $STATE_DIR"
  fi
fi
