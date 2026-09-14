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

### Home

The wordmark sits large at the top left, on the ground, with the plus for
a new shell in the bar's glass circle at the right. The shell deck comes
first: a row of cards, one per running shell, with the host, what the
shell is doing and how long it has been up, ticking. A tap resumes the
shell; a hold offers another shell, the overview, the files, Continue on
Mac and Disconnect. After the shells come a card for each paired Mac with
what it was doing the last time the phone looked, a Boot card for Debian
when it is off, and New. When nothing runs, the hosts you were on last
stand in as cards, each one tap from a shell. Under the deck the home is
a column of panels, and the system's tab bar at the foot carries the
general things: Home, Machines and Settings, with the palette apart from
them in its own circle at the trailing end. The search circle opens the
palette as a tab, its bar focused, and closing it goes back to the tab
that was showing. Keys and snippets are reached from chips at the top of
the Machines card and from a Library band in Settings.

| Panel | Contents |
|-------|----------|
| Activity | traffic through every open shell now and at its peak, with meters, and the line over the last two minutes |
| Heartbeat | every host whose sampler is beating, one lane each: its name, its CPU now, the spread of its cores |
| World | a field of dots for the world with the night side dimmed by where the sun is, and every placed host on it with its local time |
| Fleet | hosts and live shells with meters, hosts per group as bars, group and key counts |
| Wants you | agents waiting on a connected Mac, hosts that stopped answering, lost shells; honey while there is anything; a row from a Mac opens that Mac's panes |
| Uptime | the longest-running host as a readout, then every checked host as a ranked bar |
| Recent | the hosts you were on last, as bubbles; tap to open a shell, hold for the overview, agents, the Mac link or the editor |
| Nearby | Macs on this network running Conterm |

Every panel is drawn from what the app already knows. The world and the
podium read the last probe of each host; the heartbeat reads the samplers
that keep beating for five minutes after an overview is left. A host takes
its place on the map from the zone its probe reports, or from its offset
when the zone is not one the atlas knows, drawn with a dashed ring.

Panels can be switched off and reordered from *Edit panels*; the choice is
kept in preferences. Activity, Heartbeat, World and Fleet open into a
detail: the number the panel was about, enormous, with its unit small
beside it, the facts around it, and a cream card with the chart drawn large
and the rows the panel had no room for. The Machines tab is everything a
shell can be opened on, on a cream card: this phone's Debian first, then
Macs found on the network, then the saved hosts in their groups. Each host
row opens a shell on tap and carries *Overview* and a files button beside
it; a Mac's row carries *Panes* and the overview. The Settings tab is the
settings on the same card.

Inside a terminal the title is a button. It drops the same deck over the
terminal: every other running shell, one tap from taking the screen, and
New for another shell on the same host. The palette knows the same
places: a host's files, a Mac's panes and Debian each have a row.

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
  while the host list is on screen. Bonjour does not leave the subnet, and
  the record carries only what the Mac's Remote Login already shows: its
  name, the username, whether sshd is on. Seeing a Mac is not being able to
  sign in to it; that still takes the account's password or a key.
- **Pairing.** A Mac whose Conterm offers it shows *Pair* instead of *Add*.
  The phone makes an Ed25519 key, sends the public half to the Mac over the
  local network, and shows a six-digit code; the Mac shows the same code,
  computed from the key it received, and a person clicks Allow there. The
  key goes into the Mac's `authorized_keys`, the private half into this
  phone's Keychain, and the Mac becomes a saved host that signs in with it,
  here or from anywhere the Mac is reachable. The reply carries the Mac's
  host key fingerprints, so the first connection trusts the Mac's real key
  and would still ask about any other. No password is typed anywhere. An
  older Conterm without pairing still gets *Add*, which opens the editor.
- **Quick Connect** for one-off `user@host` connections that are not saved.

### Host overview

A briefing on one host: the mark of what it runs, monochrome and plain,
with the health gem on its corner and the name beside it and what it runs beneath, the
health in a word, anything that needs saying as chips, on a Mac the way
into Conterm running there, then a column of panels. The marks are Simple
Icons, CC0, bundled as template images; a host's distribution is learned
from its first probe and kept on the record, so its mark is on the row from
then on. The
one-shot probe collects what the machine is in a single SSH round trip. A
second, lighter script reads the counters every three seconds and the
difference from the last read is the rate. One model per host lives for the
app's lifetime, and the sampler keeps going for five minutes after the
screen is left, so coming back finds four minutes of history and the
connection still warm; then it stops on its own.

| Panel | Contents |
|-------|----------|
| Vitals | CPU and memory, and a chart of the least and most busy core over the last four minutes, newest at the right |
| Load | the one and fifteen minute averages with meters and a word for the direction, the three averages as capsules with a full bar equal to the core count |
| System | disk, memory and CPU as concentric rings with a legend, then the facts that are numbers but not shares: uptime, logged in, failed units, listening, cron, running containers |
| Disks | every mount as a ramp of capsules filling toward its edge |
| Network | traffic in and out from the sampler, then addresses and listening ports |
| Containers | one bubble per container, lit while running; tap for start, stop and restart |
| Workloads | VMs, Kubernetes |
| Health | failed systemd units, cron, logins, pending reboot, updates |
| Busiest | the hungriest process by CPU and by memory as readouts, then every one as a ranked bar the length of its share |
| Recent errors | journal and kernel messages |

Vitals and Network open into details of their own, with the number
enormous, the memory as a ramp, the chart drawn large and the sampler's
window summed up. A cached result renders immediately while a fresh probe
runs, and the screen reports the age of the data it is showing. Pull to
refresh; *Open a shell* connects to the host from the overview.

Containers across Docker, Podman, containerd and Apple's `container` are
listed together and can be started, stopped and restarted. Stop and restart
require confirmation. The confirmation names the container and the action, and
flags hosts whose names match production patterns.

### Files

A host's files, from the overview, from a long press on a host, and from
folder to folder. Every operation is one command on the connection the
app already has, so it works on any machine a shell works on, through the
same jump host, with the same key: a listing is `ls -l` in the C locale,
a download is `head -c` into the channel, an upload is `cat` with the
bytes on the channel's stdin. No SFTP subsystem is needed.

- **Browse.** Folders first, then by name, newest or largest; dotfiles
  hidden until asked for. The header says how many folders and files and
  how much they weigh. Pull to refresh.
- **Preview and edit.** Text up to 512 KB opens in an editor and saves
  back with one tap; images are drawn; anything else is described. A file
  bigger than that is shared whole rather than shown.
- **Move files.** Upload from the Files app, several at once, up to 32 MB
  each. Share any file out to Files, AirDrop or another app.
- **Tidy.** New folder, new file, rename, delete (with a confirmation that
  names the host), copy the path.

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

### Conterm on a Mac

The Mac you left, from the phone. Every paired Mac has a card on the home
and a *Panes* pill on its row in Machines; both open the same screen. The
head says how many groups, tabs, panes and agents the Mac has and how
many agents are waiting; under it, every window, its tabs under their
group headings in the Mac's colours, and every pane with *Continue* on
it, which opens that pane's screen and a keyboard into it. A Mac on the
network that is not paired yet shows *Pair* under Nearby in Machines.

### Linux on the phone

A Debian machine of the phone's own, under *This iPhone* in Machines and
as a card on the home while it is off. *Boot* starts it; its console is a
session like any other, on the deck with the rest, resumed with a tap,
kept running while you are elsewhere in the app, and ended with *Power
off* in its menu.

The machine is a RISC-V computer emulated in WebAssembly inside a hidden
web view, which is where iOS lets code be compiled as it runs. It boots a
Linux 6.1 kernel and the `debian:trixie-slim` root filesystem that
[container2wasm](https://github.com/container2wasm/container2wasm) packs
into the image, with the memory set at build time (512 MB). The
emulator's console is wired straight into the terminal, and the terminal's
size reaches the guest as a console resize, so full-screen programs lay out
for the phone and follow the keyboard.

| | |
|---|---|
| Speed | Interpreted; a boot takes a few seconds, a prompt answers in a beat, a compile is a coffee |
| Disk | In memory, from the image; nothing installed at runtime survives a power off |
| Network | HTTP and HTTPS, through the app: `apt`, `curl`, `pip`, `git` over https. ssh and other ports need the experimental direct mode (Settings). ping does not work |
| Memory | The web view's process holds the machine; if iOS reclaims it, the row says so and *Boot* starts over |

By default the network is container2wasm's `c2w-net-proxy` (built on
gvisor) in a second worker: the guest gets an address by DHCP and an HTTP
proxy at 192.168.127.253, which the well-known `http_proxy` and
`https_proxy` variables point at, with `SSL_CERT_FILE` and its cousins
pointing at the proxy's certificate. Each request the stack makes goes to
the app's loopback server, which makes it for real with the phone's
network and streams the answer back, so the web view's cross-origin rules
never apply to the guest. This carries HTTP and HTTPS only.

Direct networking (Settings, experimental) instead runs the full
gvisor-tap-vsock stack natively in the app (`Vendor/NetStack.xcframework`,
built from `netstack/` by `scripts/build-netstack.sh`), reached over a
loopback WebSocket. It forwards the guest's TCP to real sockets on any
port, ssh included, with end-to-end TLS. Connecting works; sustained
HTTPS and apt are not yet reliable, because every packet crosses a
round trip between the emulator and the stack, so it is off by default.

The image is built, not checked in: `scripts/linux-image.sh` builds a
Debian image with a working toolset (`scripts/linux/guest.Dockerfile`:
bash, git, python3, curl, wget, vim, nano, less, tree, jq, `ip`, `ps`, the
archive tools and more), converts it with container2wasm into
`Resources/linux/debian.wasm`, and builds the network stack beside it. The
toolset image is about 240 MB; trim the Dockerfile's package list for a
smaller app, or pass an image name to convert something else. A build
without those files shows the row with the reason, or boots without a
network.

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
- **Panes on the phone.** Tap a pane, or Continue, and it opens here. Two
  ways to see it. As a picture, the Mac captures the pane's pixels from
  its window twice a second, so colours, bold and the layout come through
  as they are and the whole width fits the phone; pinch to zoom. As text,
  the Mac reads the screen's characters, which wrap to the phone, take a
  font size, and can be selected and copied. Both stream over the same
  channel the state does while the phone renews its attach. A row of keys
  (Esc, Tab, ^C, ^D, ^L, the arrows, Delete, Return) and a line to type
  into go back as real key events, so a TUI such as Claude Code sees a
  real Return and a real Escape. Any pane works the same: a local shell,
  an `ssh` to a server, an agent. A pane whose agent is waiting says so
  above the keys. The mirror lapses on the Mac three minutes after the
  phone stops renewing it. The picture needs Screen Recording for Conterm
  on the Mac; without it the phone keeps the text.
- **Control.** A fixed set of commands, including focusing a pane, replying
  to a waiting agent, attaching to a pane, typing into it and sending it a
  named key. Arbitrary shell is not among them. Commands are
  base64-encoded and delivered through a temporary file and an atomic rename,
  so payload text cannot be interpreted as shell syntax and the Mac never
  reads a partial file. Each command carries a send timestamp and is discarded
  by the Mac if it is more than a minute old.
- **Staleness.** A snapshot that has stopped updating is labelled with its
  age, not presented as current.
- **Handoff.** A Mac pane that is an `ssh` somewhere shows a phone button
  and *Open here*: the same host opens on the phone, matched among the
  saved hosts by hostname or alias and then by user. The other way,
  *Continue on Mac* on an overview, a host's long press or a session's
  menu asks the Mac for a new tab, waits for it to publish, and types the
  `ssh` line for the host into the pane that appeared, with the port and
  jump host the record carries. The Mac connects with its own keys. With
  several Macs saved, it asks which; the Macs are the hosts whose probe
  said macOS.

### Widgets, Lock Screen and Dynamic Island

Six widget families over one data contract, drawn the way the app is: on
the flat ground chosen in Settings, in translucent tiles with a lit rim, the
number first and large, in the same typeface.

| Family | Shows |
|--------|-------|
| inline | whether anything is running |
| circular | how many sessions, and whether any need attention |
| rectangular | the active session and its uptime |
| small | the current session and its clock, or the host count when nothing runs |
| medium | the live count large, the sessions beside it as tiles |
| large | live, hosts and signals as readouts, the sessions with their traffic, what wants you |

Widgets are driven by `ContermSnapshot.Signal`, a uniform record with a kind,
a title and a weight. Every family with room renders signals in weight order,
so adding one takes an enum case and a line in `WidgetBridge`, with no layout
change. Agents waiting on a connected Mac are published this way. The
snapshot carries the ground's id, so a widget follows a colour change at its
next refresh.

A Live Activity carries a running session while the app is backgrounded. The
compact Dynamic Island shows a lit prompt mark and the elapsed time; the
expanded island has the host and phase, the clock, bytes in and out, the
traffic between the last updates as small bars, and the shell's title. The
Lock Screen banner is the same panel on the ground. The ring around the
island is the ground's own light while the shell is up and a status colour
only when it is not. Updates are throttled to stay inside the Live Activity
refresh budget.

See [docs/WIDGETS.md](docs/WIDGETS.md) for the design system and how to extend
it.

### Command palette

The search bar at the top of the home screen, over saved hosts, host
overviews, Quick Connect, ssh_config import, the key library and settings,
with an inline calculator supporting
arithmetic, `0x`/`0b`/`0o` literals, base conversion, and unit conversion
across data sizes, time, length, mass, volume and temperature. Results are
ranked by frequency and recency of use. The bar and the results are two
detached bubbles, as on the Mac; the results snap open under the bar when
it is touched and morph away when a result is picked or the bar is
dismissed.

### Snippets

Saved commands, scoped to a single host or available everywhere, opened from a
key on the accessory row. A snippet is typed into the session and submitted
with a Return keypress rather than pasted, so it behaves identically to manual
input. A snippet can be marked as not self-submitting, which types the command
and leaves it for editing. Eight read-only starters ship with the app.

### iPad

`NavigationSplitView` with the home in the sidebar and the session in the
detail column. The four navigation destinations are declared once and attached
to whichever column owns navigation for the current size class. The phone and
tablet layouts share one definition. Content is width-limited on large
displays; the terminal is exempt, since width there is columns.

### Settings

The ground colour and whether it smokes, glass panels (every panel as
monochrome glass, whatever colour it would wear), terminal width in
columns (font size is derived from this and the screen width), keep screen
awake, sound effects, haptics, typing haptics, launch animation, and an
interface scale that affects the chrome around the terminal but not the
terminal itself.

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

The Linux machine's image is optional and built separately. It needs Docker
(OrbStack or Docker Desktop, with buildx) and Go; the first run compiles a
RISC-V kernel and the emulator inside Docker and takes a long while, later
runs only repack the image:

```bash
bash scripts/linux-image.sh                 # debian:trixie-slim, 512 MB
LINUX_IMAGE_MEMORY_MB=384 bash scripts/linux-image.sh
```

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

Four harnesses open a single screen, for cases a unit test cannot assert:

| Environment variable | Opens |
|---|---|
| `CONTERM_DEMO=1` | render check: surface, bytes in, distinct pixels out |
| `CONTERM_OVERVIEW=1` | host overview against a live host |
| `CONTERM_WIDGETS=1` | every widget family at its real size |
| `CONTERM_DESIGN=1` | the design primitives, cycling on their own |
| `CONTERM_DESIGN=settings`, `=editor` | the gallery with that sheet already open |
| `CONTERM_SEED_HOSTS=1` | three saved hosts, if the list is empty |
| `CONTERM_TAB=hosts` | start on that tab |
| `CONTERM_PAIR=1` | pair with the first Mac on the network that offers it, then open it |
| `CONTERM_TOUR=1` | the home, the overview, a shell, a scroll, a panel's detail, a folder of files and one file, the tabs, a search and a change of ground, by itself |

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
  Design/     Theme.swift (tokens, springs), Palettes.swift (the grounds),
              Surfaces.swift (ground and sheet),
              Glass.swift (the lens system), Morph.swift (the change transition),
              Panels.swift (the cards), Charts.swift (capsule bars, pulse, line, ring),
              Readout.swift, SegmentedPill.swift, DesignGallery.swift
  Home/       the home screen, its router, the feature capsule, the panels
  Terminal/   libghostty bridge, UIKit surface, key map, session, registry
  SSH/        transport protocol, libssh2, ssh_config, keys, known_hosts
  Hosts/      host model, groups, HostProbe, HostPulse, overview, containers, Nearby
  Files/      RemoteFiles.swift (entries, the transport over exec, a fake),
              FileBrowserView.swift (a folder), FilePreviewView.swift (a file)
  Agents/     transcript collector, Agent Center
  Remote/     the link to Conterm on macOS
  Linux/      the Debian machine: LinuxMachine.swift (the web view and its
              console), LoopbackServer.swift (the page's origin and the
              HTTP fetch relay), LinuxNetStack.swift (the direct stack)
  Palette/    command palette, frecency, calculator
  Snippets/   saved commands
  Feel/       synthesised sound effects and haptics
  Settings/   preferences
Shared/       the grounds, widget design system, faces and the Live Activity
              faces, compiled into both targets
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

The app has two surfaces. The ground is chosen in Settings: Smoke by
default, near-black with grey wisps drifting and turning over it, or one flat
bright saturated colour, with wisps of its own family over it if that is
switched on. The launch screen and every screen after it sit on it. Things you read closely, the host list, a form, the
settings, sit on a cream sheet in warm ink. Chrome on the ground is
translucent white with a lit rim; chrome on the sheet is white. Status
colours have a deep cut for the sheet and a light cut for the ground, so a
gem means the same thing on both. The terminal is a black tile on the
ground and takes none of this.

| Surface | Where | Type | Action colour |
|---|---|---|---|
| Ground | home panels, overview, agents, remote, palette | white | cream |
| Cream sheet | hosts and settings tabs, editor, quick connect, keys, snippets | ink | the ground's deep cut |
| Terminal | the session | the terminal's own | cyan |

| Ground | Default |
|---|---|
| Smoke | yes |
| Crimson, Ember, Indigo, Ocean, Forest, Violet, Midnight, Graphite | |

Changing the ground recolours the ground, the launch wash, the action
colour on the sheet, and the terminal's chrome. The cream, the ink and the
status colours do not change.

Information sits in panels: a rounded card with a small uppercase label and
a glyph in one corner, the number large, the picture beneath it. The home
and the overview are columns of them. Numbers come first and large, with a
glyph and a word beneath them.

| Bed | Type | Used for |
|-----|------|----------|
| Glass | white | translucent on the ground with a lit rim: the panels that hold bubbles |
| Ink | white | a neutral near-black, behind a chart: vitals, errors |
| Cream | ink | the fleet, load, the busiest processes, a folder's files, a file |
| Grass | white | something alive: open shells, heartbeat, healthy, workloads |
| Amber | white | something to notice: what wants you, health with a failed unit, uptime, a folder that would not open |
| Azure | white | activity, the disks, the recent hosts |
| Teal | white | world, the network, the machines nearby |
| Violet | white | the containers, nothing wanting you |

With *Glass panels* on in Settings every bed is drawn as glass.

A bed can change: a deck card is grass while its shell runs, the Health
panel turns amber when something needs attention, and the colour morphs
in front of you. The beds are the same on every ground; changing
the ground changes the ground and the widgets, never a panel. On cream,
glyphs, numbers and controls are ink: colour is for beds and for status,
never for a glyph. A panel opened into its detail keeps its bed under the
whole screen.

| Chart | Shape | Used for |
|-------|-------|----------|
| Capsule bars | thin capsules close together, the one that matters solid, labels under them or in a legend | load averages, hosts per group |
| Pulse | a line per sample from its low to its high on a gridded field, the newest lit | the least and most busy core |
| Line | a smooth line with a soft fill and a dot on the newest point | traffic |
| Ring | an arc | a share |
| Ring stack | concentric rings, one share each, a legend beside | disk, memory and CPU on the overview |
| Capsule ramp | a row of capsules growing from dots to pills, lit up to the value | memory, a disk |
| Rank bars | horizontal capsules the length of each share, the first solid, the name on the bar | the busiest processes |

Panels arrive one after another, each focusing in from a blur, and so do
the cards on the Hosts and Settings tabs, their titles rising first, every
time the tab is shown. In a scrolling column a panel fades and shrinks a
little as it leaves the screen and comes back as it enters, driven by the
scroll itself, so scrolling back plays the arrivals again; a panel taller
than the screen counts as arrived once a slice of it is in view. Inside
a panel, bars grow to their heights, the pulse chart draws its lines in one
by one and grows each new one at the end, a line draws itself from the
left, bubbles pop in across a cloud, a ring draws itself round, and a ramp
lights its capsules one after another. Nothing glows except the activity
line; a gem is a dot. A pushed screen
grows out of the row, bubble or panel that was tapped and shrinks back into
it. Every number that changes goes out of focus and the new one focuses in;
nothing rolls.

Text is set in Manrope, bundled as a variable font under the SIL Open Font
License; the terminal keeps its monospace and the wordmark its own face.
Changing the ground recolours every screen at once, including the panels
and the search bar, while the settings are still open.

Motion follows one rule: a value that changes while it is on screen goes out
of focus and the new one focuses into its place. That covers a number after
a refresh, a connection phase in the status strip, and a loading row
becoming the loaded content. Counts roll their digits. A segmented control
moves one thumb between options. Controls sink under the finger and spring
back on release. Reduce Motion keeps the crossfades and drops the blur.

## License

MIT. See [LICENSE](LICENSE). Built on
[libghostty](https://github.com/ghostty-org/ghostty) and
[libxev](https://github.com/mitchellh/libxev) (MIT),
[libssh2](https://libssh2.org) (BSD-3-Clause) and
[OpenSSL](https://openssl.org) (Apache-2.0). Full notices are in
[NOTICE.md](NOTICE.md). Not affiliated with the Ghostty project.
