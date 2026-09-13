-- Persists a compiled fresh-game startup initializer bundle through the
-- shared staged publication primitive: the artifact is written into a
-- disposable staging root, read back and validated there, and only then is
-- the completed stage published with the marker last.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")

local NewGameInitCacheWriter = {}

function NewGameInitCacheWriter.isReady(cacheFs, marker)
  return NewGameInitCache.isReady(cacheFs, marker)
end

local function stageBundle(stage, bundle)
  stage:writeLua(NewGameInitCache.path(), bundle.artifact)
  local artifact = stage:loadLua(NewGameInitCache.path())
  if type(artifact) ~= "table" then
    Errors.raise("NEW_GAME_INIT_CACHE_READBACK_FAILED", "startup initializer readback failed", {})
  end
  local ok, err = NewGameInitCache.validate(artifact)
  if not ok then
    Errors.raise("NEW_GAME_INIT_CACHE_READBACK_FAILED", "startup initializer readback is invalid", {
      cause = err and err.message or tostring(err),
    })
  end
  stage:write(NewGameInitCache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function NewGameInitCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "startup initializer staging requires a PreparedArtifact")
  assert(bundle and bundle.marker and bundle.artifact, "stage requires a startup initializer bundle")
  assert(bundle.artifact.schema == NewGameInitCache.SCHEMA, "startup initializer schema mismatch")
  artifact:addOwnedRoot(NewGameInitCache.dir())
  stageBundle(artifact:stageFs(), bundle)
  return bundle.marker
end

function NewGameInitCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.artifact, "write requires a startup initializer bundle")
  assert(bundle.artifact.schema == NewGameInitCache.SCHEMA, "startup initializer schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "new-game-init", {
    NewGameInitCache.dir(),
  })
  local ok, err = pcall(stageBundle, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return NewGameInitCacheWriter
