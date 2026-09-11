-- Owns version-aware semantic validation for complete persisted GameSave
-- records and the PlayerData boundary used by an in-memory new game.

local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptSave = require("libs.script.src.ScriptSave")
local WorldState = require("libs.hgss.src.script.WorldState")
local AuxiliaryFieldUi = require("libs.hgss.src.ui.AuxiliaryFieldUi")
local FieldAudioSave = require("libs.hgss.src.audio.FieldAudioSave")
local FieldObjectSave = require("libs.hgss.src.save.FieldObjectSave")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local GameSave = require("libs.hgss.src.save.GameSave")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")
local Errors = require("libs.errors.src.Errors")
local FieldScriptCompatibility = require("game.hgss.src.field.FieldScriptCompatibility")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local BagSave = require("libs.hgss.src.save.BagSave")
local MonsErrors = require("libs.mons.src.errors")
local MonsSave = require("libs.mons.src.MonsSave")

---@class GameSaveValidation
---@field contexts table<string, table<string, unknown>>
---@field contextLoader (fun(versionId: string): table<string, unknown>)?
---@field overrideFs table<string, unknown>|nil repository override filesystem for default contexts
local GameSaveValidation = {}
GameSaveValidation.__index = GameSaveValidation

---@param cacheFs CacheFs
---@param overrideFs table<string, unknown>
---@param versionId string
---@return table<string, unknown>
local function contextForCache(cacheFs, overrideFs, versionId)
  local fontDef = FieldFontLoader.load(cacheFs)
  local manifest, loadError = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if not manifest then
    error(loadError)
  end
  local valid, err = FieldUiAssetCache.validateManifest(manifest)
  if not valid then
    error(err)
  end
  local frameIndexes = {}
  for frame = 0, manifest.dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  local index = assert(cacheFs:loadLua(AudioCache.indexPath()), "audio index missing")
  assert(index.schema == AudioCache.INDEX_SCHEMA, "audio index schema is invalid")
  assert(type(index.sequences) == "table", "audio index sequences are required")
  local audioSequenceIds = {}
  for sequenceId, sequence in pairs(index.sequences) do
    assert(type(sequenceId) == "number" and sequence.id == sequenceId, "audio index sequence identity is invalid")
    audioSequenceIds[sequenceId] = true
  end
  -- The mon catalog behind every mons bucket validated in this version:
  -- loaded once per version context through the ready cache path, then
  -- held as the immutable domain catalog its fingerprint belongs to. The
  -- shared item catalog loads beside it: mon composition consumes it now,
  -- and later Bag validation reuses the same version context.
  local monRoot = MonCache.loadCatalog(cacheFs)
  local itemCatalog = ItemCatalog.new(ItemCache.loadCatalog(cacheFs))
  local monCatalog = MonCatalog.new(monRoot, itemCatalog)
  local monLanguage = monRoot.version.language
  assert(
    HgssMonService.GAMES[versionId] ~= nil,
    "GameSave validation requires a native game identity for " .. tostring(versionId)
  )
  assert(
    HgssMonService.LANGUAGES[monLanguage] ~= nil,
    "GameSave validation requires a native language identity for " .. tostring(monLanguage)
  )
  return {
    charmap = fontDef.charmap,
    frameIndexes = frameIndexes,
    audioSequenceIds = audioSequenceIds,
    scriptCompatibility = FieldScriptCompatibility.new({ cacheFs = cacheFs, overrideFs = overrideFs }),
    monCatalog = monCatalog,
    itemCatalog = itemCatalog,
  }
end

---@param options table<string, unknown>?
---@return GameSaveValidation
function GameSaveValidation.new(options)
  options = options or {}
  return setmetatable({
    contexts = {},
    contextLoader = options.contextLoader,
    overrideFs = options.overrideFs,
  }, GameSaveValidation)
end

function GameSaveValidation:_context(versionId)
  local context = self.contexts[versionId]
  if context then
    return context
  end
  context = self.contextLoader and self.contextLoader(versionId)
    or contextForCache(
      CacheFs.forVersion(versionId),
      assert(self.overrideFs, "override filesystem is required"),
      versionId
    )
  assert(type(context) == "table", "GameSave validation context must be a table")
  assert(type(context.audioSequenceIds) == "table", "GameSave validation audio sequence ids are required")
  assert(type(context.scriptCompatibility) == "table", "GameSave script compatibility context is required")
  self.contexts[versionId] = context
  return context
end

---@param record table<string, unknown>
---@param context table<string, unknown>?
---@return table<string, unknown>|nil, Errors.Error?
function GameSaveValidation:validate(record, context)
  local ok, result, err = pcall(function()
    if context == nil and (type(record) ~= "table" or type(record.versionId) ~= "string") then
      return GameSave.validate(record)
    end
    local selected = context or self:_context(record.versionId)
    local function playerDataValidate(value)
      return PlayerData.validate(value, selected)
    end
    local function scriptsValidate(value)
      local options = selected.scriptCompatibility:validationOptions()
      return ScriptSave.validate(value, options)
    end
    local function worldValidate(value)
      return WorldState.validate(value, { objectsValidate = FieldObjectSave.validate })
    end
    local function auxiliaryUiValidate(value)
      return AuxiliaryFieldUi.validate(value)
    end
    local function audioValidate(value)
      return FieldAudioSave.validate(value, selected)
    end
    -- The single application owner of mons validation context: the domain
    -- catalog, its fingerprint, the generated charmap, the native
    -- version/language mapping, and the structural met-date checks owned by
    -- the mon record validator. A context without a mon catalog fails
    -- closed: no bucket is ever accepted unvalidated.
    local function monsValidate(value)
      local monCatalog = selected.monCatalog
      if monCatalog == nil then
        MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons validation requires a mon catalog", {})
      end
      assert(monCatalog ~= nil, "mons validation requires a mon catalog")
      -- MonsSave.validate reports success as a boolean; the canonical
      -- bucket itself is what the save record carries forward, so a
      -- re-validated record never degrades the bucket into `true`.
      MonsSave.validate(value, {
        catalog = monCatalog,
        charmap = selected.charmap,
        games = selected.monGames or HgssMonService.GAMES,
        languages = selected.monLanguages or HgssMonService.LANGUAGES,
      })
      return value
    end
    -- The single application owner of bag validation context: the version
    -- item catalog the bag bucket validates against. A context without an
    -- item catalog fails closed: no bucket is ever accepted unvalidated.
    local function bagValidate(value)
      local itemCatalog = selected.itemCatalog
      if itemCatalog == nil then
        Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "bag validation requires an item catalog", {
          bucket = "bag",
        })
      end
      assert(itemCatalog ~= nil, "bag validation requires an item catalog")
      return BagSave.validate(value, itemCatalog)
    end
    return GameSave.validate(record, {
      playerDataValidate = playerDataValidate,
      scriptsValidate = scriptsValidate,
      worldValidate = worldValidate,
      auxiliaryUiValidate = auxiliaryUiValidate,
      audioValidate = audioValidate,
      monsValidate = monsValidate,
      bagValidate = bagValidate,
    })
  end)
  if ok then
    return result, err
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

function GameSaveValidation:validatePlayerData(playerData, context)
  local ok, result, err = pcall(function()
    return PlayerData.validate(playerData, context)
  end)
  if ok then
    return result, err
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return GameSaveValidation
