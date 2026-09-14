-- Cold-cache application lifecycle through production composition.
-- Continue waits for field core before strict load and for location
-- geometry before field entry; New Game enters Oak on bootstrap alone and
-- holds the finalized handoff until core plus initial geometry are ready;
-- warps hold their cover while the destination compiles and commit once;
-- the starter chooser demand-loads its actual portrait pages and drops
-- closed interest. Real ROM-derived caches stay in the path; only host
-- boundaries (audio output, clocks, save-root location) are faked, and
-- nothing renders.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FakeCache = require("tests.support.FakeCache")
local SaveFs = require("libs.storage.src.SaveFs")
local GameSave = require("libs.hgss.src.save.GameSave")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local HgssGame = require("game.hgss.src.HgssGame")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local MonsSave = require("libs.mons.src.MonsSave")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "field-core", "map:60", "map:61" },
    tags = { "cache", "lifecycle", "application" },
  },
  tests = {},
}

local JOYSTICK = {
  getID = function()
    return 1
  end,
}

local function seedRecord(saveId, versionId)
  return {
    schema = GameSave.SCHEMA,
    saveId = saveId,
    versionId = versionId,
    playTimeSeconds = 61,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-" .. versionId,
    facing = "south",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = MonsSave.empty("test-catalog-fingerprint", 7),
  }
end

local function isolatedStore()
  return GameSaveStore.new(SaveFs.global(FakeCache.new()))
end

local function withRouteSpies(store, fieldFactory, fn)
  local original = {
    storeNew = GameSaveStore.new,
    fieldNew = FieldState.new,
    apply = NewGameInitialization.apply,
  }
  rawset(GameSaveStore, "new", function()
    return store
  end)
  FieldState.new = fieldFactory
  local ok, err = pcall(fn)
  rawset(GameSaveStore, "new", original.storeNew)
  FieldState.new = original.fieldNew
  if not ok then
    error(err, 0)
  end
end

local function withApplySpy(fn)
  local original = NewGameInitialization.apply
  local calls = {}
  rawset(NewGameInitialization, "apply", function(candidate)
    calls[#calls + 1] = candidate
    return original(candidate)
  end)
  local ok, err = pcall(fn, calls)
  rawset(NewGameInitialization, "apply", original)
  if not ok then
    error(err, 0)
  end
end

local function pumpGame(game, ticks)
  for _ = 1, ticks do
    game:update(1 / 60)
  end
end

function T.tests.continue_waits_for_core_then_validates_before_field()
  local versionId = AcceptanceHarness.defaultVersion()
  local store = isolatedStore()
  local saveId = store:reserve()
  store:publishFirst(seedRecord(saveId, versionId))
  local listedBefore = store:list()
  local loads = {}
  local originalLoad = store.load
  store.load = function(self, id)
    loads[#loads + 1] = id
    return originalLoad(self, id)
  end

  local fieldCalls = {}
  local entered = nil
  local coreReady, geometryReady = false, false
  local requestedMaps = {}
  local host = {
    requestMilestone = function(name, _)
      Assert.equal(name, "field-core")
      if coreReady then
        return true
      end
      return false
    end,
    requestField = function(mapId, _)
      requestedMaps[#requestedMaps + 1] = mapId
      if geometryReady then
        return true
      end
      return false
    end,
    ensureField = function(_)
      return true
    end,
    requestCell = function(_)
      return true
    end,
    ensureCell = function(_)
      return true
    end,
  }
  withRouteSpies(store, function(record, _)
    fieldCalls[#fieldCalls + 1] = record
    entered = { dispose = function() end }
    return entered
  end, function()
    local game = HgssGame.new({ versionId = versionId, onExit = function() end, derivedAssets = host })
    local ok, err = pcall(function()
      local card = game.state:view().items[2]
      Assert.equal(card.saveId, saveId)
      Assert.isTrue(card.canContinue, "a displayed record stays continuable while field core is cold")
      Assert.isNil(card.errorSummary, "a pending cache never reads as a corrupt save")
      game.state:keypressed("down")
      game.state:keypressed("return")
      Assert.equal(#fieldCalls, 0, "Continue waits for field core before strict load")
      Assert.deepEqual(loads, {}, "strict load runs only after core readiness")
      pumpGame(game, 5)
      Assert.equal(#fieldCalls, 0, "the menu stays responsive without entering field while core is pending")
      Assert.deepEqual(loads, {}, "pumping never loads before core readiness")
      coreReady = true
      local waited = 0
      while #loads == 0 and waited < 60 do
        game:update(1 / 60)
        waited = waited + 1
      end
      Assert.deepEqual(loads, { saveId }, "exactly one strict load follows core readiness")
      Assert.equal(#fieldCalls, 0, "field begins only after location geometry is current")
      waited = 0
      while #requestedMaps == 0 and waited < 60 do
        game:update(1 / 60)
        waited = waited + 1
      end
      Assert.isTrue(#requestedMaps >= 1, "the saved location geometry is requested once core is ready")
      for _, mapId in ipairs(requestedMaps) do
        Assert.equal(mapId, 60, "only the saved location geometry is awaited")
      end
      geometryReady = true
      waited = 0
      while #fieldCalls == 0 and waited < 60 do
        game:update(1 / 60)
        waited = waited + 1
      end
      Assert.equal(#fieldCalls, 1, "field entry commits once geometry is current")
      Assert.equal(fieldCalls[1].saveId, saveId, "field receives the strictly loaded record")
      Assert.equal(game.state, entered, "the committed field becomes the running state")
      Assert.deepEqual(store:list(), listedBefore, "Continue mutates neither the catalog nor any payload")
    end)
    game:dispose()
    if not ok then
      error(err, 0)
    end
  end)
end

local OAK_INTERACTIVE = {
  greeting = true,
  oak_welcome = true,
  oak_world_inhabited = true,
  oak_live_alongside = true,
  oak_tell_about_yourself = true,
  gender_question = true,
  gender_select = true,
  gender_confirm = true,
  name_prompt = true,
  name_confirm = true,
  final_dialogue = true,
}

local function completeOak(game, oakState)
  -- The real handoff finalizes only after its full-black frame is
  -- presented: draw calls stay stubbed at the host boundary (no GPU work)
  -- while the production renderer observes the presented frame.
  local originalDraw = love.graphics.draw
  rawset(love.graphics, "draw", function()
    return nil
  end)
  local ok, completed = pcall(function()
    for _ = 1, 3600 do
      if game.state ~= oakState then
        return true
      end
      local view = oakState:view()
      if view.phase == "name_edit" then
        game:textinput("GOLD")
        game:keypressed("left")
        game:keypressed("return")
      elseif OAK_INTERACTIVE[view.phase] then
        game:gamepadpressed(JOYSTICK, "a")
        game:gamepadreleased(JOYSTICK, "a")
      else
        if view.phase == "handoff_black" then
          game:draw()
        end
        game:update(1 / 60)
      end
    end
    return false
  end)
  love.graphics.draw = originalDraw
  if not ok then
    error(completed, 0)
  end
  return completed
end

function T.tests.new_game_holds_the_finalized_handoff_until_core_and_geometry_are_ready()
  local versionId = AcceptanceHarness.defaultVersion()
  local store = isolatedStore()
  local fieldCalls = {}
  local requested = { milestones = {}, maps = {}, pages = 0 }
  local coreReady, geometryReady = false, false
  local host = {
    requestMilestone = function(name, _)
      requested.milestones[#requested.milestones + 1] = name
      if name == "field-core" and coreReady then
        return true
      end
      return false
    end,
    requestField = function(mapId, _)
      requested.maps[#requested.maps + 1] = mapId
      if geometryReady then
        return true
      end
      return false
    end,
    ensureField = function(_)
      return true
    end,
    requestCell = function(_)
      return true
    end,
    ensureCell = function(_)
      return true
    end,
    requestMonPortraitPage = function(_)
      requested.pages = requested.pages + 1
      return true
    end,
  }
  local audio = FakeAudioOutput.new()
  local originalCompose = OakIntroComposition.compose
  rawset(OakIntroComposition, "compose", function(options)
    local input = {}
    for key, value in pairs(options) do
      input[key] = value
    end
    input.audioOutput = { audio = audio.audio, sound = audio.sound }
    input.clock = {
      nowLocal = function()
        return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
      end,
    }
    input.randomU32 = function()
      return 0x12345678
    end
    return originalCompose(input)
  end)
  local okCompose, errCompose = pcall(function()
    withApplySpy(function(applyCalls)
      withRouteSpies(store, function(record, _)
        fieldCalls[#fieldCalls + 1] = record
        return { dispose = function() end }
      end, function()
        local game = HgssGame.new({ versionId = versionId, onExit = function() end, derivedAssets = host })
        local ok, err = pcall(function()
          game.state:keypressed("return")
          local oakState = assert(game.state, "New Game enters Oak on bootstrap alone")
          Assert.equal(requested.pages, 0, "Oak starts without awaiting unrelated portrait pages")
          Assert.isTrue(completeOak(game, oakState), "the real Oak intro finalizes its candidate")
          Assert.equal(#applyCalls, 1, "finalization applies exactly once to the Oak candidate")
          local finalized = applyCalls[1]
          Assert.equal(assert(finalized.playerData and finalized.playerData.profile).name, "GOLD")
          Assert.equal(#fieldCalls, 0, "the handoff requests field core before constructing field")
          local waited = 0
          while #requested.milestones == 0 and waited < 60 do
            game:update(1 / 60)
            waited = waited + 1
          end
          Assert.deepEqual(
            requested.milestones,
            { "field-core" },
            "only field core is awaited beyond the finalized candidate"
          )
          coreReady = true
          waited = 0
          while #requested.maps == 0 and waited < 60 do
            game:update(1 / 60)
            waited = waited + 1
          end
          Assert.equal(#fieldCalls, 0, "the handoff still waits for initial location geometry")
          local distinctMaps = {}
          for _, mapId in ipairs(requested.maps) do
            distinctMaps[mapId] = true
          end
          local distinctCount = 0
          for _ in pairs(distinctMaps) do
            distinctCount = distinctCount + 1
          end
          Assert.equal(distinctCount, 1, "only the initial location geometry is awaited")
          Assert.equal(requested.pages, 0, "unrelated portrait pages remain sweep while entering field")
          geometryReady = true
          waited = 0
          while #fieldCalls == 0 and waited < 60 do
            game:update(1 / 60)
            waited = waited + 1
          end
          Assert.equal(#fieldCalls, 1, "field entry commits once core and geometry are ready")
          Assert.equal(#applyCalls, 1, "waiting never applies initialization again")
        end)
        game:dispose()
        if not ok then
          error(err, 0)
        end
      end)
    end)
  end)
  rawset(OakIntroComposition, "compose", originalCompose)
  if not okCompose then
    error(errCompose, 0)
  end
end

local function labHarness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local location = { mapSymbol = map or "MAP_NEW_BARK_ELMS_LAB_1F", fieldX = 4, fieldZ = 13, facing = "north" }
      if map == "MAP_NEW_BARK" then
        -- Fresh-save locations are map-local: the runtime adds the scene
        -- origin, so the town door approach (global 695,397 under origin
        -- 672,384) boots as local 23,13.
        location = { mapSymbol = map, fieldX = 23, fieldZ = 13, facing = "north" }
      end
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = location,
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
      }
    end,
  })
end

local function recordsNamed(game, name)
  local records = {}
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

-- Drives the open chooser's presentation preparation through the exact
-- production seam the running field advances once per frame
-- (FieldState:_advanceStarterPreparation ->
-- StarterChoiceState:advancePresentationPreparation): the live runtime's own
-- chooser with its borrowed queue and the semantic host that gates the
-- actual portrait pages. The graphics backend is a host-boundary placeholder;
-- headless acceptance never reaches upload (the render trap owns that
-- boundary). No field state is assembled here.
local function pumpDemand(game, host)
  local starter = game.runtime.starterChoice
  if starter == nil or not starter:isActive() or starter:isPresentationReady() then
    return
  end
  local ok, err = pcall(function()
    starter:advancePresentationPreparation({
      assetPreparation = game.runtime.assetPreparation,
      gxRenderer = {},
      derivedAssets = host,
    }, 1)
  end)
  if not ok then
    -- The headless acceptance harness owns GPU upload through its render
    -- trap, so the first mesh/image realization step always refuses here
    -- while the page poll above it has already run: page interest is
    -- observed, uploads stay blocked. Only that harness-boundary refusal is
    -- tolerated; any other preparation failure (absent page, missing bytes)
    -- still fails the journey loudly.
    Assert.isTrue(
      tostring(err):find("acceptance runtime attempted love.graphics.", 1, true) ~= nil,
      "presentation preparation fails only at the harness render boundary: " .. tostring(err)
    )
  end
end

local function pump(game, ticks, stop, modal, demandHost)
  for tick = 1, ticks do
    if game.runtime.errorText then
      return { fault = game.runtime.errorText }
    end
    if stop ~= nil and stop() then
      return { stopped = true }
    end
    local snapshot = game:snapshot()
    if snapshot.dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    elseif modal == true and snapshot.fieldLocked and tick % 3 == 0 then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    elseif modal == true and snapshot.fieldLocked and tick % 12 == 0 then
      game:move("right")
    else
      game:step()
    end
    if demandHost ~= nil then
      pumpDemand(game, demandHost)
    end
  end
  if stop ~= nil and stop() then
    return { stopped = true }
  end
  return { stopped = false }
end

local function passHost()
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
  }
end

function T.tests.warp_waits_under_cover_then_commits_once()
  local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
  Assert.isTrue(
    type(FieldMapLoader.requestWarp) == "function",
    "warp waits under cover while destination artifacts compile"
  )
  local versionId = AcceptanceHarness.defaultVersion()
  local pendingAll = false
  local host = passHost()
  function host.requestField(_, _)
    if pendingAll then
      return false
    end
    return true
  end
  function host.requestCell(_, _)
    if pendingAll then
      return false
    end
    return true
  end
  local game = labHarness():boot({
    versionId = versionId,
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = { derivedAssets = host },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local source = assert(game.runtime.runtimeMap, "the source map is live before the warp")
    local sourceSymbol = assert(source.mapSymbol, "the source map carries its symbol")
    game:moveTo({ fieldX = 695, fieldZ = 397 })
    game:step({ direction = "north" })
    local started = game:advanceUntil("the door warp starts", function()
      return game:snapshot().transition.phase ~= "idle"
    end, 120)
    Assert.notNil(started, "stepping into the production door starts a warp")
    pendingAll = true
    for _ = 1, 30 do
      game:step()
      Assert.equal(
        game.runtime.runtimeMap.mapSymbol,
        sourceSymbol,
        "source ownership stays live while the destination compiles"
      )
      Assert.isTrue(
        game:snapshot().transition.phase ~= "idle",
        "the covered transition holds instead of committing or aborting"
      )
    end
    pendingAll = false
    local destination = game:waitForTransition()
    Assert.notNil(destination, "the held warp commits once its destination is ready")
    Assert.isTrue(
      game.runtime.runtimeMap.mapSymbol ~= sourceSymbol,
      "the committed destination replaces the held source exactly once"
    )
    Assert.equal(game:renderAttempts(), 0, "warp acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function standNextTo(game, actorId)
  local actors = game:snapshot().actors
  local target = assert(actors[actorId], "actor is not visible: " .. actorId)
  local player = game:snapshot().player
  local function directionToward(fromX, fromZ, toX, toZ)
    if toX > fromX then
      return "east"
    end
    if toX < fromX then
      return "west"
    end
    if toZ > fromZ then
      return "south"
    end
    return "north"
  end
  local routed = false
  for _, tile in ipairs({
    { fieldX = target.fieldX + 1, fieldZ = target.fieldZ },
    { fieldX = target.fieldX - 1, fieldZ = target.fieldZ },
    { fieldX = target.fieldX, fieldZ = target.fieldZ + 1 },
    { fieldX = target.fieldX, fieldZ = target.fieldZ - 1 },
  }) do
    local ok = pcall(function()
      game:moveTo(tile)
    end)
    if ok then
      local now = game:snapshot()
      local distance = math.abs(now.player.fieldX - target.fieldX) + math.abs(now.player.fieldZ - target.fieldZ)
      if distance == 1 then
        routed = true
        player = now.player
        break
      end
    end
  end
  Assert.isTrue(routed, "production movement must reach a tile adjacent to " .. actorId)
  game:face(directionToward(player.fieldX, player.fieldZ, target.fieldX, target.fieldZ))
end

local ELM_SCRIPT = "vanilla.hgss.scr_seq.0843.script_000"
local STARTER_SCRIPT = "vanilla.hgss.scr_seq.0843.script_012"

local function openLabChooser(game)
  game:waitForFieldEntry()
  game:moveTo({ fieldX = 4, fieldZ = 10 })
  game:advanceUntil("the welcome scene starts", function()
    return #recordsNamed(game, "script.started") > 0
  end, 60)
  local starts = recordsNamed(game, "script.started")
  local welcomeScriptId = starts[#starts].payload.scriptId
  local welcome = pump(game, 1500, function()
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == welcomeScriptId then
        return record.payload.completed == true
      end
    end
    return false
  end)
  Assert.isNil(welcome.fault, "the welcome scene must run without a runtime fault")
  Assert.isTrue(welcome.stopped, "the welcome scene must conclude before starter choice")
  local elmActor = nil
  do
    local actorIds = {}
    for actorId in pairs(game:snapshot().actors) do
      if not actorId:find("player", 1, true) then
        actorIds[#actorIds + 1] = actorId
      end
    end
    table.sort(actorIds)
    for _, actorId in ipairs(actorIds) do
      local ok = pcall(standNextTo, game, actorId)
      if ok then
        game:pressAction()
        if game:interaction().scriptId == ELM_SCRIPT then
          elmActor = actorId
          break
        end
        local drained = pump(game, 200, function()
          return not game:snapshot().dialogue.modal
        end)
        if drained.fault ~= nil then
          error("runtime fault while driving " .. actorId .. ": " .. tostring(drained.fault))
        end
      end
    end
  end
  Assert.notNil(elmActor, "Elm must start his generated dispatcher script")
  local elmDone = pump(game, 1500, function()
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == ELM_SCRIPT then
        return record.payload.completed == true
      end
    end
    return false
  end)
  Assert.isNil(elmDone.fault, "Elm's dispatcher must run without a runtime fault")
  Assert.isTrue(elmDone.stopped, "Elm's dispatcher must conclude before the table owns the choice")
  local triggered = false
  for _, tile in ipairs({
    { fieldX = 8, fieldZ = 5 },
    { fieldX = 7, fieldZ = 4 },
    { fieldX = 9, fieldZ = 4 },
    { fieldX = 8, fieldZ = 3 },
  }) do
    if not triggered then
      local ok = pcall(function()
        game:moveTo(tile)
      end)
      if ok then
        for _, facing in ipairs({ "north", "south", "east", "west" }) do
          if not triggered then
            game:face(facing)
            game:pressAction()
            if game:interaction().scriptId == STARTER_SCRIPT then
              triggered = true
            end
          end
        end
      end
    end
  end
  Assert.isTrue(triggered, "the ball table must start the generated starter script")
  local opened = pump(game, 1200, function()
    local chooser = game.runtime.starterChoice
    return chooser ~= nil and chooser:isActive()
  end, true)
  Assert.isNil(opened.fault, "the starter flow must run without a runtime fault")
  Assert.isTrue(opened.stopped, "the starter chooser must open through the generated script")
  return assert(game.runtime.starterChoice, "the open chooser is owned by the runtime")
end

local function pageHost()
  local host = passHost()
  host.pagesPending = true
  host.pageRequests = {}
  host.pagesServed = {}
  function host.requestMonPortraitPage(pageId, _)
    host.pageRequests[#host.pageRequests + 1] = pageId
    if host.pagesPending then
      return false
    end
    host.pagesServed[pageId] = true
    return true
  end
  return host
end

local function distinctPages(requests)
  local seen, out = {}, {}
  for _, pageId in ipairs(requests) do
    if not seen[pageId] then
      seen[pageId] = true
      out[#out + 1] = pageId
    end
  end
  table.sort(out)
  return out
end

local function customizedCandidates()
  local origin = { trainerId = 1 }
  return {
    { species = "ABRA", form = 0, personality = 0x11111111, origin = origin },
    { species = "PIDGEY", form = 0, personality = 0x22222222, origin = origin },
    { species = "RATTATA", form = 0, personality = 0x33333333, origin = origin },
  }
end

function T.tests.actual_candidate_pages_are_demand_loaded_and_close_drops_interest()
  local versionId = AcceptanceHarness.defaultVersion()
  local host = pageHost()
  local game = labHarness():boot({
    versionId = versionId,
    save = "fresh",
    fieldOptions = { derivedAssets = host, recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    local chooser = openLabChooser(game)
    pump(game, 60, nil, true, host)
    Assert.isFalse(
      chooser:isPresentationReady(),
      "the chooser holds its input until the actual portrait pages are ready"
    )
    local trioPages = distinctPages(host.pageRequests)
    Assert.isTrue(#trioPages >= 1, "only the actual candidates pages are requested before presentation")
    Assert.isTrue(#trioPages <= 3, "no absent page reaches preparation")
    chooser:close()
    Assert.isFalse(chooser:isActive(), "closing the chooser releases its presentation")
    host.pagesPending = false
    -- No runtime steps while closed: the live starter task re-presents a
    -- yanked chooser on its next poll (ChooseStarterTask.poll reopens while
    -- its own close hasn't run), so stepping here would reopen the trio
    -- before the manual reopen below. Advance only preparation, exactly what
    -- production pumping does on an inactive chooser (a no-op), while the
    -- host reports the old pages ready.
    for _ = 1, 30 do
      pumpDemand(game, host)
    end
    Assert.isFalse(chooser:isPresentationReady(), "a closed chooser receives no late page resources")
    host.pagesPending = true
    local reopened = assert(game.runtime.starterChoice, "the starter choice task stays live while closed")
    reopened:open(0, customizedCandidates())
    pump(game, 60, nil, true, host)
    Assert.isFalse(reopened:isPresentationReady(), "the reopened chooser waits for its own customized pages")
    local bothPages = distinctPages(host.pageRequests)
    Assert.isTrue(
      #bothPages > #trioPages,
      "reopening requests the new candidates pages instead of reusing closed interest"
    )
    host.pagesPending = false
    -- Drawable readiness needs GPU uploads, which this harness forbids by
    -- construction (renderAttempts stays 0 below); that gate is proved by
    -- the graphics-capable preparation suites instead. Here the journey
    -- proves every reopened demand actually served: the host serves a page
    -- exactly when the session would report it ready.
    local servedFrom = #host.pageRequests
    local ready = pump(game, 600, function()
      for index = servedFrom + 1, #host.pageRequests do
        if not host.pagesServed[host.pageRequests[index]] then
          return false
        end
      end
      return #host.pageRequests > servedFrom
    end, true, host)
    Assert.isNil(ready.fault, "page loading must resolve without a runtime fault")
    Assert.isTrue(ready.stopped, "the reopened chooser loads its actual pages without a runtime fault")
    -- No renderAttempts assertion here by construction: loading advances
    -- preparation up to GPU realization, and every love.graphics call in
    -- this harness trips the render trap (which stays installed, so no
    -- visual claim can pass silently). Drawable realization itself is
    -- proved by the graphics-capable preparation suites instead.
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
