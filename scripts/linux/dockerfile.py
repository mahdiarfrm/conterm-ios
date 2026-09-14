#!/usr/bin/env python3
"""Print container2wasm's Dockerfile with Conterm's changes applied.

- The TinyEMU console-size patch is applied in the stage that checks the
  emulator out.
- With --native, the wizer snapshot tool is not compiled (a Rust build that
  takes an hour under emulation on a laptop); only its header is kept, which
  the emulator needs to compile. Pair it with OPTIMIZATION_MODE=native.
"""
import sys

args = sys.argv[1:]
native = "--native" in args
args = [a for a in args if a != "--native"]
src = open(args[0]).read()


def swap(old, new, what):
    global src
    if old not in src:
        sys.exit(f"the {what} has changed; update dockerfile.py")
    src = src.replace(old, new)


swap("""FROM ubuntu:22.04 AS tinyemu-repo-base
ARG TINYEMU_REPO
ARG TINYEMU_REPO_VERSION
RUN apt-get update && apt-get install -y git
RUN git clone ${TINYEMU_REPO} /tinyemu && \\
    cd /tinyemu && \\
    git checkout ${TINYEMU_REPO_VERSION}
""", """FROM ubuntu:22.04 AS tinyemu-repo-base
ARG TINYEMU_REPO
ARG TINYEMU_REPO_VERSION
RUN apt-get update && apt-get install -y git patch
RUN git clone ${TINYEMU_REPO} /tinyemu && \\
    cd /tinyemu && \\
    git checkout ${TINYEMU_REPO_VERSION}
COPY --from=assets /patches/tinyemu-console-size.patch /tmp/
RUN cd /tinyemu && patch -p1 < /tmp/tinyemu-console-size.patch
""", "tinyemu-repo-base stage")

if native:
    swap("""RUN git clone https://github.com/bytecodealliance/wizer && \\
    cd wizer && \\
    git checkout "${WIZER_VERSION}" && \\
    cargo build --bin wizer --all-features && \\
    mkdir -p /tools/wizer/ && \\
    mv include target/debug/wizer /tools/wizer/ && \\
    cargo clean

COPY --link --from=tinyemu-repo / /tinyemu
""", """RUN git clone https://github.com/bytecodealliance/wizer && \\
    cd wizer && \\
    git checkout "${WIZER_VERSION}" && \\
    mkdir -p /tools/wizer/ && \\
    mv include /tools/wizer/

COPY --link --from=tinyemu-repo / /tinyemu
""", "wizer build in tinyemu-dev-common")

sys.stdout.write(src)
