---
name: tdd
description: Use when implementing or changing behavior — features, bug fixes, stateful/resource-owning/async changes, and refactors that need characterization. Requires writing and observing a failing test before production code. Not for docs-only or skill-only edits.
---

# TDD

Test-first implementation is the repository workflow, not a suggestion. A failing test
observed **before** the production edit is the only evidence that the edit is what fixed
the behavior.

## Cycle

1. **Identify the smallest observable contract and the correct test layer.** Name the
   behavior in one sentence, then pick the layer that isolates it cheapest (see
   "Layer selection").
2. **Read the nearby tests.** Find the existing owner of that contract and extend it;
   do not duplicate a behavior another module already asserts.
3. **Write one failing test — or a characterization test — before production code.**
4. **Run the narrow test and verify it is red for the intended behavioral reason.** A
   red from a require path, syntax error, or missing capability is not a signal; fix the
   test first.
5. **Implement the minimum behavior that makes it green.**
6. **Refactor while green.**
7. **For stateful, cached, asynchronous, persistent, or resource-owning code, add at
   least one failure or multi-step sequence test**: an Nth-stage acquisition failure, a
   double dispose, a busy/reentrant start, a last-known-good preservation.
8. **Run the relevant layer, then `scripts/test.sh`, then `scripts/lint.sh`
9. **Report** the red signal, the green signal, the tests added or changed, and any case
   deliberately omitted with the reason.

## Layer selection

- **Unit** — one module or a small pure object graph: next to the module in
  `libs/<lib>/tests`.
- **Component integration** — several real production collaborators, synthetic fixtures
  and temporary files.
- **Graphics smoke** — real offscreen LÖVE graphics objects; declares the graphics
  capability and never skips by returning early.
- **ROM conformance** — a ready user-owned dump through parsers/digesters/compilers;
  the ROM-gated layer skips explicitly, never by early return.
- **Acceptance** — a user-visible flow through production composition, stopping before
  rendering. `.agents/skills/acceptance-testing/SKILL.md` owns its rules; read it before
  writing one.

When behavior is only protected at a higher layer, prefer a lower-layer test if it
isolates the failure cause; keep the acceptance test when composition is the contract.

## Rules

- Never write production code first and backfill a passing test.
- Never weaken or delete a valid failing acceptance test merely to make the branch green.
- Assert behavior and ownership boundaries, not helper call order or private fields
  without a durable reason.
- Prefer real collaborators when cheap and deterministic; fake true host boundaries.
- A fake may omit a production collaborator only if absence is part of the production
  contract. Otherwise make the fake conform to the real interface.
- Do not add production forwarding interfaces only for tests.
- Do not create a regression test that scans source text merely to prove an old
  implementation name is absent. Test the current behavioral or architectural contract
  that made the deletion correct.
- A round trip needs an independent contract anchor when writer and reader are both
  project code.
- Refactors require characterization before movement when behavior is not already
  protected.
- A failing test must fail before the implementation edit is applied.

## Red for the right reason

A red result is only useful if it names the missing behavior. When the test fails, read
the error: is it the behavior, or a require path, a syntax error, a missing capability,
or a wrong fixture? A load/environment failure means the test is wrong, not the
production code. When the runner has no filter (it executes the whole suite), run it and
read the failing module's own output lines rather than the aggregate.

## Red flags

| Thought | Reality |
|---|---|
| "I'll write the code, then a test to prove it" | Backfilled tests protect the implementation you happened to write, not the contract. The test must fail before the edit. |
| "It passes without my change, close enough" | The test never observed the bug. Make it red for the intended reason first. |
| "This acceptance test blocks me, I'll weaken it" | A valid failing acceptance test is the contract. Fix production, or record evidence and escalate — never quietly weaken. |
| "I'll assert the internal call order, it's deterministic" | Assert behavior and ownership. Call order and private fields are implementation detail. |
| "The refactor is behavior-preserving, no tests needed" | If the behavior is unprotected, it moves with the code. Characterize first. |
| "The round trip passes, so the format is right" | Writer and reader can share the same mistake. Add an independently authored anchor. |
| "One suite run at the end is enough" | Narrow test first, then layer, then full suite — a red at the end is cheap to localize early. |
