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
  function store:list()
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

local function saveRecord(saveId)
  return {
    saveId = saveId,
    versionId = READY_VERSION,
    playerData = { profile = { name = "GOLD" } },
    playTimeSeconds = 0,
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
  local okText, textOrError = pcall(require, "libs.hgss.src.ui.FieldTextRenderer")
  Assert.isTrue(okText, "the Main Menu must render through FieldTextRenderer: " .. tostring(textOrError))
  local okRenderer, rendererOrError = pcall(require, "game.hgss.src.menu.MainMenuRenderer")
  Assert.isTrue(okRenderer, "the Main Menu must own its renderer: " .. tostring(rendererOrError))
  modules.fieldText = textOrError
  modules.menuRenderer = rendererOrError
  local original = {
    fieldNew = modules.fieldState.new,
    apply = modules.initialization.apply,
    validationNew = modules.validation.new,
    storeNew = modules.store.new,
    candidate = modules.newGame.createCandidate,
    oakCompose = modules.oak.compose,
    textNew = modules.fieldText.new,
    menuRendererNew = modules.menuRenderer.new,
  }
  local context
  context = {
    fieldCalls = {},
    applyCalls = {},
    validationCalls = {},
    storeCalls = {},
    candidateCalls = {},
    oakCalls = {},
    textCalls = {},
    menuRendererCalls = {},
    texts = {},
    menuRenderers = {},
    rendererFailure = nil,
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
  -- Headless composition never loads generated presentation assets: the
  -- required text/renderer constructors are replaced with strict fakes that
  -- observe wiring and ownership instead.
  local function fakeText()
    local text = { releases = 0, draws = 0 }
    function text:drawText()
      self.draws = self.draws + 1
    end
    function text:release()
      self.releases = self.releases + 1
    end
    return text
  end
  modules.fieldText.new = function(options)
    context.textCalls[#context.textCalls + 1] = options
    local text = fakeText()
    context.texts[#context.texts + 1] = text
    return text
  end
  modules.menuRenderer.new = function(options)
    context.menuRendererCalls[#context.menuRendererCalls + 1] = options
    if context.rendererFailure ~= nil then
      error(context.rendererFailure, 0)
    end
    Assert.equal(options.text, context.texts[#context.texts], "the menu renderer must own the composed menu text")
    local renderer = {
      text = options.text,
      draws = 0,
      disposed = 0,
    }
    function renderer:draw()
      self.draws = self.draws + 1
    end
    function renderer:dispose()
      self.disposed = self.disposed + 1
      if self.text and self.text.release then
        self.text:release()
      end
      self.text = nil
    end
    context.menuRenderers[#context.menuRenderers + 1] = renderer
    return renderer
  end
  local ok, err = pcall(function()
    fn(modules, context)
  end)

  modules.fieldState.new = original.fieldNew
  rawset(modules.initialization, "apply", original.apply)
  modules.validation.new = original.validationNew
  rawset(modules.store, "new", original.storeNew)
  rawset(modules.newGame, "createCandidate", original.candidate)
  rawset(modules.oak, "compose", original.oakCompose)
  modules.fieldText.new = original.textNew
  modules.menuRenderer.new = original.menuRendererNew
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
    local candidate = { saveId = "save-00000003", versionId = READY_VERSION, playerData = nil }
    local finalized = { saveId = candidate.saveId, versionId = READY_VERSION, playerData = {} }
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
    })
    Assert.equal(getmetatable(game).__index, modules.game)
    Assert.equal(getmetatable(game.state).__index, modules.menu)
    Assert.equal(menuView(game.state).kind, "main_menu")
    Assert.equal(#context.validationCalls, 1)
    Assert.equal(#context.storeCalls, 1)

    game.state:keypressed("down")
    game.state:keypressed("return")
    Assert.equal(#context.fieldCalls, 1)
    Assert.equal(context.fieldCalls[1].game, continueRecord)
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
    })
    newGame.state:keypressed("return")
    Assert.equal(#context.candidateCalls, 1)
    Assert.equal(#context.oakCalls, 1)
    context.oakCalls[1].onComplete(finalized)
    Assert.equal(#context.applyCalls, 1)
    Assert.equal(context.applyCalls[1], finalized)
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
    })
    quitGame.state:keypressed("escape")
    Assert.deepEqual(exits, { { kind = "quit" } })
    quitGame:dispose()
  end)
end

function T.menu_presentation_is_wired_from_fakes_and_released_exactly_once()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
    })
    Assert.equal(#context.textCalls, 1, "menu text construction must run once per game")
    Assert.equal(#context.menuRendererCalls, 1, "menu renderer construction must run once per game")
    Assert.equal(#context.texts, 1)
    Assert.equal(#context.menuRenderers, 1)
    local renderer = context.menuRenderers[1]
    Assert.equal(renderer.text, context.texts[1], "the fake renderer must own the fake menu text")
    Assert.equal(menuView(game.state).kind, "main_menu")
    game:dispose()
    Assert.equal(renderer.disposed, 1, "the menu renderer must be disposed exactly once")
    Assert.equal(context.texts[1].releases, 1, "the owned menu text must be released exactly once")
  end)
end

function T.menu_renderer_failure_releases_the_allocated_text_exactly_once()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    context.rendererFailure = "injected menu renderer failure"
    local ok, err = pcall(modules.hgssGame.new, {
      versionId = READY_VERSION,
      onExit = function() end,
    })
    Assert.isFalse(ok, "a menu renderer failure must fail game construction")
    Assert.isTrue(string.find(tostring(err), "injected menu renderer failure") ~= nil)
    Assert.equal(#context.texts, 1, "the text must be allocated before the renderer fails")
    Assert.equal(context.texts[1].releases, 1, "the allocated text must be released exactly once")
    Assert.equal(#context.menuRenderers, 0, "no menu renderer may escape a failed construction")
  end)
end

function T.composition_spies_restore_presentation_constructors_when_the_body_throws()
  local fieldText = require("libs.hgss.src.ui.FieldTextRenderer")
  local menuRenderer = require("game.hgss.src.menu.MainMenuRenderer")
  local textNew, rendererNew = fieldText.new, menuRenderer.new
  local ok, err = pcall(withCompositionSpies, function()
    error("injected composition body failure", 0)
  end)
  Assert.isFalse(ok, "the spy wrapper must rethrow the body failure")
  Assert.isTrue(string.find(tostring(err), "injected composition body failure") ~= nil)
  Assert.equal(fieldText.new, textNew, "the text constructor must be restored after a throw")
  Assert.equal(menuRenderer.new, rendererNew, "the menu renderer constructor must be restored after a throw")
end

return { tests = T }
