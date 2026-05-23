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
LIBCXX_SYMBOL="__ZNKSt3__115basic_stringbufIcNS_11char_traitsIcEENS_9allocatorIcEEE3strEv"

compatible_libcxx() {
    nm -g "$1" 2>/dev/null | grep "$LIBCXX_SYMBOL" >/dev/null
}

rpath_deps() {
    otool -L "$1" 2>/dev/null | sed -n 's/^[[:space:]]*@rpath\/\([^[:space:]]*\.dylib\).*/\1/p'
}

find_rpath_dep() {
    local dep="$1"
    local source_dir="$2"
    local dir

    for dir in \
        "$COMPAT_DIR" \
        "$source_dir" \
        "$source_dir/c++" \
        "$source_dir/unwind" \
        "$source_dir/.." \
        "$source_dir/../c++" \
        "$source_dir/../unwind" \
        /usr/local/opt/llvm/lib/c++ \
        /usr/local/opt/llvm/lib/unwind \
        /usr/local/opt/llvm/lib \
        /opt/homebrew/opt/llvm/lib/c++ \
        /opt/homebrew/opt/llvm/lib/unwind \
        /opt/homebrew/opt/llvm/lib; do
        if [ -f "$dir/$dep" ]; then
            echo "$dir/$dep"
            return 0
        fi
    done

    return 1
}

sign_dylib() {
    if command -v codesign &>/dev/null; then
        codesign --force --sign - "$1" 2>/dev/null || true
    fi
}

copy_rpath_dep() {
    local dep="$1"
    local source_dir="$2"
    local dep_dst="$COMPAT_DIR/$dep"
    local dep_src
    local nested_dep
    local nested_dst
    local nested_src

    if [ ! -f "$dep_dst" ]; then
        dep_src="$(find_rpath_dep "$dep" "$source_dir")" || {
            echo "ERROR: Could not find runtime dependency $dep for $LIBCXX_DST" >&2
            exit 1
        }
        cp -L "$dep_src" "$dep_dst"
        chmod u+w "$dep_dst"
        echo "  Copied $dep from $dep_src"
    else
        dep_src="$dep_dst"
    fi

    install_name_tool -id "$dep_dst" "$dep_dst" 2>/dev/null || true

    # Homebrew libc++abi depends on @rpath/libunwind.1.dylib. Handle that
    # one-level dependency so the copied runtime is self-contained.
    for nested_dep in $(rpath_deps "$dep_dst"); do
        [ "$nested_dep" = "$(basename "$dep_dst")" ] && continue

        nested_dst="$COMPAT_DIR/$nested_dep"
        if [ ! -f "$nested_dst" ]; then
            nested_src="$(find_rpath_dep "$nested_dep" "$(dirname "$dep_src")")" || {
                echo "ERROR: Could not find runtime dependency $nested_dep for $dep_dst" >&2
                exit 1
            }
            cp -L "$nested_src" "$nested_dst"
            chmod u+w "$nested_dst"
            echo "  Copied $nested_dep from $nested_src"
        fi

        install_name_tool -id "$nested_dst" "$nested_dst" 2>/dev/null || true
        install_name_tool -change "@rpath/$nested_dep" "$nested_dst" "$dep_dst" 2>/dev/null || true
        sign_dylib "$nested_dst"
    done

    sign_dylib "$dep_dst"
}

self_contain_libcxx() {
    local source_dir="$1"
    local dep
    local dep_dst

    chmod u+w "$LIBCXX_DST"
    install_name_tool -id "$LIBCXX_DST" "$LIBCXX_DST" 2>/dev/null || true

    for dep in $(rpath_deps "$LIBCXX_DST"); do
        [ "$dep" = "$(basename "$LIBCXX_DST")" ] && continue

        copy_rpath_dep "$dep" "$source_dir"
        dep_dst="$COMPAT_DIR/$dep"
        install_name_tool -change "@rpath/$dep" "$dep_dst" "$LIBCXX_DST" 2>/dev/null || true
    done

    sign_dylib "$LIBCXX_DST"
}

copy_libcxx() {
    local candidate="$1"

    if ! compatible_libcxx "$candidate"; then
        echo "ERROR: libc++ at $candidate does not provide required C++ ABI symbols." >&2
        exit 1
    fi

    cp -L "$candidate" "$LIBCXX_DST"
    echo "  Copied libc++ from $candidate"
    self_contain_libcxx "$(dirname "$candidate")"
}

if [ -f "$LIBCXX_DST" ]; then
    if ! compatible_libcxx "$LIBCXX_DST"; then
        echo "ERROR: existing libc++ at $LIBCXX_DST does not provide required C++ ABI symbols." >&2
        echo "Remove it and re-run this script after installing a compatible libc++." >&2
        exit 1
    fi

    echo "  libc++ already present at $LIBCXX_DST — skipping."
    self_contain_libcxx "$(dirname "$LIBCXX_DST")"
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
            if compatible_libcxx "$candidate"; then
                copy_libcxx "$candidate"
                break
            fi
        fi
    done

    # Try: Homebrew LLVM
    if [ ! -f "$LIBCXX_DST" ]; then
        for candidate in \
            /usr/local/opt/llvm/lib/libc++.1.dylib \
            /usr/local/opt/llvm/lib/c++/libc++.1.dylib \
            /opt/homebrew/opt/llvm/lib/libc++.1.dylib \
            /opt/homebrew/opt/llvm/lib/c++/libc++.1.dylib; do
            if [ -f "$candidate" ]; then
                if compatible_libcxx "$candidate"; then
                    copy_libcxx "$candidate"
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
                copy_libcxx "$candidate"
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
