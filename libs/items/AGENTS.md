# libs/items Agent Guidance

Read root `AGENTS.md` first. `libs/items` owns roster-independent item identity
and Bag-relevant item metadata. It is pure Lua with no LÖVE, source ROM, game,
HGSS field, script, mon, or presentation knowledge.

## Boundary

- Production modules under `libs/items/src` may depend only on `libs.items`
  itself and the source-independent foundations `libs.assets`, `libs.codec`,
  `libs.errors`, and `libs.math`.
- They must not import `libs.nds`, `libs.script`, `libs.hgss`, `libs.mons`,
  `libs.ui`, `game`, `app`, `romdump`, or `love`.
- Semantic item keys are primary. Native numeric identities stay only because
  exact native encoding gives them current use.
- The generated item catalog root is validated through the owned asset
  schema; pocket definitions are the schema-owned source contract.

## Contracts

- Schemas are strict with no silent repair. Unknown fields, duplicate native
  identities, missing range members, malformed pockets, and malformed optional
  TM/berry data fail loudly with structured package errors; programming
  invariants use `assert`.
- `ItemCatalog` is immutable after construction and copies its input root.
  Records are immutable by convention.
- Native item IDs cross runtime boundaries only for native/script/codec
  compatibility; every normal runtime lookup resolves through `ItemCatalog`.
- Icon selection names a generated manifest entry; no source member identity
  enters catalog records.

## Design

- No service, inventory framework, plugin API, or cross-game item-use
  abstraction without an explicit product decision. This package owns item
  definitions and identity only.
- One owner per validation rule: record shape in the asset schema, identity
  resolution in the catalog.
- Reuse the asset schema, deterministic serialization, and structured errors
  already in the foundations.
