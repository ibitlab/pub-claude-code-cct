#!/usr/bin/env bash
# Uninstall cct: remove the ~/.local/bin/cct symlink.
#
# Usage:
#   uninstall.sh
#
# This script deletes nothing but its own symlink. cct's state file and the
# merged-project bindings are listed at the end so you can remove them by
# hand if you want a clean slate.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/cct"
BIN="$HOME/.local/bin"
LINK="$BIN/cct"
STATE_DIR="$HOME/.cache/cct"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cct"

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

left=0
for d in "$STATE_DIR" "$CONFIG_DIR"; do
  if [[ -d "$d" ]]; then
    (( left == 0 )) && echo "left in place (remove by hand if you no longer want them):"
    left=1
    echo "  $d"
  fi
done
