-- Composes the concrete HeartGold/SoulSilver application over the generic game host.

local Game = require("game.src.Game")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local NewGame = require("game.hgss.src.newgame.NewGame")
local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
local FieldState = require("game.hgss.src.field.FieldState")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local RepoFs = require("game.src.RepoFs")
local CacheFs = require("libs.storage.src.CacheFs")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")

---@class HgssGameOptions
---@field versionId string
---@field onExit fun(result: table<string, unknown>|nil)
---@field development boolean?
---@field derivedAssets table<string, function>?

local HgssGame = {}

local function fieldStateOptions(options, saveStore, saveValidation, extra)
  local fieldOptions = {
    development = options.development == true,
    saveStore = saveStore,
    saveValidation = saveValidation,
    derivedAssets = options.derivedAssets,
  }
  if extra then
    for key, value in pairs(extra) do
      fieldOptions[key] = value
    end
  end
  return fieldOptions
end

local function newGameCandidate(saveStore, versionId)
  -- The domain catalog behind the unpublished mons bucket resolves lazily
  -- inside candidate construction, so application routing never touches
  -- cache IO: the candidate carries the exact fingerprint the field
  -- runtime validates against.
  local function loadMonCatalog()
    local cacheFs = CacheFs.forVersion(versionId)
    return MonCatalog.new(MonCache.loadCatalog(cacheFs), ItemCatalog.new(ItemCache.loadCatalog(cacheFs)))
  end
  return NewGame.createCandidate({
    saveService = saveStore,
    versionId = versionId,
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
    catalogLoader = loadMonCatalog,
    nowSeconds = os.time(),
  })
end

---@param options HgssGameOptions
---@param game Game
---@param saveStore table<string, unknown>
---@param saveValidation GameSaveValidation
---@param versionId string
local function installRoutes(options, game, saveStore, saveValidation, versionId)
  local function enterField(record, extraOptions)
    game:setState(FieldState.new(record, fieldStateOptions(options, saveStore, saveValidation, extraOptions)))
  end

  local function onOakComplete(result)
    assert(type(result) == "table" and result.playerData ~= nil, "Oak intro completed without a finalized game")
    enterField(NewGameInitialization.apply(result), { initialFadeIn = true })
  end

  local function bootOakIntro()
    local candidate = newGameCandidate(saveStore, versionId)
    game:setState(OakIntroComposition.compose({
      candidate = candidate,
      versionId = versionId,
      onComplete = onOakComplete,
    }))
  end

  local function onMenuResult(result)
    if result.kind == "quit" then
      game:exit(result)
    elseif result.kind == "new_game" then
      bootOakIntro()
    elseif result.kind == "continue" then
      enterField(assert(result.game))
    end
  end

  local width, height = love.graphics.getDimensions()
  game:setState(MainMenuState.new({
    saveStore = saveStore,
    readyVersions = { versionId },
    width = width,
    height = height,
    onResult = onMenuResult,
  }))
end

---@param options HgssGameOptions
---@return Game
function HgssGame.new(options)
  assert(type(options) == "table", "HgssGame requires options")
  local versionId = assert(options.versionId, "HgssGame requires a versionId")
  assert(type(versionId) == "string" and versionId ~= "", "HgssGame versionId is invalid")
  assert(type(options.onExit) == "function", "HgssGame requires an onExit callback")

  local game = Game.new({ onExit = options.onExit })

  local saveValidation = GameSaveValidation.new({
    overrideFs = RepoFs.new(love.filesystem.getSourceBaseDirectory()),
  })
  local function validateSaveRecord(record)
    return saveValidation:validate(record)
  end
  local saveStore = GameSaveStore.new(SaveFs.global(), {
    recordValidate = validateSaveRecord,
  })
  installRoutes(options, game, saveStore, saveValidation, versionId)
  return game
end

return HgssGame
