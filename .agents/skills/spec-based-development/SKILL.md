---
name: spec-based-development
description: Implement finalized design-heavy implementation-spec bundles in portemon through dependency-safe isolated subagent pipelines. Use when a human provides SPEC.md plus deliverables/Dxx-*.md and wants the repository changed while preserving pinned-baseline design contracts, exact repository reuse/compatibility prescriptions, acceptance-first development, TDD, provider-contract integration gates, fresh integrated design and branch reviews, exact per-deliverable commit messages, controlled deviations, and final branch verification without leaking temporary spec context into permanent artifacts.
---

# Spec-Based Development

Act as the orchestration layer for a finalized implementation specification. Do not write production code yourself. Validate the contract, create isolated worktrees, dispatch fresh subagents, arbitrate deviations, run verification, preserve the prescribed commit history, and advance the protected target only after independent final review.

The coding agents execute the design. They do not redesign the feature merely because another implementation looks plausible.

The entire specification bundle and all orchestration state are temporary. Never propagate `SPEC.md`, deliverable/requirement/acceptance IDs, deviation IDs, planning terminology, implementation notes, or spec rationale into production code, tests, test names, comments, docstrings, documentation, changelogs, or commit messages.

## Contract semantics

Interpret the finalized bundle exactly as follows:

- **Locked**: all normative text is locked by default, including compatibility, reuse, architecture, lifecycle, interfaces, implementation footprint, novelty budget, implementation recipe, acceptance, verification, handoff, and commit contracts. Changing a locked contract requires an approved deviation.
- **Preferred**: only text explicitly marked `**Preferred:**`. An implementation may choose a mechanically equivalent local alternative only when every locked behavior, architecture boundary, lifecycle rule, public surface, compatibility rule, and acceptance result remains identical. Record the alternative and concrete equivalence evidence in temporary notes so review can judge it. If equivalence is arguable rather than objective, treat the choice as locked and propose a deviation.
- **Discretionary**: only choices explicitly listed under `## Allowed implementation discretion`. Keep them behaviorally and architecturally immaterial.

A weaker agent must not infer additional discretion from words such as “implementation detail”, “for example”, or “follow conventions”.

## Workflow

1. Prepare and validate the bundle against the current design-heavy contract.
2. Capture and protect the target branch/head; create a dedicated integration branch/worktree from the exact research commit.
3. Schedule all currently unblocked deliverables from the declared DAG.
4. For each deliverable run: acceptance authoring -> implementation -> verification and contract gates -> exact commit -> integration.
5. Re-run applicable global verification after each integration batch.
6. After all deliverables integrate, audit requirement coverage and exact commit history, run global verification, perform the sole fresh integrated design-conformance review, then run the normal branch review.
7. Fold any valid final-review fixes into their owning deliverable commits, rerun verification and any final review invalidated by those fixes, and only then fast-forward the protected target.
8. Report completion, deviations, verification, and any unresolved blockers; remove temporary state when safe.

## 1. Prepare the bundle

Accept either a ZIP or an unpacked directory with this root shape:

```text
SPEC.md
deliverables/
  D01-<slug>.md
  D02-<slug>.md
```

Extract ZIPs under `.agents/tmp/`; never commit the bundle.

Read `SPEC.md` in full. Require: Goal, Global constraints, Non-goals, Source basis, Shared terminology, Shared architecture, Global decisions, Requirement coverage, Deliverables, Dependency graph, Cross-deliverable contracts, Global verification, and Integration constraints.

For every deliverable require the current design-heavy sections, including:

- Current-state evidence and Compatibility contract;
- Repository reuse contract with Must reuse / Must preserve / May extend or refactor / Must not reimplement / New abstractions justified;
- Behavioral contract;
- Architecture and design, including responsibility boundaries and extension/public surface;
- Implementation footprint and Novelty budget;
- Interfaces and data contracts;
- Required implementation and file-by-file Implementation recipe;
- Acceptance contract, Lower-level test requirements, Verification, and Review hotspots;
- Pitfalls and forbidden approaches, Handoff, Commit, Allowed implementation discretion, and Definition of done.

Stop rather than guessing when a required section is missing, an exact file/symbol prescription is unresolved, the dependency graph is invalid, a commit message is templated instead of literal, or the bundle contains unresolved TODO/TBD placeholders.

### Baseline and protected target

Require a clean primary worktree. Capture:

- current named target branch;
- current target `HEAD`;
- full `Research commit` from `SPEC.md`.

The target `HEAD` must equal the research commit before implementation starts. Do not reinterpret a spec against a nearby revision. Never stash, reset, discard, or absorb unrelated human changes.

Create a dedicated local integration branch/worktree, for example `agent/<bundle-slug>`, from the research commit. All implementation, integration, final review, fixups, and history rewriting happen there. Do not advance the protected target until the end. Never push or open a PR unless the human separately asks.

## 2. Temporary orchestration state

Keep temporary state under ignored paths such as:

```text
.agents/tmp/<bundle-slug>/
  bundle/
  notes.md
  deviations.md
  worktree-notes/

.worktrees/spec-<slug>-Dxx/
```

Initialize `notes.md` with deliverable, acceptance, integration, and handoff state. Use it as an append-only implementation-time channel; do not turn it into a reasoning diary.

Use this deviation ledger:

```markdown
# Approved specification deviations — <bundle>

## DEV-01 — <short description>
- Deliverable: Dxx
- Spec location: `<file>` -> `<section / exact contract>`
- Authoritative replacement: <precise replacement contract>
- Acceptance impact: None | <exact affected scenarios>
- Evidence: <repository fact, test/live evidence, or human decision>
- Authority: orchestrator-objective-evidence | human
```

If there are none, write `None.`.

A subagent may propose but never approve a deviation. The orchestrator may approve only a narrow objective correction proven by repository evidence at the research baseline when externally observable behavior, acceptance semantics, architecture, ownership, lifecycle, API/persistence/security/failure contracts, dependency edges, and public surface remain unchanged. All other material changes require human approval.

Never edit the spec to conceal an approved deviation.

## 3. Dependency-safe worktrees

For each currently unblocked deliverable:

- create a dedicated branch/worktree from the current integration branch;
- independent deliverables may run concurrently from the same integrated prerequisite state;
- a consumer starts only after every provider it depends on is integrated;
- serialize when `Integration constraints`, generated artifacts, shared mutable fixtures, migrations, or overlapping unfinished interfaces make parallel work unsafe.

After a deliverable is verified and committed, rebase it onto the current integration branch and fast-forward the integration branch. Do not create merge commits. If a conflict requires semantic edits, dispatch a fresh integration-fix subagent with only the affected contract files and approved deviations.

Remove integrated worktrees and temporary branches.

## 4. Subagent context boundary

`SPEC.md` is shared contract context. A deliverable pipeline receives only:

- absolute path to `SPEC.md`;
- absolute path to exactly its own deliverable file;
- absolute path to its private worktree notes;
- absolute path to the deviation ledger and IDs of deviations applicable to it, or `None`;
- its worktree path;
- repository-local instructions/skills discovered normally.

Do not preload unrelated deliverables. Do not paste or paraphrase the spec into prompts; pass paths.

Final integrated reviewers receive the spec bundle and approved deviations but **never** implementation/worktree notes, author summaries, failed approaches, or design rationalizations produced during implementation.

## 5. Per-deliverable pipeline

Read the active deliverable in full before dispatching. In particular, explicitly inspect its Compatibility contract, Repository reuse contract, Architecture and design, Implementation footprint, Novelty budget, Implementation recipe, Review hotspots, and Commit contract before any production implementation begins.

### 5.1 Author acceptance first

Dispatch a fresh `general-purpose` subagent:

1. Read `SPEC.md`, the active deliverable, and worktree notes; work only in the worktree and do not read other deliverables.
2. Read `.agents/skills/acceptance-testing/SKILL.md` and follow it.
3. Author exactly the deliverable's acceptance scenarios before production implementation. Preserve setup, observable boundary, expected result, layer, fixtures/capabilities, and expected pre-implementation red.
4. Keep spec IDs only in temporary notes; never place them in committed test names/code/fixtures/comments.
5. Observe the intended missing-behavior red. Syntax/load/capability/unrelated failures are not valid red. If a scenario is already green or its expected red is objectively impossible, record evidence and propose a deviation; do not manufacture failure.
6. Modify only tests/test support/fixtures permitted by the contract; do not modify production code or commit.
7. Record scenario-to-test mapping, red/pass/blocked state, capabilities, and concrete facts in worktree notes.

### 5.2 Implement the prescribed design

Dispatch a fresh `general-purpose` subagent:

1. Read `SPEC.md`, the active deliverable, worktree notes, applicable deviations, repository instructions, and `.agents/skills/tdd/SKILL.md`.
2. Implement only this deliverable. Treat all unmarked normative text as Locked, explicitly marked `**Preferred:**` text as Preferred, and only `Allowed implementation discretion` as Discretionary.
3. Follow the Repository reuse contract literally: reuse exact named mechanisms; preserve named contracts; do not reimplement prohibited concerns; introduce only abstractions justified by `New abstractions justified` and the Novelty budget.
4. Follow the Architecture and design contracts for responsibility, public/private surface, state ownership, lifecycle, control flow, ordering, and extension points.
5. Follow the file-by-file Implementation recipe. Do not substitute another architecture merely because it could satisfy acceptance tests.
6. Treat Implementation footprint as an overbuild guard. If materially more production files, layers, helpers, or shared abstractions appear necessary, stop before adding them, re-search repository reuse, and propose a design deviation when the expansion remains necessary.
7. Make pre-authored acceptance tests pass without weakening them or changing their frozen behavioral semantics; add the required lower-level tests.
8. If deviating from a Preferred prescription, record the exact alternative and objective equivalence evidence in notes. Do not create a deviation when equivalence is clear; otherwise stop and propose one.
9. Never copy temporary spec/planning vocabulary into permanent artifacts.
10. If a Locked contract is false or impossible, stop that disputed part and record concrete evidence as a proposed deviation. Do not silently reinterpret it.
11. Record the actual production files added/modified/deleted, every new reusable/shared production abstraction, realized provided-contract symbols/interfaces, verification state, Preferred alternatives, and proposed deviations. These are orchestration facts, not design justification. Do not commit.

### 5.3 Verify and gate integration

Do not dispatch an independent design reviewer, `change-review`, or another generic cleanup reviewer here. Per-deliverable gates are factual checks; independent design conformance and repository-quality review happen after integration.

Run every command under the deliverable's `## Verification`, plus any `SPEC.md` Global verification command applicable and safe at this stage.

Record each acceptance scenario and verification command as pass/fail/blocked. Required skipped/unavailable capabilities are not green.

Compare the implementation facts recorded in worktree notes with the locked `Implementation footprint`, `New abstractions justified`, and `Novelty budget`. If the implementation materially exceeds the declared production files/layers/shared abstractions, stop before commit, re-search repository reuse, and propose a design deviation when the expansion remains necessary. Do not normalize extra machinery merely because it now exists.

If the deliverable provides one or more cross-deliverable contracts, reconcile the realized provider before unblocking any consumer. For every provided `Cxx`, check the implementation against the exact `Cross-deliverable contracts` entry in `SPEC.md`, including prescribed symbols/interfaces/schema, ownership/lifecycle, ordering or availability guarantees when specified, stable guarantees, and explicit non-guarantees. This is a narrow provider-contract gate, not a general design review. If the realized provider cannot truthfully satisfy the declared contract, stop and use the deviation process before integrating it or starting a consumer.

Also check the deliverable's `## Commit` Gate before committing.

Do not commit while acceptance/lower-level tests fail, required verification is blocked, implementation footprint/novelty accounting violates the locked contract, a provided-contract gate fails, or a proposed material deviation remains unresolved.

### 5.4 Commit exactly as prescribed

Read the deliverable's `## Commit` contract.

- `Required: yes`: tracked changes must exist and must fit Scope/Exclusions. Commit once using the exact literal `Message` **verbatim**, with no body, trailers, AI attribution, or rewriting.
- `Required: no`: require no tracked deliverable changes and create no commit.
- `Required: conditional`: if tracked changes are necessary, use the exact literal Message verbatim; if all gates pass with no tracked changes, create no empty commit.

Never synthesize `<scope>: <description>`. The spec writer already researched repository history and chose the subject.

Record the resulting commit SHA and exact subject in temporary notes, then integrate dependency-safely.

## 6. Cross-deliverable contracts

Provider contracts in `SPEC.md` are Locked shared interfaces. Consumers must use the exact provided symbol/schema/lifecycle/stable guarantees and must respect explicit non-guarantees.

A consumer may not extend or reinterpret a provider contract because its implementation would be easier. If the provided contract is insufficient, stop and propose a deviation before changing either deliverable.

A provider does not unblock its consumers merely because its own tests pass. It must also pass the provider-contract gate in 5.3 against the exact shared contract the consumers were designed to consume.

Implementation-time handoff messages may report concrete realized facts, but they may not silently broaden a cross-deliverable contract.

## 7. Final coverage, history, and integrated design review

After every deliverable is integrated on the dedicated integration branch, perform the only independent design-conformance review in the pipeline. The reviewer must assume no deliverable received an earlier independent design review; passing per-deliverable gates is evidence, not proof of design quality.

1. Cross-check `Requirement coverage`: every requirement owner completed and every mapped acceptance scenario is green.
2. Audit every deliverable Commit contract against branch history. Each required/changed deliverable has exactly the prescribed subject; no forbidden body/trailer/planning vocabulary exists; no unexpected implementation commit bypasses a deliverable contract.
3. Run every `SPEC.md` Global verification command.
4. Dispatch a fresh integrated design reviewer with `SPEC.md`, **every deliverable listed in the Deliverables table**, the deviation ledger, and the integration worktree. Explicitly forbid implementation notes and author summaries.
5. First audit **each deliverable independently** against its full contract and owned diff:
   - compatibility classifications and intentional changes;
   - every Must reuse / Must preserve / Must not reimplement clause;
   - every new production abstraction against `New abstractions justified` and the Novelty budget;
   - responsibility boundaries, public/private surface, state ownership, lifecycle, ordering, and extension points;
   - Implementation footprint and file-by-file Implementation recipe;
   - Preferred alternatives for objective mechanical equivalence;
   - Review hotspots, forbidden approaches, and acceptance/test ownership.
6. Then audit the **integrated design** across deliverables:
   - every provided/consumed cross-deliverable contract is realized exactly and consumers do not reinterpret or broaden it;
   - no concern, abstraction, state owner, lifecycle mechanism, or public/mod-facing surface is duplicated across deliverables;
   - dependency directions and ownership remain coherent after integration;
   - abstractions that appeared locally justified but became redundant in the integrated design are removed;
   - cross-deliverable composition does not create footprint/public-surface growth that no individual deliverable contract justifies.
7. Apply a deletion/reuse bias. Fix violations directly when the locked contract determines the correction. Return only unresolved decisions that genuinely require a deviation.
8. Run `.agents/skills/branch-review/SKILL.md` as the **only generic repository-quality review** in the pipeline. Give it `SPEC.md`, every deliverable file, and approved deviations, never implementation notes. It must assume no per-deliverable generic cleanup review occurred.
9. Re-run all affected and global verification after review fixes.

Do not dispatch `change-review` or substitute another generic cleanup/review agent per deliverable. The integrated design review owns spec conformance once; `branch-review` owns simplification, naming, speculative branches/helpers, residue, test quality, lint, adversarial correctness, and exhaustive branch verification once.

### Preserve exact deliverable history after final-review fixes

Final-review fixes must not create an arbitrary extra “review fixes” commit that defeats exact per-deliverable commit contracts.

Classify each fix by owning deliverable. For each affected deliverable, create a temporary `fixup!` commit targeting that deliverable's exact commit, then autosquash on the integration branch. Split fixes when they belong to different deliverables. If a fix changes cross-deliverable ownership or cannot be assigned without changing the finalized decomposition, treat it as a deviation.

After autosquash, re-run the exact commit-history audit and global verification. Re-run a fresh integrated design review only when final-review fixes changed production architecture, responsibility/ownership, lifecycle, shared/public surface, cross-deliverable contracts, or another locked design contract. Do not repeat the expensive design review merely because cleanup or history rewriting occurred. The final branch should retain the exact subjects prescribed by the spec.

## 8. Advance the protected target

Immediately before delivery, verify the protected primary worktree is still clean, still on the captured target branch, and still at the captured target head. If it moved, stop for explicit reconciliation; do not reset, overwrite, or force-update it.

Only after final coverage, history audit, verification, and reviews are green may the target branch be fast-forwarded to the reviewed integration branch. Never force-update the target.

## 9. Finish

Report concisely:

- deliverables completed and their exact commit subjects/SHAs, including legitimate zero-commit deliverables;
- approved deviations and authority;
- Preferred alternatives actually used;
- acceptance coverage and blocked capabilities;
- final Global verification state;
- unresolved human decisions, if any.

Remove prepared bundle extraction, worktree notes, integrated worktrees, and other temporary state when safe. Preserve nothing from the discarded spec in repository history.

## Hard rules

- Orchestrate; subagents implement and review.
- Execute the finalized design; do not casually re-plan it.
- Exact research baseline or stop.
- Locked is the default. Preferred requires objective mechanical equivalence. Discretionary exists only where explicitly granted.
- Reuse named repository mechanisms; unbudgeted shared abstractions require re-search and usually a deviation.
- Acceptance green does not excuse violating architecture/reuse/lifecycle contracts.
- Never weaken acceptance to make an implementation pass.
- Never invent or rewrite deliverable commit messages.
- Never create empty commits for no-change/conditional deliverables.
- Never commit the spec bundle, notes, deviations, or temporary IDs/planning vocabulary.
- Never expose implementation notes or author reasoning to final integrated reviewers.
- Never turn blocked/skipped required verification green.
- Never push or create a PR unless separately requested.

## Red flags

| Thought | Reality |
|---|---|
| “The tests pass, so this alternative architecture is fine.” | Acceptance proves behavior, not conformance to a locked design/reuse contract. |
| “I can make this cleaner with a new generic helper.” | New shared abstractions must be justified and budgeted in the finalized spec. |
| “The prescribed helper is awkward, so I will copy its logic.” | `Must reuse` and `Must not reimplement` are design contracts, not suggestions. |
| “Preferred means optional.” | Only mechanically equivalent alternatives are allowed without a deviation. |
| “I will pick a better commit subject.” | The exact message is already part of the deliverable contract. |
| “I will add a final cleanup commit.” | Fold final fixes into their owning deliverable commits and preserve prescribed subjects. |
| “The final reviewer should see our notes so it understands why.” | Independent review must not inherit implementation rationalizations. |
| “HEAD is close enough to the research commit.” | Exact file/symbol recipes were researched at one pinned revision; drift invalidates them. |
