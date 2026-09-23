# libs/assets Agent Guidance

Read root `AGENTS.md` first. `libs/assets` owns portemon-defined generated/mod-facing asset
contracts, not the Nintendo/HGSS source formats that produce them.

## Boundary

- Production modules under `libs/assets/src` may depend only on `libs.assets` itself and
  the source-independent foundations `libs.codec`, `libs.errors`, and `libs.math`.
- They must not import `libs.nds`, `libs.script`, `libs.hgss`, `game`, `app`, `romdump`, or `love`.
- A structure belongs here only when a custom asset producer/consumer can understand it
  without knowing NDS/HGSS/decomp details.
- Source NARC/member IDs, offsets, overlay addresses, packed flags, and equivalent provenance
  stay producer-side unless the asset/runtime contract has a concrete semantic use for them.
- Keep paths, schema definitions, validation, and source-independent encoders/decoders with
  the contract they own.

## Domain topology

- `src/audio` owns derived audio data contracts, readiness, and validation.
- `src/model` owns project-defined mesh, model, animation, pose, and render-state contracts.
- `src/field` owns field-specific generated caches, text, UI, weather, effects, and movement
  contracts.
- `src/newgame` owns New Game and Oak startup asset contracts.
- The `src` root retains shared asset, script, protocol, and utility contracts that are not
  exclusive to one domain. Keep these as shallow siblings; do not add technical-layer
  directories, registries, or compatibility modules for moved paths.

## Contracts and compatibility

- Current project-owned schemas are strict. Required fields remain required; unknown modes and
  malformed values fail loudly. Do not add aliases/defaults for old development artifacts or
  incomplete fixtures.
- Generated artifacts have no compatibility guarantee unless the project explicitly declares
  one. Prefer cleaning the contract and rebuilding derived data over permanent shims.
- Change `DerivedAssetContract` when the shared persisted/generated contract changes. Do not
  bump it for compiler implementation changes; `romdump` producer fingerprinting owns those.
- Public/mod-facing fields must have a current semantic consumer. Do not preserve source
  trivia or add optional extension slots "for mods later".
- Keep encoders/decoders and validators authoritative. Runtime/inspectors must not grow a
  second interpretation with slightly different semantics.

## Design

- Prefer small declarative schemas over framework-like asset objects when data is sufficient.
- Keep internal helpers private. A test that wants an internal parser/helper is not itself a
  reason to widen the public surface.
- Use structured `Errors` for malformed generated/external asset data and `assert` for
  programming invariants.
- Tests protect schema semantics, round trips, rejection rules, and intentional architecture
  boundaries rather than source text or implementation shape.
