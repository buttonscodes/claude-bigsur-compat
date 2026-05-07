#!/bin/bash
#
# Builds the ICU compatibility shim for macOS Big Sur.
# Requires: Xcode Command Line Tools (for cc, vtool, install_name_tool, codesign)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPAT_DIR="$HOME/.claude/compat"

echo "Building ICU compat shim..."

mkdir -p "$COMPAT_DIR"

# Build libicucore.A.dylib — re-exports system ICU + adds missing symbols
cc -dynamiclib \
    -o "$COMPAT_DIR/libicucore.A.dylib" \
    "$SCRIPT_DIR/icu_compat.c" \
    -Wl,-reexport-licucore \
    -isysroot "$(xcrun --show-sdk-path)" \
    -install_name "$COMPAT_DIR/libicucore.A.dylib" \
    -mmacosx-version-min=11.0

echo "  Built $COMPAT_DIR/libicucore.A.dylib"

# Copy source for reference
cp "$SCRIPT_DIR/icu_compat.c" "$COMPAT_DIR/icu_compat.c"

echo ""
echo "Now obtaining a compatible libc++..."
echo ""

# libc++ strategy: the Claude binary needs C++ ABI symbols added after
# Big Sur's libc++ (e.g. basic_stringbuf::str() const, basic_stringstream VTT).
# We need a newer libc++ that still runs on macOS 11.

LIBCXX_DST="$COMPAT_DIR/libc++.1.dylib"

if [ -f "$LIBCXX_DST" ]; then
    echo "  libc++ already present at $LIBCXX_DST — skipping."
else
    # Try: Anaconda / Miniconda
    for candidate in \
        /opt/anaconda3/lib/libc++.1.0.dylib \
        /opt/anaconda3/lib/libc++.1.dylib \
        "$HOME/anaconda3/lib/libc++.1.0.dylib" \
        "$HOME/miniconda3/lib/libc++.1.0.dylib" \
        /usr/local/anaconda3/lib/libc++.1.0.dylib; do
        if [ -f "$candidate" ]; then
            # Verify it has the needed symbol
            if nm -g "$candidate" 2>/dev/null | grep -q "__ZNKSt3__115basic_stringbufIcNS_11char_traitsIcEENS_9allocatorIcEEE3strEv"; then
                cp "$candidate" "$LIBCXX_DST"
                echo "  Copied libc++ from $candidate"
                break
            fi
        fi
    done

    # Try: Homebrew LLVM
    if [ ! -f "$LIBCXX_DST" ]; then
        for candidate in \
            /usr/local/opt/llvm/lib/libc++.1.dylib \
            /usr/local/opt/llvm/lib/c++/libc++.1.dylib; do
            if [ -f "$candidate" ]; then
                if nm -g "$candidate" 2>/dev/null | grep -q "__ZNKSt3__115basic_stringbufIcNS_11char_traitsIcEENS_9allocatorIcEEE3strEv"; then
                    cp "$candidate" "$LIBCXX_DST"
                    echo "  Copied libc++ from $candidate"
                    break
                fi
            fi
        done
    fi

    # Try: conda install
    if [ ! -f "$LIBCXX_DST" ] && command -v conda &>/dev/null; then
        echo "  Attempting: conda install -y libcxx..."
        if conda install -y libcxx 2>/dev/null; then
            CONDA_PREFIX="$(conda info --base)"
            candidate="$CONDA_PREFIX/lib/libc++.1.0.dylib"
            if [ -f "$candidate" ]; then
                cp "$candidate" "$LIBCXX_DST"
                echo "  Copied libc++ from conda"
            fi
        fi
    fi

    if [ ! -f "$LIBCXX_DST" ]; then
        echo ""
        echo "ERROR: Could not find a compatible libc++."
        echo ""
        echo "Please install one of:"
        echo "  - Anaconda/Miniconda (includes LLVM libc++ 14+)"
        echo "  - Homebrew LLVM:  brew install llvm"
        echo "  - Conda package:  conda install libcxx"
        echo ""
        echo "Then re-run this script."
        exit 1
    fi
fi

echo ""
echo "Build complete! Files in $COMPAT_DIR:"
ls -lh "$COMPAT_DIR"/*.dylib
echo ""
echo "Now run:  ./patch-claude.sh"
