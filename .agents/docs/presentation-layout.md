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
  placement helpers (fullscreen, cover-or-frame resolution, single/paired
  composition, static framed and centered boxes). It owns
  no gameplay, resources, or drawing.
- `ApplicationPresentation` owns one open interface's published plan,
  pointer capture, and ordered cancellation. One plan supplies both
  input mapping and drawing; geometry changes, focus loss, and close
  cancel held presses before any stale release. Plans are static:
  no position is remembered between opens, resolves, or instances.

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
- Wide/tall single surface: a static centered framed box. The complete
  outer frame (content plus the 0/16/0/8 exterior around the overlapped
  body) fits at the largest integer scale inside the usable bounds; a box
  that cannot fit at unit scale falls back to the native-like case.
  Geometry is deterministic: an equivalent re-resolution returns the
  identical placement.
- Same-display pairs are contiguous: side-by-side or stacked panes share
  one integer scale with no synthetic gap, and one fitted outer frame
  surrounds their common envelope as part of scale selection.
- Integer fitting is the norm: the largest permitted integer fit with
  at most one safe bump. Cropping is budgeted per edge in logical
  pixels (default 4, independently overridable, zero where controls
  reach an edge); edge-critical content uses protected rectangles that
  a bump must keep visible. Crops land on whole source pixels.
- Cover or frame: the crop budget spends only on a genuine fullscreen
  cover, and a covering fit publishes no frame. Any visible decorated
  fit uses zero content overdraw and reserves the complete exterior
  chrome instead: no plan is both cropped-for-cover and framed. When
  no complete decorated unit-scale box fits, the constrained
  native-like fallback applies rather than a clipped frame.
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
| Single wide display | Static centered framed box | Content keeps its logical geometry; the frame never moves. |
| Single tall display | Static centered framed box, stacked pairs | Same frame rules; pairs stack vertically with no gap. |
| Constrained single display | Native-like fallback | Compact interfaces keep essential controls; reduce or crop only nonessential content. |

A feature with no meaningful auxiliary content need not invent a second panel.
Transient decorative content may overlap only when it cannot obscure active
controls or essential state. Both source roles must not be blindly composited at
the same coordinates.

## Application frames, background, and dismissal

Underfilled field applications are decorated with the player's selected
HGSS dialogue frame (`playerData.options.textFrame`), rotated so the
source frame's thick right edge becomes the top edge and drawn from the
masked application atlas. The innermost 8-logical-pixel frame band
overlaps application content on every edge, so only the 0/16/0/8
remainder (left/top/right/bottom) reserves room outside the application:
opaque decoration may cover edge body pixels while cleared padding
reveals the body underneath. The frame is pure plan geometry until
field or Starter presentation draws it after application content
through the shared frame renderer; application code never invents
border styling.

Plans publish their decorative geometry alongside content, input, and render callbacks:

- `frames`: the decorative outer geometry drawn around content, carrying
  no embedded controls or window identity.

Settled pixels outside application panes and frames stay whatever the
host already rendered, which is the paused field wherever field
presentation exists. Field child applications layer directly over the
retained Start Menu and the paused world with no transition overlay:
launching a child keeps the already-open menu alive and drawable
beneath it (the menu re-resolves its plan against fresh display facts
but takes no semantic input while covered), and closing a child
atomically composes a fresh menu from current policy with the
remembered selection, so capability changes are reflected with no
blank interval. Applications never paint a matte over the field to
"own" the background; the startup Main Menu is the exception that
proves the rule, painting its own backdrop because no field exists
beneath it.

A decorative frame is part of the application: presses on the border or
on non-interactive panes are consumed as interior and do nothing. Framed
application borders contain no embedded controls. A pointer-down fully
outside every pane and frame is the sole pointer dismissal affordance
for the closable field applications (Start Menu, Bag, Party, Trainer
Card): it dismisses at once. This dismissal is terminal and bypasses
nested cancel/unwind behavior; it is not ordinary Cancel and it never
clicks through to the paused field.

Three surfaces never gain an outer frame or outside dismissal:

- Oak Naming stays canonical 256x192, centered and scaled but
  undecorated, and outside presses neither insert glyphs nor leave
  name editing.
- The startup Main Menu is a responsive fullscreen surface with its
  own backdrop and no HGSS frame.
- Starter Choice draws an outer frame when underfilled but stays
  blocking: outside presses never dismiss it.

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
