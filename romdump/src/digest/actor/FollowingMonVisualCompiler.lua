-- Follower-specific source selection compiled into existing field-actor
-- visual definitions. Species/form/gender resolve to source follower sprites
-- through src/follow_mon.c FollowMon_GetSpriteID (model LUT plus form-count
-- and female-form tables); each sprite compiles through the shared
-- FieldActorCompiler sprite pipeline into a directional atlas visual with
-- source-authentic placement, poses, timing, and render state. A static-model
-- fallback is never a valid follower representation: the follower runtime
-- selects cardinal facing and walk locomotion frames from the atlas, which a
-- static model cannot supply.
-- Runtime visual IDs live in the documented follower range
-- (FOLLOWER_VISUAL_ID_BASE + tp_param index) so they cannot collide with map
-- actor IDs. The enormous source species-to-model LUT never reaches runtime:
-- the mon catalog carries only the resolved visual ID plus normalized size
-- and object parameters. Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- src/follow_mon.c, include/follow_mon.h,
-- include/constants/follow_mon_idx.h.

local Errors = require("libs.errors.src.Errors")
local MonSources = require("romdump.src.config.MonSources")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local Hashing = require("romdump.src.digest.Hashing")

---@class FollowingMonVisualCompiler
local FollowingMonVisualCompiler = {}

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

local CARDINAL_DIRECTIONS = { "north", "south", "west", "east" }
local LOCOMOTION_POSES = { "idle", "walk" }

---@param visualId integer remapped follower visual id
---@param spriteId integer source follower sprite id
---@param kind string render kind under test
---@param detail string failed capability
---@return Errors.Error
local function capabilityFailure(visualId, spriteId, kind, detail)
  return Errors.new(
    "MON_FOLLOWER_VISUAL_UNSUPPORTED",
    "follower visual " .. visualId .. " cannot face and walk: " .. detail,
    {
      visualId = visualId,
      spriteId = spriteId,
      kind = kind,
    }
  )
end

-- Follower capability beyond structural validity: the visual must be an
-- atlas, every cardinal direction must carry both idle and walk clips, and
-- the clips must not all alias one frame. Structural validation already
-- proves present poses are well-formed with resident frames, so this
-- predicate checks kind, clip presence, and the degenerate single-frame
-- fallback. A visual may legitimately share frames across some poses; only
-- the global single-frame alias is rejected.
---@param visual table<string, unknown> remapped follower visual
---@param visualId integer remapped follower visual id
---@param spriteId integer source follower sprite id
local function assertFollowerCapability(visual, visualId, spriteId)
  local render = visual.render
  if render.kind ~= "atlas" then
    error(
      capabilityFailure(
        visualId,
        spriteId,
        render.kind,
        "render kind " .. tostring(render.kind) .. " carries no locomotion frames"
      ),
      0
    )
  end
  local observed = {}
  for _, direction in ipairs(CARDINAL_DIRECTIONS) do
    local set = visual.directions[direction]
    if set == nil then
      error(capabilityFailure(visualId, spriteId, render.kind, "missing " .. direction .. " direction"), 0)
    end
    for _, poseName in ipairs(LOCOMOTION_POSES) do
      local pose = set[poseName]
      if pose == nil then
        error(
          capabilityFailure(visualId, spriteId, render.kind, "missing " .. direction .. " " .. poseName .. " pose"),
          0
        )
      end
      for _, segment in ipairs(pose.frames) do
        observed[segment.frameIndex] = true
      end
    end
  end
  local distinct = 0
  for _ in pairs(observed) do
    distinct = distinct + 1
  end
  if distinct <= 1 then
    error(capabilityFailure(visualId, spriteId, render.kind, "every cardinal idle and walk pose aliases one frame"), 0)
  end
end

-- Every tp_param index reachable from native species/forms/gender
-- combinations, in ascending order. Reserved identities (NONE/EGG/BAD_EGG)
-- have no follower model and contribute nothing.
local function reachableParamIndexes()
  local seen, ordered = {}, {}
  local function add(paramIndex)
    if paramIndex ~= nil and not seen[paramIndex] then
      seen[paramIndex] = true
      ordered[#ordered + 1] = paramIndex
    end
  end
  for speciesId = 1, MonSources.MAX_SPECIES do
    for _, form in ipairs(MonSources.runtimeForms(speciesId)) do
      add(MonSources.followerParamIndex(speciesId, form, false))
      if MonSources.followerFemaleFlags[speciesId] == true then
        add(MonSources.followerParamIndex(speciesId, form, true))
      end
    end
  end
  table.sort(ordered)
  return ordered
end

-- Compile every reachable follower sprite into field-actor visuals keyed by
-- runtime visual ID. Shiny state needs no separate visual: the source
-- sprite selection ignores shininess (FollowMon_GetSpriteID takes no shiny
-- input) and carries it as runtime object state instead.
---@param romFs table<string, unknown>
---@return table<string, unknown>|nil, Errors.Error|string|nil
function FollowingMonVisualCompiler.compile(romFs)
  local paramIndexes = reachableParamIndexes()
  local spriteIds = {}
  for _, paramIndex in ipairs(paramIndexes) do
    spriteIds[#spriteIds + 1] = MonSources.FOLLOWER_SPRITE_BASE + paramIndex
  end
  local ok, result = pcall(function()
    local compiled = must(FieldActorCompiler.compileSprites(romFs, spriteIds))
    local visuals, atlases = {}, {}
    for position, paramIndex in ipairs(paramIndexes) do
      local spriteId = spriteIds[position]
      local visual = must(compiled.visuals[spriteId])
      local atlas = must(compiled.atlases[spriteId])
      local visualId = MonSources.followerVisualId(paramIndex)
      visual.spriteId = visualId
      visual.render.image = FieldActorCache.atlasPath(visualId)
      if not FieldActorCache.isValidVisual(visual, visualId) then
        error(
          Errors.new("MON_FOLLOWER_VISUAL_INVALID", "remapped follower visual " .. visualId .. " is invalid", {
            visualId = visualId,
            spriteId = spriteId,
          }),
          0
        )
      end
      assertFollowerCapability(visual, visualId, spriteId)
      visuals[visualId] = visual
      atlases[visualId] = atlas
    end
    local visualIds = {}
    for visualId in pairs(visuals) do
      visualIds[#visualIds + 1] = visualId
    end
    table.sort(visualIds)
    return {
      visualIds = visualIds,
      visuals = visuals,
      atlases = atlases,
      dependencies = {
        cacheFormat = FieldActorCache.FORMAT,
        schema = FieldActorCache.SCHEMA,
        followerRangeBase = MonSources.FOLLOWER_VISUAL_ID_BASE,
        spriteBase = MonSources.FOLLOWER_SPRITE_BASE,
        paramIndexes = paramIndexes,
        actorInputs = compiled.dependencies,
      },
    }
  end)
  if not ok then
    if Errors.is(result) then
      local failure = result --[[@as Errors.Error|string]]
      return nil, failure
    end
    error(result, 0)
  end
  return result
end

-- Merge compiled follower visuals into a field-actor bundle before it is
-- written. Follower IDs sort above map sprite IDs, so appending keeps a
-- deterministic index order, and the marker is recomputed over the extended
-- dependencies so follower inputs participate in freshness. A visual ID that
-- collides with a map actor fails loudly instead of overwriting it.
function FollowingMonVisualCompiler.mergeIntoActorBundle(actorBundle, follower)
  assert(
    actorBundle and actorBundle.index and follower and follower.visualIds,
    "merge requires an actor bundle and follower visuals"
  )
  for _, visualId in ipairs(follower.visualIds) do
    assert(follower.visuals[visualId], "follower visual missing for " .. visualId)
    assert(follower.atlases[visualId], "follower atlas missing for " .. visualId)
    if actorBundle.visuals[visualId] ~= nil or actorBundle.atlases[visualId] ~= nil then
      error(
        Errors.new("MON_FOLLOWER_VISUAL_COLLISION", "follower visual " .. visualId .. " collides with a map actor", {
          visualId = visualId,
        }),
        0
      )
    end
    actorBundle.visuals[visualId] = follower.visuals[visualId]
    actorBundle.atlases[visualId] = follower.atlases[visualId]
    actorBundle.index.spriteIds[#actorBundle.index.spriteIds + 1] = visualId
  end
  actorBundle.dependencies.follower = follower.dependencies
  actorBundle.marker =
    FieldActorCache.marker(actorBundle.dependencies.versionRomSha1, Hashing.hashLua(actorBundle.dependencies))
  return actorBundle
end

return FollowingMonVisualCompiler
