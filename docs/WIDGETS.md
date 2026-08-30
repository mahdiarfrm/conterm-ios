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

## The look

It is a terminal, not a card about one. Monospaced throughout, a prompt on
the first line, and status as a *character* in the text flow — `●` up, `◌`
connecting, `○` closed, `✕` failed — rather than a dot placed beside it.
No border, no gradient, no colour except on those glyphs.

The first attempt was a rounded card with a grey stroke, a rainbow hairline
and rounded-sans type. That is every developer-tool widget ever made, and it
broke rules this project had already written down: `GLASS-REDESIGN.md` lists
coloured ambient backdrops under **dead ends**, and `NodeCard.swift` rejected
a bright ring because it "read as neon paint".

Small does not try to be a small Medium. A name-and-time column truncates to
`sibche-p…` at 170pt, so the fleet is a row of glyphs — `●●◌●` — which says
how many and what shape they are in, and cannot truncate.

## App Groups

Live. `group.dev.conterm.ios` is on both targets and in the signed
entitlements. Registering it needed Xcode to be logged in to the developer
account — writing the entitlement is not enough on its own, because the
provisioning profile only regenerates when Xcode can reach Apple. If it ever
breaks again, that is the thing to check first.
