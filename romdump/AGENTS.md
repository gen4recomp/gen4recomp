# romdump Agent Guidance

Read root `AGENTS.md` first. This file owns rules specific to ROM ingestion, source research,
and compilation into g4recomp assets.

## Source ownership

- `romdump` owns HGSS/decomp-derived source structures and policy: source catalogs, member
  selection, physical identities, packed game fields, and compilation semantics. Reusable
  Nintendo container and Nitro/NNS format mechanics belong in `libs/nds`.
- Keep source-member selection, physical archive/file/member IDs, overlay addresses, packed
  source flags, and ROM-specific catalogs producer-side unless a generated asset has a
  concrete runtime/mod-facing semantic need for the fact.
- `src/build` owns explicit per-version cache build stages; `CacheBuilder` retains batch
  lifecycle, staged-world publication, and successful-build attestation ownership.
- `libs/codec` supplies generic binary primitives and `libs/nds` supplies reusable Nintendo
  format mechanics; HGSS-specific interpretation stays here.
- Build-only source manifests and provenance belong here. Generated/mod-facing schemas belong
  in `libs/assets` and must not need HGSS knowledge to interpret.

## Source evidence and vocabulary

- Source-format modules and source-derived tests name the authoritative external/source
  reference in their header comment: GBATEK, a pinned `pret/pokeheartgold` symbol/file and
  commit, or another authoritative primary source. Do not use a checked-in focused research
  document or temporary implementation spec as the authority.
- Distinguish verified ROM facts from inferred semantics. Use neutral names when gameplay
  meaning has not been traced yet; do not promote a guess into a durable asset field.
- Source offsets, `narcId`, `fileId`, `memberId`, overlay table indices, and similar source
  identities are zero-based. Never expose a generic `id` when the source identity kind matters.
- Validate finite/integer/range constraints before values become offsets, indices, sizes, or
  binary fields. Treat malformed source data as structured errors, not plausible defaults.

## Compilation boundary

- If an implementation change can alter generated output for the same ROM while the shared
  asset contract is unchanged, it is producer implementation and belongs under `romdump`.
- Normalize source-specific structure before publication so runtime code does not need NARC,
  Nitro, overlay, packed-bitfield, or decomp knowledge.
- Do not duplicate winner selection, schema validation, source resolution, or normalization in
  inspectors/debug tools. Inspection surfaces call the authoritative producer logic.
- Compiler implementation freshness uses the `romdump/src` producer fingerprint. Do not add a
  manual compiler version just to invalidate cache after source-code changes.
- A real generated contract change updates the authoritative `DerivedAssetContract` identity
  in `libs/assets`; do not use contract versions as source-code revision counters.

## Digest source layout

- Keep digest producers in shallow semantic domains: `map`, `model`, `actor`, `field`, `ui`,
  `newgame`, `mons`, and `items`; audio and script producers belong in their existing `audio` and `script`
  domains. Follower visuals merge into the actor bundle, so their producer lives in `actor`;
  starter-choice producers belong to the game-start flow in `newgame`.
- Keep only proven cross-domain utilities at the digest root. Current root utilities are
  `Hashing` and `Lz10`; do not add technical-stage directories or compatibility aliases.
- A digest module's path reflects its semantic owner, while its module contents and generated
  outputs remain independent of that filesystem organization. Update first-party requires and
  tests when a producer moves.

## Tests

- Pure source decoders/parsers can use synthetic unit fixtures. Keep commercial ROM bytes and
  derived commercial assets out of the repository.
- ROM/compiler/corpus facts use the ROM layer and declare the required capability. Do not make
  unit tests depend on a user-owned dump.
- When source compilation changes a user-visible runtime behavior, pair producer evidence with
  the cheapest runtime/acceptance evidence that proves the normalized asset is consumed
  correctly.
- Byte-for-byte/generated-output checks are appropriate when reproducibility is the actual
  compiler contract; do not snapshot incidental catalogs just to notice ordinary additions.
