# claude-bigsur-compat

Run the latest Claude Code CLI on macOS Big Sur (11.x).

Starting with version ~2.1.85, Claude Code ships a compiled Bun binary (`bin/claude.exe`) instead of a Node.js script. This binary targets macOS 13+ (Ventura) and will not launch on Big Sur. This repo provides a set of shims and a patching script that work around the three incompatibilities so the binary runs on macOS 11.

**This is a hack.** It works, but it is not an officially supported configuration. See [Limitations](#limitations).

Tested with Claude Code **2.1.132** on macOS **11.7.11** (x86_64).

---

## Table of Contents

- [Requirements](#requirements)
- [Setup](#setup)
- [Usage](#usage)
- [Auto-patch on update](#auto-patch-on-update)
- [How it works](#how-it-works)
- [Limitations](#limitations)
- [Files](#files)
- [License](#license)

---

## Requirements

- **macOS Big Sur (11.x)** -- may also work on Monterey (12.x)
- **Xcode Command Line Tools** (`xcode-select --install`) -- provides `cc`, `vtool`, `install_name_tool`, `codesign`
- **Node.js** via [nvm](https://github.com/nvm-sh/nvm) (tested with v22.22.0)
- **A compatible libc++ source** -- one of:
  - Anaconda or Miniconda (ships LLVM libc++ 14+)
  - Homebrew LLVM (`brew install llvm`)
  - conda `libcxx` package (`conda install libcxx`)

## Setup

```bash
git clone https://github.com/anthropics/claude-bigsur-compat.git  # adjust URL as needed
cd claude-bigsur-compat

# One-time: build the ICU shim and locate a compatible libc++
./build.sh
```

`build.sh` compiles the ICU shim library and copies a suitable `libc++.1.dylib` into `~/.claude/compat/`. When the selected libc++ has `@rpath` runtime dependencies (for example Homebrew LLVM's `libc++abi.1.dylib` and `libunwind.1.dylib`), the build script also copies those dependencies into `~/.claude/compat/` and rewrites the dylib references so Claude Code can launch without `DYLD_LIBRARY_PATH`. You only need to run this once.

## Usage

After each Claude Code install or update:

```bash
npm install -g @anthropic-ai/claude-code@latest
./patch-claude.sh
```

The patch script auto-detects your Node.js directory. If detection fails, pass it explicitly:

```bash
./patch-claude.sh --node-dir ~/.nvm/versions/node/v22.22.0
```

The Anthropic VS Code extension bundles its own Claude Code native binary and may bypass your shell `PATH`. If the extension fails with the same Big Sur `dyld` errors, patch the bundled binary explicitly:

```bash
for binary in "$HOME"/.vscode/extensions/anthropic.claude-code-*-darwin-*/resources/native-binary/claude; do
  [ -f "$binary" ] && ./patch-claude.sh --binary "$binary"
done
```

The script is idempotent -- if the binary is already patched, it will report that and exit.

---

## Auto-patch on update

Claude Code has a built-in auto-updater (`autoUpdates: true` in `~/.claude.json`) that periodically re-runs `npm install -g @anthropic-ai/claude-code`. Every install replaces `bin/claude.exe` and undoes the patch, so plain auto-update + Big Sur means a recurring dyld error.

You can either disable auto-update and re-patch manually after each `npm install`, or install a launchd watcher that re-runs `patch-claude.sh` automatically whenever the binary changes:

```bash
./install-auto-patch.sh
```

This:

- Copies `patch-claude.sh` to `~/.claude/compat/` (a TCC-unrestricted directory -- launchd can't execute scripts under `~/Documents/` or `~/Desktop/` on Catalina+).
- Writes `~/Library/LaunchAgents/local.claude-patch.plist` with absolute paths (launchd plists don't expand `~` or `$HOME`).
- Bootstraps the agent via `launchctl bootstrap`.

From then on, every change inside `<node>/lib/node_modules/@anthropic-ai/claude-code/bin/` fires `patch-claude.sh`. The script's idempotency check (`otool -L | grep $COMPAT_DIR`) makes spurious fires harmless. Logs land at `~/Library/Logs/claude-patch.log`.

This watcher covers the npm-installed Claude Code binary. It does not watch VS Code extension directories, so re-run the `--binary` command above after updating the Anthropic VS Code extension.

To remove:

```bash
./uninstall-auto-patch.sh
```

Re-run `install-auto-patch.sh` after switching Node.js versions (e.g., `nvm install`). The plist hardcodes the Node directory, so a version change without re-installing leaves the watcher pointing at the old path.

---

## How it works

The Claude Code binary (`claude.exe`) fails on Big Sur for three reasons. Each is addressed by a separate fix:

### 1. Missing ICU symbols

Big Sur ships ICU 66; the binary expects ICU 69+ symbols. The most important is `ubrk_clone`, introduced in ICU 69 as a simpler replacement for `ubrk_safeClone`.

`icu_compat.c` is compiled into a `libicucore.A.dylib` that **re-exports the entire system ICU** (via `-Wl,-reexport-licucore`) and adds the 11 missing symbols:

| Symbol | Implementation |
|---|---|
| `ubrk_clone` | Real shim -- wraps `ubrk_safeClone` from ICU 66 |
| `unumf_openForSkeletonAndLocale` | Wrapper -- retries after removing default `integer-width/*...` skeleton tokens rejected by ICU 66 |
| `ucal_getTimeZoneOffsetFromLocal` | Stub -- returns `U_UNSUPPORTED_ERROR` |
| `udtitvfmt_formatCalendarToResult` | Stub |
| `unumrf_openForSkeletonWithCollapseAndIdentityFallback` | Constructor shim -- returns a non-null sentinel |
| `unumrf_close`, `unumrf_openResult`, `unumrf_closeResult` | Constructor/result shim |
| `unumrf_formatDoubleRange`, `unumrf_formatDecimalRange` | Stub |
| `unumrf_resultAsValue` | Stub |
| `uplrules_selectForRange` | Stub |

### 2. Missing libc++ ABI symbols

Big Sur's system `libc++` is too old and lacks symbols like `basic_stringbuf::str() const` and `basic_stringstream` VTT entries. The build script locates a newer LLVM libc++ (from Anaconda, Homebrew, or conda) that provides these symbols and still runs on macOS 11. For Homebrew LLVM, it also vendors the related runtime dylibs that libc++ loads through `@rpath`.

### 3. Mach-O minimum OS version

The binary's Mach-O `LC_BUILD_VERSION` has `minos` set to `13.0`. The dynamic linker (`dyld`) on Big Sur rejects it outright. `vtool` is used to lower this to `11.0`.

### Patching sequence

`patch-claude.sh` performs four steps on `claude.exe`:

1. `vtool -set-build-version macos 11.0 ...` -- lower the minos
2. `install_name_tool -change` -- redirect ICU to the compat shim
3. `install_name_tool -change` -- redirect libc++ to the compatible version
4. `codesign --force --sign -` -- ad-hoc re-sign (required after modifying the binary)

The original binary is backed up to `claude.exe.original`.

---

## Limitations

- **Most stubbed ICU functions do not work.** They exist only to satisfy the linker. The `unumf_openForSkeletonAndLocale` wrapper preserves ordinary number formatting by dropping ICU 66-incompatible default integer-width skeleton tokens, and the `unumrf_open*` functions return sentinel objects so JavaScriptCore can construct `Intl.NumberFormat`. Actual number-range formatting still returns `U_UNSUPPORTED_ERROR`. If Claude Code calls `formatRange()`, `uplrules_selectForRange`, or `ucal_getTimeZoneOffsetFromLocal` at runtime, that operation will fail. In practice, Claude Code does not appear to use these code paths.
- **`ubrk_clone` is a real shim** and works correctly by delegating to `ubrk_safeClone`. This is the only symbol the binary actually calls during normal operation.
- **You must re-patch after every update.** `npm install -g @anthropic-ai/claude-code@latest` replaces the binary, so run `./patch-claude.sh` again each time. See [Auto-patch on update](#auto-patch-on-update) for a launchd watcher that does this automatically.
- **x86_64 only.** Big Sur on Apple Silicon is unlikely in the wild, but this has only been tested on Intel.
- **Not officially supported.** This is a community workaround. A future Claude Code update could add new symbol dependencies that break compatibility.

---

## Files

```
claude-bigsur-compat/
  icu_compat.c              C source for the ICU shim library
  build.sh                  Compiles the shim + finds/copies a compatible libc++
  patch-claude.sh           Patches claude.exe after install/update
  install-auto-patch.sh     Installs a launchd watcher that re-patches on update
  uninstall-auto-patch.sh   Removes the launchd watcher
  README.md                 This file
```

Build artifacts are placed in `~/.claude/compat/`:

```
~/.claude/compat/
  libicucore.A.dylib   ICU shim (re-exports system ICU + missing symbols)
  libc++.1.dylib       Compatible LLVM libc++
  libc++abi.1.dylib    Copied when required by the selected libc++
  libunwind.1.dylib    Copied when required by the selected libc++
  icu_compat.c         Copy of the source for reference
```

---

## License

MIT
