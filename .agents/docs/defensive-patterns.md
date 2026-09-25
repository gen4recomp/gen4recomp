# Defensive Patterns

This document records hard-won failure classes that recur across the repository.
It is not a generic checklist and should not grow from every isolated bug.
Prefer a code invariant, owning API, static gate, or focused test when those
can make a rule mechanical.

## Acquisition and cleanup

Every acquired resource has exactly one owner. Before acquiring resource N,
know who releases resources 1..N if a later step fails.

- A multi-step constructor or loader cleans up only resources it acquired before
  propagating the original failure.
- Cleanup after failed construction is not recovery. Do not turn programming or
  corruption failures into a half-valid object or plausible success.
- Push, mount, subscribe, acquire, open, and creating host resources change
  ownership and require a matching release path.
- Do not build a generic lifetime helper merely to avoid explicit ownership in
  one operation.

## Usable objects

A normal constructor or factory returns a usable object or fails. Required
collaborators remain required after construction. If partial availability is a
real domain state, represent it explicitly with a state type or state machine.

## Replacement and publication

Never destroy the last known-good artifact or state before its replacement is
fully built and validated:

1. stage new state without disturbing the published state;
2. validate the complete stage;
3. publish by transferring the authoritative reference or identity.

A completion marker proves completeness; it does not by itself make replacement
transactional. Ownership changes when publication starts. After that point the
publisher owns rollback or recovery material, and the caller must not blindly
remove the stage after a publish error.

Filesystem wrappers must propagate failed write, remove, rename, and create
operations. Reporting success after persistence failed violates publication.

Stateful subsystems own busy and reentrancy rules. A protection or pin has one
owner; shared protection needs explicit tokens/counting or a redesigned owner.
When callbacks can mutate a dispatched collection, define whether that affects
the current or next dispatch.

## Persistent and derived state

Persistent user data, especially saves, must not share a deletion root with
generated or rebuildable cache state. Cache invalidation must be incapable of
deleting user state by construction.

## Shared state and caching

- A cache key includes every property affecting immutable runtime configuration.
- Do not cache by source path or bytes and then mutate the shared result for
  different consumers. Put configuration in identity or keep consumer state
  outside the cached value.
- Keep temporary builder, sorter, scheduler, and queue bookkeeping local; do
  not attach scratch fields to caller-owned or shared objects.
- Development producer-byte digests and explicit per-game release counters
  identify the immutable cache generation; persisted contract versions
  describe formats and APIs, not compiler revisions.

## Strict data and recovery

Current project-owned schemas are strict. Missing required data and unknown
enum or mode values are errors unless a current producer contract requires
otherwise. Before adding a default, alias, compatibility path, or broad
recovery branch, identify the current valid input that needs it.

Catch only failures the caller can intentionally recover from. A recovery
boundary must not collapse corruption or programmer errors into an operational
success path.

## Review trigger

When code touches one of these classes, review the successful path and at least
one material failure or sequence path. A failure found here should usually
produce the smallest regression test at the owner that violated the contract,
not an automatic new end-to-end journey.
