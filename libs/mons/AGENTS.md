# libs/mons Agent Guidance

Read root `AGENTS.md` first. `libs/mons` owns roster-independent mon and party
mechanics plus exact Generation-IV representation. It is pure Lua with no
LÖVE, source ROM, game, HGSS field, script, or presentation knowledge.

## Boundary

- Production modules under `libs/mons/src` may depend only on `libs.mons`
  itself and the source-independent foundations `libs.assets`, `libs.codec`,
  `libs.errors`, and `libs.math`.
- They must not import `libs.nds`, `libs.script`, `libs.hgss`, `libs.ui`,
  `game`, `app`, `romdump`, or `love`.
- Generation-specific algorithms and formats live under `src/gen4`; the
  top-level modules own the semantic record, catalog, party, and save bucket.
- Semantic keys are primary. Native numeric identities stay only because
  exact native encoding gives them current use.

## Contracts

- The semantic record is authoritative; the boxed codec is a projection.
  Only independent source-of-truth values persist: level, nature, gender,
  shininess, and maximum stats derive from experience, personality, trainer
  identity, and catalog data, and are never stored.
- Schemas are strict with no silent repair. Unknown fields, duplicate native
  identities, unencodable text, and inconsistent derivations fail loudly with
  structured package errors; programming invariants use `assert`.
- `MonCatalog` is immutable after construction and copies its input root.
- `Party` owns dense zero-based slots, copies, and revision; callers never
  mutate the internal array.
- Creation goes through named policies only; there is no free-form
  constructor for mutually coupled values.
- The boxed codec proves compatibility with fixed byte vectors, never with
  round trips alone. Cipher state is local to the codec.

## Design

- No facade, registry, callbacks, hooks, extension points, mutable catalog,
  or mod-facing API without an explicit product decision.
- One owner per validation rule: record shape in `Mon`, representability in
  `NativeLegality`, bytes in `BoxCodec`.
- Reuse the asset schema, binary/text/charmap owners, structured errors, and
  deterministic serialization already in the foundations.
