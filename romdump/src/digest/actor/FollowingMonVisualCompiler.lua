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

-- Retail idle-bob selection for the follower object: ov01_022055B0 returns the
-- low nibble of map-object param 1 for object 253, and src/follow_mon.c packs
-- that param from follower parameter bytes 1..2 as (data[1] << 8) | data[2],
-- so the third archive byte carries the observed nibble. Source:
-- pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- asm/overlay_01_022053EC.s, src/follow_mon.c.
---@param member string validated four-byte follower parameter member
---@return boolean
local function usesAlternateIdleBob(member)
  return string.byte(member, 3) % 16 ~= 0
end

-- Retail ov01_021F8FC0 bob timing for the alternate branch, on the shared
-- 20-tick idle clock: south rests mid-loop while north/west/east hold the
-- first half raised. Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- asm/overlay_01_021F8D80.s.
---@param direction string cardinal facing
---@param tick integer zero-based normalized idle tick
---@return boolean
local function alternateBobIsRaised(direction, tick)
  if direction == "south" then
    return tick <= 4 or tick >= 15
  end
  return tick <= 9
end

---@param visual table<string, unknown>
---@return string
local function renderKindOf(visual)
  local render = visual.render
  if type(render) == "table" and type(render.kind) == "string" then
    return render.kind
  end
  return "unknown"
end

-- Move only the vertical presentation of each cardinal idle pose onto the
-- facing-specific schedule above. Frame indices, segment timing, loop state,
-- and source ranges are preserved exactly; the raised magnitude is the one
-- the shared compiler already emitted, never a duplicated constant.
---@param visual table<string, unknown> remapped follower visual
---@param visualId integer remapped follower visual id
---@param spriteId integer source follower sprite id
local function applyAlternateIdleBob(visual, visualId, spriteId)
  local kind = renderKindOf(visual)
  local presentation = visual.idlePresentation
  if type(presentation) ~= "table" or presentation.mode ~= "animated" then
    error(capabilityFailure(visualId, spriteId, kind, "facing-specific idle bob requires an animated idle"), 0)
  end
  local expanded = {}
  local magnitudes = {}
  for _, direction in ipairs(CARDINAL_DIRECTIONS) do
    local set = visual.directions[direction]
    local pose = set and set.idle
    if pose == nil then
      error(capabilityFailure(visualId, spriteId, kind, "missing " .. direction .. " idle pose"), 0)
    end
    local frameIndexes = {}
    for _, segment in ipairs(pose.frames) do
      for _ = 1, segment.ticks do
        frameIndexes[#frameIndexes + 1] = segment.frameIndex
        if segment.displayOffsetY ~= 0 then
          magnitudes[segment.displayOffsetY] = true
        end
      end
    end
    if #frameIndexes ~= 20 then
      error(
        Errors.new(
          "MON_FOLLOWER_IDLE_DURATION_UNEXPECTED",
          "follower visual "
            .. visualId
            .. " "
            .. direction
            .. " idle covers "
            .. #frameIndexes
            .. " ticks, expected 20",
          { visualId = visualId, spriteId = spriteId, direction = direction, durationTicks = #frameIndexes }
        ),
        0
      )
    end
    expanded[direction] = frameIndexes
  end
  local magnitude, distinct = nil, 0
  for offset in pairs(magnitudes) do
    magnitude, distinct = offset, distinct + 1
  end
  if distinct ~= 1 or magnitude == nil then
    error(
      Errors.new(
        "MON_FOLLOWER_IDLE_OFFSET_AMBIGUOUS",
        "follower visual " .. visualId .. " carries " .. distinct .. " distinct idle bob magnitudes, expected 1",
        { visualId = visualId, spriteId = spriteId, distinctMagnitudes = distinct }
      ),
      0
    )
  end
  for _, direction in ipairs(CARDINAL_DIRECTIONS) do
    local pose = visual.directions[direction].idle
    local frameIndexes = expanded[direction]
    local encoded = {}
    for tick = 0, 19 do
      local sample = {
        frameIndex = frameIndexes[tick + 1],
        displayOffsetY = alternateBobIsRaised(direction, tick) and magnitude or 0,
      }
      local last = encoded[#encoded]
      if last and last.frameIndex == sample.frameIndex and last.displayOffsetY == sample.displayOffsetY then
        last.ticks = last.ticks + 1
      else
        encoded[#encoded + 1] = { frameIndex = sample.frameIndex, ticks = 1, displayOffsetY = sample.displayOffsetY }
      end
    end
    pose.frames = encoded
  end
end

-- Read one follower parameter member selected by the same index that selects
-- the follower sprite. The member must be exactly four bytes; a missing or
-- malformed member fails structurally instead of defaulting the selection.
---@param archive table<string, unknown> opened follower parameter archive
---@param paramIndex integer follower parameter member index
---@return string four-byte member
local function readFollowerParamMember(archive, paramIndex)
  local member, err = archive:readMember(paramIndex)
  if not member then
    if Errors.is(err) then
      error(err, 0)
    end
    error(
      Errors.new("MON_FOLLOWER_PARAM_MISSING", "follower_params member " .. paramIndex .. " is absent", {
        archive = "follower_params",
        alias = "follower_params",
        memberId = paramIndex,
        paramIndex = paramIndex,
      }),
      0
    )
  end
  if #member ~= 4 then
    error(
      Errors.new(
        "MON_FOLLOWER_BAD_SIZE",
        "follower_params member " .. paramIndex .. " is " .. #member .. " bytes, expected 4",
        {
          archive = "follower_params",
          alias = "follower_params",
          memberId = paramIndex,
          paramIndex = paramIndex,
          size = #member,
        }
      ),
      0
    )
  end
  return member
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
    local followerParamsInfo = romFs:resolvedNarc("follower_params")
    if not followerParamsInfo then
      Errors.raise("ROMFS_NARC_UNRESOLVED", "follower_params NARC is unavailable", { name = "follower_params" })
    end
    local followerParamsRaw = must(romFs:read(followerParamsInfo.fileId))
    local followerParamsArchive = must(romFs:openNarc("follower_params"))
    local compiled = must(FieldActorCompiler.compileSprites(romFs, spriteIds))
    local visuals, atlases = {}, {}
    for position, paramIndex in ipairs(paramIndexes) do
      local spriteId = spriteIds[position]
      local alternate = usesAlternateIdleBob(readFollowerParamMember(followerParamsArchive, paramIndex))
      local visual = must(compiled.visuals[spriteId])
      local atlas = must(compiled.atlases[spriteId])
      local visualId = MonSources.followerVisualId(paramIndex)
      visual.spriteId = visualId
      visual.render.image = FieldActorCache.atlasPath(visualId)
      if alternate then
        applyAlternateIdleBob(visual, visualId, spriteId)
      end
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
        followerParams = {
          symbol = followerParamsInfo.symbol,
          alias = followerParamsInfo.alias,
          narcId = followerParamsInfo.narcId,
          fileId = followerParamsInfo.fileId,
          path = followerParamsInfo.path,
          sha1 = Hashing.sha1hex(followerParamsRaw),
        },
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
