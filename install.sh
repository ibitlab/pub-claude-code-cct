#!/usr/bin/env bash
# Install cct by symlinking claude-dev/cct into ~/.local/bin.
# Pull updates propagate automatically (symlink, not copy).
#
# Usage: install.sh [--force]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/cct"
BIN="$HOME/.local/bin"
LINK="$BIN/cct"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

[[ -f "$TARGET" ]] || { echo "cct not found at $TARGET" >&2; exit 1; }
[[ -f "$HERE/pricing.json" && -f "$HERE/pricing.jq" ]] \
  || { echo "pricing.json / pricing.jq missing in $HERE" >&2; exit 1; }

# Only touch the known scripts we ship — don't +x unrelated .sh a user might drop in.
chmod +x "$TARGET" \
  "$HERE/list-sessions.sh" "$HERE/session-stats.sh" \
  "$HERE/session-tools.sh" "$HERE/dead-sessions.sh" \
  "$HERE/cost-report.sh" "$HERE/project-costs.sh" "$HERE/stack-report.sh" \
  "$HERE/active-sessions.sh" "$HERE/status.sh" \
  "$HERE/session-questions.sh" \
  "$HERE/time-report.py" "$HERE/export-prompts.py" \
  "$HERE/install.sh" "$HERE/uninstall.sh"

mkdir -p "$BIN"

# Refuse to trample a pre-existing cct unless --force.
if [[ -e "$LINK" || -L "$LINK" ]]; then
  existing=$(readlink "$LINK" 2>/dev/null || echo "$LINK")
  if [[ "$existing" == "$TARGET" ]]; then
    echo "already installed: $LINK -> $TARGET"
    exit 0
  fi
  if [[ $FORCE -ne 1 ]]; then
    echo "refusing to overwrite existing $LINK (-> $existing)" >&2
    echo "re-run with --force to replace." >&2
    exit 1
  fi
  echo "replacing existing $LINK (-> $existing)"
fi

ln -sfn "$TARGET" "$LINK"
echo "installed: $LINK -> $TARGET"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: $BIN is not on \$PATH. Add this to your shell rc:"
     echo "      export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
