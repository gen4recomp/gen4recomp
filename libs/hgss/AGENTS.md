# libs/hgss Agent Guidance

Read root `AGENTS.md` first. `libs/hgss` owns recreated HeartGold/SoulSilver runtime
mechanisms and presents HGSS-facing seams to the application layer.

## Domain organization

Keep reviewer-facing mechanisms in these shallow domain subpackages:

- `field` — deterministic session/application coordination, input, camera, field
  applications, shared errors/IDs, and services that coordinate sibling domains.
- `actors` — field actor/player identity, movement, autonomy, and actor definitions.
- `world` — maps, cells, residency, collision, terrain, zones, weather, and world facts.
- `interaction` — event, message, signpost, choice, and interaction resolution.
- `transition` — warps, doors, fades, entrances, and field transition semantics.
- `script` — HGSS value/reference semantics and field-shaped script adapters.
- `audio` — HGSS audio policy composed over the NDS sound mechanisms.
- `presentation` — field scene, camera, queue, and presentation composition.
- `ui` — reusable HGSS runtime UI mechanisms; game-independent button primitives belong in `libs/ui`.
- `save` — HGSS save semantics.
- `items` — HGSS Bag inventory mechanics, field cursor, and the live Bag service.
- `mons` — the HGSS-facing live mon/party service over the domain package; follower
  field coordination stays in `field`.

These are semantic siblings inside `libs/hgss` because the mechanisms are HGSS-specific;
do not create a generic `libs/field` package. Cross-domain coordination belongs in
`field`, not in a new catch-all or technical-layer directory. Presentation renderers
remain in `presentation` even when they draw actors or field effects.

HGSS may consume `libs/nds`, `libs/script`, `libs/assets`, and foundation libraries when
those mechanisms are part of a concrete runtime responsibility. It must not import
`romdump` or own application policy.

## Application boundary

Launcher state, LÖVE process composition, version selection, ROM provisioning, and process
exit policy belong to `app`.
Story flow, Main Menu, new-game sequencing, Professor Oak intro policy, field application
composition, save compatibility, and application audio belong to the concrete `game/hgss`
package. Do not move those policies into this library merely because
they invoke a reusable HGSS mechanism.
The generic running-game lifecycle and host adapters belong to `game`; `FieldSession` is a
field-simulation mechanism, not a game entry point.
