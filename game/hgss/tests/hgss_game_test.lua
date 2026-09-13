-- Component coverage for the concrete HGSS application entry. It exercises
-- production Main Menu routing while observing existing composition seams.

local Assert = require("tests.support.Assert")

local T = {}

local READY_VERSION = "heartgold"

local function loadApplicationModules()
  local ok, hgssGameOrError = pcall(require, "game.hgss.src.HgssGame")
  Assert.isTrue(ok, "the concrete HGSS application must provide its entry: " .. tostring(hgssGameOrError))
  local okGame, gameOrError = pcall(require, "game.src.Game")
  Assert.isTrue(okGame, "the HGSS application must compose the generic game host: " .. tostring(gameOrError))
  local okField, fieldOrError = pcall(require, "game.hgss.src.field.FieldState")
  Assert.isTrue(okField, "the HGSS application must own FieldState: " .. tostring(fieldOrError))
  local okInit, initOrError = pcall(require, "game.hgss.src.newgame.NewGameInitialization")
  Assert.isTrue(okInit, "the HGSS application must own new-game initialization: " .. tostring(initOrError))
  local okMenu, menuOrError = pcall(require, "game.hgss.src.menu.MainMenuState")
  Assert.isTrue(okMenu, "the HGSS application must own Main Menu: " .. tostring(menuOrError))
  local okValidation, validationOrError = pcall(require, "game.hgss.src.save.GameSaveValidation")
  Assert.isTrue(okValidation, "the HGSS application must own save validation: " .. tostring(validationOrError))
  local okStore, storeOrError = pcall(require, "libs.hgss.src.save.GameSaveStore")
  Assert.isTrue(okStore, "the HGSS application must compose the save store: " .. tostring(storeOrError))
  local okNewGame, newGameOrError = pcall(require, "game.hgss.src.newgame.NewGame")
  Assert.isTrue(okNewGame, "the HGSS application must compose New Game: " .. tostring(newGameOrError))
  local okOak, oakOrError = pcall(require, "game.hgss.src.newgame.OakIntroComposition")
  Assert.isTrue(okOak, "the HGSS application must compose Oak: " .. tostring(oakOrError))
  return {
    hgssGame = hgssGameOrError,
    game = gameOrError,
    fieldState = fieldOrError,
    initialization = initOrError,
    menu = menuOrError,
    validation = validationOrError,
    store = storeOrError,
    newGame = newGameOrError,
    oak = oakOrError,
  }
end

local function fakeStore(entries)
  local store = { entries = entries, loads = {}, deletes = {} }
  function store:listMetadata()
    return self.entries
  end
  function store:load(saveId)
    self.loads[#self.loads + 1] = saveId
    for _, entry in ipairs(self.entries) do
      if entry.saveId == saveId then
        return entry
      end
    end
    error("missing fake save " .. saveId)
  end
  function store:delete(saveId)
    self.deletes[#self.deletes + 1] = saveId
    return true
  end
  return store
end

local function readyHost()
  return {
    requestMilestone = function()
      return true
    end,
    requestField = function()
      return true
    end,
    ensureField = function()
      return true
    end,
    requestCell = function()
      return true
    end,
    ensureCell = function()
      return true
    end,
    requestMonPortraitPage = function()
      return true
    end,
    status = function()
      return {}
    end,
  }
end

local function planningLoader()
  return {
    requestLocation = function()
      return true
    end,
    globalPosition = function(_, _, fieldX, fieldZ)
      return { x = fieldX, z = fieldZ }
    end,
  }
end

local function settle(game)
  for _ = 1, 10 do
    game:update(1 / 60)
  end
end

local function saveRecord(saveId)
  return {
    saveId = saveId,
    versionId = READY_VERSION,
    playerData = { profile = { name = "GOLD" } },
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
  }
end

local function disposableState(kind)
  local state = { kind = kind, disposed = 0 }
  function state:dispose()
    self.disposed = self.disposed + 1
  end
  return state
end

-- All monkey patches are restored after the callback, including when a
-- constructor or assertion fails.
local function withCompositionSpies(fn)
  local modules = loadApplicationModules()
  local original = {
    fieldNew = modules.fieldState.new,
    apply = modules.initialization.apply,
    validationNew = modules.validation.new,
    storeNew = modules.store.new,
    candidate = modules.newGame.createCandidate,
    oakCompose = modules.oak.compose,
  }
  local context
  context = {
    fieldCalls = {},
    applyCalls = {},
    validationCalls = {},
    storeCalls = {},
    candidateCalls = {},
    oakCalls = {},
    stores = {},
    validationFactory = function(_)
      return {
        validate = function(_, record)
          return record
        end,
      }
    end,
    storeFactory = function(_, index)
      return assert(context.stores[index], "test store not configured")
    end,
    candidateFactory = function(_)
      return assert(context.candidate, "test candidate not configured")
    end,
    oakFactory = function(_)
      return assert(context.oakState, "test Oak state not configured")
    end,
  }

  modules.fieldState.new = function(game, options)
    context.fieldCalls[#context.fieldCalls + 1] = { game = game, options = options }
    return disposableState("field")
  end
  rawset(modules.initialization, "apply", function(game)
    context.applyCalls[#context.applyCalls + 1] = game
    return game
  end)
  modules.validation.new = function(options)
    context.validationCalls[#context.validationCalls + 1] = options
    return context.validationFactory(options)
  end
  rawset(modules.store, "new", function(fs, options)
    context.storeCalls[#context.storeCalls + 1] = { fs = fs, options = options }
    return context.storeFactory(fs, #context.storeCalls)
  end)
  rawset(modules.newGame, "createCandidate", function(options)
    context.candidateCalls[#context.candidateCalls + 1] = options
    return context.candidateFactory(options)
  end)
  rawset(modules.oak, "compose", function(options)
    context.oakCalls[#context.oakCalls + 1] = options
    return context.oakFactory(options)
  end)
  local ok, err = pcall(function()
    fn(modules, context)
  end)

  modules.fieldState.new = original.fieldNew
  rawset(modules.initialization, "apply", original.apply)
  modules.validation.new = original.validationNew
  rawset(modules.store, "new", original.storeNew)
  rawset(modules.newGame, "createCandidate", original.candidate)
  rawset(modules.oak, "compose", original.oakCompose)
  if not ok then
    error(err, 0)
  end
end

local function menuView(menu)
  return assert(menu:view())
end

function T.hgss_entry_owns_menu_continue_new_game_oak_and_quit_routing()
  withCompositionSpies(function(modules, context)
    local exits = {}
    local continueRecord = saveRecord("save-00000002")
    context.stores[1] = fakeStore({ continueRecord })
    context.stores[2] = fakeStore({})
    context.stores[3] = fakeStore({})
    local candidate = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = nil,
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    local finalized = {
      saveId = candidate.saveId,
      versionId = READY_VERSION,
      playerData = {},
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    context.candidate = candidate
    context.candidateFactory = function(options)
      Assert.equal(options.saveService, context.stores[2])
      Assert.equal(options.versionId, READY_VERSION)
      Assert.notNil(options.eventState)
      Assert.notNil(options.scriptSymbols)
      Assert.deepEqual(options.mapIdentity, {
        mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
        fieldX = 6,
        fieldZ = 6,
        sourceFacing = 1,
      })
      return candidate
    end
    context.oakState = disposableState("oak")
    context.oakFactory = function(options)
      Assert.equal(options.candidate, candidate)
      Assert.equal(options.versionId, READY_VERSION)
      Assert.isTrue(type(options.onComplete) == "function")
      return context.oakState
    end

    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      development = false,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    Assert.equal(getmetatable(game).__index, modules.game)
    Assert.equal(getmetatable(game.state).__index, modules.menu)
    Assert.equal(menuView(game.state).kind, "main_menu")
    Assert.equal(#context.validationCalls, 1)
    Assert.equal(#context.storeCalls, 1)

    game.state:keypressed("down")
    game.state:keypressed("return")
    Assert.equal(#context.fieldCalls, 0, "Continue waits for core and geometry before strict load")
    settle(game)
    Assert.equal(#context.fieldCalls, 1)
    Assert.equal(context.fieldCalls[1].game, continueRecord)
    Assert.deepEqual(context.stores[1].loads, { continueRecord.saveId })
    Assert.equal(type(context.storeCalls[1].options.recordValidate), "function")
    local firstField = game.state
    game:setState(nil)
    Assert.equal(firstField.disposed, 1)

    local newGame = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      development = true,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    newGame.state:keypressed("return")
    Assert.equal(#context.candidateCalls, 1)
    Assert.equal(#context.oakCalls, 1)
    context.oakCalls[1].onComplete(finalized)
    Assert.equal(#context.applyCalls, 1)
    Assert.equal(context.applyCalls[1], finalized)
    Assert.equal(#context.fieldCalls, 1, "the handoff requests core and geometry before constructing field")
    settle(newGame)
    Assert.equal(#context.fieldCalls, 2)
    Assert.equal(context.fieldCalls[2].game, finalized)
    Assert.isTrue(context.fieldCalls[2].options.development)
    Assert.equal(context.oakState.disposed, 1)
    newGame:setState(nil)

    local quitGame = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    quitGame.state:keypressed("escape")
    Assert.deepEqual(exits, { { kind = "quit" } })
    quitGame:dispose()
  end)
end

function T.cancelling_field_preparation_returns_to_the_menu_without_publishing()
  withCompositionSpies(function(modules, context)
    local continueRecord = saveRecord("save-00000002")
    context.stores[1] = fakeStore({ continueRecord })
    local pending = true
    local host = readyHost()
    host.requestMilestone = function()
      return not pending
    end
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = host,
      fieldMapLoader = planningLoader(),
    })
    game.state:keypressed("down")
    game.state:keypressed("return")
    settle(game)
    Assert.equal(#context.fieldCalls, 0, "pending core never constructs the field")
    game.state:keypressed("escape")
    Assert.equal(getmetatable(game.state).__index, modules.menu, "cancellation returns to the owning menu")
    Assert.equal(#context.fieldCalls, 0, "cancellation publishes no field")
    pending = false
    settle(game)
    Assert.equal(#context.fieldCalls, 0, "a cancelled preparation never transfers late")
    game:dispose()
  end)
end

return { tests = T }
