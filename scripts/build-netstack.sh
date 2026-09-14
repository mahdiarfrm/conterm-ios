#!/bin/bash
# Build the user-space network stack (netstack/, gvisor-tap-vsock) as an
# xcframework the app links, for the Linux machine's networking. Produces
# Vendor/NetStack.xcframework with device (iOS arm64) and simulator (iOS
# simulator arm64) slices. Needs Go and the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=Vendor/NetStack.xcframework
BUILD=.build-netstack
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD/device" "$BUILD/sim"

build() {
  local sdk=$1 minflag=$2 dest=$3
  local sysroot; sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
    CC="$(xcrun --sdk "$sdk" -f clang) -arch arm64 -isysroot $sysroot $minflag" \
    go build -C netstack -buildmode=c-archive -trimpath \
      -o "$OLDPWD/$dest/libnetstack.a" .
}

echo "==> device slice"
OLDPWD=$PWD build iphoneos "-mios-version-min=18.0" "$BUILD/device"
echo "==> simulator slice"
OLDPWD=$PWD build iphonesimulator "-mios-simulator-version-min=18.0" "$BUILD/sim"

mkdir -p "$BUILD/device/Headers" "$BUILD/sim/Headers"
cp "$BUILD/device/libnetstack.h" "$BUILD/device/Headers/"
cp "$BUILD/sim/libnetstack.h" "$BUILD/sim/Headers/"

xcodebuild -create-xcframework \
  -library "$BUILD/device/libnetstack.a" -headers "$BUILD/device/Headers" \
  -library "$BUILD/sim/libnetstack.a" -headers "$BUILD/sim/Headers" \
  -output "$OUT"
echo "OK: $OUT"
ls -la "$OUT"
