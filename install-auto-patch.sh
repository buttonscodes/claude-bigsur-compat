#!/bin/bash
#
# Installs a launchd WatchPaths agent that re-runs patch-claude.sh
# every time Claude Code's bin/claude.exe is rewritten (i.e. after
# `npm install -g @anthropic-ai/claude-code@latest`, including the
# built-in auto-updater). Once installed, you never have to manually
# re-patch — auto-updates can stay enabled.
#
# What this does:
#   1. Copies patch-claude.sh to ~/.claude/compat/ so it lives in a
#      TCC-unrestricted directory (~/Documents/ and ~/Desktop/ are
#      protected; launchd-spawned scripts under those paths get
#      "Operation not permitted" on Catalina+).
#   2. Detects your Node.js install dir (override with --node-dir).
#   3. Generates ~/Library/LaunchAgents/local.claude-patch.plist
#      with absolute paths (launchd plists don't expand ~ or $HOME).
#   4. Bootstraps the agent. From now on, every change to
#      <node>/lib/node_modules/@anthropic-ai/claude-code/bin/ fires
#      patch-claude.sh. The script is idempotent so spurious fires
#      are harmless.
#
# Usage:
#   ./install-auto-patch.sh                            # auto-detect node
#   ./install-auto-patch.sh --node-dir ~/.nvm/versions/node/v22.22.0
#
# Re-run after switching Node.js versions (the plist hardcodes the
# node dir for reliability — see README for why).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPAT_DIR="$HOME/.claude/compat"
PLIST_LABEL="local.claude-patch"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_PATH="$HOME/Library/Logs/claude-patch.log"

NODE_DIR=""
while (( "$#" )); do
    case "$1" in
        --node-dir) NODE_DIR="$2"; shift 2 ;;
        --node-dir=*) NODE_DIR="${1#--node-dir=}"; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Auto-detect node dir if not specified.
if [ -z "$NODE_DIR" ]; then
    if command -v node &>/dev/null; then
        NODE_DIR="$(dirname "$(dirname "$(command -v node)")")"
    elif [ -d "$HOME/.nvm" ]; then
        NODE_DIR="$(ls -d "$HOME"/.nvm/versions/node/v* 2>/dev/null | sort -V | tail -1)"
    fi
fi
if [ -z "$NODE_DIR" ] || [ ! -d "$NODE_DIR" ]; then
    echo "ERROR: could not detect Node.js dir. Pass --node-dir explicitly." >&2
    exit 1
fi

CLAUDE_BIN_DIR="$NODE_DIR/lib/node_modules/@anthropic-ai/claude-code/bin"
if [ ! -d "$CLAUDE_BIN_DIR" ]; then
    echo "ERROR: Claude Code package not found at $CLAUDE_BIN_DIR" >&2
    echo "       Run: npm install -g @anthropic-ai/claude-code" >&2
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/patch-claude.sh" ]; then
    echo "ERROR: patch-claude.sh not found alongside this installer at $SCRIPT_DIR" >&2
    exit 1
fi

# Verify build artifacts exist; the patch script will fail without them.
if [ ! -f "$COMPAT_DIR/libicucore.A.dylib" ] || [ ! -f "$COMPAT_DIR/libc++.1.dylib" ]; then
    echo "ERROR: compat libraries not built. Run ./build.sh first." >&2
    exit 1
fi

# Step 1: copy patch-claude.sh to ~/.claude/compat/ (TCC-safe).
# We copy rather than symlink because symlinks under ~/Documents are
# still TCC-restricted when launchd resolves them.
echo "[1/3] Copying patch-claude.sh to $COMPAT_DIR/"
mkdir -p "$COMPAT_DIR"
cp "$SCRIPT_DIR/patch-claude.sh" "$COMPAT_DIR/patch-claude.sh"
chmod +x "$COMPAT_DIR/patch-claude.sh"

# Step 2: generate the plist with absolute paths. We use printf rather
# than a heredoc to avoid heredoc tab/space pitfalls.
echo "[2/3] Writing $PLIST_PATH"
mkdir -p "$(dirname "$PLIST_PATH")"
mkdir -p "$(dirname "$LOG_PATH")"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${COMPAT_DIR}/patch-claude.sh</string>
    <string>--node-dir</string>
    <string>${NODE_DIR}</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>${CLAUDE_BIN_DIR}</string>
  </array>
  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST_PATH" >/dev/null

# Step 3: bootstrap the agent. If a previous version is loaded,
# bootout first so the new plist is picked up.
echo "[3/3] Loading launchd agent ${PLIST_LABEL}"
DOMAIN="gui/$(id -u)"
if launchctl print "$DOMAIN/$PLIST_LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$PLIST_LABEL" 2>/dev/null || true
fi
launchctl bootstrap "$DOMAIN" "$PLIST_PATH"

echo ""
echo "Done. Auto-patch is active."
echo ""
echo "  Watched: $CLAUDE_BIN_DIR"
echo "  Runs:    $COMPAT_DIR/patch-claude.sh --node-dir $NODE_DIR"
echo "  Log:     $LOG_PATH"
echo ""
echo "To remove: ./uninstall-auto-patch.sh"
