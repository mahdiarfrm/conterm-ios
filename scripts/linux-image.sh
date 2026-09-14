#!/bin/bash
# Build the Debian image the Linux machine boots, as WebAssembly, into
# Resources/linux/debian.wasm.
#
# Needs Docker (OrbStack or Docker Desktop, with buildx) and Go. The first
# run compiles a RISC-V Linux kernel and the emulator inside Docker, which
# takes a long while; later runs reuse that work and only repack the image.
#
#   scripts/linux-image.sh                    # debian:trixie-slim, 512 MB
#   scripts/linux-image.sh debian:trixie      # another image
#   LINUX_IMAGE_MEMORY_MB=384 scripts/linux-image.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# With no argument the image is built from scripts/linux/guest.Dockerfile
# (Debian plus a working set of tools). Pass an image name to convert that
# instead, e.g. scripts/linux-image.sh alpine:3.20.
IMAGE=${1:-}
MEMORY=${LINUX_IMAGE_MEMORY_MB:-512}
LOGLEVEL=${LINUX_IMAGE_LOGLEVEL:-4}
# "native" starts the emulator from scratch on every boot; "wizer" snapshots
# its startup into the image, a second or two faster per boot, at the cost of
# compiling wizer (an hour under emulation on a laptop).
OPTIMIZATION=${LINUX_IMAGE_OPTIMIZATION:-native}
WORK=${LINUX_IMAGE_WORK:-.linux-image}
C2W_VERSION=v0.8.4
OUT=Resources/linux/debian.wasm

mkdir -p "$WORK"
if [ ! -d "$WORK/container2wasm" ]; then
  echo "==> fetching container2wasm $C2W_VERSION"
  git clone -q --depth 1 -b "$C2W_VERSION" https://github.com/container2wasm/container2wasm "$WORK/container2wasm"
fi
if [ ! -x "$WORK/c2w" ]; then
  echo "==> building c2w"
  (cd "$WORK/container2wasm" && go build -o ../c2w ./cmd/c2w)
fi

# The emulator patch rides in through the assets build context; the init
# patch is applied to the clone, which the same context builds init from.
mkdir -p "$WORK/container2wasm/patches"
cp scripts/linux/tinyemu-console-size.patch "$WORK/container2wasm/patches/"
if git -C "$WORK/container2wasm" apply --check "$PWD/scripts/linux/init-winsize.patch" 2>/dev/null; then
  git -C "$WORK/container2wasm" apply "$PWD/scripts/linux/init-winsize.patch"
fi
NATIVE=""
[ "$OPTIMIZATION" = native ] && NATIVE="--native"
python3 scripts/linux/dockerfile.py $NATIVE "$WORK/container2wasm/Dockerfile" > "$WORK/Dockerfile"

if [ -z "$IMAGE" ]; then
  IMAGE=conterm-linux:latest
  echo "==> building the guest image $IMAGE (riscv64, with tools)"
  docker buildx build --platform=linux/riscv64 --load \
    -t "$IMAGE" -f scripts/linux/guest.Dockerfile scripts/linux/
fi

echo "==> building the network stack"
(cd "$WORK/container2wasm/extras/c2w-net-proxy" && GOOS=wasip1 GOARCH=wasm go build -o "$OLDPWD/Resources/linux/c2w-net-proxy.wasm" .)

echo "==> converting $IMAGE (riscv64, ${MEMORY} MB)"
"$WORK/c2w" --target-arch=riscv64 \
  --dockerfile "$WORK/Dockerfile" --assets "$WORK/container2wasm" \
  --build-arg "VM_MEMORY_SIZE_MB=$MEMORY" \
  --build-arg INIT_DEBUG=false \
  --build-arg "LINUX_LOGLEVEL=$LOGLEVEL" \
  --build-arg "OPTIMIZATION_MODE=$OPTIMIZATION" \
  "$IMAGE" "$OUT"
ls -la "$OUT"
