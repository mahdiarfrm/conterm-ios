#!/usr/bin/env bash
# Builds OpenSSL and libssh2 as iOS xcframeworks into Vendor/.
#
# Why not SwiftNIO SSH: it implements only modern primitives — Ed25519 and
# ECDSA keys, AES-GCM, curve25519 key exchange. A stock `id_rsa`, an RSA
# host key, or a server that negotiates aes256-ctr simply fails to connect,
# which for an SSH client is fatal rather than inconvenient. libssh2 covers
# what OpenSSH covers.
#
#   bash scripts/build-libssh2.sh          # build both, assemble xcframeworks
#   bash scripts/build-libssh2.sh clean    # start from scratch
set -euo pipefail
cd "$(dirname "$0")/.."

# OpenSSL 3.5 is the current LTS line; libssh2 1.11.1 is the latest release.
# Checksums are the ones published on the GitHub release, verified on fetch —
# a silently swapped crypto tarball is exactly the supply-chain failure this
# app cannot afford.
OPENSSL_VERSION="3.5.8"
OPENSSL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"
LIBSSH2_VERSION="1.11.1"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
IOS_MIN="18.0"

WORK=".build-ssh"
OUT="Vendor"
mkdir -p "$WORK" "$OUT"

if [[ "${1:-}" == "clean" ]]; then
    echo "==> removing $WORK"
    rm -rf "$WORK"
    mkdir -p "$WORK"
fi

fetch() { # url sha256 dest
    local url="$1" sha="$2" dest="$3"
    if [[ -f "$dest" ]]; then
        if echo "$sha  $dest" | shasum -a 256 -c - >/dev/null 2>&1; then return 0; fi
        echo "==> checksum mismatch on $(basename "$dest"), refetching"
        rm -f "$dest"
    fi
    echo "==> fetching $(basename "$dest")"
    curl -fsSL --retry 3 -o "$dest" "$url"
    echo "$sha  $dest" | shasum -a 256 -c -
}

# --------------------------------------------------------------------------
# OpenSSL
# --------------------------------------------------------------------------
# Two slices: arm64 device and arm64 simulator. There is no x86_64 slice —
# every Mac that can run this toolchain is Apple Silicon, and an Intel
# simulator slice would double the build for nothing.
#
# `ios64-xcrun` and `iossimulator-xcrun` invoke xcrun themselves to find the
# right SDK, so no CROSS_TOP/CROSS_SDK dance is needed.
build_openssl() { # slice configure-target min-version-flag
    local slice="$1" target="$2" minflag="$3"
    local src="$WORK/openssl-$OPENSSL_VERSION"
    local prefix; prefix="$PWD/$WORK/openssl-$slice"
    [[ -f "$prefix/lib/libssl.a" ]] && { echo "==> openssl/$slice already built"; return 0; }

    echo "==> building openssl for $slice"
    rm -rf "$WORK/build-openssl-$slice"
    cp -R "$src" "$WORK/build-openssl-$slice"
    (
        cd "$WORK/build-openssl-$slice"
        # no-async: OpenSSL's async engine uses setcontext/makecontext,
        #   which iOS does not provide.
        # no-shared: an iOS app cannot dlopen a dylib it did not ship
        #   signed, and a static archive is what an xcframework wants.
        # no-tests/no-docs: nothing here is run or read on device.
        # OpenSSL refuses to mix make variables (CFLAGS=...) with compiler
        # flags given as command-line options, so the flags go inline.
        # The min-version flag differs per slice, and it is what stamps the
        # Mach-O platform. Using the device flag for the simulator produces a
        # library tagged platform 2 rather than 7, and -create-xcframework
        # then rejects both slices as the same identifier.
        ./Configure "$target" \
            no-shared no-async no-tests no-docs no-legacy \
            --prefix="$prefix" \
            "${minflag}=${IOS_MIN}" -O2
        make -j"$(sysctl -n hw.ncpu)" build_libs
        make install_dev
    ) > "$WORK/openssl-$slice.log" 2>&1 || {
        echo "ERROR: openssl/$slice failed — see $WORK/openssl-$slice.log" >&2
        tail -30 "$WORK/openssl-$slice.log" >&2
        exit 1
    }
    echo "==> openssl/$slice ok"
}

# --------------------------------------------------------------------------
# libssh2
# --------------------------------------------------------------------------
build_libssh2() { # slice sdk arch cmake-sysroot
    local slice="$1" sysroot="$2"
    local src="$PWD/$WORK/libssh2-$LIBSSH2_VERSION"
    local ssl="$PWD/$WORK/openssl-$slice"
    local prefix="$PWD/$WORK/libssh2-$slice"
    [[ -f "$prefix/lib/libssh2.a" ]] && { echo "==> libssh2/$slice already built"; return 0; }

    echo "==> building libssh2 for $slice"
    rm -rf "$WORK/build-libssh2-$slice"
    mkdir -p "$WORK/build-libssh2-$slice"
    (
        cd "$WORK/build-libssh2-$slice"
        cmake "$src" \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_SYSROOT="$sysroot" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
            -DCMAKE_INSTALL_PREFIX="$prefix" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCRYPTO_BACKEND=OpenSSL \
            -DOPENSSL_ROOT_DIR="$ssl" \
            -DOPENSSL_INCLUDE_DIR="$ssl/include" \
            -DOPENSSL_CRYPTO_LIBRARY="$ssl/lib/libcrypto.a" \
            -DOPENSSL_SSL_LIBRARY="$ssl/lib/libssl.a" \
            -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_STATIC_LIBS=ON \
            -DBUILD_EXAMPLES=OFF \
            -DBUILD_TESTING=OFF \
            -DENABLE_ZLIB_COMPRESSION=OFF
        cmake --build . --config Release -j"$(sysctl -n hw.ncpu)"
        cmake --install .
    ) > "$WORK/libssh2-$slice.log" 2>&1 || {
        echo "ERROR: libssh2/$slice failed — see $WORK/libssh2-$slice.log" >&2
        tail -30 "$WORK/libssh2-$slice.log" >&2
        exit 1
    }
    echo "==> libssh2/$slice ok"
}

# --------------------------------------------------------------------------
# xcframework assembly
# --------------------------------------------------------------------------
# libssh2 and OpenSSL are three separate archives that always travel
# together, so each becomes one xcframework with its own headers.
# None of these xcframeworks ship headers.
#
# Xcode copies every xcframework's headers into one shared `include/` in the
# build products. GhosttyKit declares an umbrella module over that directory,
# so any header landing beside it — every openssl/*.h, say — is claimed by
# module GhosttyKit, warned about, and the module comes out malformed. The
# symptom is not a missing header but a Swift error that `libssh2_init` does
# not exist.
#
# So the C headers go to Vendor/include instead, reached by
# HEADER_SEARCH_PATHS, and the shared include/ stays GhosttyKit's alone.
# Device and simulator headers are identical for both libraries, so one copy
# serves both slices.
assemble() { # name lib-relpath
    local name="$1" rel="$2"
    local fw="$OUT/$name.xcframework"
    rm -rf "$fw"
    xcodebuild -create-xcframework \
        -library "$WORK/$rel-device/lib/lib$name.a" \
        -library "$WORK/$rel-simulator/lib/lib$name.a" \
        -output "$fw" > /dev/null
    echo "==> $fw"
}

DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
      "$OPENSSL_SHA256" "$WORK/openssl.tar.gz"
[[ -d "$WORK/openssl-$OPENSSL_VERSION" ]] || tar xf "$WORK/openssl.tar.gz" -C "$WORK"

fetch "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VERSION/libssh2-$LIBSSH2_VERSION.tar.gz" \
      "$LIBSSH2_SHA256" "$WORK/libssh2.tar.gz"
[[ -d "$WORK/libssh2-$LIBSSH2_VERSION" ]] || tar xf "$WORK/libssh2.tar.gz" -C "$WORK"

build_openssl device    ios64-xcrun        -mios-version-min
build_openssl simulator iossimulator-xcrun -mios-simulator-version-min

build_libssh2 device    "$DEVICE_SDK"
build_libssh2 simulator "$SIM_SDK"

# Catch a mis-stamped slice here, where the error names the cause, rather
# than at -create-xcframework, which only says "identifier already exists".
check_platform() { # lib expected-platform
    # `|| true` on each stage: under `set -e` a grep that matches nothing
    # takes the whole script down silently, which is a maddening way to
    # learn that otool changed its output.
    local got
    got="$(otool -l "$1" 2>/dev/null | grep -m1 -A2 LC_BUILD_VERSION 2>/dev/null | awk '/platform/{print $2}' || true)"
    if [[ "$got" != "$2" ]]; then
        echo "ERROR: $1 is Mach-O platform ${got:-unknown}, expected $2." >&2
        echo "ERROR: (2 = iOS device, 7 = iOS simulator)" >&2
        exit 1
    fi
}
for lib in libcrypto libssl; do
    check_platform "$WORK/openssl-device/lib/$lib.a" 2
    check_platform "$WORK/openssl-simulator/lib/$lib.a" 7
done
check_platform "$WORK/libssh2-device/lib/libssh2.a" 2
check_platform "$WORK/libssh2-simulator/lib/libssh2.a" 7

assemble ssh2   libssh2
assemble crypto openssl
assemble ssl    openssl

echo "==> $OUT/include"
rm -rf "$OUT/include"
mkdir -p "$OUT/include"
cp -R "$WORK/libssh2-device/include/." "$OUT/include/"
cp -R "$WORK/openssl-device/include/." "$OUT/include/"

echo
echo "OK: xcframeworks in $OUT/"
