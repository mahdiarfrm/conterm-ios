<p align="center">
  <img src="docs/assets/banner.png" alt="Conterm for iOS" width="100%" />
</p>

<p align="center">
  <a href="https://github.com/mahdiarfrm/conterm-ios/blob/master/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-555555" /></a>
  <a href="https://github.com/mahdiarfrm/conterm-ios/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/mahdiarfrm/conterm-ios?style=flat&color=FF2E2E" /></a>
  <img alt="Platform" src="https://img.shields.io/badge/iOS%20%7C%20iPadOS-18%2B-555555" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-555555" />
</p>

<p align="center">
  <a href="https://github.com/mahdiarfrm/conterm"><b>Conterm for macOS</b></a> ·
  <a href="#building-from-source">Build from source</a> ·
  <a href="https://github.com/mahdiarfrm/conterm-ios/issues">Issues</a>
</p>

**Conterm for iOS** is an SSH client for iPhone and iPad built on
[Ghostty's](https://github.com/ghostty-org/ghostty) terminal engine. It
provides full VT emulation with GPU rendering, a diagnostics view for
connected hosts, monitoring and reply for AI coding agents running on remote
machines, and Home Screen, Lock Screen and Dynamic Island widgets.

It shares a design system with
[Conterm for macOS](https://github.com/mahdiarfrm/conterm) but is a separate
application, not a port.

> Conterm is an independent frontend built on **libghostty**, with local
> patches that make a terminal without a pty possible on iOS. It is not
> affiliated with, endorsed by, or sponsored by the Ghostty project. The
> terminal engine (parsing, scrollback, selection, search, fonts and GPU
> rendering) is Ghostty's, under the MIT licence. Third-party notices are in
> [NOTICE.md](NOTICE.md).

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Building from source](#building-from-source)
- [Testing](#testing)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [License](#license)

## Features

### Terminal

- Full VT emulation through libghostty: parsing, scrollback, selection, wide
  glyphs, ligatures and Metal rendering. Full-screen applications such as
  `vi`, `htop` and `tmux` behave as they do in a desktop terminal.
- Sessions are held in a store keyed by host and outlive the screen that shows
  them. Leaving the terminal view does not close the shell, and a host can have
  several concurrent shells.
- A key accessory row above the software keyboard: latching `ctrl` and `alt`,
  `esc`, `tab`, the four arrow keys, and the punctuation a shell needs
  (`/ - | ~`), plus keys to open snippets and dismiss the keyboard.
- Find in scrollback using libghostty's own search, which covers the whole
  buffer and not only the visible viewport. Matches are highlighted by the
  renderer, and stepping through them scrolls the match into view.
- Touch scrolling at 1:1 tracking with momentum, at the display's native
  refresh rate, which is 120 Hz on ProMotion devices.
- Characters are delivered through the key path with real keycodes, not the
  paste path. Control bytes therefore survive, and applications using
  bracketed paste receive keystrokes as keystrokes.

### Hosts

- **ssh_config import.** Parses `~/.ssh/config`, follows `Include` directives
  and applies ssh-style glob patterns. `Match` blocks are skipped, not
  partially applied.
- **Groups.** Colour-coded and collapsible. Membership is stored on the host
  and definitions in a separate file. Renaming or recolouring a group does not
  rewrite host records, and deleting a group does not delete its hosts.
- **Key library.** Private keys are imported from Files, stored in the
  Keychain and referenced by identifier, which lets one key serve many hosts.
  Format (OpenSSH, PKCS#1 RSA/EC/DSA, PKCS#8) and encryption are detected at
  import, and a passphrase is requested only for an encrypted key.
- **Nearby.** Discovers Macs running Conterm over Bonjour (`_conterm._tcp`)
  while the host list is on screen, and prefills the host editor from the
  advertised record. Browsing stops when the list is dismissed.
- **Quick Connect** for one-off `user@host` connections that are not saved.

### Host overview

A diagnostics screen for a host, collected in a single SSH round trip. The
header panel carries load, memory and disk under a summary status indicator;
the sections below hold the detail.

| Section | Contents |
|---------|----------|
| Vitals | uptime, full load triplet, memory |
| Disks | usage per mount |
| Network | interfaces and addresses |
| Workloads | containers, VMs, Kubernetes |
| Health | failed systemd units |
| Busiest | top processes by CPU and memory |
| Recent errors | journal and kernel messages |

A cached result renders immediately while a fresh probe runs, and the screen
reports the age of the data it is showing. Pull to refresh; *Open a shell*
connects to the host from the overview.

Containers across Docker, Podman, containerd and Apple's `container` are
listed together and can be started, stopped and restarted. Stop and restart
require confirmation. The confirmation names the container and the action, and
flags hosts whose names match production patterns.

### Agent Center

Monitors [Claude Code](https://www.anthropic.com/claude-code) sessions running
on remote hosts over SSH.

Transcripts stay on the host. The remote collector reads only the bytes
appended since the last poll and emits one line per assistant message; the
client keeps the file offsets and accumulates state locally. The collector is
written in `awk`, so the host needs neither `jq` nor Python. A bounded tail
read populates the session list in about a second and a second pass fills in
usage figures. Steady-state cost is roughly 0.6 s of host CPU per poll.

Reported per session: project, branch, working directory, model, phase, token
usage, cost and burn rate. Sessions waiting for input sort first.

Sessions running under tmux can be replied to. The collector lists tmux panes
and encodes each pane's working directory the way Claude Code encodes a
project directory, making the match an exact string comparison. Reply text and
Return are sent as two separate `send-keys` invocations, because a trailing
newline is treated as pasted input and not as a submission.

### Conterm on macOS

Reads the state file published by the macOS app over the SSH connection that
is already open, rather than over a network service. This needs no listening
port on the Mac and works anywhere the machine is reachable, including through
a jump host.

- **Transport.** One long-lived channel on the pooled connection. A loop on
  the Mac watches the state file's mtime and writes only on change; typical
  latency is around 300 ms. A three-second heartbeat makes the loop exit on
  `SIGPIPE` when the client disconnects.
- **Contents.** Windows, tabs, tab groups, and each pane's working directory,
  SSH target and agent state.
- **Control.** A fixed set of five commands, including focusing a pane and
  replying to a waiting agent. Arbitrary shell is not among them. Commands are
  base64-encoded and delivered through a temporary file and an atomic rename,
  so payload text cannot be interpreted as shell syntax and the Mac never
  reads a partial file. Each command carries a send timestamp and is discarded
  by the Mac if it is more than a minute old.
- **Staleness.** A snapshot that has stopped updating is labelled with its
  age, not presented as current.

### Widgets, Lock Screen and Dynamic Island

Six widget families over one data contract:

| Family | Shows |
|--------|-------|
| inline | whether anything is running |
| circular | how many sessions, and whether any need attention |
| rectangular | the active session and its uptime |
| small | the current session in detail |
| medium | the current session and the rest of the fleet |
| large | the above, plus outstanding signals |

Widgets are driven by `ContermSnapshot.Signal`, a uniform record with a kind,
a title and a weight. Every family with room renders signals in weight order,
so adding one takes an enum case and a line in `WidgetBridge`, with no layout
change. Agents waiting on a connected Mac are published this way.

A Live Activity carries a running session while the app is backgrounded. The
compact Dynamic Island shows status and host; the expanded and Lock Screen
presentations add session state, throughput and a system-drawn elapsed timer.
Updates are throttled to stay inside the Live Activity refresh budget.

See [docs/WIDGETS.md](docs/WIDGETS.md) for the design system and how to extend
it.

### Command palette

A persistent search bar over saved hosts, host overviews, Quick Connect,
ssh_config import and the key library, with an inline calculator supporting
arithmetic, `0x`/`0b`/`0o` literals, base conversion, and unit conversion
across data sizes, time, length, mass, volume and temperature. Results are
ranked by frequency and recency of use.

### Snippets

Saved commands, scoped to a single host or available everywhere, opened from a
key on the accessory row. A snippet is typed into the session and submitted
with a Return keypress rather than pasted, so it behaves identically to manual
input. A snippet can be marked as not self-submitting, which types the command
and leaves it for editing. Eight read-only starters ship with the app.

### iPad

`NavigationSplitView` with the host list in the sidebar and the session in the
detail column. The four navigation destinations are declared once and attached
to whichever column owns navigation for the current size class. The phone and
tablet layouts share one definition. Content is width-limited on large
displays; the terminal is exempt, since width there is columns.

### Settings

Terminal width in columns (font size is derived from this and the screen
width), keep screen awake, sound effects, haptics, typing haptics, launch
animation, and an interface scale that affects the chrome around the terminal
but not the terminal itself.

### Security

- **Host key verification** is performed by the connection rather than by its
  callers, so it cannot be omitted at a call site. Trust on first use presents
  the SHA-256 fingerprint in four-character groups for comparison against
  `ssh-keyscan`. A changed host key is rejected with no override; clearing a
  stored key is an explicit action in the host editor.
- **Background connections** (host probes, Agent Center and the macOS reader)
  never raise the trust prompt. They fail instead. The prompt appears only for
  a connection the user initiated.
- **Private key material** is stored in the Keychain under the key's own
  identifier and is never copied into a host record.

## Requirements

| | |
|---|---|
| Runtime | iOS / iPadOS 18 or later, iPhone and iPad |
| Build | Xcode 26 and its Command Line Tools |
| Signing | An Apple Developer account. The App Group used by the widget extension (`group.dev.conterm.ios`) must be registered on the App ID, which requires Xcode to be signed in. |

There is no App Store build. This is source to compile and run on your own
device.

## Building from source

Both native dependencies are built from source; neither is checked in.

```bash
git clone https://github.com/mahdiarfrm/conterm-ios.git
cd conterm-ios

bash scripts/build-ghostty.sh install   # clone pin, apply patches, zig build
bash scripts/build-libssh2.sh           # OpenSSL + libssh2, device and simulator
open Conterm.xcodeproj
```

`build-ghostty.sh` fetches the pinned Zig toolchain itself, using the constants
in `scripts/ghostty-pin.sh`, and verifies that every slice of the resulting
xcframework exports `_ghostty_surface_write_output`. Without that check, a
build in which the patches failed to apply would only reveal the problem much
later, as a terminal that renders nothing.

Running on a device also requires the iOS platform bundle, which Xcode 26 does
not install by default:

```bash
xcodebuild -downloadPlatform iOS
```

## Testing

The suite runs against a real SSH daemon, not a mock.

```bash
bash scripts/test-host.sh    # throwaway sshd: own host key, client key, config
bash scripts/selftest.sh     # build, install, run the suite
```

`test-host.sh` starts an sshd under `.test-host/`, running as the current user
and writing nothing outside that directory. `selftest.sh` builds, installs and
runs the suite against it, on the simulator or on a connected iPhone; on a
device the key is passed in the environment instead of by path.

Coverage includes host key rejection for unknown and changed keys, connection
phases and latency, multiplexed commands, pty geometry matching the grid,
resizes reaching the remote, a 200 KB flood arriving intact, full-screen
applications drawing and exiting, UTF-8 and wide glyphs, punctuation, scroll
tracking measured in rows moved per screen dragged, and an end-to-end round
trip of the macOS link including adversarial payload text.

Three harnesses open a single screen against the test host, for cases a unit
test cannot assert:

| Environment variable | Opens |
|---|---|
| `CONTERM_DEMO=1` | render check: surface, bytes in, distinct pixels out |
| `CONTERM_OVERVIEW=1` | host overview against a live host |
| `CONTERM_WIDGETS=1` | every widget family at its real size |

## Architecture

iOS does not permit `fork`, `exec` or pty allocation, so a terminal on the
platform cannot own a process and must be fed bytes from outside. Upstream
libghostty has a single termio backend, which spawns a child on a pty, and its
C API provides no way to push bytes into a surface externally.

`patches/ghostty/` adds both: a `termio.External` backend that takes its bytes
from the embedder, and a `ghostty_surface_write_output` entry point to deliver
them.

```
output   SSH bytes → ghostty_surface_write_output() → VT parse → Metal
input    UIKey/UIKeyInput → ghostty_surface_key()/_text()
                          → External.zig queueWrite()
                          → write_callback → libssh2_channel_write
resize   layoutSubviews → ghostty_surface_set_size()
                        → resize_callback → libssh2_channel_request_pty_size
```

libghostty owns VT parsing, scrollback, selection, search, fonts and GPU
rendering. The Swift layer moves bytes and provides the application around it.

### The libxev patch

libghostty wakes its renderer and IO threads with `xev.Async`, which on Darwin
is a mach port watched by `EVFILT_MACHPORT`. The libxev revision Ghostty pins
gates that kevent registration on `os.tag == .macos`, so on iOS the wait is
never armed. `notify()` still reports success, because the port's queue limit
is 1, so every send after the first undelivered one returns `SEND_TIMED_OUT`,
which libxev treats as an indication that the port will wake. The renderer
thread therefore parks in `kevent64` at startup and never rebuilds a cell. The
failure mode is a terminal that draws its background colour and nothing else,
with no error reported anywhere.

Upstream fixed this in libxev `7bf2b2f`. `patches/libxev/` is that commit
applied to the pinned revision, and `build-ghostty.sh` vendors libxev into the
checkout so the fix is not lost to a dependency fetch.

### SSH transport

The transport is libssh2 rather than SwiftNIO SSH. SwiftNIO SSH implements
modern primitives only (Ed25519 and ECDSA keys, AES-GCM, curve25519 key
exchange), so a stock `id_rsa`, an RSA host key, or a server negotiating
`aes256-ctr` fails to connect.

Connections are pooled one per host and held for 90 seconds past their last
use, with shells, commands and watchers multiplexed as channels on them. The
handshake is the expensive part of SSH and the part a mobile radio penalises
most.

## Repository layout

```
Sources/
  App/        entry point, scene, root navigation, signals, widget bridge
  Design/     Theme.swift (tokens, springs), Glass.swift (the lens system)
  Terminal/   libghostty bridge, UIKit surface, key map, session, registry
  SSH/        transport protocol, libssh2, ssh_config, keys, known_hosts
  Hosts/      host model, groups, HostProbe, overview, containers, Nearby
  Agents/     transcript collector, Agent Center
  Remote/     the link to Conterm on macOS
  Palette/    command palette, frecency, calculator
  Snippets/   saved commands
  Feel/       synthesised sound effects and haptics
  Settings/   preferences
Shared/       widget design system and faces, compiled into both targets
Widget/       the WidgetKit extension
patches/ghostty/
  0001  renderer teardown fix (carried from Conterm)
  0002  termio.External backend
  0003  embedded apprt options + ghostty_surface_write_output
  0004  point build.zig.zon at the vendored libxev
patches/libxev/
  0001  arm EVFILT_MACHPORT on every Darwin target, not macOS alone
scripts/      build-ghostty.sh, build-libssh2.sh, ghostty-pin.sh, selftest.sh
```

Design tokens, springs and the glass system are ported from Conterm's
`UI/Theme.swift` and `UI/Effects/LiquidGlass.swift` so the two applications
share an appearance. Colour is reserved for meaning: status (working, needs
attention, ready, danger), one user-chosen accent, and the brand red on
launch. Everything else is monochrome.

## License

MIT. See [LICENSE](LICENSE). Built on
[libghostty](https://github.com/ghostty-org/ghostty) and
[libxev](https://github.com/mitchellh/libxev) (MIT),
[libssh2](https://libssh2.org) (BSD-3-Clause) and
[OpenSSL](https://openssl.org) (Apache-2.0). Full notices are in
[NOTICE.md](NOTICE.md). Not affiliated with the Ghostty project.
