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
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local RepoFs = require("game.src.RepoFs")
local CacheFs = require("libs.storage.src.CacheFs")
local DisplayContext = require("game.hgss.src.ui.DisplayContext")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")

---@class HgssGameOptions
---@field versionId string
---@field onExit fun(result: table<string, unknown>|nil)
---@field development boolean?
---@field derivedAssets table<string, function>?
---@field topologyProvider (fun(width: number, height: number): ScreenTopology)? actual host surfaces for every entry route
---@field presentationOverrides table<string, table<string, unknown>>? per-case function overrides by application

local HgssGame = {}

local function fieldStateOptions(options, saveStore, saveValidation, extra, shared)
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
  if shared then
    for key, value in pairs(shared) do
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

-- Validates and copies the product-root override record once: only the
-- four case function fields merge per application, unknown case keys and
-- non-functions fail at composition. Unknown application entries ride
-- along copied for their owning slice; each owner consumes only its entry.
---@param overrides table<string, unknown>?
---@return table<string, table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>>>?
local function copyPresentationOverrides(overrides)
  if overrides == nil then
    return nil
  end
  assert(type(overrides) == "table", "presentation overrides must be a record")
  local cases = { dualDisplay = true, nativeLike = true, wide = true, tall = true }
  local copied = {}
  for applicationId, entry in pairs(overrides) do
    assert(type(entry) == "table", "the overrides for " .. tostring(applicationId) .. " must be a record")
    local entryCopy = {}
    for key, fn in pairs(entry) do
      assert(cases[key] == true, "unknown presentation override case " .. tostring(key))
      assert(type(fn) == "function", "the override for " .. tostring(key) .. " must be a function")
      entryCopy[key] = fn
    end
    copied[applicationId] = entryCopy
  end
  return copied
end

---@param options HgssGameOptions
---@param game Game
---@param saveStore table<string, unknown>
---@param saveValidation GameSaveValidation
---@param versionId string
local function installRoutes(options, game, saveStore, saveValidation, versionId)
  -- One actual-display measurement owner and one copied override record
  -- for every entry route: the field consumes them now, and the separately
  -- owned Main Menu and Oak routes receive the same inputs in their slices.
  local displayContext = DisplayContext.new({ topologyProvider = options.topologyProvider })
  local presentationOverrides = copyPresentationOverrides(options.presentationOverrides)
  local function enterField(record, extraOptions)
    game:setState(FieldState.new(
      record,
      fieldStateOptions(options, saveStore, saveValidation, extraOptions, {
        displayContext = displayContext,
        presentationOverrides = presentationOverrides,
      })
    ))
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
  local versionCache = CacheFs.forVersion(versionId)
  local menuText = FieldTextRenderer.new({ cacheFs = versionCache })
  local rendererOk, menuRendererOrError = pcall(MainMenuRenderer.new, { text = menuText, versionId = versionId })
  if not rendererOk then
    menuText:release()
    error(menuRendererOrError, 0)
  end
  game:setState(MainMenuState.new({
    saveStore = saveStore,
    readyVersions = { versionId },
    width = width,
    height = height,
    renderer = assert(menuRendererOrError),
    onResult = onMenuResult,
    displayContext = displayContext,
    overrides = presentationOverrides ~= nil and presentationOverrides.main_menu or nil,
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
