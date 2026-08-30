# Widgets

Six faces, one design, one data contract.

    inline       is anything running
    circular     how many, and is anything wrong
    rectangular  which one, and how long
    small        the session you are actually in
    medium       that, plus the rest of the fleet
    large        all of it, plus what wants you

## Adding a feature to the widgets

Emit a `ContermSnapshot.Signal` from `WidgetBridge.compose()`. Every face
that has room already knows how to draw one, ranked by `Signal.Kind.weight`,
so nothing in the layouts has to change. Add a case to `Kind` with a weight
and an SF Symbol; that is the whole change.

Signals are a list of small uniform things rather than a set of named fields
for exactly this reason — a widget layout that grows a branch per feature is
a widget layout nobody dares touch by the fifth one.

## Looking at them

    CONTERM_WIDGETS=1   the gallery: every face at its real size
    CONTERM_WIDGETS=2   only the tall ones, which don't fit a screenshot

The faces live in `Shared/` so the app renders exactly what the extension
does. Widget design is otherwise: change a number, build, install, remove
the widget from the home screen, add it back, squint.

## The one thing left: App Groups

The extension cannot read the app's container. Sharing needs an App Group,
and the capability has to exist on the App ID before a profile can carry it —
which `xcodebuild` cannot do. Until then `ContermSnapshotStore` falls back to
the app's own container, so the app writes happily and widgets on the home
screen show their placeholder.

To turn it on, once, in Xcode:

1. Open `Conterm.xcodeproj`.
2. Target **Conterm** → Signing & Capabilities → **+ Capability** → App Groups.
3. Add `group.dev.conterm.ios`.
4. Repeat for the **ContermWidget** target, same group.

`Resources/Conterm.entitlements` and `Resources/ContermWidget.entitlements`
are already written with the right contents; step 2 is what registers the
capability with the developer account, and Xcode will wire them up. Requires
a paid developer account — App Groups are not available to a free personal
team.

The gallery says which state you are in, at the top.
