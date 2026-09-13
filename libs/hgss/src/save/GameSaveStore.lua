-- Owns the global save catalog and published GameSave payloads. Reservation,
-- first publication, update, and deletion are serialized through SaveFs and
-- keep catalog visibility authoritative over the games directory.

local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")
local SaveFs = require("libs.storage.src.SaveFs")
local StorageErrors = require("libs.storage.src.errors")

local GameSaveStore = {}
GameSaveStore.__index = GameSaveStore

GameSaveStore.CATALOG_SCHEMA = "g4-save-catalog-v1"
GameSaveStore.CATALOG_PATH = "catalog.lua"
GameSaveStore.CATALOG_TEMP_PATH = "catalog.lua.tmp"

local function idForNumber(number)
  return string.format("save-%08d", number)
end

local function numberForId(saveId)
  local number = saveId:match("^save%-(%d+)$")
  if not number then
    return nil
  end
  return tonumber(number)
end

local function isMissing(err)
  return Errors.is(err) and err.code == StorageErrors.SAVE_FILE_MISSING
end

local function catalogError(message, context)
  Errors.raise(GameSaveErrors.GAME_SAVE_CATALOG_INVALID, message, context or {})
end

---@class GameSaveCatalog
---@field schema string
---@field nextId integer
---@field allocatedIds string[]
---@field deletedIds string[]
---@field saveIds string[]

---@param catalog unknown
---@return GameSaveCatalog
local function validateCatalog(catalog)
  if type(catalog) ~= "table" or catalog.schema ~= GameSaveStore.CATALOG_SCHEMA then
    catalogError("save catalog schema is unsupported", { schema = type(catalog) == "table" and catalog.schema or nil })
  end
  if
    type(catalog.nextId) ~= "number"
    or catalog.nextId % 1 ~= 0
    or catalog.nextId < 1
    or catalog.nextId > 0xFFFFFFFF
  then
    catalogError("save catalog next id is invalid", { nextId = catalog.nextId })
  end
  if type(catalog.allocatedIds) ~= "table" then
    catalogError("save catalog allocation history is required", {})
  end
  if type(catalog.deletedIds) ~= "table" then
    catalogError("save catalog deletion history is required", {})
  end
  if type(catalog.saveIds) ~= "table" then
    catalogError("save catalog save ids are required", {})
  end
  ---@cast catalog GameSaveCatalog
  local allowed = { schema = true, nextId = true, allocatedIds = true, deletedIds = true, saveIds = true }
  for key in pairs(catalog) do
    if not allowed[key] then
      catalogError("save catalog contains an unknown field", { field = key })
    end
  end
  for _, ids in ipairs({ catalog.allocatedIds, catalog.deletedIds, catalog.saveIds }) do
    for key in pairs(ids) do
      if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #ids then
        catalogError("save catalog id lists must be contiguous arrays", {})
      end
    end
  end
  local allocated = {}
  for index = 1, #catalog.allocatedIds do
    local saveId = catalog.allocatedIds[index]
    local valid, err = GameSave.validateSaveId(saveId)
    if not valid then
      error(err)
    end
    if numberForId(saveId) ~= index or allocated[saveId] then
      catalogError("save catalog allocation history is not monotonic", { saveId = saveId })
    end
    allocated[saveId] = true
  end
  if #catalog.allocatedIds ~= catalog.nextId - 1 then
    catalogError("save catalog allocation history does not match next id", {})
  end
  local deleted = {}
  for index = 1, #catalog.deletedIds do
    local saveId = catalog.deletedIds[index]
    if not allocated[saveId] or deleted[saveId] then
      catalogError("save catalog deletion history is invalid", { saveId = saveId })
    end
    deleted[saveId] = true
  end
  local seen = {}
  local previousAllocationPosition = 0
  for index = 1, #catalog.saveIds do
    local saveId = catalog.saveIds[index]
    local valid, err = GameSave.validateSaveId(saveId)
    if not valid then
      error(err)
    end
    if seen[saveId] then
      catalogError("save catalog contains a duplicate id", { saveId = saveId })
    end
    local number = numberForId(saveId)
    if number == nil then
      catalogError("save catalog contains an unallocated id", { saveId = saveId })
    end
    if number >= catalog.nextId or not allocated[saveId] then
      catalogError("save catalog contains an unallocated id", { saveId = saveId })
    end
    if deleted[saveId] then
      catalogError("save catalog exposes a deleted id", { saveId = saveId })
    end
    local allocationPosition = assert(numberForId(saveId))
    if allocationPosition <= previousAllocationPosition then
      catalogError("save catalog ordering is not creation ordering", { saveId = saveId })
    end
    previousAllocationPosition = allocationPosition
    seen[saveId] = true
  end
  for key in pairs(catalog.saveIds) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #catalog.saveIds then
      catalogError("save catalog save ids must be a contiguous array", {})
    end
  end
  return catalog
end

---@return GameSaveCatalog
local function emptyCatalog()
  return { schema = GameSaveStore.CATALOG_SCHEMA, nextId = 1, allocatedIds = {}, deletedIds = {}, saveIds = {} }
end

---@class GameSaveStoreModule
---@field new fun(saveFs: SaveFs, opts: table<string, unknown>?): GameSaveStore
---@class GameSaveStore
---@field saveFs SaveFs
---@field opts table<string, unknown>
---@field private _busy boolean
---@field reserve fun(self: GameSaveStore): string
---@field list fun(self: GameSaveStore): table[]
---@field listMetadata fun(self: GameSaveStore): table[]
---@field load fun(self: GameSaveStore, saveId: string): table<string, unknown>?, Errors.Error?
---@field publishFirst fun(self: GameSaveStore, record: table<string, unknown>): boolean
---@field save fun(self: GameSaveStore, record: table<string, unknown>): boolean
---@field delete fun(self: GameSaveStore, saveId: string): boolean
---@param saveFs SaveFs
---@param opts table<string, unknown>?
---@return GameSaveStore
function GameSaveStore.new(saveFs, opts)
  assert(
    getmetatable(saveFs) == SaveFs and saveFs:prefix() == "saves/" and saveFs.versionId == nil,
    "global GameSave store requires a global SaveFs"
  )
  local store = setmetatable({ saveFs = saveFs, opts = opts or {}, _busy = false }, GameSaveStore)
  ---@cast store GameSaveStore
  return store
end

function GameSaveStore:_mutate(operation)
  assert(not self._busy, "game save mutation is already active")
  self._busy = true
  local ok, first = pcall(operation)
  self._busy = false
  if not ok then
    error(first)
  end
  return first
end

function GameSaveStore:_readCatalog()
  local catalog, err = self.saveFs:loadLua(GameSaveStore.CATALOG_PATH)
  if catalog == nil then
    if isMissing(err) then
      return emptyCatalog()
    end
    if err ~= nil then
      error(err)
    end
    catalogError("save catalog load returned neither a catalog nor an error", {})
  end
  return validateCatalog(catalog)
end

function GameSaveStore:_writeCatalog(catalog)
  local ok, err = pcall(function()
    self.saveFs:writeLua(GameSaveStore.CATALOG_TEMP_PATH, catalog)
    self.saveFs:replace(GameSaveStore.CATALOG_TEMP_PATH, GameSaveStore.CATALOG_PATH)
  end)
  if not ok then
    pcall(function()
      self.saveFs:remove(GameSaveStore.CATALOG_TEMP_PATH)
    end)
    error(err)
  end
end

function GameSaveStore:_gamePath(saveId)
  local valid, err = GameSave.validateSaveId(saveId)
  if not valid then
    error(err)
  end
  valid = assert(valid)
  return "games/" .. saveId .. ".lua"
end

function GameSaveStore:_payloadTempPath(saveId)
  return self:_gamePath(saveId) .. ".tmp"
end

function GameSaveStore:_validateRecord(record, expectedSaveId)
  local validator = self.opts.recordValidate
  local valid, err
  if validator then
    assert(type(validator) == "function", "recordValidate must be a function")
    valid, err = validator(record)
  else
    valid, err = GameSave.validate(record, self.opts)
  end
  if not valid then
    error(err)
  end
  valid = assert(valid)
  if expectedSaveId ~= nil and valid.saveId ~= expectedSaveId then
    Errors.raise(GameSaveErrors.GAME_SAVE_SAVE_ID_MISMATCH, "game save id does not match its catalog identity", {
      expected = expectedSaveId,
      actual = valid.saveId,
    })
  end
  return valid
end

function GameSaveStore:_isListed(catalog, saveId)
  for index = 1, #catalog.saveIds do
    if catalog.saveIds[index] == saveId then
      return index
    end
  end
  return nil
end

function GameSaveStore:_isReserved(catalog, saveId)
  for _, allocatedId in ipairs(catalog.allocatedIds) do
    if allocatedId == saveId then
      for _, deletedId in ipairs(catalog.deletedIds) do
        if deletedId == saveId then
          return false
        end
      end
      return not self:_isListed(catalog, saveId)
    end
  end
  return false
end

function GameSaveStore:_loadPublished(saveId)
  local record, err = self.saveFs:loadLua(self:_gamePath(saveId))
  if record == nil and err ~= nil then
    error(err)
  end
  return self:_validateRecord(record --[[@as table]], saveId)
end

-- Reads one payload's display envelope without deep validation: the raw
-- record is loaded as stored and only GameSave.metadata runs over it. The
-- injected record validator never runs and no generated cache is touched.
-- A catalog-listed id whose payload carries another id is a mismatch.
---@param saveId string
---@return table<string, unknown>
function GameSaveStore:_loadEnvelope(saveId)
  local record, err = self.saveFs:loadLua(self:_gamePath(saveId))
  if record == nil then
    if err ~= nil then
      error(err)
    end
    Errors.raise(GameSaveErrors.GAME_SAVE_NOT_PUBLISHED, "save payload is missing", { saveId = saveId })
  end
  assert(type(record) == "table")
  local envelope, envelopeErr = GameSave.metadata(record)
  if envelope == nil then
    error(assert(envelopeErr))
  end
  if envelope.saveId ~= saveId then
    Errors.raise(GameSaveErrors.GAME_SAVE_SAVE_ID_MISMATCH, "game save id does not match its catalog identity", {
      expected = saveId,
      actual = envelope.saveId,
    })
  end
  return envelope
end

---@return string
function GameSaveStore:reserve()
  local saveId = self:_mutate(function()
    local catalog = self:_readCatalog()
    if catalog.nextId >= 0xFFFFFFFF then
      catalogError("save catalog allocation is exhausted", { nextId = catalog.nextId })
    end
    local saveId = idForNumber(catalog.nextId)
    catalog.nextId = catalog.nextId + 1
    catalog.allocatedIds[#catalog.allocatedIds + 1] = saveId
    self:_writeCatalog(catalog)
    return saveId
  end)
  return saveId
end

---@return table[]
function GameSaveStore:list()
  local catalog = self:_readCatalog()
  local entries = {}
  for index = #catalog.saveIds, 1, -1 do
    local saveId = catalog.saveIds[index]
    local ok, recordOrError = pcall(function()
      return self:_loadPublished(saveId)
    end)
    if ok then
      local record = assert(recordOrError --[[@as table]])
      entries[#entries + 1] = {
        saveId = saveId,
        versionId = record.versionId,
        playerData = record.playerData,
        playTimeSeconds = record.playTimeSeconds,
      }
    elseif Errors.is(recordOrError) then
      entries[#entries + 1] = { saveId = saveId, error = recordOrError }
    else
      error(recordOrError)
    end
  end
  return entries
end

-- Metadata-only listing for menu cards: validates the catalog and each
-- payload's display envelope without invoking the injected deep validator
-- and without reading generated caches. A listed envelope is not thereby
-- semantically valid. Ordering and per-entry error reporting match list().
---@return table[]
function GameSaveStore:listMetadata()
  local catalog = self:_readCatalog()
  local entries = {}
  for index = #catalog.saveIds, 1, -1 do
    local saveId = catalog.saveIds[index]
    local ok, envelopeOrError = pcall(function()
      return self:_loadEnvelope(saveId)
    end)
    if ok then
      entries[#entries + 1] = assert(envelopeOrError --[[@as table]])
    elseif Errors.is(envelopeOrError) then
      entries[#entries + 1] = { saveId = saveId, error = envelopeOrError }
    else
      error(envelopeOrError)
    end
  end
  return entries
end

---@param saveId string
---@return table<string, unknown>|nil, Errors.Error?
function GameSaveStore:load(saveId)
  local valid, idErr = GameSave.validateSaveId(saveId)
  if not valid then
    return nil, idErr
  end
  local catalog = self:_readCatalog()
  if not self:_isListed(catalog, saveId) then
    Errors.raise(GameSaveErrors.GAME_SAVE_NOT_PUBLISHED, "save id is not catalog-visible", { saveId = saveId })
  end
  local ok, recordOrError = pcall(function()
    return self:_loadPublished(saveId)
  end)
  if ok then
    return recordOrError
  end
  error(recordOrError)
end

---@param record table<string, unknown>
---@return boolean
function GameSaveStore:publishFirst(record)
  return self:_mutate(function()
    local catalog = self:_readCatalog()
    local valid = self:_validateRecord(record)
    if self:_isListed(catalog, valid.saveId) then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_ALREADY_PUBLISHED,
        "game save is already catalog-visible",
        { saveId = valid.saveId }
      )
    end
    if not self:_isReserved(catalog, valid.saveId) then
      Errors.raise(GameSaveErrors.GAME_SAVE_NOT_RESERVED, "game save id was not reserved", { saveId = valid.saveId })
    end
    -- A first publication has no prior checkpoint to protect. The record is
    -- fully validated before the staged payload is moved into place, and
    -- catalog visibility is published only after that move succeeds.
    local payloadPath = self:_gamePath(valid.saveId)
    local temporaryPath = self:_payloadTempPath(valid.saveId)
    local payloadOk, payloadErr = pcall(function()
      self.saveFs:writeLua(temporaryPath, valid)
      self.saveFs:replace(temporaryPath, payloadPath)
    end)
    if not payloadOk then
      -- The first payload has no previous checkpoint to restore. Remove any
      -- staged residue and rethrow the original failure; catalog visibility
      -- remains unchanged and a failed payload move cannot publish a file.
      pcall(function()
        self.saveFs:remove(temporaryPath)
      end)
      error(payloadErr)
    end
    local allocationPosition
    for index, allocatedId in ipairs(catalog.allocatedIds) do
      if allocatedId == valid.saveId then
        allocationPosition = index
        break
      end
    end
    allocationPosition = assert(allocationPosition, "reserved save id is missing from allocation history")
    local insertion = #catalog.saveIds + 1
    for index, publishedId in ipairs(catalog.saveIds) do
      local publishedPosition
      for candidate, allocatedId in ipairs(catalog.allocatedIds) do
        if allocatedId == publishedId then
          publishedPosition = candidate
          break
        end
      end
      if publishedPosition > allocationPosition then
        insertion = index
        break
      end
    end
    table.insert(catalog.saveIds, insertion, valid.saveId)
    self:_writeCatalog(catalog)
    return true
  end)
end

---@param record table<string, unknown>
---@return boolean
function GameSaveStore:save(record)
  return self:_mutate(function()
    local catalog = self:_readCatalog()
    local valid = self:_validateRecord(record)
    if not self:_isListed(catalog, valid.saveId) then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_NOT_PUBLISHED,
        "game save is not catalog-visible",
        { saveId = valid.saveId }
      )
    end
    local temporaryPath = self:_payloadTempPath(valid.saveId)
    local ok, err = pcall(function()
      self.saveFs:writeLua(temporaryPath, valid)
      self.saveFs:replace(temporaryPath, self:_gamePath(valid.saveId))
    end)
    if not ok then
      pcall(function()
        self.saveFs:remove(temporaryPath)
      end)
      error(err)
    end
    return true
  end)
end

---@param saveId string
---@return boolean
function GameSaveStore:delete(saveId)
  local valid, idErr = GameSave.validateSaveId(saveId)
  if not valid then
    error(idErr)
  end
  return self:_mutate(function()
    local catalog = self:_readCatalog()
    local index = self:_isListed(catalog, saveId)
    if index then
      table.remove(catalog.saveIds, index)
      catalog.deletedIds[#catalog.deletedIds + 1] = saveId
      self:_writeCatalog(catalog)
    end
    -- Catalog removal is the logical commit. A failed cleanup leaves an
    -- invisible orphan, never a visible entry with a deliberately destroyed
    -- payload; the cleanup error still reaches the caller.
    self.saveFs:remove(self:_gamePath(saveId))
    self.saveFs:remove(self:_payloadTempPath(saveId))
    return true
  end)
end

return GameSaveStore
