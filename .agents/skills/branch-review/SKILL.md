---
name: branch-review
description: Use when reviewing everything a branch adds on top of master - a fresh-context, deletion-biased review of all unmerged work that fixes established issues directly, validates the branch premise and design intent, verifies the complete branch, and reports whether the development system or agent guidance could have prevented material findings without bloating guidance.
---

# Branch Review

Review **all unmerged changes on the current branch** with a fresh reader and a strong bias
toward deletion, reuse, and fixing the owning invariant rather than the reported symptom.
Fix established issues directly. Leave only decisions whose correct behavior genuinely
requires the human.

For spec-driven branches, this is the only generic repository-quality review in the
implementation pipeline. Assume no per-deliverable cleanup reviewer has already handled
naming, residue, speculative branches/helpers, simplification, test quality, lint, or
adversarial correctness; own those concerns here across the complete integrated branch.

The review also performs a prevention retrospective after the code review. That retrospective
may recommend guidance changes, but it must not edit guidance during the review.

## Dispatch

Run the review in one `general-purpose` subagent with empty context. The point is a reader
that has not inherited the implementation agent's rationale.

The dispatch prompt contains only:

1. `Read .agents/skills/branch-review/SKILL.md and follow it.`
2. The repository root as an absolute path.
3. `Derive the complete unmerged scope yourself from git. Fix established issues directly.`
4. `Return: premise findings; structural/file/function/test findings and fixes; net line
   delta; findings deliberately left and why; guidance/prevention feedback; final
   verification and lint status.`

If a finalized implementation spec exists for the branch, also pass the absolute path to its
`SPEC.md`, **every deliverable file listed in its Deliverables table**, and the applicable
approved-deviation record, if any. Do not pass implementation notes, author
summaries, failed approaches, or design rationalizations.

When the subagent returns, inspect the summary and independently verify the final branch gate
before reporting completion.

---

Everything below is for the review subagent.

## Scope

```bash
git merge-base HEAD master
git diff --stat $(git merge-base HEAD master)..HEAD
git log --oneline $(git merge-base HEAD master)..HEAD
git status --short
```

Review every committed and uncommitted change above `master`, including untracked files. Read
the complete head version of changed files, not only diff hunks. If the branch is `master` or
the merge base is `HEAD`, report that there is no unmerged branch scope and stop.

### Commit messages

Inspect every unmerged commit message in full:

```bash
git log --format=%B $(git merge-base HEAD master)..HEAD
```

Every commit must have one non-empty subject line only and no AI attribution/trailers. Fix
history violations directly so the branch itself is clean.

## Load the owning guidance

Before judging design, read:

- root `AGENTS.md`;
- every nested `AGENTS.md` applicable to changed files;
- `.agents/skills/review-checklist.md`;
- `docs/architecture.md` when boundaries/composition are touched;
- `.agents/docs/defensive-patterns.md` when ownership, partial failure, publication, persistence,
  caches, or shared state are touched;
- `tests/AGENTS.md` and the owning test runner/code for test changes or behavioral coverage.

Read relevant `.agents/docs/adr/` entries and git history only when the branch changes an architectural
choice, restores an apparent omission, or otherwise depends on historical intent. Do not read
history as ritual; use it to resolve a real intent question.

Repository guidance is the source of repository rules. This skill owns the review procedure,
not a duplicate architecture manual.

## Review method

Perform these passes in order. Do not sample a large branch.

### Pass 0 - premise and intent

Before accepting the branch's framing:

- Establish the current/master behavior that motivated the change when feasible.
- Identify the exact execution/data path where the problem or missing behavior occurs.
- Identify the owner/invariant the change should affect and inspect sibling callers/paths.
- Ask whether an apparent gap/omission/restriction was intentional. Check tests, `.agents/docs/adr/`,
  and targeted history when that question is material.
- Compare the branch's design assumptions with the real repository behavior. A branch built
  on a false premise is a finding even if its code is internally clean.

If a finalized spec is present, treat it as desired-state authority while still verifying its
current-state premises against the repository. Approved deviations supersede only the exact
contracts they replace.

### Pass 1 - overall change shape

Start from the changed-file/module graph before reading function bodies:

- Does each new production file/module earn permanent existence?
- Is the same concern implemented twice or in parallel with an existing owner?
- Are dependency directions and applicable subtree boundaries preserved?
- Did a feature change grow a framework, manager, hook system, compatibility layer, or public
  surface beyond what its current consumers need?
- Could deleting or merging a structural unit make the remaining review smaller and clearer?

Make structural cuts first.

### Pass 2 - per-file organization

For each surviving changed file:

- Does it own one coherent responsibility?
- Is public/mod-facing surface minimal and backed by current consumers?
- Are internals exported only to make tests easier?
- Are responsibilities duplicated across neighboring modules?
- Are related operations colocated with the state/invariant they own?
- Are comments current contracts/facts rather than implementation-history prose?

### Pass 3 - function and control flow

Read function bodies against `.agents/skills/review-checklist.md` and applicable subsystem
guidance. Inspect every new fallback, compatibility branch, recovery path, cache/state flag,
and helper layer. Require a reachable current caller, contract, invariant, or failure mode to
keep extra complexity.

### Pass 4 - tests

Review missing and excessive coverage:

- Does the suite prove changed behavior at the owning boundary?
- Does real production composition get exercised where composition itself is the contract?
- Are failure/lifecycle sequences covered where material?
- Are tests freezing expected-to-change data or source text instead of behavior/invariants?
- Are fake-driven production branches or implementation-reproducing mocks present?
- Is expensive setup duplicated when one scenario could prove related postconditions?

For a spec-driven branch, independently reconcile every acceptance scenario in the finalized
deliverables against the tests at `HEAD`. Map scenarios by behavior; permanent test names must
not contain temporary acceptance IDs. Treat a scenario as unsatisfied when it is missing,
materially weakened, moved below its prescribed observable boundary, bypasses required
production composition, makes a required capability/version optional or skippable, or no
longer proves the specified expected result. Do not rely on implementation notes, author
scenario mappings, or claims that a changed test is mechanically equivalent; establish the
equivalence from the spec and test itself.

Fix tests and production design together when difficult testing exposes unnecessary coupling.

### Pass 5 - explicit simplification/replacement pass

Apply the replacement ladder from `.agents/skills/review-checklist.md` to every substantial
new abstraction, dependency, helper layer, option, hook, compatibility path, and public API.
For each retained piece of permanent surface, be able to name its current consumer and the
responsibility/invariant that earns it.

Prefer a few high-confidence cuts over speculative churn. Net line delta is a diagnostic, not
an acceptance criterion.

### Pass 6 - adversarial correctness

Re-read the surviving design looking specifically for subtle bugs: ownership transfer,
partial acquisition, replacement/disposal, stale or shared state, ordering, reentrancy,
publication failure, error mapping, boundary/index mistakes, and accidental contract changes.
Use `.agents/docs/defensive-patterns.md` where applicable.

## Applying fixes and verification

Fix established issues directly, working in small edits and running focused tests as useful.
Do not preserve buggy behavior merely because changing it changes output when intended
behavior is established by the task/spec, a current contract, authoritative source material,
or a durable accepted decision.

Leave an issue unresolved only when the correct behavior/design genuinely requires a human
choice. State the alternatives and evidence concisely.

Before declaring the review complete:

1. Run `scripts/lint.sh` and fix every finding at its source.
2. Run the full available `scripts/test.sh` suite.
3. Explicitly run affected ROM/acceptance evidence when the branch requires it and the
   capability is available. A ROM-gated requirement skipped because the dump is unavailable
   is blocked evidence, not proof supplied by CI.
4. Re-run affected verification after review fixes.
5. Report any remaining infrastructure/capability block honestly.

## Prevention and guidance feedback

After code findings are settled, ask of each **material failure class**, not every nit:

> Could the development system have prevented this issue earlier, and what is the cheapest
> authoritative prevention layer?

Classify the cause first:

- **missing knowledge** - a repository fact was absent or scoped where the agent would not
  reasonably discover it;
- **missing decision rule** - the facts were available, but the guidance did not tell the
  agent how to choose between plausible designs;
- **guidance discoverability** - the right rule existed but was duplicated, buried, or in
  the wrong scope;
- **mechanization gap** - agents are being asked to remember something a code invariant,
  API, lint/static/build gate, or test can enforce more reliably;
- **ordinary implementation defect** - no durable process/guidance change would reasonably
  prevent the mistake.

Recommend prevention in this order:

1. Make the bad state impossible through code/design invariants.
2. Change the owning API/responsibility so the correct path is natural.
3. Add a low-false-positive lint/static/build gate.
4. Add/strengthen a durable behavioral or intentional architecture test.
5. Clarify, consolidate, or relocate existing guidance.
6. Add a new narrow guidance rule only when judgment cannot be mechanized reliably.
7. Make no prevention change when the defect is ordinary or too specific.

### Anti-bloat gate for new guidance

Recommend a genuinely new permanent rule only when all applicable answers are yes:

- Does it describe a recurring/plausibly recurring **class** of mistakes rather than this
  implementation detail?
- Would an agent need this judgment before code exists, rather than being better protected
  by code, API shape, tooling, or tests?
- Is the rule not already clearly implied by existing guidance?
- Is there one obvious home: root, a subtree, defensive patterns, testing guidance, an ADR,
  or a workflow skill?
- Can the rule be short and decision-oriented rather than preserving incident history?
- Does expected recurrence/severity justify the context cost?

Prefer **replace/strengthen**, **consolidate**, or **relocate** over **append**. Root
`AGENTS.md` is intentionally compact; treat roughly 2,000 words as a budget, not a target. A
proposal that grows it should normally identify an equal or larger deletion/relocation.

Do not edit agent guidance during this branch review. Report recommendations separately so a
later guidance-gardening change can deduplicate, generalize, reject, or mechanize them without
contaminating the code review.

For each recommendation report:

- material finding(s) that triggered it;
- failure-class classification;
- best prevention layer;
- whether this strengthens/relocates existing guidance or proposes a new rule;
- concise proposed rule or mechanism;
- why it passes the anti-bloat gate.

If no guidance/process change is justified, say so. End the section by answering: **Could the
development system have prevented any material findings without bloating agent guidance?**

## Rules

- Evidence is required for keeping complexity, not for deleting speculative complexity.
- Preserve intended contracts, not accidental implementation structure.
- The branch diff is the scope, but material pre-existing debt in directly touched code may
  be fixed when doing so makes the branch simpler or safer; label it in the summary.
- Never use implementation notes/author rationale to excuse a design. Review the code,
  repository contracts, accepted decisions, and spec/deviations when present.
- Report final verification truthfully. Never turn an unavailable capability into green.
