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
#   ./patch-claude.sh --binary /path/to/claude
#
set -euo pipefail

COMPAT_DIR="$HOME/.claude/compat"

usage() {
    echo "Usage: $0 [--node-dir /path/to/node/version] [--binary /path/to/claude]"
    echo "Example: $0 --node-dir ~/.nvm/versions/node/v22.22.0"
    echo "Example: $0 --binary ~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

is_macho() {
    [ -f "$1" ] && file "$1" 2>/dev/null | grep -q "Mach-O"
}

is_node_entry() {
    [ -f "$1" ] && head -1 "$1" 2>/dev/null | grep -q "#!/usr/bin/env node"
}

is_fallback_stub() {
    [ -f "$1" ] || return 1
    local size
    size="$(stat -f "%z" "$1" 2>/dev/null || echo 0)"
    [ "$size" -lt 4096 ] || return 1
    grep -E -q "native binary not installed|postinstall did not run|optional dependency" "$1" 2>/dev/null
}

stat_signature() {
    if [ -e "$1" ]; then
        stat -f "%z:%m" "$1" 2>/dev/null || echo "missing"
    else
        echo "missing"
    fi
}

wait_for_stable_file() {
    local path="$1"
    local last=""
    local same=0
    local sig
    local i

    for i in 1 2 3 4 5 6 7 8 9 10; do
        sig="$(stat_signature "$path")"
        if [ "$sig" != "missing" ] && [ "$sig" = "$last" ]; then
            same=$((same + 1))
            if [ "$same" -ge 2 ]; then
                return 0
            fi
        else
            same=0
        fi
        last="$sig"
        sleep 1
    done
}

acquire_lock() {
    local lock_dir="$COMPAT_DIR/patch-claude.lock"
    local i now mtime age

    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        if mkdir "$lock_dir" 2>/dev/null; then
            trap 'rmdir "$COMPAT_DIR/patch-claude.lock" 2>/dev/null || true' EXIT
            return 0
        fi

        now="$(date +%s)"
        mtime="$(stat -f "%m" "$lock_dir" 2>/dev/null || echo "$now")"
        age=$((now - mtime))
        if [ "$age" -gt 600 ]; then
            echo "Removing stale lock: $lock_dir"
            rmdir "$lock_dir" 2>/dev/null || true
        fi
        sleep 1
    done

    die "Timed out waiting for patch lock: $lock_dir"
}

native_package_name() {
    local os cpu
    os="$(uname -s)"
    cpu="$(uname -m)"

    if [ "$os" != "Darwin" ]; then
        die "This patcher only supports macOS"
    fi

    case "$cpu" in
        x86_64) echo "claude-code-darwin-x64" ;;
        arm64) echo "claude-code-darwin-arm64" ;;
        *) die "Unsupported macOS architecture: $cpu" ;;
    esac
}

native_binary_path() {
    local pkg src node_bin resolved
    pkg="$(native_package_name)"
    src="$CLAUDE_PKG/node_modules/@anthropic-ai/$pkg/claude"
    if [ -x "$src" ]; then
        echo "$src"
        return 0
    fi

    node_bin="$NODE_DIR/bin/node"
    if [ ! -x "$node_bin" ]; then
        node_bin="$(command -v node || true)"
    fi
    if [ -n "$node_bin" ]; then
        resolved="$("$node_bin" -e 'const path=require("path"); const pkg=process.argv[1]; const base=process.argv[2]; try { const p=require.resolve("@anthropic-ai/"+pkg+"/package.json", {paths:[base]}); console.log(path.join(path.dirname(p), "claude")); } catch { process.exit(1); }' "$pkg" "$CLAUDE_PKG" 2>/dev/null || true)"
        if [ -n "$resolved" ] && [ -x "$resolved" ]; then
            echo "$resolved"
            return 0
        fi
    fi

    return 1
}

run_postinstall() {
    local node_bin
    node_bin="$NODE_DIR/bin/node"
    if [ ! -x "$node_bin" ]; then
        node_bin="$(command -v node || true)"
    fi

    [ -n "$node_bin" ] || return 1
    [ -f "$CLAUDE_PKG/install.cjs" ] || return 1

    echo "Running Claude Code postinstall to place native binary..."
    (cd "$CLAUDE_PKG" && "$node_bin" install.cjs)
}

has_minos_11() {
    otool -l "$1" 2>/dev/null | grep -A5 "LC_BUILD_VERSION" | grep -q "minos 11.0"
}

patch_minos() {
    local tmp="$CLAUDE_EXE.tmp"
    local status

    rm -f "$tmp"

    set +e
    "$VTOOL" -set-build-version macos 11.0 15.5 -replace -output "$tmp" "$CLAUDE_EXE" 2>/dev/null
    status=$?
    set -e

    if [ "$status" -eq 0 ] && has_minos_11 "$tmp"; then
        mv "$tmp" "$CLAUDE_EXE"
        return 0
    fi

    if [ -s "$tmp" ] && is_macho "$tmp" && has_minos_11 "$tmp"; then
        echo "  vtool returned $status but produced a valid patched output; continuing."
        mv "$tmp" "$CLAUDE_EXE"
        return 0
    fi

    rm -f "$tmp"
    if has_minos_11 "$CLAUDE_EXE"; then
        echo "  vtool returned $status after updating minos in place; continuing."
        return 0
    fi

    die "vtool failed while patching Mach-O minimum macOS version (exit $status)"
}

repair_placeholder_binary() {
    local src

    [ -n "${CLAUDE_PKG:-}" ] || die "Cannot repair fallback stub without an npm package context"

    wait_for_stable_file "$CLAUDE_EXE"

    if is_macho "$CLAUDE_EXE" || is_node_entry "$CLAUDE_EXE"; then
        return 0
    fi

    if is_fallback_stub "$CLAUDE_EXE"; then
        echo "Detected fallback claude.exe stub; repairing native binary placement."
    else
        echo "claude.exe is not a Mach-O binary; attempting native binary placement."
    fi

    run_postinstall || true
    wait_for_stable_file "$CLAUDE_EXE"

    if is_macho "$CLAUDE_EXE" || is_node_entry "$CLAUDE_EXE"; then
        return 0
    fi

    src="$(native_binary_path || true)"
    if [ -z "$src" ]; then
        die "Native Claude Code binary not found. Reinstall without --ignore-scripts or --omit=optional."
    fi

    echo "Copying native binary from optional dependency:"
    echo "  $src"
    mkdir -p "$(dirname "$CLAUDE_EXE")"
    cp -p "$src" "$CLAUDE_EXE"
    chmod 755 "$CLAUDE_EXE"

    is_macho "$CLAUDE_EXE" || die "Restored claude.exe is not a Mach-O binary"
}

NODE_DIR=""
EXPLICIT_BINARY=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --node-dir)
            shift
            [ "$#" -gt 0 ] || die "--node-dir requires a value"
            NODE_DIR="$1"
            ;;
        --node-dir=*)
            NODE_DIR="${1#--node-dir=}"
            ;;
        --binary|--claude-exe)
            option="$1"
            shift
            [ "$#" -gt 0 ] || die "$option requires a value"
            EXPLICIT_BINARY="$1"
            ;;
        --binary=*|--claude-exe=*)
            EXPLICIT_BINARY="${1#*=}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ -z "$NODE_DIR" ] && [ -z "$EXPLICIT_BINARY" ]; then
                NODE_DIR="$1"
            else
                die "unknown arg: $1"
            fi
            ;;
    esac
    shift
done

[ -z "$NODE_DIR" ] || [ -z "$EXPLICIT_BINARY" ] || die "--node-dir and --binary cannot be used together"

if [ -n "$EXPLICIT_BINARY" ]; then
    CLAUDE_EXE="$EXPLICIT_BINARY"
    CLAUDE_PKG=""
else
    # Auto-detect Node.js directory
    if [ -z "$NODE_DIR" ]; then
        if command -v node &>/dev/null; then
            NODE_DIR="$(dirname "$(dirname "$(command -v node)")")"
        elif [ -d "$HOME/.nvm" ]; then
            NODE_DIR="$(ls -d "$HOME"/.nvm/versions/node/v* 2>/dev/null | sort -V | tail -1)"
        fi
    fi

    [ -n "$NODE_DIR" ] || die "could not detect Node.js dir. Pass --node-dir explicitly."

    CLAUDE_PKG="$NODE_DIR/lib/node_modules/@anthropic-ai/claude-code"
    CLAUDE_EXE="$CLAUDE_PKG/bin/claude.exe"
fi

mkdir -p "$COMPAT_DIR"
acquire_lock

if [ -n "$CLAUDE_PKG" ]; then
    if [ ! -d "$CLAUDE_PKG" ]; then
        echo "Claude Code package not present yet; update may still be in progress."
        for i in 1 2 3 4 5 6 7 8 9 10; do
            [ -d "$CLAUDE_PKG" ] && break
            sleep 1
        done
    fi

    [ -d "$CLAUDE_PKG" ] || die "Claude Code package not found at $CLAUDE_PKG"

    if [ ! -f "$CLAUDE_EXE" ]; then
        echo "claude.exe not present yet; update may still be in progress."
        repair_placeholder_binary
    fi

    repair_placeholder_binary
else
    [ -f "$CLAUDE_EXE" ] || die "Claude binary not found at $CLAUDE_EXE"
    wait_for_stable_file "$CLAUDE_EXE"
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

if ! is_macho "$CLAUDE_EXE"; then
    die "Refusing to patch non-Mach-O claude.exe: $CLAUDE_EXE"
fi

VERSION=$("$CLAUDE_EXE" --version 2>&1 || echo "unknown (binary won't run yet)")
echo "Patching Claude Code ($VERSION) for Big Sur compatibility..."

# Backup original only after proving it is a native binary. This avoids
# replacing a useful backup with npm's fallback stub during auto-update races.
cp -p "$CLAUDE_EXE" "$CLAUDE_EXE.original"

# Step 1: Lower minos from 13.0 to 11.0
echo "  [1/4] Patching minimum macOS version (13.0 → 11.0)..."
patch_minos

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
