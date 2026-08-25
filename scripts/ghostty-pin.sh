#!/usr/bin/env bash
# Pin constants for the libghostty build, shared by build-ghostty.sh and
# setup.sh. Lifted from conterm's scripts/ghostty-pin.sh — the iOS app
# tracks the same upstream commit, plus the external-termio patches in
# patches/ghostty/ that make a pty-less surface possible at all.
GHOSTTY_KIT_REPO="thdxg/ghostty"
GHOSTTY_KIT_TAG="build-2026-07-01"
GHOSTTY_KIT_VERSION="1.3.2-main-+24c5671"
GHOSTTY_KIT_COMMIT="24c56716f0dfe55911f6f81ee76198a95423851e"
GHOSTTY_KIT_ZIG="0.15.2"

# SwiftPM and Xcode both require a `lib` prefix on a static library inside
# an xcframework; ghostty emits `ghostty-internal.a`.
normalize_lib_prefix() {
    # `find` rather than a glob: this file gets sourced as often as it gets
    # executed, and an unmatched glob is a hard error in zsh.
    local fw="$1" lib dir base
    while IFS= read -r lib; do
        dir="$(dirname "$lib")"; base="$(basename "$lib")"
        [[ "$base" == lib* ]] && continue
        mv "$lib" "$dir/lib$base"
    done < <(find "$fw" -name '*.a' -type f)
    /usr/libexec/PlistBuddy -c "Print" "$fw/Info.plist" > /dev/null 2>&1 || return 0
    python3 - "$fw/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f: d = plistlib.load(f)
for lib in d.get('AvailableLibraries', []):
    n = lib.get('BinaryPath', '')
    if n and not n.startswith('lib'):
        lib['BinaryPath'] = 'lib' + n
        lib['LibraryPath'] = 'lib' + n
with open(p, 'wb') as f: plistlib.dump(d, f)
PY
}

kit_version() {
    local fw="$1" lib
    lib="$(find "$fw" -name '*.a' -print -quit)"
    [[ -n "$lib" ]] || return 0
    strings "$lib" 2>/dev/null | grep -oE '1\.[0-9]+\.[0-9]+-main-\+[0-9a-f]+' | head -1
}
