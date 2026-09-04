-- Strict cache contract for the normalized field-effect model and its assets.

local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local FieldEffectAssetCache = {}
FieldEffectAssetCache.FORMAT = Contract.fieldEffects.cacheFormat
local DIR = "data/generated/field/effects"
local INDEX = DIR .. "/index.lua"
local MARKER = DIR .. "/complete"
local ASSET_DIR = "assets/generated/field/effects"

local MARKER_PREFIX = FieldEffectAssetCache.FORMAT .. ":"

local function finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validLifecycle(lifecycle, frameCount)
  if type(lifecycle) ~= "table" or type(lifecycle.mode) ~= "string" then
    return false
  end
  if lifecycle.mode == "hold_until_owner_moves" then
    return finiteNumber(lifecycle.holdFrame)
      and lifecycle.holdFrame >= 0
      and lifecycle.holdFrame == math.floor(lifecycle.holdFrame)
      and finiteNumber(frameCount)
      and lifecycle.holdFrame < frameCount
      and lifecycle.frameCount == nil
  elseif lifecycle.mode == "once" then
    return finiteNumber(lifecycle.frameCount)
      and lifecycle.frameCount >= 1
      and lifecycle.frameCount == math.floor(lifecycle.frameCount)
      and finiteNumber(frameCount)
      and lifecycle.frameCount == frameCount
      and lifecycle.holdFrame == nil
  end
  return false
end

local function validPlacement(offset)
  return type(offset) == "table" and finiteNumber(offset.x) and finiteNumber(offset.y) and finiteNumber(offset.z)
end

local function validSurfPresentation(presentation)
  if type(presentation) ~= "table" then
    return false
  end
  local fieldCount = 0
  for _ in pairs(presentation) do
    fieldCount = fieldCount + 1
  end
  if fieldCount ~= 5 then
    return false
  end
  if not validPlacement(presentation.initialPlayerOffset) then
    return false
  end
  if not validPlacement(presentation.playerBaseOffset) then
    return false
  end
  if not validPlacement(presentation.attachmentBaseOffset) then
    return false
  end
  local oscillator = presentation.oscillator
  if type(oscillator) ~= "table" then
    return false
  end
  local oscillatorCount = 0
  for _ in pairs(oscillator) do
    oscillatorCount = oscillatorCount + 1
  end
  if oscillatorCount ~= 4 then
    return false
  end
  if
    not finiteNumber(oscillator.initialY)
    or not finiteNumber(oscillator.minY)
    or not finiteNumber(oscillator.maxY)
    or not finiteNumber(oscillator.stepY)
  then
    return false
  end
  if oscillator.stepY <= 0 or oscillator.minY > oscillator.maxY then
    return false
  end
  if oscillator.initialY < oscillator.minY or oscillator.initialY > oscillator.maxY then
    return false
  end
  local yaw = presentation.yawDegrees
  if type(yaw) ~= "table" then
    return false
  end
  local yawCount = 0
  for _ in pairs(yaw) do
    yawCount = yawCount + 1
  end
  if yawCount ~= 4 then
    return false
  end
  return finiteNumber(yaw.north) and finiteNumber(yaw.south) and finiteNumber(yaw.west) and finiteNumber(yaw.east)
end

local function validSurfDefinition(definition)
  return type(definition) == "table"
    and type(definition.model) == "table"
    and definition.model.kind == "static"
    and type(definition.lifecycle) == "nil"
    and validSurfPresentation(definition.presentation)
end

local function validGrassDefinition(definition)
  local model = definition.model
  local animations = type(model) == "table" and model.animations
  local clip = type(animations) == "table" and animations[1]
  local lifecycle = definition.lifecycle
  local placementOffset = definition.placementOffset
  return type(definition.lifetime) == "nil"
    and type(definition.animation) == "nil"
    and type(model) == "table"
    and model.kind == "nitro-dynamic"
    and type(animations) == "table"
    and #animations == 1
    and type(clip) == "table"
    and type(lifecycle) == "table"
    and lifecycle.mode == "hold_until_owner_moves"
    and validLifecycle(lifecycle, clip.frameCount)
    and validPlacement(placementOffset)
end

local function validTrainerRevealDefinition(definition)
  local model = definition.model
  local animations = type(model) == "table" and model.animations
  local clip = type(animations) == "table" and animations[1]
  local lifecycle = definition.lifecycle
  local placementOffset = definition.placementOffset
  return type(definition.lifetime) == "nil"
    and type(definition.animation) == "nil"
    and validPlacement(placementOffset)
    and type(model) == "table"
    and model.kind == "nitro-dynamic"
    and type(animations) == "table"
    and #animations == 1
    and type(clip) == "table"
    and type(lifecycle) == "table"
    and lifecycle.mode == "once"
    and validLifecycle(lifecycle, clip.frameCount)
end

-- The follower-transition definition: exactly two compiled models (one
-- static companion, one animated model carrying the single source clip),
-- the once lifecycle with the traced prelude tick count and the exact
-- compiled clip frame count, and the normalized placement offset.
local function validTransitionDefinition(definition)
  if type(definition.lifetime) ~= "nil" or type(definition.animation) ~= "nil" then
    return false
  end
  if type(definition.models) ~= "table" or #definition.models ~= 2 then
    return false
  end
  local animatedClip = nil
  for _, model in ipairs(definition.models) do
    if type(model) ~= "table" then
      return false
    end
    if model.kind == "nitro-dynamic" then
      if animatedClip ~= nil then
        return false
      end
      local animations = model.animations
      local clip = type(animations) == "table" and animations[1]
      if type(animations) ~= "table" or #animations ~= 1 or type(clip) ~= "table" then
        return false
      end
      animatedClip = clip
    elseif model.kind ~= "static" then
      return false
    end
  end
  if animatedClip == nil then
    return false
  end
  if type(definition.model) ~= "nil" then
    return false
  end
  local lifecycle = definition.lifecycle
  if type(lifecycle) ~= "table" or lifecycle.mode ~= "once" or lifecycle.preludeTicks ~= 2 then
    return false
  end
  return validLifecycle(lifecycle, animatedClip.frameCount) and validPlacement(definition.placementOffset)
end

function FieldEffectAssetCache.indexPath()
  return INDEX
end
function FieldEffectAssetCache.definitionPath(kind)
  assert(type(kind) == "string" and kind ~= "", "field-effect kind required")
  return DIR .. "/" .. kind .. ".lua"
end
function FieldEffectAssetCache.markerPath()
  return MARKER
end
function FieldEffectAssetCache.geometryPath(sha1)
  return ASSET_DIR .. "/geometry/" .. sha1 .. ".g4mesh"
end
function FieldEffectAssetCache.texturePath(sha1)
  return ASSET_DIR .. "/textures/" .. sha1 .. ".png"
end
function FieldEffectAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldEffectAssetCache.FORMAT, romSha1, depHash)
end

function FieldEffectAssetCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or expectedMarker:sub(1, #MARKER_PREFIX) ~= MARKER_PREFIX then
    return false
  end
  if cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local loaded, index = pcall(cacheFs.loadLua, cacheFs, INDEX)
  if not loaded or type(index) ~= "table" or index.schema ~= Contract.fieldEffects.indexSchema then
    return false
  end
  local required = {
    "warp_entrance",
    "tall_grass",
    "very_tall_grass",
    "trainer_reveal",
    "surf_attachment",
    "follower_transition",
  }
  if type(index.effects) ~= "table" then
    return false
  end
  local effectCount = 0
  for _ in pairs(index.effects) do
    effectCount = effectCount + 1
  end
  if effectCount ~= #required then
    return false
  end
  local expectedKinds = {
    warp_entrance = "model",
    tall_grass = "animated_model",
    very_tall_grass = "animated_model",
    trainer_reveal = "animated_model",
    surf_attachment = "model",
    follower_transition = "transition",
  }
  for _, kind in ipairs(required) do
    local entry = index.effects and index.effects[kind]

    if
      type(entry) ~= "table"
      or entry.kind ~= expectedKinds[kind]
      or entry.definition ~= kind
      or entry.path ~= FieldEffectAssetCache.definitionPath(kind)
    then
      return false
    end
    local definitionLoaded, definition = pcall(cacheFs.loadLua, cacheFs, entry.path)
    if not definitionLoaded or type(definition) ~= "table" then
      return false
    end
    local descriptors = definition.models or { definition.model }
    if kind ~= "follower_transition" and definition.models ~= nil then
      return false
    end
    local descriptorCount = 0
    for _ in ipairs(descriptors) do
      descriptorCount = descriptorCount + 1
    end
    if descriptorCount == 0 then
      return false
    end
    for _, descriptor in ipairs(descriptors) do
      local valid, err = pcall(ModelAsset.validate, descriptor)
      if not valid then
        return false, err
      end
      local referenced, paths = pcall(ModelAsset.referencedPaths, descriptor)
      if not referenced then
        return false, paths
      end
      for _, path in ipairs(paths) do
        if not cacheFs:exists(path) then
          return false
        end
      end
    end
    if kind == "warp_entrance" and (type(definition.lifetime) ~= "number" or definition.lifetime <= 0) then
      return false
    end
    if kind == "tall_grass" or kind == "very_tall_grass" then
      if not validGrassDefinition(definition) then
        return false
      end
    elseif kind == "trainer_reveal" then
      if not validTrainerRevealDefinition(definition) then
        return false
      end
    elseif kind == "surf_attachment" then
      if not validSurfDefinition(definition) then
        return false
      end
    elseif kind == "follower_transition" then
      if not validTransitionDefinition(definition) then
        return false
      end
    end
  end
  return true
end

return FieldEffectAssetCache
