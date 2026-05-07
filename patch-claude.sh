#!/bin/bash
#
# Patches the Claude Code binary for macOS Big Sur (11.x) compatibility.
#
# Claude Code 2.1.85+ ships a compiled Bun binary (bin/claude.exe) that
# requires macOS 13+ due to newer ICU and libc++ symbols. This script:
#
#   1. Lowers the Mach-O minos from 13.0 → 11.0 (via vtool)
#   2. Redirects libicucore → our shim (re-exports system ICU + missing symbols)
#   3. Redirects libc++ → a compatible version (LLVM libc++ 14+)
#   4. Re-signs the binary (ad-hoc codesign)
#
# Usage:
#   npm install -g @anthropic-ai/claude-code@latest
#   ./patch-claude.sh [--node-dir /path/to/node]
#
set -euo pipefail

COMPAT_DIR="$HOME/.claude/compat"

# Allow overriding the Node.js directory
NODE_DIR="${1:-}"
if [ -n "$NODE_DIR" ] && [ "$NODE_DIR" = "--node-dir" ]; then
    NODE_DIR="${2:-}"
fi

# Auto-detect Node.js directory
if [ -z "$NODE_DIR" ]; then
    if command -v node &>/dev/null; then
        NODE_DIR="$(dirname "$(dirname "$(command -v node)")")"
    elif [ -d "$HOME/.nvm" ]; then
        NODE_DIR="$(ls -d "$HOME"/.nvm/versions/node/v* 2>/dev/null | sort -V | tail -1)"
    fi
fi

CLAUDE_PKG="$NODE_DIR/lib/node_modules/@anthropic-ai/claude-code"
CLAUDE_EXE="$CLAUDE_PKG/bin/claude.exe"

if [ ! -f "$CLAUDE_EXE" ]; then
    echo "ERROR: claude.exe not found at $CLAUDE_EXE"
    echo ""
    echo "Usage: $0 [--node-dir /path/to/node/version]"
    echo "Example: $0 --node-dir ~/.nvm/versions/node/v22.22.0"
    exit 1
fi

# Verify compat libraries exist
if [ ! -f "$COMPAT_DIR/libicucore.A.dylib" ] || [ ! -f "$COMPAT_DIR/libc++.1.dylib" ]; then
    echo "ERROR: Compat libraries not found. Run ./build.sh first."
    exit 1
fi

# Find vtool
VTOOL=""
for candidate in \
    /Library/Developer/CommandLineTools/usr/bin/vtool \
    "$(xcrun --find vtool 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        VTOOL="$candidate"
        break
    fi
done

if [ -z "$VTOOL" ]; then
    echo "ERROR: vtool not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

# Check if already patched
if otool -L "$CLAUDE_EXE" 2>/dev/null | grep -q "$COMPAT_DIR"; then
    echo "Already patched."
    "$CLAUDE_EXE" --version 2>&1
    exit 0
fi

# Check if this is a JS entry (older versions don't need patching)
if head -1 "$CLAUDE_EXE" 2>/dev/null | grep -q "#!/usr/bin/env node"; then
    echo "This version uses a Node.js entry point — no patching needed."
    "$CLAUDE_EXE" --version 2>&1
    exit 0
fi

VERSION=$("$CLAUDE_PKG/bin/claude.exe" --version 2>&1 || echo "unknown (binary won't run yet)")
echo "Patching Claude Code ($VERSION) for Big Sur compatibility..."

# Backup original
cp "$CLAUDE_EXE" "$CLAUDE_EXE.original"

# Step 1: Lower minos from 13.0 to 11.0
echo "  [1/4] Patching minimum macOS version (13.0 → 11.0)..."
"$VTOOL" -set-build-version macos 11.0 15.5 -replace -output "$CLAUDE_EXE.tmp" "$CLAUDE_EXE" 2>/dev/null
mv "$CLAUDE_EXE.tmp" "$CLAUDE_EXE"

# Step 2: Redirect libicucore to our shim
echo "  [2/4] Redirecting ICU to compat shim..."
install_name_tool -change /usr/lib/libicucore.A.dylib "$COMPAT_DIR/libicucore.A.dylib" "$CLAUDE_EXE"

# Step 3: Redirect libc++ to compatible version
echo "  [3/4] Redirecting libc++ to compatible version..."
install_name_tool -change /usr/lib/libc++.1.dylib "$COMPAT_DIR/libc++.1.dylib" "$CLAUDE_EXE"

# Step 4: Re-sign (ad-hoc)
echo "  [4/4] Re-signing binary..."
codesign --force --sign - "$CLAUDE_EXE" 2>/dev/null

echo ""
echo "Done! Verifying..."
"$CLAUDE_EXE" --version 2>&1
echo ""
echo "Original backed up to: $CLAUDE_EXE.original"
