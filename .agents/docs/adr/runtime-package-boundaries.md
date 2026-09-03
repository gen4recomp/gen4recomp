# ADR: Runtime package boundaries

**Status:** Accepted
**Date:** 2026-08-30
**Scope:** Ownership and dependency direction for reusable runtime mechanisms, source
producers, generated assets, and application composition.

## Context

The runtime has reusable Nintendo DS behavior, mod-script machinery, and recreated
HeartGold/SoulSilver mechanisms in distinct packages. The source producer also has
responsibility for supported-ROM identity and HGSS-specific compilation, while the
application owns launcher and story policy. These responsibilities require explicit seams
in the current package graph.

The durable ownership question is: does behavior exist because Nintendo DS/Nitro works
that way, because HGSS works that way, because the mod platform works that way, or because
g4recomp stores or composes it that way? The answer determines its owner.

The application-top refinement is recorded separately in
[Application and game boundaries](application-game-boundaries.md). This ADR remains the
accepted decision for the reusable runtime packages and their relationship to producers.

## Decision

The top-level runtime packages are `libs/nds`, `libs/script`, and `libs/hgss`,
alongside the existing foundation and asset packages.

- `libs/nds` owns reusable Nintendo DS, Nitro, and NNS mechanisms. Its semantic levels are
  explicit: `rom`, `nitro/g3d`, `gx`, `nitro/sound`, and the host-specific `love` backend.
  It depends downward on foundations only; it does not know project asset schemas or HGSS.
- `libs/script` owns the project mod DSL/compiler/runtime/scheduler/registry substrate.
  `gen4.script` is the only supported mod-facing script surface. HGSS meanings enter the
  generic machinery through collaborators rather than being embedded in script core.
- `libs/hgss` owns recreated HGSS mechanisms, organized by `field`, `script`, `audio`,
  `presentation`, `ui`, and `save`. It may compose NDS, script, and asset mechanisms but
  does not own launcher, story, or new-game policy.
- `libs/assets` owns g4recomp-defined generated and mod-facing serialization, validation,
  paths, and schemas.
- `libs/mons` owns the roster-independent mon/party domain with semantic records,
  Generation-IV creation, legality, and boxed serialization. It depends downward on
  assets and foundations only; it does not know HGSS story, field, script, or
  presentation policy.
- `romdump` owns supported-ROM identity, HGSS source interpretation, lowering, and derived
  asset compilation. It may consume lower reusable packages but never HGSS runtime code.
- `app` owns the process shell, launcher, version selection, provisioning, and process exit
  policy. `game` owns the generic running-game lifecycle and host adapters. `game/hgss` owns
  the concrete HGSS application composition, story and new-game flow, intro policy, and
  user-facing product states. The application packages reach Nintendo mechanisms through
  HGSS-facing APIs and do not import `libs.nds` directly; `app` may use the existing narrow
  `romdump` provisioning boundary.

The dependency edges run from NDS to foundations, from assets and script to their allowed
lower layers, from HGSS to NDS/script/assets, and from `game/hgss` to the generic game host
and reusable mechanisms. `romdump` remains beside HGSS as a producer, while `app` sits
above the game packages and may use only the documented romdump provisioning boundary.

Mixed current seams are split by meaning rather than assigned to a miscellaneous package:
`NdsRom` separates generic cartridge parsing from supported-ROM identity and cache policy;
`DsMaterial` separates Nintendo register semantics from HGSS field policy;
`libs/nds/src/nitro/sound/InstrumentSelector.lua` directly owns Nintendo voice selection while
`AudioBank` retains project-asset record validation and serialization;
`RuntimeValues` separates generic script evaluation from HGSS references; and `GxRenderer`
separates NDS raster execution from HGSS field presentation.

## Alternatives considered

- Retain `libs/engine` as the permanent broad runtime owner: rejected because it hides
  semantic ownership and keeps unrelated dependency directions coupled.
- Put all low-level behavior in a single `libs/nds` miscellaneous bucket: rejected because
  mod-platform and HGSS semantics are not Nintendo platform semantics, and the resulting
  bucket would recreate the same working-set problem.
- Add compatibility forwarding modules from the old namespace: rejected because internal
  package paths are not a persisted or supported contract, and aliases would prolong the
  ambiguous ownership model.

## Consequences

Contributors can classify a module by the reason its behavior exists, and the repository
enforces an explicit dependency DAG. `libs/nds` stays independent of project-specific
schemas, `libs/script` stays independent of HGSS meaning, and the generic `game` host
remains independent of Nintendo implementation details. This decision does not change runtime behavior,
persistence schemas, generated asset schemas, or resource lifecycle contracts.

## Revisit when

Revisit if a fourth coherent semantic package cannot fit this dependency graph without an
inversion. Resolve that responsibility explicitly; do not introduce a catch-all package.
