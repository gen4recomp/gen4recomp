-- MapProps: the door/model lookup facade. A scene's map props resolve a
-- field coordinate to the door of the building placed there -- field
-- coordinate -> building placement -> ModelInstance -> semantic door
-- animation -- with the doorway API gameplay uses:
--
--     door = mapProps:doorAt(runtimeMap, x, z)
--     door:open()
--     door:close()
--     door:isFinished()
--
-- Door ownership is precomputed once when the scene is assembled: the
-- assembly enumerates the DOOR-kind (behavior 105) tiles of the permission
-- cell (DoorTiles.fromGrid, local indices 0..31) and resolves each to the
-- placement whose pivot (the transform translation, [13]/[15]) is NEAREST
-- the tile centre -- the predicate verified against the real ROM, where
-- door models are planar slabs whose model-space AABB does not contain the
-- tile centre (New Bark member 26: x[-0.3,0.0] z[0.0,0.0]) and a containment
-- test resolves the wrong static building. A geometric tie (every placement
-- within DOOR_TIE_EPSILON_SQ of the global best distance) is resolved by the
-- generated door semantics already carried on each placement record
-- (`doorSoundType`, `doorRoles`, see ModelDoorMetadata): one semantic owner
-- wins, no semantic owner resolves a static door with no placement owner,
-- and several semantic owners stay a diagnosable ambiguity. The nearest
-- pivot decides ownership only within MAX_DOOR_PIVOT_DISTANCE_TILES (corpus-backed: a
-- real-ROM census over every door map found each door tile's nearest pivot
-- within the bound); a tile beyond it is diagnosed once at assembly as
-- uncovered, like a tile with no placement at all. doorAt is then an O(1)
-- index lookup: no placement scan, no matrix inversion, no epsilon on the
-- hot path. The index is authoritative: a tile it does not cover resolves
-- nil, and mutating the placement list after assembly changes nothing.
-- Ambiguity (several placements with door semantics tied for one door
-- tile) and missing coverage (a
-- door tile with no placement at all, or none within the bound) are data
-- failures diagnosed once at assembly, not per lookup. A geometric tie with
-- no door-semantic candidate is a valid static door, not a failure. Only DOOR-kind warp tiles resolve; stairs, directional warps, and
-- generic warps return nil (their choreography is separate policy). A door
-- whose building is static (no animated instance) resolves but animates
-- nothing -- HGSS's interior doors without animation records behave the
-- same. Pure domain module.
--
-- The playback surface is the collapsed animation object graph:
-- MapProps carries no controller. MapDoor plays through the instance and
-- retains the returned play handle on the tile's index entry
-- (entry.animation); isFinished reads that handle, so the finish state never
-- depends on the disposable MapDoor identity. SceneProp keeps exactly
-- play/stop/isFinished -- pause/resume/setDirection/animationsFor have no
-- production caller and do not exist.
--
-- Door sound identity and role duration are generated data, carried on each
-- placement record (`doorSoundType`, `doorRoles`) by whoever builds the
-- placements array (FieldMapLoader reads them from the model descriptor
-- cache -- see ModelDoorMetadata -- so both a headless and a presentation
-- MapProps over the same generated data agree). A door with no live
-- ModelInstance is not thereby "static": when the generated data carries a
-- role duration for it, MapDoor plays a semantic-only timer (retained on the
-- same entry.animation slot, advanced once per tick by MapProps:updateFixed,
-- the deterministic engine clock) that reaches completion at the same source
-- frame a presentation ModelInstance would. Only a role with NO generated
-- duration and no live instance is immediate/nothing-to-wait-for (nil),
-- matching HGSS's genuinely unanimated interior doors.
--
-- Production constructs exactly one MapProps per runtime map (FieldMapLoader
-- builds it before the scene loader runs); a presentation load attaches its
-- live ModelInstances into that SAME instance (MapProps:attachInstances)
-- rather than constructing a second one, so headless and presentation always
-- read the one retained per-tile playback slot -- there is no cross-instance
-- census to keep in sync.

local WarpSystem = require("libs.hgss.src.transition.WarpSystem")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local AnimationClip = require("libs.assets.src.model.AnimationClip")
local DoorSound = require("libs.hgss.src.transition.DoorSound")

local ANIMATION_CATEGORIES = { AnimationClip.CATEGORIES.joint, AnimationClip.CATEGORIES.material }

---@class MapProps
---@field placements table<string, unknown> -- scene placement records (read only after assembly)
---@field placementIndex table<string, unknown> -- [placementIndex] = { modelKey }
---@field doorIndex table<string, unknown> -- ["localX:localZ"] = { placementIndex, modelKey, doorSoundType, roles, animation }
---@field instances { [integer]: ModelInstance|nil }
local MapProps = {}
MapProps.__index = MapProps

-- The corpus-backed door-ownership bound, in tiles (one world unit per
-- tile): a door tile whose NEAREST placement pivot is farther away is
-- uncovered. Over the whole real-ROM census (517 maps, 111 door tiles) the
-- largest nearest-pivot distance is 4.001953 tiles (Rotom room); the bound
-- clears that with headroom. Distances are measured from the transform
-- translation to the tile centre, matching the pivot predicate below.
MapProps.MAX_DOOR_PIVOT_DISTANCE_TILES = 5.0

-- The ambiguity tie window, in SQUARED tile units (the units the tie
-- comparison works in): transform translations are dyadic products, so real
-- ties are exact (gap 0) and the window only guards hand-authored or modded
-- floats. Corpus window: it must catch the synthetic 1.3e-6 gap and stay
-- below the smallest real non-tie gap (0.01171875 sq, Route 5); 1e-4 leaves
-- headroom on both sides.
local DOOR_TIE_EPSILON_SQ = 1e-4

local function raiseUnknown(definition, animation)
  Errors.raise(
    FieldErrors.MAP_PROP_ANIM_UNKNOWN,
    "map prop has no animation named " .. tostring(animation) .. " (model " .. definition.key .. ")",
    { animation = animation, modelKey = definition.key }
  )
end

-- Build the door census once at assembly: ownership (nearest pivot,
-- semantic tie classification, coverage -- unchanged from the original
-- per-lookup-free
-- assembly) plus each tile's generated sound type and role durations, read
-- straight off the owning placement record (`doorSoundType`, `doorRoles`)
-- rather than any live instance.
local function entryForPlacement(selected)
  return {
    placementIndex = selected.placementIndex,
    modelKey = selected.modelKey,
    animation = nil,
    doorSoundType = selected.doorSoundType,
    roles = selected.doorRoles,
  }
end

-- A static tied door has no arbitrary placement owner: choreography needs
-- no placement-specific animation or sound, so the entry carries no
-- placement identity at all.
local function staticDoorEntry()
  return {
    placementIndex = nil,
    modelKey = nil,
    animation = nil,
    doorSoundType = nil,
    roles = nil,
  }
end

-- The compact serializable door-role summary of one tied candidate: which
-- semantic roles exist and their generated frame counts.
local function roleSummary(roles)
  if roles == nil then
    return nil
  end
  local summary = {}
  if roles.open ~= nil then
    summary.open = { frameCount = roles.open.frameCount }
  end
  if roles.close ~= nil then
    summary.close = { frameCount = roles.close.frameCount }
  end
  return summary
end

local function candidateRecord(candidate)
  return {
    placementIndex = candidate.placement.placementIndex,
    modelKey = candidate.placement.modelKey,
    distance = candidate.distance,
    doorSoundType = candidate.placement.doorSoundType,
    doorRoles = roleSummary(candidate.placement.doorRoles),
  }
end

-- Deterministic ambiguity context: tile X/Z plus every tied candidate
-- ordered by placement index (falling back to the stable tie-set order
-- when indices cannot be compared), each carrying identity, pivot
-- distance, sound identity, and role durations.
local function raiseAmbiguousDoor(tile, tied)
  local ordered = {}
  for _, candidate in ipairs(tied) do
    ordered[#ordered + 1] = candidate
  end
  local comparable = true
  for _, candidate in ipairs(ordered) do
    if type(candidate.placement.placementIndex) ~= "number" then
      comparable = false
      break
    end
  end
  if comparable then
    table.sort(ordered, function(a, b)
      return a.placement.placementIndex < b.placement.placementIndex
    end)
  end
  local candidates = {}
  for _, candidate in ipairs(ordered) do
    candidates[#candidates + 1] = candidateRecord(candidate)
  end
  local indices = {}
  for _, candidate in ipairs(ordered) do
    indices[#indices + 1] = candidate.placement.placementIndex
  end
  local names = {}
  for _, candidate in ipairs(ordered) do
    names[#names + 1] = tostring(candidate.placement.placementIndex)
  end
  Errors.raise(
    FieldErrors.MAP_PROP_AMBIGUOUS_DOOR,
    "door tile (" .. tile.x .. "," .. tile.z .. ") is tied between placements " .. table.concat(names, ", "),
    {
      x = tile.x,
      z = tile.z,
      placements = indices,
      candidates = candidates,
    }
  )
end

local function buildDoorCensus(placements, doorTiles)
  local doorIndex = {}
  for _, tile in ipairs(doorTiles) do
    local wx, wz = FieldGrid.tileCenterToWorld(tile.x, tile.z)
    -- Two passes: find the GLOBAL nearest placement first, then check for a
    -- tie only against that global minimum. A single running-best scan is
    -- order-dependent -- two far, irrelevant placements that happen to tie
    -- with each other (neither anywhere near the tile) would wrongly abort
    -- the tile before a much closer, unambiguous placement later in the
    -- list is ever considered.
    local best
    for _, placement in ipairs(placements) do
      local dx, dz = placement.transform[13] - wx, placement.transform[15] - wz
      local distance = dx * dx + dz * dz
      if not best or distance < best.distance then
        best = { placement = placement, distance = distance }
      end
    end
    if not best then
      Errors.raise(
        FieldErrors.MAP_PROP_UNCOVERED_DOOR,
        "door tile (" .. tile.x .. "," .. tile.z .. ") has no building placement",
        { x = tile.x, z = tile.z }
      )
    end
    local nearestDistance = math.sqrt(best.distance)
    if nearestDistance > MapProps.MAX_DOOR_PIVOT_DISTANCE_TILES then
      Errors.raise(
        FieldErrors.MAP_PROP_UNCOVERED_DOOR,
        "door tile ("
          .. tile.x
          .. ","
          .. tile.z
          .. ") nearest placement is "
          .. nearestDistance
          .. " tiles away (beyond "
          .. MapProps.MAX_DOOR_PIVOT_DISTANCE_TILES
          .. ")",
        { x = tile.x, z = tile.z, nearestDistance = nearestDistance }
      )
    end
    -- The tie set is the whole geometric ambiguity: the global best
    -- plus every other placement within the tie window of the true
    -- nearest distance. Geometry alone cannot distinguish these
    -- candidates, so the generated door semantics decide below.
    local tied = { { placement = best.placement, distance = best.distance } }
    for _, placement in ipairs(placements) do
      if placement ~= best.placement then
        local dx, dz = placement.transform[13] - wx, placement.transform[15] - wz
        local distance = dx * dx + dz * dz
        if math.abs(distance - best.distance) < DOOR_TIE_EPSILON_SQ then
          tied[#tied + 1] = { placement = placement, distance = distance }
        end
      end
    end
    -- After nearest-distance/bound checks, classify the whole geometric tie set.
    if #tied == 1 then
      doorIndex[tile.x .. ":" .. tile.z] = entryForPlacement(tied[1].placement)
    else
      local semantic = {}
      for _, candidate in ipairs(tied) do
        if candidate.placement.doorRoles ~= nil then
          semantic[#semantic + 1] = candidate
        end
      end
      if #semantic == 1 then
        doorIndex[tile.x .. ":" .. tile.z] = entryForPlacement(semantic[1].placement)
      elseif #semantic == 0 then
        doorIndex[tile.x .. ":" .. tile.z] = staticDoorEntry()
      else
        raiseAmbiguousDoor(tile, tied)
      end
    end
  end
  return doorIndex
end

-- `doorTiles` are the DOOR-kind tiles of the scene's permission cell as
-- local indices -- exactly the list the assembly enumerates and the space
-- doorAt keys its index with. Several door-semantic placements tied for one
-- tile (within DOOR_TIE_EPSILON_SQ) and missing coverage (a door tile with
-- no placement at all, or none within MAX_DOOR_PIVOT_DISTANCE_TILES) raise
-- here, once, as generated-data failures rather than per-lookup surprises.
-- A tie with no door-semantic candidate is a valid static door.
---@param opts { placements: table<string, unknown>, instances: { [integer]: table<string, unknown>|nil }, doorTiles: { x: integer, z: integer }[] }
---@return MapProps
function MapProps.new(opts)
  assert(opts and opts.placements and opts.instances and opts.doorTiles, "map props options required")
  local self = setmetatable({
    placements = opts.placements,
    instances = opts.instances,
    placementIndex = {},
    doorIndex = buildDoorCensus(opts.placements, opts.doorTiles),
  }, MapProps)
  for _, placement in ipairs(opts.placements) do
    assert(placement.placementIndex ~= nil, "placement missing placementIndex: " .. tostring(placement.modelKey))
    self.placementIndex[placement.placementIndex] = { modelKey = placement.modelKey }
  end
  return self
end

-- Attach presentation ModelInstances after construction: the visual
-- adapter over the SAME semantic door state a headless composition already
-- built, never a second census. Merges into the existing instance table so
-- a partial presentation load (a subset of placements) does not clobber
-- instances attached earlier.
---@param byPlacement { [integer]: ModelInstance|nil }
function MapProps:attachInstances(byPlacement)
  for placementIndex, instance in pairs(byPlacement) do
    self.instances[placementIndex] = instance
  end
end

-- Advance every currently-playing semantic-only door role (no live
-- ModelInstance backing it) by one tick, on the deterministic engine clock
-- RuntimeFieldMap:updateAnimated() drives every fixed tick regardless of
-- presentation. A role with no generated duration, or with a live-instance
-- handle (advanced by the instance's own updateFixed), is left alone.
function MapProps:updateFixed()
  for _, entry in pairs(self.doorIndex) do
    local anim = entry.animation
    if anim and anim.semantic and anim.player.frameCount and anim.player.frame < anim.player.frameCount then
      anim.player.frame = anim.player.frame + 1
    end
  end
end

-- The MapDoor handle: the resolved door at a tile. `instance` is the door's
-- building ModelInstance (nil for static buildings, or in a headless
-- composition) and `entry` is the tile's retained index record -- the play
-- handle lives there, not on the disposable handle, so a fresh resolution of
-- the tile observes the animation the previous handle played.
---@class MapDoor
---@field x integer
---@field z integer
---@field warp table<string, unknown> -- the warp record at the door tile
---@field placementIndex integer|nil -- nil only for a static tied door with no semantic owner
---@field modelKey string|nil -- nil only for a static tied door with no semantic owner
---@field doorSoundType integer|nil
---@field instance table<string, unknown>|nil
---@field entry table<string, unknown> -- the retained index record ({ animation = handle|nil, roles = ... })
local MapDoor = {}
MapDoor.__index = MapDoor

-- The generated frame-count duration of `role` for this door, or nil when
-- the generated data carries no such role (a door whose model has no
-- door.open/door.close clip at all -- HGSS's genuinely unanimated interior
-- doors).
local function roleFrameCount(entry, role)
  if not entry.roles then
    return nil
  end
  if role == AnimationClip.ROLES.DOOR_OPEN then
    return entry.roles.open and entry.roles.open.frameCount or nil
  end
  if role == AnimationClip.ROLES.DOOR_CLOSE then
    return entry.roles.close and entry.roles.close.frameCount or nil
  end
  return nil
end

-- A semantic-only playback handle: no live ModelInstance, but the generated
-- duration is real, so completion must not be immediate. `frame` advances
-- once per MapProps:updateFixed tick; isComplete mirrors the checked-advance
-- rule real AnimationPlayers use (done exactly at frame == frameCount).
local function newSemanticAnimation(frameCount)
  local function isComplete(self)
    return self.frame >= self.frameCount
  end
  return {
    semantic = true,
    player = {
      frame = 0,
      frameCount = frameCount,
      isComplete = isComplete,
    },
  }
end

-- Play the door's opening animation: the semantic door.open role, once, from
-- frame 0, stopping the door's previous play. A static door (no animated
-- instance and no generated duration) has nothing to play and does nothing,
-- like HGSS doors without animation records. Raises MAP_PROP_ANIM_UNKNOWN
-- when a live instance's clips lack the role (a data problem worth a
-- diagnostic, not a silent fallback).
function MapDoor:open()
  self:_play(AnimationClip.ROLES.DOOR_OPEN)
  return self.doorSoundType and DoorSound.sequence(self.doorSoundType, "open") or nil
end

-- Play the door's closing animation: the semantic door.close role, once,
-- from frame 0, stopping the door's previous play. Static doors no-op.
function MapDoor:close()
  self:_play(AnimationClip.ROLES.DOOR_CLOSE)
  return self.doorSoundType and DoorSound.sequence(self.doorSoundType, "close") or nil
end

-- One door has one playing attachment: playing a role stops the tile's
-- retained play handle first, then plays fresh from frame 0. The retained
-- handle is the LIVE attachment instance:play returned (or the semantic-only
-- timer when no instance backs this door), so isFinished reads it directly
-- and replays always restart.
function MapDoor:_play(role)
  if self.instance and not self.instance.soundOnly then
    local definition = self.instance.definition
    if not definition:animation(role) then
      raiseUnknown(definition, role)
    end
    if self.entry.animation then
      self.instance:stop(self.entry.animation)
    end
    self.entry.animation = self.instance:play(role, { loopMode = "once" })
    return
  end
  local frameCount = roleFrameCount(self.entry, role)
  if frameCount == nil then
    -- No live instance and no generated duration for this role: a genuinely
    -- static door, like HGSS's unanimated interior doors. Nothing to play.
    return
  end
  self.entry.animation = newSemanticAnimation(frameCount)
end

-- Whether the door's current animation has reached its end (the player's
-- single checked-advance completion: a once-clip finishes exactly when its
-- frame reaches numFrame * FRAME_UNIT, whether that player is a live
-- ModelInstance attachment or the semantic-only timer _play synthesizes).
-- Nil when nothing is playing -- a static door with no generated duration,
-- or a door that has not been opened or closed yet -- so a waiter treats nil
-- as "nothing to wait for". The handle is read from the tile's retained
-- index record, so any handle resolving this tile reports the same finish
-- state regardless of whether IT carries a live instance.
function MapDoor:isFinished()
  if not self.entry.animation then
    return nil
  end
  return self.entry.animation.player:isComplete()
end

-- Resolve the door at a field tile: the tile must carry a warp whose
-- metatile behavior classifies as a DOOR (behavior 105). Returns a MapDoor
-- for the tile's precomputed placement -- the O(1) index read over the
-- scene's local door tiles; the nearest pivot, ambiguity, and missing
-- coverage were decided once at assembly -- or nil when the tile is out of
-- permission coverage, has no warp, is not a door-kind warp, or the index
-- does not cover it. `instance` is read live from the current instance
-- table, so a door whose model loses its animated instance after assembly
-- resolves statically.
---@param runtimeMap table<string, unknown>
---@param fieldX integer
---@param fieldZ integer
---@return MapDoor?
function MapProps:doorAt(runtimeMap, fieldX, fieldZ)
  local origin = runtimeMap.coordinateOrigin
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  if not runtimeMap.collision:containsLocal(localX, localZ) then
    return nil
  end
  local warp = WarpSystem.findAt(runtimeMap, fieldX, fieldZ)
  if not warp then
    return nil
  end
  -- The tile is inside permission coverage (checked above), so the behavior
  -- byte is always present; only the DOOR metatile resolves a door.
  local behavior = assert(runtimeMap.collision:getLocal(localX, localZ).behavior)
  if not MetatileBehavior.isDoor(behavior) then
    return nil
  end
  local entry = self.doorIndex[localX .. ":" .. localZ]
  if not entry then
    return nil
  end
  return setmetatable({
    x = fieldX,
    z = fieldZ,
    warp = warp,
    placementIndex = entry.placementIndex,
    modelKey = entry.modelKey,
    instance = entry.placementIndex ~= nil and self.instances[entry.placementIndex] or nil,
    entry = entry,
    doorSoundType = entry.doorSoundType,
  }, MapDoor)
end

-- The generic scripted-prop handle: an animated placement addressed by its
-- map-data index, with the semantic playback surface scripts use. Unlike the
-- door lookup it needs no tile or behavior classification -- scripts know
-- the object they animate (HGSS addresses field objects by index). A static
-- placement (no animated instance) resolves to a handle whose ops no-op.
-- The surface is exactly play/stop/isFinished; pause/resume/setDirection/
-- animationsFor have no production caller and do not exist.
---@class SceneProp
---@field placementIndex integer
---@field modelKey string
---@field instance table<string, unknown>|nil
---@field pause nil -- deliberately absent: no production caller
---@field resume nil
---@field setDirection nil
---@field animationsFor nil
local SceneProp = {}
SceneProp.__index = SceneProp

-- The playing attachment of a prop's clip, or nil when nothing plays.
local function attachmentByClip(instance, clip)
  assert(instance ~= nil)
  local animationState = instance.animationState
  assert(animationState ~= nil)
  for _, category in ipairs(ANIMATION_CATEGORIES) do
    for _, attachment in ipairs(animationState:attachments(category)) do
      if attachment.clip == clip then
        return attachment
      end
    end
  end
  return nil
end

-- Play an animation by role or clip name; `opts` passes through to the
-- instance (loopMode). Returns the live attachment handle. Raises
-- MAP_PROP_ANIM_UNKNOWN for a name the model does not define.
function SceneProp:play(animation, opts)
  if not self.instance then
    return nil
  end
  if not self.instance.definition:animation(animation) then
    raiseUnknown(self.instance.definition, animation)
  end
  return self.instance:play(animation, opts)
end

-- Stop an animation by role or clip name.
function SceneProp:stop(animation)
  if not self.instance then
    return nil
  end
  if not self.instance.definition:animation(animation) then
    raiseUnknown(self.instance.definition, animation)
  end
  return self.instance:stop(animation)
end

-- The player's single checked-advance completion for the prop's play of
-- `animation` (a once-clip finishes exactly when its frame reaches numFrame *
-- FRAME_UNIT), or nil when nothing is playing (a static prop, or no play
-- yet) -- a waiter treats nil as "nothing to wait for".
function SceneProp:isFinished(animation)
  if not self.instance then
    return nil
  end
  local clip = self.instance.definition:animation(animation)
  if not clip then
    raiseUnknown(self.instance.definition, animation)
  end
  local attachment = attachmentByClip(self.instance, clip)
  if not attachment then
    return nil
  end
  return attachment.player:isComplete()
end

-- Resolve the scripted-prop handle for a placement index, or nil when no
-- placement has that index. The placement index is precomputed at assembly
-- like the door index: prop() never rescans the placement list per call.
---@param placementIndex integer
---@return SceneProp?
function MapProps:prop(placementIndex)
  local entry = self.placementIndex[placementIndex]
  if not entry then
    return nil
  end
  return setmetatable({
    placementIndex = placementIndex,
    modelKey = entry.modelKey,
    instance = self.instances[placementIndex],
  }, SceneProp)
end

-- Resolve the prop nearest a semantic field tile. Transition choreography uses
-- this only for map behaviors whose source animation is owned by a placed
-- model; the returned handle still validates the requested clip on play.
function MapProps:propAt(runtimeMap, fieldX, fieldZ)
  local localX, localZ = fieldX - runtimeMap.coordinateOrigin.x, fieldZ - runtimeMap.coordinateOrigin.z
  local worldX, worldZ = FieldGrid.tileCenterToWorld(localX, localZ)
  local nearest
  for _, placement in ipairs(self.placements) do
    local dx = placement.transform[13] - worldX
    local dz = placement.transform[15] - worldZ
    local distance = dx * dx + dz * dz
    if not nearest or distance < nearest.distance then
      nearest = { placement = placement, distance = distance }
    end
  end
  return nearest and self:prop(nearest.placement.placementIndex) or nil
end

return MapProps
