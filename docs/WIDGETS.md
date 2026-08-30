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

Conterm's, ported from the Mac app's own `Theme.swift` and `LiquidGlass.swift`
rather than invented here — because two apps called Conterm should not look
like two products. Copied by value, since a widget extension cannot import
the app's design layer.

- A near-black bed with one soft wash of the brand red in a corner: the same
  crimson / signature-red / coral family the launch overlay uses, at a
  fraction of the opacity, scaled to the surface so it reads as warmth at
  every size rather than as a maroon tint on a small one.
- Chrome is flat glass — `chromeFill` black at 0.20 with a hairline top-lit
  rim, white 0.30 to 0.06, in `.plusLighter`. The house signature.
- Rounded SF for names, monospaced digits for anything that changes.
- Colour means state: green up, blue connecting, amber wants you, red gone.
  The brand red appears once, as the mark.

Two dead ends got here first, both worth remembering. A rounded card with a
grey stroke and a rainbow hairline — every developer-tool widget ever made,
and against rules this project had already written down. Then a literal
terminal, `~ %` prompt and all: distinctive, but a costume. Conterm's chrome
has never looked like a terminal, and a widget that does belongs to some
other app.

## App Groups

Live. `group.dev.conterm.ios` is on both targets and in the signed
entitlements. Registering it needed Xcode to be logged in to the developer
account — writing the entitlement is not enough on its own, because the
provisioning profile only regenerates when Xcode can reach Apple. If it ever
breaks again, that is the thing to check first.
