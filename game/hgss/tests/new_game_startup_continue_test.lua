-- The generated fresh-game startup initializer is a fresh-New-Game-only
-- transition: the HGSS game entry must invoke it on the Oak completion handoff
-- and must never invoke it on Continue.

local Assert = require("tests.support.Assert")
local HgssGame = require("game.hgss.src.HgssGame")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")

local T = {}

local function controllerFor(candidate)
  local controller = { phase = "opening_wait", started = 0, disposed = 0 }
  function controller:start()
    self.started = self.started + 1
  end
  function controller:tick() end
  function controller:press() end
  function controller:inputText() end
  function controller:deleteGlyph() end
  function controller:dispose()
    self.disposed = self.disposed + 1
  end
  function controller:view()
    return {
      phase = self.phase,
      name = "GOLD",
      message = "generated",
      visual = "background",
      genderFocus = 0,
      nameInputEnabled = false,
    }
  end
  function controller:result()
    return candidate
  end
  return controller
end

local function withSpies(fn)
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local originalApply = NewGameInitialization.apply
  local originalFieldStateNew = FieldState.new
  local originalValidationNew = GameSaveValidation.new
  local originalStoreNew = GameSaveStore.new
  local originalCandidate = NewGame.createCandidate
  local originalOakCompose = OakIntroComposition.compose
  local applyCalls = {}
  local fieldStateCalls = {}
  local context = { stores = {}, candidates = {}, oakStates = {}, fieldOptions = {} }
  rawset(NewGameInitialization, "apply", function(candidate, _)
    applyCalls[#applyCalls + 1] = candidate
    local artifact = {
      schema = DerivedAssetContract.newGameInit.schema,
      versionId = candidate.versionId or "heartgold",
      operations = {
        {
          op = "set_flag",
          id = FieldScriptSymbols.flagsByName.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY,
          symbol = "FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY",
        },
        {
          op = "set_flag",
          id = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND,
          symbol = "FLAG_HIDE_NEW_BARK_FRIEND",
        },
      },
      sourceDependency = { standardScriptMember = 0, sha1 = "0000000000000000000000000000000000000000" },
    }
    return originalApply(candidate, artifact)
  end)
  FieldState.new = function(game, options)
    fieldStateCalls[#fieldStateCalls + 1] = game
    context.fieldOptions[#context.fieldOptions + 1] = options
    return { dispose = function() end }
  end
  rawset(GameSaveValidation, "new", function()
    return {
      validate = function(_, record)
        return record
      end,
    }
  end)
  rawset(GameSaveStore, "new", function()
    return assert(context.store, "test save store not configured")
  end)
  rawset(NewGame, "createCandidate", function()
    return assert(context.candidate, "test candidate not configured")
  end)
  rawset(OakIntroComposition, "compose", function(options)
    local state = assert(context.oakState, "test Oak state not configured")
    state.onComplete = options.onComplete
    return state
  end)

  local ok, err = pcall(function()
    fn(applyCalls, fieldStateCalls, context)
  end)
  rawset(NewGameInitialization, "apply", originalApply)
  FieldState.new = originalFieldStateNew
  rawset(GameSaveValidation, "new", originalValidationNew)
  rawset(GameSaveStore, "new", originalStoreNew)
  rawset(NewGame, "createCandidate", originalCandidate)
  rawset(OakIntroComposition, "compose", originalOakCompose)
  if not ok then
    error(err, 0)
  end
end

local function newGame(context, candidate)
  local controller = controllerFor(candidate)
  context.candidate = candidate
  context.oakState = { controller = controller, completed = false }
  function context.oakState:keypressed() end
  function context.oakState:update()
    if controller.phase == "complete" and not self.completed then
      self.completed = true
      self.onComplete(candidate)
    end
  end
  function context.oakState:dispose() end
  local game = HgssGame.new({
    versionId = "heartgold",
    onExit = function() end,
  })
  return game, controller
end

function T.fresh_oak_completion_applies_startup_initialization_before_field_state()
  withSpies(function(applyCalls, fieldStateCalls, context)
    local worldState = FieldEventState.new()
    local candidate = { saveId = "save-00000001", versionId = "heartgold", playerData = {}, worldState = worldState }
    context.store = {
      list = function()
        return {}
      end,
    }
    local game, controller = newGame(context, candidate)
    game.state:keypressed("return")
    controller.phase = "complete"
    game:update(0)
    Assert.equal(#applyCalls, 1, "fresh Oak completion must apply generated startup initialization exactly once")
    Assert.equal(applyCalls[1], candidate)
    Assert.equal(#fieldStateCalls, 1)
    Assert.equal(fieldStateCalls[1], candidate, "field construction must receive the initialized candidate")
    Assert.isTrue(
      fieldStateCalls[1].worldState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY),
      "source startup hide flag must be established before first FieldState.new"
    )
    Assert.isTrue(
      fieldStateCalls[1].worldState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND),
      "New Bark friend hide flag must be established before first FieldState.new"
    )
    game:dispose()
  end)
end

function T.continue_never_reapplies_fresh_startup_initialization()
  withSpies(function(applyCalls, fieldStateCalls, context)
    local clearedFlagGame = {
      saveId = "save-00000002",
      versionId = "heartgold",
      playerData = { profile = { name = "GOLD" } },
      playTimeSeconds = 0,
      world = { flags = { [FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND] = false } },
    }
    local store = {
      list = function()
        return { clearedFlagGame }
      end,
      load = function()
        return clearedFlagGame
      end,
    }
    context.store = store
    local game = HgssGame.new({
      versionId = "heartgold",
      onExit = function() end,
    })
    game.state:keypressed("down")
    game.state:keypressed("return")
    Assert.equal(#applyCalls, 0, "Continue must never invoke fresh startup initialization")
    Assert.equal(#fieldStateCalls, 1)
    Assert.equal(fieldStateCalls[1], clearedFlagGame)
    Assert.isFalse(
      fieldStateCalls[1].world.flags[FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND],
      "a cleared progression flag must survive Continue unchanged"
    )
    game:dispose()
  end)
end

function T.fresh_oak_completion_requests_the_covered_field_entry()
  withSpies(function(_, fieldStateCalls, context)
    local worldState = FieldEventState.new()
    local candidate = { saveId = "save-00000001", versionId = "heartgold", playerData = {}, worldState = worldState }
    context.store = {
      list = function()
        return {}
      end,
    }
    local game, controller = newGame(context, candidate)
    game.state:keypressed("return")
    controller.phase = "complete"
    game:update(0)
    Assert.equal(#fieldStateCalls, 1)
    local options = assert(context.fieldOptions[1], "a new-game field entry must carry presentation options")
    Assert.isTrue(options.initialFadeIn == true, "a new-game Oak handoff must request the covered field entry")
    Assert.isTrue(
      fieldStateCalls[1].worldState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY),
      "startup initialization is still applied before covered field construction"
    )
    game:dispose()
  end)
end

function T.continue_enters_the_field_without_the_covered_entry()
  withSpies(function(_, fieldStateCalls, context)
    local clearedFlagGame = {
      saveId = "save-00000002",
      versionId = "heartgold",
      playerData = { profile = { name = "GOLD" } },
      playTimeSeconds = 0,
      world = { flags = { [FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND] = false } },
    }
    local store = {
      list = function()
        return { clearedFlagGame }
      end,
      load = function()
        return clearedFlagGame
      end,
    }
    context.store = store
    local game = HgssGame.new({
      versionId = "heartgold",
      onExit = function() end,
    })
    game.state:keypressed("down")
    game.state:keypressed("return")
    Assert.equal(#fieldStateCalls, 1)
    local options = context.fieldOptions[1] or {}
    Assert.isTrue(options.initialFadeIn ~= true, "an ordinary Continue must never request the new-game covered entry")
    game:dispose()
  end)
end

-- Fixtures below drive a real Oak controller/state pair through the production
-- HgssGame handoff route, so the ordering proof uses the same composition the
-- running game uses: Oak draws, the completion callback, startup
-- initialization, field construction, and the first field draw.

local HANDOFF_MANIFEST = {
  schemaVersion = 7,
  sourceReference = { width = 256, height = 192 },
  background = { width = 256, height = 192, sampling = "linear" },
  widgets = {
    oak = {
      width = 80,
      height = 100,
      anchor = { x = 20, y = 100 },
      sourceBounds = { x = 40, y = 30, width = 80, height = 100 },
    },
    gender_male = {
      width = 64,
      height = 96,
      anchor = { x = 32, y = 48 },
      sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
    },
    gender_female = {
      width = 64,
      height = 96,
      anchor = { x = 32, y = 48 },
      sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
    },
    male = {
      width = 96,
      height = 120,
      anchor = { x = 48, y = 120 },
      sourceBounds = { x = 36, y = 24, width = 96, height = 120 },
    },
    shrink_male = {
      width = 44,
      height = 68,
      anchor = { x = 22, y = 68 },
      sourceBounds = { x = 142, y = 70, width = 44, height = 68 },
    },
  },
}

local HANDOFF_MESSAGES = {
  ["greeting.day"] = "greeting.day",
  ["oak.welcome"] = "oak.welcome",
  ["oak.world_inhabited"] = "oak.world_inhabited",
  ["oak.live_alongside"] = "oak.live_alongside",
  ["oak.tell_about_yourself"] = "oak.tell_about_yourself",
  ["profile.gender_question"] = "profile.gender_question",
  ["profile.gender_confirm.male"] = "profile.gender_confirm.male",
  ["profile.name_prompt"] = "profile.name_prompt",
  ["profile.name_confirm.male"] = "profile.name_confirm.male",
  ["profile.final"] = "profile.final",
}

local HANDOFF_PLAYER_DATA_CONTEXT = {
  charmap = { A = 1, B = 2, C = 3, D = 4, E = 5, F = 6, G = 7, O = 8, L = 9, [" "] = 10 },
  frameIndexes = { [0] = true },
}

local function handoffAudio()
  return {
    playMusic = function() end,
    stopMusic = function() end,
    fadeMusicOut = function() end,
    play = function() end,
    playCry = function() end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return false
    end,
  }
end

local function handoffClock()
  return {
    nowLocal = function()
      return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
    end,
  }
end

local function handoffShrinkFrames(duration, count)
  local frames = {}
  for index = 1, count do
    frames[index] = { duration = duration }
  end
  return { frames = frames }
end

local function buildHandoffOak(timeline, candidate)
  local controller = OakIntroController.new({
    candidate = candidate,
    clock = handoffClock(),
    audio = handoffAudio() --[[@as GameSound]],
    messages = HANDOFF_MESSAGES,
    assets = {
      marill = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      marill_appear = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      ball_open = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      male = { frames = { { duration = 1 } } },
      shrink_male = handoffShrinkFrames(9, 4),
    },
    virtualGlyphs = { "A", "B", "C", "D", "E", "F", "G", "O", "L" },
    playerDataContext = HANDOFF_PLAYER_DATA_CONTEXT,
    randomU32 = function()
      return 0x12345678
    end,
  })
  local renderer = {
    draw = function(_, view)
      timeline[#timeline + 1] = { kind = "oak_draw", phase = view.phase, alpha = view.finalFadeAlpha }
    end,
    dispose = function() end,
  }
  local choiceText = {
    release = function() end,
  }
  local state = OakIntroState.new({
    controller = controller,
    manifest = HANDOFF_MANIFEST,
    textRenderer = {},
    choiceText = choiceText,
    renderer = renderer,
    textInputHost = {
      setTextInput = function() end,
    },
    glyphs = { "A", "B", "C", "D", "E", "F", "G", "O", "L" },
    width = 640,
    height = 480,
  })
  return state, controller
end

local function completeHandoffMessage(controller)
  local key = assert(controller:view().messageKey, "the Oak handoff drive expected an active message")
  return controller:messageCompleted(key)
end

local function driveToFreshFullArtHold(state, controller)
  state:tick(40)
  completeHandoffMessage(controller)
  state:tick(6 + 30)
  completeHandoffMessage(controller)
  state:tick(26)
  completeHandoffMessage(controller)
  while controller:view().phase ~= "oak_live_alongside" do
    state:tick(1)
  end
  completeHandoffMessage(controller)
  while controller:view().phase ~= "oak_tell_about_yourself" do
    state:tick(1)
  end
  completeHandoffMessage(controller)
  completeHandoffMessage(controller)
  state:tick(26)
  controller:press("confirm")
  completeHandoffMessage(controller)
  controller:press("confirm")
  completeHandoffMessage(controller)
  state:tick(40)
  controller:inputText("GOLD")
  controller:press("submit")
  state:tick(26)
  completeHandoffMessage(controller)
  controller:press("confirm")
  completeHandoffMessage(controller)
  Assert.equal(controller:view().phase, "final_fade_out")
  state:tick(1)
  Assert.equal(controller:view().phase, "final_full_art_fade_in")
  state:tick(1)
  Assert.equal(controller:view().phase, "final_full_art_hold")
end

local function timelineKindCount(timeline, kind)
  local total = 0
  for _, entry in ipairs(timeline) do
    if entry.kind == kind then
      total = total + 1
    end
  end
  return total
end

local function firstTimelineIndex(timeline, kind, predicate)
  for index, entry in ipairs(timeline) do
    if entry.kind == kind and (predicate == nil or predicate(entry)) then
      return index
    end
  end
  return nil
end

-- Destination construction must wait for an actually presented full-black Oak
-- frame: the recorded timeline has to show the black Oak draw before the
-- completion callback, startup initialization, field construction, and the
-- first field draw, in that order.
function T.presented_oak_black_draw_precedes_field_construction()
  local partialCandidate = NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000017"
      end,
    },
    versionId = "heartgold",
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
  })
  withSpies(function(applyCalls, fieldStateCalls, context)
    local timeline = {}
    local oakState, oakController = buildHandoffOak(timeline, partialCandidate)
    context.candidate = partialCandidate
    context.oakState = oakState
    context.store = {
      list = function()
        return {}
      end,
    }
    local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
    local spiedApply = NewGameInitialization.apply
    rawset(NewGameInitialization, "apply", function(candidate, artifact)
      timeline[#timeline + 1] = { kind = "apply" }
      return spiedApply(candidate, artifact)
    end)
    local spiedFieldNew = FieldState.new
    FieldState.new = function(record, options)
      local field = spiedFieldNew(record, options)
      timeline[#timeline + 1] = { kind = "field_new" }
      field.draw = function()
        timeline[#timeline + 1] = { kind = "field_draw" }
      end
      field.update = function() end
      return field
    end
    local game = HgssGame.new({
      versionId = "heartgold",
      onExit = function() end,
    })
    game.state:keypressed("return")
    local routedComplete = assert(oakState.onComplete, "the Oak handoff must carry the production completion route")
    oakState.onComplete = function(result)
      timeline[#timeline + 1] = { kind = "oak_complete" }
      return routedComplete(result)
    end
    driveToFreshFullArtHold(oakState, oakController)
    for _ = 1, 300 do
      game:update(1 / 30)
      game:draw()
      if timelineKindCount(timeline, "field_draw") >= 1 then
        break
      end
    end
    Assert.equal(#applyCalls, 1, "the Oak handoff must apply startup initialization exactly once")
    Assert.equal(#fieldStateCalls, 1, "the Oak handoff must construct the destination field exactly once")
    local blackDraw = firstTimelineIndex(timeline, "oak_draw", function(entry)
      return entry.alpha >= 1 - 1e-9 and entry.phase ~= "complete"
    end)
    Assert.notNil(blackDraw, "a presented full-black Oak frame must be drawn before field construction")
    local completed = firstTimelineIndex(timeline, "oak_complete")
    local applied = firstTimelineIndex(timeline, "apply")
    local constructed = firstTimelineIndex(timeline, "field_new")
    local revealed = firstTimelineIndex(timeline, "field_draw")
    Assert.notNil(completed, "the Oak completion callback must run")
    Assert.notNil(applied, "startup initialization must run")
    Assert.notNil(constructed, "field construction must run")
    Assert.notNil(revealed, "the constructed field must draw its first frame")
    Assert.isTrue(assert(blackDraw) < assert(completed), "the full-black Oak draw must precede the completion callback")
    Assert.isTrue(assert(completed) < assert(applied), "completion must precede startup initialization")
    Assert.isTrue(assert(applied) < assert(constructed), "startup initialization must precede field construction")
    Assert.isTrue(assert(constructed) < assert(revealed), "field construction must precede the first field draw")
    game:dispose()
  end)
end

-- Continue carries no Oak handoff: the field is constructed immediately on the
-- menu result, without composing the intro, presenting any black frame, or
-- running fresh-game initialization.
function T.continue_constructs_the_field_without_the_oak_handoff()
  withSpies(function(applyCalls, fieldStateCalls, context)
    local clearedFlagGame = {
      saveId = "save-00000002",
      versionId = "heartgold",
      playerData = { profile = { name = "GOLD" } },
      playTimeSeconds = 0,
      world = { flags = { [FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND] = false } },
    }
    context.store = {
      list = function()
        return { clearedFlagGame }
      end,
      load = function()
        return clearedFlagGame
      end,
    }
    context.oakState = { dispose = function() end }
    local spiedCompose = OakIntroComposition.compose
    local composeCalls = 0
    rawset(OakIntroComposition, "compose", function(options)
      composeCalls = composeCalls + 1
      return spiedCompose(options)
    end)
    local game = HgssGame.new({
      versionId = "heartgold",
      onExit = function() end,
    })
    game.state:keypressed("down")
    game.state:keypressed("return")
    Assert.equal(composeCalls, 0, "Continue must never compose the Oak handoff")
    Assert.equal(#applyCalls, 0, "Continue must never invoke fresh startup initialization")
    Assert.equal(#fieldStateCalls, 1, "Continue must construct the field immediately without the handoff barrier")
    game:dispose()
  end)
end

return { tests = T }
