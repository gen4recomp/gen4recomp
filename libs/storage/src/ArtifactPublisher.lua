-- Shared staging/publication lifecycle for generated cache artifacts. A writer
-- stages every owned file under a disposable mirror (`staging/<version>/<name>/`,
-- mirroring the live cache-relative layout), validates the staged result, and
-- only then publishes it: each owned live root is copied to an adjacent next
-- sibling, each live root is moved aside, and the candidates are renamed into
-- place. A publication failure leaves the previous live artifact untouched:
-- staging never writes to the live tree, and a failed publish rolls every moved
-- root back before re-raising. Cleanup failure leaves the new artifact live and
-- its recovery metadata available. The move-aside / move-in / rollback lifecycle
-- itself is shared with whole-version publication
-- (`CacheFs.publishFromStage`); this module owns the artifact stage, the owned
-- root list, and the caller contract (no abort once publish has begun). Paths,
-- validation, and readback stay with the individual cache classes. Love-free;
-- all IO goes through the CacheFs backend.

local CacheFs = require("libs.storage.src.CacheFs")

---@class ArtifactPublisher
---@field stage CacheFs
---@field private _cacheFs CacheFs
---@field private _liveRoots string[]
---@field private _published boolean
local ArtifactPublisher = {}
ArtifactPublisher.__index = ArtifactPublisher

-- Begin a staged publication for one artifact. `liveRoots` are the
-- cache-relative roots the artifact owns and swaps wholesale at publish; the
-- root containing the completion marker must be listed last, so a process
-- crash mid-publish can never leave the new marker visible without its full
-- artifact (the marker root is moved aside and renamed into place last). Any
-- stale private stage from a previous attempt is removed first. Version-wide
-- publication recovery remains owned by CacheFs at publication boundaries.
-- The returned transaction exposes `stage` (a
-- CacheFs mirroring the live layout under the staging root), `publish()`, and
-- `abort()`.
function ArtifactPublisher.begin(cacheFs, name, liveRoots)
  assert(cacheFs and cacheFs.versionId, "begin requires a CacheFs")
  assert(type(name) == "string", "artifact name must be a string")
  assert(type(liveRoots) == "table" and #liveRoots >= 1, "liveRoots must list at least one owned root")
  local seen = {}
  for _, root in ipairs(liveRoots) do
    assert(type(root) == "string" and root ~= "", "each live root must be a non-empty path")
    assert(not seen[root], "duplicate live root: " .. root)
    seen[root] = true
  end
  local stage = CacheFs.forArtifactStage(cacheFs.versionId, name, cacheFs.backend)
  stage:removeTree("")
  return setmetatable({
    _cacheFs = cacheFs,
    _liveRoots = liveRoots,
    stage = stage,
  }, ArtifactPublisher)
end

-- Publish the staged artifact over the live roots. CacheFs first materializes
-- adjacent candidates, then moves live roots aside and renames the candidates
-- into place (marker root last), removing recovery material only after every
-- rename lands. The move-aside / move-in / rollback lifecycle is the shared one
-- used by whole-version publication; its outcomes apply here:
--  * success: returns true;
--  * publication failed and rollback succeeded: the original error re-raises;
--  * publication failed and rollback was incomplete:
--    CACHE_PUBLISH_ROLLBACK_INCOMPLETE raises with both errors in context,
--    and the stage keeps the remaining recovery material;
--  * publication succeeded but the stage cleanup failed:
--    CACHE_PUBLISH_CLEANUP_FAILED raises (the new artifact is live, so
--    retrying would be unsafe).
function ArtifactPublisher:publish()
  local cacheFs = self._cacheFs
  local stage = self.stage
  -- The host rename needs both destination parents to exist; createDirectory
  -- is mkdir -p. Done before anything moves, so a failure here leaves no state.
  for _, root in ipairs(self._liveRoots) do
    local parent = root:match("^(.*)/[^/]+$")
    if parent then
      cacheFs:createDirectory(parent)
      stage:createDirectory(parent)
    end
  end
  -- From here the stage may hold rollback/recovery material; the caller must
  -- not discard it.
  self._published = true
  return cacheFs:publishStaged(stage, self._liveRoots, function()
    stage:removeTree("")
  end)
end

-- Discard the staged artifact. Valid only before publish() begins: once
-- publish starts, the stage may hold rollback/recovery material and the
-- caller must not remove it. The live tree is never touched; the previous
-- artifact (if any) remains in place.
function ArtifactPublisher:abort()
  assert(not self._published, "abort is invalid once publish has begun")
  self.stage:removeTree("")
  return true
end

return ArtifactPublisher
