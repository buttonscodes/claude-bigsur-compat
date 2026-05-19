#!/bin/bash
#
# Uninstalls the launchd auto-patch agent installed by install-auto-patch.sh.
# Leaves ~/.claude/compat/ artifacts in place so you can still run
# patch-claude.sh manually after future updates.
#
# Usage:
#   ./uninstall-auto-patch.sh
#
set -euo pipefail

PLIST_LABEL="local.claude-patch"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
DOMAIN="gui/$(id -u)"

if launchctl print "$DOMAIN/$PLIST_LABEL" >/dev/null 2>&1; then
    echo "Stopping launchd agent $PLIST_LABEL"
    launchctl bootout "$DOMAIN/$PLIST_LABEL" || true
else
    echo "Agent $PLIST_LABEL is not loaded; skipping bootout."
fi

if [ -f "$PLIST_PATH" ]; then
    echo "Removing $PLIST_PATH"
    rm -f "$PLIST_PATH"
else
    echo "No plist at $PLIST_PATH."
fi

echo ""
echo "Done. Auto-patch is removed."
echo "Compat libraries and patch-claude.sh under ~/.claude/compat/ are kept."
echo "Run patch-claude.sh manually after future claude-code updates."
