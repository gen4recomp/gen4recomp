---
name: change-review
description: Use for standalone/ad-hoc uncommitted work that is ready for a pre-commit cleanup, or when a human explicitly requests a change review - a fresh-context review that fixes the working diff directly, applies repository guidance and the simplification checklist, and selects the narrowest credible tests plus lint. Do not use as an automatic stage of spec-based-development; that workflow defers generic repository-quality review to the integrated branch review.
---

# Change Review

Review and clean the **uncommitted** working diff before commit. Scope is intentionally small:
fix established issues directly rather than producing a report of work the author can already
apply.

This skill is not an automatic stage of `spec-based-development`. That workflow performs
factual per-deliverable gates and defers independent generic cleanup to `branch-review` after
all deliverables are integrated.

## Dispatch

Run one `general-purpose` subagent with empty context. The dispatch prompt contains only:

1. `Read .agents/skills/change-review/SKILL.md and follow it.`
2. The repository root/worktree as an absolute path.
3. `Derive the uncommitted scope yourself from git. Fix directly.`
4. `Return: files changed; net line delta; cuts/renames/structural fixes; findings deliberately
   left and why; tests selected and why; final test/lint status.`

If a finalized spec governs the work, also pass `SPEC.md`, exactly the active deliverable, and
applicable approved deviations. Do not pass implementation notes, author summaries, or failed
approaches; fresh review is meant to remove that bias.

The caller should inspect the return, run/confirm the selected verification and lint, and
raise any unresolved behavior decision to the human.

---

Everything below is for the review subagent.

## Scope

```bash
git status --short
git diff HEAD
```

Untracked files are in scope and must be read in full. Already committed work is out of scope.
If there is no uncommitted change, say so and stop.

## Load applicable guidance

Before editing, read root `AGENTS.md`, every nested `AGENTS.md` that applies to changed files,
and `.agents/skills/review-checklist.md`. Read `tests/AGENTS.md` and the owning test runner/code
for test or behavior changes and `.agents/docs/defensive-patterns.md` for relevant
ownership/failure work.

If a finalized spec is provided, it is desired-state authority; repository guidance still
owns repository-wide/subsystem conventions not overridden by the spec.

## Method

1. **Read the complete diff and new files before editing.** Understand the behavior and owning
   path; do not optimize a diff you have not understood.
2. **Check premise/ownership briefly.** Confirm the change acts at the owner rather than
   patching a caller-specific symptom. Escalate only material spec/product ambiguity.
3. **Apply the review checklist.** Cut/reuse first, then rename/flatten/restructure. Require a
   current consumer for new permanent shared/public surface.
4. **Review tests with production.** Remove fake-driven branches, implementation-shape tests,
   duplicate journeys, and missing material failure coverage.
5. **Select the narrowest credible verification for this diff.** Prefer
   `scripts/test.sh --filter ...` or the affected `--layer ...` when they prove the changed
   behavior. Run full `scripts/test.sh` when the change affects broad composition, test
   discovery/runner infrastructure, shared architecture boundaries, or cannot be isolated
   credibly.
6. **Run `scripts/lint.sh`.** Fix every finding at its source.
7. **Re-run checks affected by lint/review edits.** Do not repeat an already-passing expensive
   check merely because commit follows unless later edits could invalidate it.
8. **Summarize** the concrete cleanup and evidence. State any unavailable required capability
   as blocked, not green.

## Verification selection

Match evidence to the changed surface:

- Pure/local logic: focused unit/component test(s).
- Resource/lifecycle state: focused tests including the relevant failure/sequence path.
- Rendering behavior: graphics layer where the graphics path is material.
- ROM parser/compiler/source behavior: affected ROM evidence when a ready dump is available;
  lack of a dump is an explicit block for a required ROM claim.
- Production composition/user-visible flow/persistence/transitions/scripts: acceptance or
  other real composition evidence required by the applicable guidance/spec.
- Test runner, discovery, architecture gate, or broadly shared boot/composition changes: full
  available suite.

The final branch review is responsible for the exhaustive branch gate. This pass should not
burn full-suite time twice by default.

## Rules

- Less owned complexity is better; line count is only a diagnostic. Never delete necessary
  correctness/safety code to improve the delta.
- Fix, do not propose, when intended behavior is established by the task/spec, current
  contracts, tests, authoritative source material, or accepted decisions.
- A branch/fallback/helper/test does not earn existence because a hypothetical corner case can
  be imagined. Name the current caller/contract/failure mode or cut it.
- Do not weaken locked spec architecture in the name of cleanup. A real contract conflict is a
  proposed deviation, not review permission to redesign silently.
- Report verification honestly, including skipped/blocked capabilities.

Guidance/prevention retrospectives belong to the final `branch-review`, not this pre-commit
pass.
