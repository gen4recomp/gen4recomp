-- Owns field actor visual residency and conversion into draw records/items.

local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
local FieldActorDraw = require("libs.hgss.src.presentation.FieldActorDraw")

---@class FieldActorPresentationAssets: FieldActorAssets
---@field resident fun(self: FieldActorPresentationAssets, spriteId: integer): FieldActorDraw.Entry?

---@class FieldActorPresentationOptions
---@field assets FieldActorPresentationAssets? injected provider-shaped owner for focused tests

---@class FieldActorPresentationRuntime
---@field cacheFs CacheFs?
---@field actors FieldActorManager
---@field playerVisual FieldPlayerVisual

---@class FieldActorPresentation
---@field runtime FieldActorPresentationRuntime
---@field assets FieldActorPresentationAssets
---@field _presentationSpriteRefs table<integer, boolean>
---@field _lastActorManager FieldActorManager?
---@field _lastActorVisualRevision integer?
---@field _lastPlayerSpriteId integer?
---@field _actorRecords table[]?
---@field _actorDrawStorage FieldActorDrawStorage?
local FieldActorPresentation = {}
FieldActorPresentation.__index = FieldActorPresentation

---@param runtime FieldActorPresentationRuntime
---@param options FieldActorPresentationOptions?
---@return FieldActorPresentation
function FieldActorPresentation.new(runtime, options)
  options = options or {}
  local self = setmetatable({
    runtime = runtime,
    assets = options.assets or FieldActorAssetProvider.new(
      assert(runtime.cacheFs, "field actor presentation cache filesystem is unavailable")
    ),
    _presentationSpriteRefs = {},
    _lastActorManager = nil,
    _lastActorVisualRevision = nil,
    _lastPlayerSpriteId = nil,
    _actorRecords = {},
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
  }, FieldActorPresentation)
  return self
end

function FieldActorPresentation:sync()
  local runtime = self.runtime
  local actors = assert(runtime.actors, "field actor manager is unavailable")
  local playerVisual = assert(runtime.playerVisual, "field player visual is unavailable")
  local actorRevision = actors:visualRevision()
  local playerSpriteId = assert(playerVisual.spriteId, "field player visual has no spriteId")
  if
    self._lastActorManager == actors
    and self._lastActorVisualRevision == actorRevision
    and self._lastPlayerSpriteId == playerSpriteId
  then
    return
  end

  local needed = {}
  needed[playerSpriteId] = true
  actors:collectSpriteIds(needed)

  local acquired = {}
  local ok, err = pcall(function()
    for spriteId in pairs(needed) do
      if not self._presentationSpriteRefs[spriteId] then
        self.assets:acquire(spriteId)
        acquired[#acquired + 1] = spriteId
      end
    end
  end)
  if not ok then
    for _, spriteId in ipairs(acquired) do
      self.assets:release(spriteId)
    end
    error(err, 0)
  end

  local released = {}
  for spriteId in pairs(self._presentationSpriteRefs) do
    if not needed[spriteId] then
      released[#released + 1] = spriteId
    end
  end
  for _, spriteId in ipairs(released) do
    self.assets:release(spriteId)
    self._presentationSpriteRefs[spriteId] = nil
  end
  for _, spriteId in ipairs(acquired) do
    self._presentationSpriteRefs[spriteId] = true
  end
  self._lastActorVisualRevision = actorRevision
  self._lastActorManager = actors
  self._lastPlayerSpriteId = playerSpriteId
end

function FieldActorPresentation:_assetLookup(spriteId)
  return assert(self.assets:resident(spriteId), "field actor presentation visual is not resident")
  --[[@as FieldActorDraw.Entry]]
end

---@param alpha number
---@return table[]
function FieldActorPresentation:drawItems(alpha)
  local records = assert(self._actorRecords, "field actor presentation is disposed")
  records[1] = self.runtime.playerVisual:drawRecord(alpha)
  local actorRecords = self.runtime.actors:drawRecords()
  for index, record in ipairs(actorRecords) do
    records[index + 1] = record
  end
  for index = #records, #actorRecords + 2, -1 do
    records[index] = nil
  end
  local storage = assert(self._actorDrawStorage, "field actor draw storage is unavailable")
  return FieldActorDraw.itemsInto(records, function(spriteId)
    return self:_assetLookup(spriteId)
  end, storage)
end

---@return table[]
function FieldActorPresentation:records()
  return assert(self._actorRecords, "field actor presentation is disposed")
end

function FieldActorPresentation:dispose()
  self._actorRecords = nil
  self._actorDrawStorage = nil
  for spriteId in pairs(self._presentationSpriteRefs) do
    self.assets:release(spriteId)
  end
  self._presentationSpriteRefs = {}
  if self.assets then
    self.assets:dispose()
    self.assets = nil
  end
end

return FieldActorPresentation
