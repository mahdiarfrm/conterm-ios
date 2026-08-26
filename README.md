# Conterm for iOS

An SSH client built on [Ghostty](https://github.com/ghostty-org/ghostty)'s
terminal engine, in the design language of
[Conterm](https://github.com/mahdiarfrm/conterm).

Not a port of the Mac app. Conterm's lane is *ambient awareness and safety* —
see it, feel prod, get told — and several of its ideas are better on a phone
than on a desktop, because "did the 3am job run?" and "is that box OK?" are
questions you ask while away from the machine.

> Independent frontend built on **libghostty**, with local patches. Not
> affiliated with, endorsed by, or sponsored by the Ghostty project.

## How it works

iOS forbids `fork`, `exec` and pty allocation, so a terminal there cannot own
a process — it has to be fed. Upstream libghostty has exactly one termio
backend and it spawns a child on a pty, and its C API has no way to push
bytes into a surface from outside.

`patches/ghostty/` adds both: a `termio.External` backend whose bytes come
from the embedder, and `ghostty_surface_write_output` to deliver them.

`patches/libxev/` fixes a second, quieter blocker. libghostty wakes its
renderer and IO threads with `xev.Async`, which on Darwin is a mach port
watched by `EVFILT_MACHPORT` — and the revision ghostty pins gates that
kevent on `os.tag == .macos`, so on iOS the wait is never armed. `notify()`
still reports success (the port's queue limit is 1, so every send after the
first undelivered one returns `SEND_TIMED_OUT`, which libxev treats as "it
will wake up"), and the renderer thread parks in `kevent64` at startup and
never rebuilds a cell again. The terminal draws its background colour and
nothing else, forever, with no error anywhere. Upstream fixed this in
libxev@7bf2b2f; the patch is that commit applied to the pinned revision, and
`build-ghostty.sh` vendors libxev into the checkout so the fix survives.

```
output   SSH bytes → ghostty_surface_write_output() → VT parse → Metal
input    UIKey/UIKeyInput → ghostty_surface_key()/_text()
                          → External.zig queueWrite()
                          → write_callback → libssh2_channel_write
resize   layoutSubviews → ghostty_surface_set_size()
                        → resize_callback → libssh2_channel_request_pty_size
```

Ghostty owns VT parsing, scrollback, selection, fonts and GPU rendering.
Swift is a byte pump plus the product around it.

**SSH is libssh2, not SwiftNIO SSH.** SwiftNIO SSH implements modern
primitives only — Ed25519 and ECDSA keys, AES-GCM, curve25519 kex. A stock
`id_rsa`, an RSA host key, or a server negotiating `aes256-ctr` simply fails
to connect, which for an SSH client is fatal rather than inconvenient.

## Building

Requires Xcode 26 and its Command Line Tools. Both native dependencies build
from source; neither is checked in.

```bash
bash scripts/build-ghostty.sh install   # clone pin, apply patches, zig build
bash scripts/build-libssh2.sh           # OpenSSL + libssh2 for device and sim
open Conterm.xcodeproj
```

`build-ghostty.sh` fetches the pinned Zig toolchain itself (pin constants in
`scripts/ghostty-pin.sh`) and verifies that every slice actually exports
`_ghostty_surface_write_output` — a build where the patches silently failed
to apply otherwise shows up much later, as a terminal that stays black.

Running on a device also needs the iOS platform bundle, which Xcode 26 does
not install by default:

```bash
xcodebuild -downloadPlatform iOS
```

## Layout

```
Sources/
  App/        entry point, scene, root navigation
  Design/     Theme.swift (tokens, springs), Glass.swift (the lens system)
  Terminal/   libghostty bridge, UIKit surface, key map, session
  SSH/        transport protocol, libssh2 implementation, ssh_config parser
  Hosts/      host model, HostProbe, host list
patches/ghostty/
  0001  renderer teardown fix (carried from Conterm)
  0002  termio.External backend
  0003  embedded apprt options + ghostty_surface_write_output
scripts/      build-ghostty.sh, build-libssh2.sh, ghostty-pin.sh
```

## Design

The tokens, springs and the flat-lens glass system come straight from
Conterm's `UI/Theme.swift` and `UI/Effects/LiquidGlass.swift`, so the two
apps read as one product. Two rules are worth repeating because breaking
either is easy and looks bad:

- **One sheet of glass, flat lenses on top.** Never nest a real glass effect
  inside another. Every pill and chip is a plain translucent fill with a
  0.5pt top-lit rim in `.plusLighter`.
- **Glass needs varied content behind it.** Over a flat dark screen,
  "translucent" has nothing to be translucent to and reads as a tinted panel.

Colour means something or it isn't used: status (working / needs-you / ready
/ danger), one user-chosen action accent, and the warm-red brand moment on
launch. Everything else is monochrome.

## Licence

MIT. Built on [libghostty](https://github.com/ghostty-org/ghostty) (MIT),
[libssh2](https://libssh2.org) (BSD-3-Clause) and
[OpenSSL](https://openssl.org) (Apache-2.0).
