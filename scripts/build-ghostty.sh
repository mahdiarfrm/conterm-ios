#!/usr/bin/env bash
# Builds GhosttyKit.xcframework from source at the pinned commit, with the
# external-termio patches in patches/ghostty/ applied.
#
# Those patches are the whole reason this script exists rather than a
# download. Upstream libghostty has exactly one termio backend and it
# spawns a child process on a pty; iOS allows neither. patches/ghostty/
# adds a backend whose bytes come from the embedder instead, plus the
# `ghostty_surface_write_output` entry point to push them in. Without them
# an iOS surface renders an empty grid forever.
#
#   bash scripts/build-ghostty.sh            # build + verify
#   bash scripts/build-ghostty.sh install    # also replace Vendor/GhosttyKit.xcframework
#
# Env:
#   GHOSTTY_WORK     checkout dir (default .build-ghostty)
#   GHOSTTY_SYSROOT  macOS SDK for zig (default: Command Line Tools MacOSX15)
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/ghostty-pin.sh

WORK="${GHOSTTY_WORK:-.build-ghostty}"
OUT="$WORK/macos/GhosttyKit.xcframework"

# Tagless on purpose: ghostty derives its version from `git describe`, and
# the fork's `build-YYYY-MM-DD` tags land on build commits — a non-vX.Y.Z
# tag match panics the build.
if [[ ! -d "$WORK/.git" ]]; then
    echo "==> cloning ${GHOSTTY_KIT_REPO} (blobless — objects fetch on demand)"
    git clone --filter=blob:none --no-tags "https://github.com/${GHOSTTY_KIT_REPO}.git" "$WORK"
fi
git -C "$WORK" fetch --quiet --no-tags origin "$GHOSTTY_KIT_COMMIT"
git -C "$WORK" tag -l | xargs -r git -C "$WORK" tag -d > /dev/null
git -C "$WORK" checkout --quiet -B main "$GHOSTTY_KIT_COMMIT"
# The version marker embeds `git rev-parse --short`; git widens short hashes
# with history size, so pin the abbreviation to the 7 chars the fork's
# shallow CI checkout produced.
git -C "$WORK" config core.abbrev 7

# Patches go onto a pristine tree so re-runs stay idempotent.
git -C "$WORK" checkout --quiet -- .
git -C "$WORK" clean --quiet -fd src/termio || true
for p in patches/ghostty/*.patch; do
    [[ -e "$p" ]] || continue
    echo "==> applying ${p##*/}"
    git -C "$WORK" apply "$PWD/$p"
done

# libxev is vendored rather than fetched, because the revision ghostty pins
# cannot wake an event loop on iOS at all — see patches/libxev/. Everything
# in ghostty that crosses a thread (the renderer waking to rebuild cells,
# the io thread, the surface mailboxes) rides on xev.Async, so without this
# the terminal renders its background colour and never a single cell.
XEV_DIR="$WORK/vendor/libxev"
if [[ ! -f "$XEV_DIR/.conterm-patched" ]]; then
    echo "==> vendoring libxev ${GHOSTTY_KIT_XEV_COMMIT:0:7} + iOS mach-port fix"
    rm -rf "$XEV_DIR"
    mkdir -p "$XEV_DIR"
    curl -fsSL --retry 3 "$GHOSTTY_KIT_XEV_URL" | tar xz -C "$XEV_DIR" --strip-components 1
    for p in patches/libxev/*.patch; do
        [[ -e "$p" ]] || continue
        echo "==> applying ${p##*/}"
        patch -p1 -s -d "$XEV_DIR" < "$p"
    done
    touch "$XEV_DIR/.conterm-patched"
fi

# zig: the pin builds with exactly ${GHOSTTY_KIT_ZIG}. Use the system zig
# when it matches; otherwise fetch the pinned toolchain into the checkout,
# which is gitignored and survives between runs.
if ! command -v zig >/dev/null || [[ "$(zig version)" != "$GHOSTTY_KIT_ZIG" ]]; then
    # `&&` here would be an errexit landmine on Intel, and ziglang.org names
    # the Apple Silicon build `aarch64` where uname says `arm64`.
    case "$(uname -m)" in
        arm64|aarch64) ARCH=aarch64 ;;
        *)             ARCH="$(uname -m)" ;;
    esac
    ZIG_DIR="$WORK/.zig-${GHOSTTY_KIT_ZIG}-${ARCH}"
    if [[ ! -x "$ZIG_DIR/zig" ]]; then
        echo "==> fetching zig ${GHOSTTY_KIT_ZIG} (${ARCH}-macos)"
        INFO="$(curl -fsSL https://ziglang.org/download/index.json \
            | python3 -c "import json,sys; d=json.load(sys.stdin)[\"${GHOSTTY_KIT_ZIG}\"][\"${ARCH}-macos\"]; print(d[\"tarball\"], d[\"shasum\"])")"
        URL="${INFO%% *}"; SHA="${INFO##* }"
        curl -fsSL --retry 3 -o "$WORK/zig.tar.xz" "$URL"
        echo "$SHA  $WORK/zig.tar.xz" | shasum -a 256 -c - > /dev/null
        mkdir -p "$ZIG_DIR"
        tar xf "$WORK/zig.tar.xz" -C "$ZIG_DIR" --strip-components 1
        rm "$WORK/zig.tar.xz"
    fi
    export PATH="$(cd "$ZIG_DIR" && pwd):$PATH"
fi
echo "==> zig $(zig version)"

# zig discovers the SDK by probing `xcrun --show-sdk-path` — even for its own
# build runner, before --sysroot applies — and cannot read a libSystem.tbd
# newer than itself (zig 0.15 against the macOS 26 SDK fails with every libc
# symbol undefined). Shim the probe so every stage sees the same SDK.
SYSROOT="${GHOSTTY_SYSROOT:-}"
if [[ -z "$SYSROOT" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk ]]; then
    SYSROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk
fi
if [[ -n "$SYSROOT" ]]; then
    echo "==> macOS SDK for zig: $SYSROOT"
    # Scope the shim to macOS probes only — we are here *for* the iOS slices,
    # and their SDK probes must reach the real xcrun.
    SHIM="$PWD/$WORK/.sdk-shim"
    mkdir -p "$SHIM"
    cat > "$SHIM/xcrun" <<EOF
#!/bin/sh
case "\$*" in
  *--sdk\ iphone*) exec /usr/bin/xcrun "\$@";;
  *--show-sdk-path*) echo "$SYSROOT"; exit 0;;
esac
exec /usr/bin/xcrun "\$@"
EOF
    chmod +x "$SHIM/xcrun"
    export PATH="$SHIM:$PATH"
fi

echo "==> zig build (ReleaseFast, universal xcframework) — this takes a while"
(cd "$WORK" && zig build -Doptimize=ReleaseFast -Demit-xcframework=true \
    -Dxcframework-target=universal -Demit-macos-app=false -Demit-themes=true)

normalize_lib_prefix "$OUT"

# The pin check catches a drifted checkout; the symbol check catches the
# thing that actually breaks the app — a build where the patches silently
# didn't apply, which otherwise fails much later as a black terminal.
FOUND="$(kit_version "$OUT")"
if [[ "$FOUND" != "$GHOSTTY_KIT_VERSION"* && "$GHOSTTY_KIT_VERSION" != "$FOUND"* ]]; then
    echo "ERROR: built '${FOUND:-unknown}', pin expects '${GHOSTTY_KIT_VERSION}'." >&2
    echo "ERROR: the pin constants live in scripts/ghostty-pin.sh." >&2
    exit 1
fi

for slice in ios-arm64 ios-arm64-simulator macos-arm64_x86_64; do
    lib="$(find "$OUT/$slice" -name '*.a' -type f 2>/dev/null | head -1)"
    if [[ -z "$lib" ]]; then
        echo "ERROR: no static library in slice $slice" >&2
        exit 1
    fi
    # No pipe into grep here: `grep -q` exits on the first match and SIGPIPEs
    # `nm`, which under `pipefail` makes a *successful* check look like a
    # failed one — nondeterministically, since it depends on whether nm has
    # finished writing 130MB of symbols first.
    symbols="$(nm -gU "$lib" 2>/dev/null || true)"
    if [[ "$symbols" != *_ghostty_surface_write_output* ]]; then
        echo "ERROR: $slice is missing _ghostty_surface_write_output —" >&2
        echo "ERROR: the external-termio patches did not make it into this build." >&2
        exit 1
    fi
done

echo "OK: built ${FOUND}, external termio present in all slices"

if [[ "${1:-}" == "install" ]]; then
    rm -rf Vendor/GhosttyKit.xcframework
    mkdir -p Vendor
    cp -R "$OUT" Vendor/
    echo "OK: installed Vendor/GhosttyKit.xcframework"
fi
