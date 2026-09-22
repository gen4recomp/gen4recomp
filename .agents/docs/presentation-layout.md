# Dual-screen presentation layout policy

This policy describes how interfaces derived from Nintendo DS software adapt
source main and auxiliary screen roles to host displays. It defines
presentation intent, not a universal widget or layout API.

## Source semantics and host placement

The main surface is the source upper-screen role: world or primary visual
context, characters, and essential information. The auxiliary surface is the
source lower-screen role: supporting information and interaction controls,
including touch-oriented controls when a feature has them.

The roles remain meaningful when their physical placement changes. Rendering
and pointer handling must use the same host placement result. The original
screen coordinate space is semantic reference information for art and
behavior, not a requirement to render a hidden fixed-size canvas on every host.

For field presentation, preserve a stable source reference frame and safe area
for essential world context. Host scaling may reveal, crop, or reposition
nonessential presentation, but it must not make simulation coordinates depend
on window size or hide required controls.

## Shared presentation owners

Three product-local owners in `game/hgss/src/ui` carry the common
policy; leaf interfaces supply only their own geometry and callbacks.

- `DisplayContext` measures the actual drawable: host dimensions,
  topology surfaces with safe areas and reservations, and the uniform
  framebuffer-pixels-per-host-unit ratio. It never invents surfaces.
- `ApplicationLayout` classifies one of four configurations
  (`dualDisplay`, `nativeLike`, `wide`, `tall`) and offers shared
  placement helpers (fullscreen, single/paired composition, draggable
  windows). It owns no gameplay, resources, or drawing.
- `ApplicationPresentation` owns one open interface's published plan,
  pointer capture, window drag positions, and ordered cancellation. One
  plan supplies both input mapping and drawing; geometry changes, focus
  loss, and close cancel held presses before any stale release.

A leaf `InterfaceSet` provides four resolver functions, one per
configuration. Each resolver returns a complete matched interface:
logical panes with placements, an input key, a render callback, and an
input-mapping callback. A case may return a wholly different interface
(a compact selector, a lower-only composition) without replacing game
state. Product roots may override individual cases per application; an
override replaces the whole pair and never leaks across cases,
applications, or game instances.

## Configuration defaults and numeric policy

- Physical dual: the interface takes the auxiliary surface fullscreen;
  two-pane interfaces map their panes to the world/auxiliary pair.
- Near-native single surface: fullscreen. Entry into native-like
  requires aspect error at most 12 logical pixels per edge; a session
  retains it through 14 and leaves above 14.
- Wide/tall single surface: a draggable window with title strip and
  border; a window that cannot fit at unit scale falls back to the
  native-like case. Window positions are session-only and never saved.
- Integer fitting is the norm: the largest permitted integer fit with
  at most one safe bump. Cropping is budgeted per edge in logical
  pixels (default 4, independently overridable, zero where controls
  reach an edge); edge-critical content uses protected rectangles that
  a bump must keep visible. Crops land on whole source pixels.
- Below unit scale, the fitter may still retain physical 1x by cropping
  whole source pixels within the configured overdraw/protection budgets;
  when no safe 1x crop exists, the complete logical viewport draws with
  fractional downscale and zero crop so every control stays reachable.
- Host units and framebuffer pixels convert once at the drawable
  boundary; inner layout, text, and hit testing stay in logical
  pixels under one root transform.

## Host presentation strategies

| Host arrangement | Default placement | Notes |
| --- | --- | --- |
| Physical dual-screen | Auxiliary fullscreen; pairs split world/auxiliary | Preserve source separation and relative intent. |
| Single near-native display | Fullscreen | Keep the canonical logical surface; crop only within budget. |
| Single wide display | Draggable window | Shared chrome; content keeps its logical geometry. |
| Single tall display | Draggable window, stacked pairs | Same window rules; pairs stack vertically. |
| Constrained single display | Native-like fallback | Compact interfaces keep essential controls; reduce or crop only nonessential content. |

A feature with no meaningful auxiliary content need not invent a second panel.
Transient decorative content may overlap only when it cannot obscure active
controls or essential state. Both source roles must not be blindly composited at
the same coordinates.

## Feature-local layout responsibility

Each feature resolves its four cases from measured display facts and
publishes one plan that drawing and input share. Drawing and hit-testing
consume the same resulting regions. Exceptions to the defaults are
justified by interaction or readability needs, not accidental
implementation constraints. Custom compact interfaces are full
replacements selected per case; they keep source identities, service
semantics, and publication ordering while changing only presentation.

`ScreenTopology` describes host capabilities and surfaces, including semantic
roles, rectangles, safe rectangles, and touch capability. It is an input to
feature layout decisions, not a policy engine or universal layout selector.
