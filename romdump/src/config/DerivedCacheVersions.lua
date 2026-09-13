-- Explicit per-game release counters for the derived-cache generation
-- identity: release builds identify producer sources by this counter, never
-- by hashing the source tree. Bump the counter for the affected game whenever
-- producer semantics change without a shared asset-contract revision. The
-- counters are independent per game and unrelated to ROM validation or the
-- generated-format schema.
local DerivedCacheVersions = {
  heartgold = 1,
  soulsilver = 1,
}

return DerivedCacheVersions
