# Code Agent Guidance

Repository-wide standing orders for coding agents. Keep this file compact. Rules that only
matter inside one subsystem belong in that subtree's `AGENTS.md`; detailed current-state
facts belong in code/tests; reusable procedures belong in `.agents/skills/`.

## Project intent

- Prefer the correct foundation over compatibility with pre-release development artifacts.
  Preserve compatibility only when a current user-facing, persisted-data, mod-facing, or
  explicitly documented contract requires it.
- Grow game features freely, but be conservative about permanent shared/runtime surface.
  A helper local to one owner is cheaper than a framework, hook, callback, option, or public
  API that every future change must understand.
- Modability comes from explicit asset contracts and deliberately designated public APIs,
  not speculative extension points for hypothetical future mods. Public/mod-facing does not
  imply frozen: stability is an explicit project decision.
- Simplicity follows understanding. Trace the real flow first; then minimize the design.
  A small diff at the wrong ownership boundary is not a simplification.
- Assume unexpected unrelated working-tree changes are from the human. Never reset, stash,
  discard, or absorb them without instruction.

## Guidance map

Read the narrowest authoritative source instead of duplicating it:

- `docs/architecture.md`: public architectural principles and stable code entrypoints.
- `.agents/docs/defensive-patterns.md`: hard-won ownership, publication, cache, and failure rules.
- `tests/AGENTS.md`: test design, runner, layers, capabilities, and ROM policy.
- `romdump/AGENTS.md`: ROM/HGSS/decomp-source rules.
- `libs/nds/AGENTS.md`: Nintendo DS/Nitro platform ownership and dependency direction.
- `libs/script/AGENTS.md`: mod scripting platform ownership and injected game meaning.
- `libs/hgss/AGENTS.md`: recreated HGSS runtime mechanism ownership.
- `libs/ui/AGENTS.md`: shared game-independent widget ownership.
- `libs/assets/AGENTS.md`: generated/mod-facing asset contract rules.
- `libs/mons/AGENTS.md`: mon/party domain and Generation-IV representation rules.
- `app/AGENTS.md`: process, launcher, and provisioning rules.
- `game/AGENTS.md`: game-agnostic lifecycle and host-adapter rules.
- `game/hgss/AGENTS.md`: concrete HGSS application composition and policy rules.
- `.agents/docs/adr/`: durable rationale for architectural decisions likely to be revisited.
- `.agents/skills/`: workflows. Skills should consume repository guidance, not restate it.

When guidance conflicts, prefer the more specific applicable subtree rule unless it violates
an explicit repository-wide boundary here.

## Before changing code

### Verify the premise and intent

Do not treat the request's explanation as proof of the bug or of the right ownership seam.
Before editing:

1. Establish the current behavior on the relevant path.
2. Trace the execution/data flow to the owner of the violated invariant or missing behavior.
3. Inspect sibling callers/entry paths that share that owner. Fix the bug class once rather
   than special-casing the reported manifestation.
4. If an omission, restriction, or odd boundary may be deliberate, inspect nearby tests,
   documentation, `.agents/docs/adr/`, and relevant git history before "restoring" the obvious thing.
5. Separate verified current-state facts from desired-state requirements and inference.

Ask the human only when a material behavior/contract decision remains after research. Do not
ask about mechanical choices that repository evidence settles.

### Use the footprint ladder

Before adding production machinery, stop at the first rung that fully satisfies the current
requirement:

1. Avoid the machinery entirely when the behavior does not require it.
2. Extend or simplify the existing owner instead of adding a parallel owner.
3. Use Lua, LÖVE, the operating system, or another native platform facility.
4. Use an already-installed dependency.
5. Keep a small implementation local rather than creating shared/public surface.
6. Add a maintained dependency only when it materially deletes owned implementation,
   tests, and maintenance compared with the local solution.
7. Only then add a new shared abstraction, framework, hook, option, or public/mod-facing API.

The ladder optimizes permanent owned complexity, not raw line count. Net line count is a
useful diagnostic, never an acceptance criterion.

### Require a current owner and need

Every new shared module, reusable abstraction, public method, configuration option,
callback/hook, extension point, compatibility path, or mod-facing API must name the concrete
current requirement/consumer that needs it. A test-only consumer, imagined future mod, or
"might be useful later" is not enough.

One caller is strong evidence to keep code local unless the boundary itself owns a concrete
responsibility such as resource lifetime, layer separation, a current public contract, or a
source-grounded domain concept.

Treat file size and directory density as review triggers, not permission to create forwarding
modules or split cohesive catalogs, schemas, algorithms, or state owners mechanically. Split
mixed-responsibility hotspots by ownership, lifecycle, or cohesive domain after tracing the
real flow. A new top-level shared package requires a current cross-domain consumer and an owned
responsibility; field mechanisms remain under `libs/hgss` rather than a generic `libs/field`
package.

## Cross-cutting architecture

- The repository has two runnable LÖVE apps, `app/` and `romdump/`, plus shared libraries.
  See `docs/architecture.md` for the current map.
- `app/` owns the LÖVE process shell, launcher, version selection, ROM provisioning, and
  process exit policy. It may reach `romdump` only for provisioning and composes a concrete
  game application; it does not import HGSS mechanisms directly.
- `game/src/` owns the game-agnostic running-game lifecycle and host adapters (`Game`,
  `WindowConfig`, `LocalClock`, `RepoFs`, and audio output). It must not import `app`,
  `game/hgss`, `libs/hgss`, `libs/nds`, or `romdump`.
- `game/hgss/` owns the concrete HeartGold/SoulSilver application: menu, new-game/Oak,
  field application, save compatibility, and application audio. It
  consumes the generic `game` host and reusable mechanisms, but does not import `app`,
  `romdump`, or `libs/nds`.
- Domain logic should remain independently testable from LÖVE. `libs/assets`, `libs/codec`,
  `libs/storage`, `libs/errors`, and `libs/math` must not `require` love.
- Reusable Nintendo container and Nitro/NNS format mechanics belong in `libs/nds`.
  HGSS/decomp-derived formats, NARC/member selection, source-specific overlay use, raw
  bitfields, source catalogs, and build-only source manifests stay in `romdump`.
- `libs/assets` owns only g4recomp-defined generated/mod-facing formats, paths, schemas,
  validation, and source-independent encoders/decoders. It must never import `romdump`.
- `libs/nds`, `libs/script`, and `libs/hgss` are the runtime package owners described by
  their package guidance. `game/hgss` depends on HGSS mechanisms, not Nintendo implementation
  details; direct imports of `libs.nds` from either game package are forbidden.
- Normal `game/hgss` runtime consumes generated assets and HGSS-facing mechanisms; generic
  `game` owns only lifecycle and host adapters. Neither game package decodes ROM formats or
  imports decomp-derived references. The `app` launcher/import UI is the sole provisioning
  exception that reaches `romdump`; runtime packages do not.
- Producer test: if changing a module can change generated output for an unchanged raw dump
  without changing the shared asset contract, that implementation belongs under `romdump`.
- Source physical IDs, paths, offsets, and packing belong in producer dependencies or
  provenance unless runtime/mod-facing behavior has a concrete semantic use for them.
- Winner selection, conflict resolution, status classification, schema validation, and
  similar business rules have one authoritative implementation.
- `tests/architecture/module_boundaries_test.lua` mechanically enforces important dependency
  boundaries. Keep it green; prefer adding similarly low-false-positive gates when a rule is
  mechanically checkable.

## Correctness and ownership

- Make assumptions explicit. Use `assert` for programming invariants and structured `Errors`
  for malformed external/generated data or expected diagnosable runtime failures.
- Project-owned current schemas are strict. Do not add `or {}`, plausible defaults, aliases,
  or missing-field branches without a current producer/caller that can validly require them.
- Generated artifacts get no backward-compatibility path unless explicitly required.
- Every acquired resource has exactly one owner and every replacement/disposal path is
  exactly-once. Constructors/factories return a usable object or fail; do not normalize
  half-valid objects guarded by optional collaborators.
- Stateful subsystems own their own reentrancy/busy protection. Do not rely on every caller
  remembering the invariant.
- Preserve the last known-good state until its replacement is complete. Follow the detailed
  acquisition, publication, persistence, and cache contracts in `.agents/docs/defensive-patterns.md`.
- Catch only failures the caller can intentionally recover from. Broad fallbacks that turn
  programmer errors or corruption into plausible runtime state are bugs.
- Prefer pure functions and local state. Do not attach temporary bookkeeping to caller-owned
  objects or mutate shared cached values differently per consumer.

## Testing and verification

Read `tests/AGENTS.md` for the test contract and runner mechanics.

- Use TDD for behavior changes. Use the `acceptance-testing` skill before work that changes a
  user-visible flow, production composition, persistence, transitions, scripts, or
  ROM-derived behavior.
- Tests protect behavior, relationships, and intentional architecture invariants. Do not add
  change-detector tests that freeze expected-to-change catalogs/counts, or source-text tests
  whose contract is that a symbol/string never appears again.
- Test the real composition path when composition, resource wiring, persistence, ROM-derived
  data, or host integration is the contract. Do not let mocks prove a path production never
  executes.
- Stateful, cached, resource-owning, or asynchronous logic needs a failure or multi-step
  sequence test when that sequence is material.
- Required production collaborators remain required in tests. Fix incomplete fakes rather
  than adding production fallbacks for them.
- Select the narrowest credible local evidence for the diff using `scripts/test.sh` filters
  and layers. The final integrated/branch gate runs the full available suite. CI cannot
  exercise user-owned ROM data, so affected ROM/acceptance evidence must not be assumed to
  exist merely because CI is green.
- Tests are code and runtime cost. Prefer strengthening an existing owner test, the cheapest
  layer that proves the contract, and one expensive production boot with multiple related
  assertions over repeated journeys.

## Code quality and conventions

- Be concrete, brief, and deletion-biased. Remove dead code, speculative compatibility,
  forwarding layers, stale comments, debug/trace residue, and unnecessary nesting.
- LuaLS is intentionally strict: `scripts/lint.sh` must be clean through Hint. Fix findings
  at their source; do not weaken `.luarc.json`, add broad suppressions/globals, edit vendored
  types/generated overrides, or erase types with `any`.
- Exact `_` is the intentional unused discard; delete unused named bindings.
- Annotate public APIs, non-obvious table/data shapes, and places where an annotation states
  an invariant or materially improves inference. Do not annotate trivial private locals just
  because they were touched.
- Library code lives under `libs/<lib>/src/`; application code lives under `app/src/`,
  `game/src/`, `game/hgss/src/`, and `romdump/src/`.
  Require by full repo-relative path, for example `require("libs.codec.src.BinaryReader")`.
- Each Lua module returns one table. Instance types set `M.__index = M` and construct with
  `setmetatable({...}, M)`. Use 2-space indent, LF, and a final newline.
- Open modules with a short role comment. For external binary formats, name the authoritative
  external/source reference rather than temporary implementation material.
- Source offsets and source IDs are zero-based. Use semantic names such as `narcId`, `fileId`,
  and `memberId`, never a generic `id` when the kind matters.
- Generic binary primitives belong in `libs/codec`; reusable Nintendo container and
  Nitro/NNS packing belongs in `libs/nds`; interpreting HGSS/decomp-derived source packing
  belongs in `romdump`; project-owned generated binary formats belong in `libs/assets`.
- A `_private` method is not an inter-module API. Expose a semantic public operation or move
  the responsibility instead of reaching across modules to an underscored helper.

## Temporary context, comments, and durable decisions

- Implementation specs and orchestration state are disposable. Temporary requirement,
  deliverable, acceptance, deviation, gate, or phase identifiers must not appear in
  production code, tests, comments, docs, changelogs, or commit messages.
- Comments and normal docs state current contracts and facts, not reasoning transcripts or
  implementation history. Delete comments that merely justify accidental complexity.
- Public documentation is intentionally minimal: `README.md` provides orientation and
  routine commands, while `docs/` contains only principle-oriented public architecture.
- Put durable rationale or policy requiring engineering judgment in `.agents/docs/`. Exact
  implementation facts, schemas, catalogs, and current state belong in code, tests, or
  comments next to their owner.
- Temporary research and implementation notes belong under `.agents/tmp/` and are not
  committed as permanent documentation. Do not create a generated API or current-state
  document merely because it can be generated.
- An ADR exists only when its why/tradeoff is likely to be revisited and cannot be replaced
  by a mechanical invariant or test. ADRs are not mandatory for ordinary changes; follow
  `.agents/docs/adr/README.md`.

## Commands and commits

- Prefer scripts in `scripts/` over ad-hoc commands. If a repeated repository task lacks a
  script, prefer adding one rather than teaching agents a fragile command sequence.
- Write temporary files under `.agents/tmp/`.
- ROM files (`.nds`, `.zip`) are commonly under workspace `tmp/`; ready dumps are commonly
  under `.cache/love/g4recomp/{heartgold,soulsilver}`.
- Prefer direct command syntax over shell indirection/variable substitution when invoking
  skills or repository scripts.
- Use scoped single-line commit subjects: `<scope>: <description>`.
- Do not add `Co-Authored-By` trailers or AI attribution. The human is solely responsible for
  repository commits.
