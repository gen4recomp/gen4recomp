# Architecture

g4recomp separates source knowledge, generated contracts, reusable runtime
mechanisms, and product composition. The boundaries keep ROM-specific facts
out of runtime code and keep saves independent from rebuildable assets.

## Dependency direction

Dependencies point from consumer to dependency. The architecture test enforces
this positive package graph and rejects unknown first-party targets:

```text
libs/assets ──► codec, errors, math
libs/mons ────► assets, codec, errors, math
libs/nds ─────► codec, errors, math
libs/script ──► assets, codec, errors, math, storage
libs/hgss ────► nds, script, assets, codec, errors, math, storage
libs/ui ──────► (leaf, no first-party dependencies)
romdump ──────► nds, script, assets, codec, errors, math, storage
game ─────────► codec, errors, math, storage
game/hgss ────► game, hgss, ui, assets, script, codec, errors, math, storage
app ──────────► game, game/hgss, errors
app ── provisioning only ──► romdump
```

`game/src` is game-agnostic. It must not import `app`, `game/hgss`,
`libs/hgss`, `libs/nds`, or `romdump`. `game/hgss` is the concrete HGSS
application and must not import `app`, `romdump`, or `libs/nds`. `app` owns
the only runtime path that reaches `romdump`, and only for ROM provisioning.

## Ownership

| Area | Owner | Contract |
| --- | --- | --- |
| Process and provisioning | `app/` | LÖVE callbacks, launcher, version selection, file drops, cache routing, and process exit |
| Generic game host | `game/src/` | state lifecycle, host adapters, resize, input forwarding, and exit notification |
| HGSS product | `game/hgss/` | menu, New Game/Oak, field composition, saves, and application audio |
| HGSS mechanisms | `libs/hgss/` | reusable field, script adapters, audio, presentation, and save behavior |
| Shared widgets | `libs/ui/` | game-independent button primitives |
| Mod scripting | `libs/script/` | the `gen4.script` runtime, composition, scheduling, and persistence |
| Nintendo formats | `libs/nds/` | reusable DS, Nitro, NNS, graphics, and renderer mechanisms |
| Asset contracts | `libs/assets/` | generated schemas, cache paths/readiness, validation, and mod-facing text forms |
| Mon domain | `libs/mons/` | semantic mon records, parties, Generation-IV creation/legality/codec, and the mons save bucket |
| Source digestion | `romdump/` | ROM access, NARC/HGSS interpretation, provenance, and derived-asset production |

Source-specific parsing belongs in `romdump`, even when pure. A structure
belongs in `libs/assets` only when a custom producer or consumer can use it
without understanding the source ROM. Runtime code consumes the resulting
contract; it does not parse NARC members, ROM bytes, overlays, or decompilation
references.

Generic binary, storage, error, and mathematical primitives stay in their
focused libraries. New shared APIs and extension points need a current
consumer; hypothetical future mods do not establish ownership.

## Repository shape

```text
app/          interactive LÖVE shell (`love app/`)
game/src/     generic game host and adapters
game/hgss/    concrete HeartGold/SoulSilver application
romdump/      source ingestion and asset production (`love romdump/`)
libs/assets/  generated and mod-facing contracts
libs/mons/    semantic mon/party domain and Generation-IV representation
libs/codec/   serialization primitives
libs/storage/ cache, save, and staged publication
libs/errors/  structured errors
libs/math/    fixed-point and matrix primitives
libs/nds/     Nintendo DS/Nitro/NNS mechanisms
libs/script/  mod scripting platform
libs/hgss/    recreated HGSS mechanisms
data/         game-owned manifests and scripts
tests/        runner, ROM, acceptance, and graphics suites
```

The entrypoints are `app/main.lua`, `romdump/main.lua`, `app/src/App.lua`,
`game/src/Game.lua`, and `game/hgss/src/HgssGame.lua`. Modules use full
repo-relative require paths. Tests live beside their owner; the shared runner
and architecture gates live under `tests/`.

## Runtime and data lifecycle

The app provisions a private raw dump, then launches `HgssGame`, which creates
the generic `Game` host and installs the HGSS application. Once the derived
cache is ready, runtime does not need the ROM:

```text
ROM → app/romdump provisioning → immutable raw dump
                                  ↓
                         rebuildable derived assets
                                  ↓
                         game/hgss runtime
```

Import verifies the ROM before touching the live dump. Extraction and derived
builds stage, validate, and publish complete trees; markers are written last.
A failed replacement leaves the last ready artifact usable. Generated cache
data and persistent saves use separate namespaces.

`game/hgss` owns the application composition. Its `FieldRuntime` owns the
non-rendering field session, maps, actors, scripts, input, transitions, saves,
and deterministic camera state. `FieldState` owns the LÖVE presentation and
GPU resources. Reusable field simulation and HGSS mechanisms remain in
`libs/hgss`; the generic `Game` lifecycle remains in `game/src`.

## Asset and mod boundary

`romdump` turns source structures into project-owned assets. `libs/assets`
exposes those assets as stable, source-independent data: for example, message
records carry display text, tokens, and metadata rather than code units or
source offsets. The runtime renders and formats that contract. Physical IDs,
paths, offsets, packing, and decompilation catalogs remain producer-side unless
a product feature gives one semantic meaning.

The raw dump is lossless and versioned independently from derived assets. A
producer fingerprint and asset-contract identity determine whether a full
rebuild is needed; per-artifact completion markers repair missing derived
classes without invalidating the raw dump.

## ID namespaces

These indices are unrelated and must remain named by kind:

| Name | Meaning |
| --- | --- |
| `narcId` | HGSS/decompilation NARC catalog index |
| `fileId` | NDS cartridge FAT index |
| `memberId` | NARC member FAT index |

Paths resolve through the ROM's FNT/FAT, while catalog names provide semantic
source labels. IDs and offsets are zero-based.

For dual-screen adaptation policy, see [`.agents/docs/presentation-layout.md`](../.agents/docs/presentation-layout.md).
For cache and publication failure rules, see [`.agents/docs/defensive-patterns.md`](../.agents/docs/defensive-patterns.md).
