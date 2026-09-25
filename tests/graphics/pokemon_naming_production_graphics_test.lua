-- Renders the retail Elm starter naming flow through FieldState's production
-- runtime and presentation ownership.

local Assert = require("tests.support.Assert")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonBucket = require("tests.support.MonBucket")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local FIXED_DT = 1 / 30
local PREVENT_ESCAPE = FieldScriptSymbols.flagsByName.FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  Assert.isTrue(#versions > 0, "a ready ROM-derived cache is required")
  return versions
end

local function newGame(versionId)
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = { mapSymbol = LAB, fieldX = 4, fieldZ = 13, facing = "north" },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "fastest", textFrame = 0 },
    },
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = MonBucket.emptyForVersion(versionId),
    bag = BagSave.empty(),
  }
end

local function step(state)
  state:update(FIXED_DT)
  if state.runtime.session.mapEntryStage == "await_presentation" then
    state:draw()
  end
end

local function advanceUntil(state, label, predicate, bound)
  for _ = 1, bound do
    if predicate() then
      return
    end
    step(state)
  end
  local runtime = state.runtime
  error(
    "timed out waiting for "
      .. label
      .. " (mapEntryStage="
      .. tostring(runtime and runtime.session.mapEntryStage)
      .. ", map="
      .. tostring(runtime and runtime.runtimeMap and runtime.runtimeMap.mapSymbol)
      .. ", error="
      .. tostring(runtime and runtime.errorText)
      .. ")",
    0
  )
end

local function moveOne(state, direction)
  local runtime = assert(state.runtime)
  if runtime.player.facing ~= direction then
    runtime.player:turn(direction)
  end
  runtime:press(direction)
  step(state)
  runtime:release(direction)
  advanceUntil(state, "production movement to settle", function()
    return runtime.player.motion == "idle"
  end, 120)
end

local function moveTo(state, target)
  local game = { runtime = assert(state.runtime) }
  for _ = 1, 12 do
    local route, boundary = FieldMovement.route(game, target)
    if route ~= nil then
      for _, edge in ipairs(route) do
        moveOne(state, edge.direction)
      end
      return true
    end
    if boundary == nil then
      return false
    end
    for _, edge in ipairs(boundary.route) do
      moveOne(state, edge.direction)
    end
    moveOne(state, boundary.direction)
  end
  error("production movement did not reach " .. target.fieldX .. ":" .. target.fieldZ, 0)
end

local function advanceStory(state, bound)
  local runtime = assert(state.runtime)
  for _ = 1, bound do
    if runtime.errorText then
      error("retail Elm script faulted: " .. runtime.errorText, 0)
    end
    if runtime.dialogue:status().modal then
      runtime:pressAction()
      step(state)
      runtime:releaseAction()
    else
      step(state)
    end
  end
end

local function interactionAt(runtime)
  local player = runtime.player
  local intent = runtime.interactionResolver:resolve({
    runtimeMap = runtime.runtimeMap,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    surfaceId = player.surfaceId,
    worldY = player.worldY,
    facing = player.facing,
    tick = runtime.session.tick + 1,
  })
  local hit = intent and runtime.scripts.client:resolve(intent)
  return hit and hit.trigger.scriptId
end

local function face(state, direction)
  local runtime = assert(state.runtime)
  advanceUntil(state, "player movement to settle before facing", function()
    return runtime.player.motion == "idle"
  end, 120)
  runtime.player:turn(direction)
end

local function triggerScript(state, scriptId, targets)
  local runtime = assert(state.runtime)
  local seen = {}
  local neighbors = {
    { x = 0, z = -1, facing = "south" },
    { x = 0, z = 1, facing = "north" },
    { x = -1, z = 0, facing = "east" },
    { x = 1, z = 0, facing = "west" },
  }
  for _, target in ipairs(targets) do
    local positions = {}
    if target.interactionTile then
      positions[1] = { tile = target.tile }
    else
      for _, neighbor in ipairs(neighbors) do
        positions[#positions + 1] = {
          tile = { fieldX = target.tile.fieldX + neighbor.x, fieldZ = target.tile.fieldZ + neighbor.z },
          facing = neighbor.facing,
        }
      end
    end
    for _, position in ipairs(positions) do
      if moveTo(state, position.tile) then
        for _, direction in ipairs({ "north", "south", "east", "west" }) do
          face(state, position.facing or direction)
          local resolvedScriptId = interactionAt(runtime)
          seen[#seen + 1] = tostring(resolvedScriptId)
          if resolvedScriptId == scriptId then
            runtime:pressAction()
            step(state)
            runtime:releaseAction()
            return
          end
        end
      end
    end
  end
  error("retail interaction " .. scriptId .. " was not reachable: " .. table.concat(seen, ","), 0)
end

local function activeActors(runtime)
  local actors = {}
  for _, actor in ipairs(runtime.actors:actorsOf(runtime.runtimeMap.mapId)) do
    local position = actor:getFieldPosition()
    if actor.actorId:find("player", 1, true) == nil then
      actors[#actors + 1] = { tile = { fieldX = position.fieldX, fieldZ = position.fieldZ }, actor = actor }
    end
  end
  table.sort(actors, function(first, second)
    return first.actor.actorId < second.actor.actorId
  end)
  return actors
end

local function reachNaming(state)
  local runtime = assert(state.runtime)
  local firstModal
  advanceUntil(state, "lab map entry", function()
    return runtime.session.mapEntryStage == nil
  end, 240)

  -- Complete the real welcome trigger so Elm's source dispatcher and the
  -- counter's source starter script own their normal prerequisites.
  moveTo(state, { fieldX = 4, fieldZ = 10 })
  advanceStory(state, 1200)
  Assert.isTrue(runtime.scripts.worldState:isFlagSet(PREVENT_ESCAPE), "the retail welcome scene completed")
  triggerScript(state, "vanilla.hgss.scr_seq.0843.script_000", activeActors(runtime))
  advanceStory(state, 1500)

  -- The table's background interaction is a generated coordinate event.
  triggerScript(state, "vanilla.hgss.scr_seq.0843.script_012", {
    { tile = { fieldX = 8, fieldZ = 5 }, interactionTile = true },
    { tile = { fieldX = 7, fieldZ = 4 }, interactionTile = true },
    { tile = { fieldX = 9, fieldZ = 4 }, interactionTile = true },
    { tile = { fieldX = 8, fieldZ = 3 }, interactionTile = true },
  })
  for _ = 1, 9000 do
    if runtime.errorText then
      error("retail starter script faulted: " .. runtime.errorText, 0)
    end
    if runtime.pokemonNaming:isActive() then
      return
    end
    local contextChoice = runtime.contextChoiceProvider
    if contextChoice and contextChoice:isActive() then
      runtime:pressAction()
      step(state)
      runtime:releaseAction()
    elseif runtime.dialogue:status().modal or (runtime.starterChoice and runtime.starterChoice:isActive()) then
      if firstModal == nil then
        firstModal = runtime.dialogue:status()
      end
      runtime:pressAction()
      step(state)
      runtime:releaseAction()
    else
      step(state)
    end
  end
  local starter = runtime.starterChoice
  local scheduler = runtime.scripts.scheduler
  local tasks = scheduler:tasks()
  local activeTask = tasks[1]
  local lastInput = scheduler:currentInput()
  error(
    "retail starter script did not open the nickname screen (foreground="
      .. tostring(scheduler:foregroundScriptId())
      .. ", choice="
      .. tostring(starter and starter:isActive())
      .. ", presentationReady="
      .. tostring(starter and starter:isPresentationReady())
      .. ", dialogue="
      .. tostring(runtime.dialogue:status().modal)
      .. ", dialogState="
      .. tostring(runtime.dialogue:status().state)
      .. ", waiting="
      .. tostring(runtime.dialogue:status().waiting)
      .. ", boundary="
      .. tostring(runtime.dialogue:status().continuationKind)
      .. ", revealed="
      .. tostring(runtime.dialogue:status().revealedGlyphs)
      .. "/"
      .. tostring(runtime.dialogue:status().pageGlyphCount)
      .. ", firstState="
      .. tostring(firstModal and firstModal.state)
      .. ", choiceHost="
      .. tostring(runtime.contextChoiceProvider and runtime.contextChoiceProvider:isActive())
      .. ", player="
      .. tostring(runtime.player.fieldX)
      .. ":"
      .. tostring(runtime.player.fieldZ)
      .. ", taskCount="
      .. tostring(#scheduler:tasks())
      .. ", taskType="
      .. tostring(activeTask and activeTask.taskType)
      .. ", taskPhase="
      .. tostring(activeTask and activeTask.state and activeTask.state.phase)
      .. ", lastAction="
      .. tostring(lastInput and lastInput.pressedAction)
      .. ", lastUiConfirm="
      .. tostring(lastInput and lastInput.uiEvents and #lastInput.uiEvents)
      .. ", error="
      .. tostring(runtime.errorText)
      .. ")",
    0
  )
end

local function pressNamingInput(state, input)
  local runtime = assert(state.runtime)
  if input == "cancel" then
    runtime:pressCancel()
    step(state)
    runtime:releaseCancel()
  else
    runtime:press(input)
    step(state)
    runtime:release(input)
  end
end

local function submitAtOk(state)
  local runtime = assert(state.runtime)
  for _ = 1, 6 do
    local status = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
    if status.snapshot.cursor.row == 1 then
      break
    end
    pressNamingInput(state, "north")
  end
  local status = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
  Assert.equal(status.snapshot.cursor.row, 1, "navigation reaches the naming home row")

  for _ = 1, 6 do
    status = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
    if status.snapshot.cursor.controlId == "ok" then
      break
    end
    pressNamingInput(state, "east")
  end
  status = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
  Assert.equal(status.snapshot.cursor.controlId, "ok", "navigation reaches the naming OK control")
  runtime:pressAction()
  step(state)
  runtime:releaseAction()
  advanceUntil(state, "retail naming task to close", function()
    return not runtime.pokemonNaming:isActive()
  end, 120)
end

local function renderPixels(scope, state, canvas)
  local graphics = love.graphics
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  state:draw()
  graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function regionChanged(first, second, placement, logical)
  local scale = assert(placement.scale)
  local origin = assert(placement.origin)
  local left = math.floor(origin.x + logical.x * scale)
  local top = math.floor(origin.y + logical.y * scale)
  local right = math.ceil(origin.x + (logical.x + logical.width) * scale)
  local bottom = math.ceil(origin.y + (logical.y + logical.height) * scale)
  for y = top, bottom - 1 do
    for x = left, right - 1 do
      local firstRed, firstGreen, firstBlue, firstAlpha = first:getPixel(x, y)
      local secondRed, secondGreen, secondBlue, secondAlpha = second:getPixel(x, y)
      if firstRed ~= secondRed or firstGreen ~= secondGreen or firstBlue ~= secondBlue or firstAlpha ~= secondAlpha then
        return true
      end
    end
  end
  return false
end

local function verifyVersion(scope, versionId)
  local audioOutput = FakeAudioOutput.new()
  local state = assert(FieldState.new(newGame(versionId), {
    audioOutput = { audio = audioOutput.audio, sound = audioOutput.sound },
  }))
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  reachNaming(state)
  local runtime = assert(state.runtime)

  local status = assert(state.runtime.pokemonNaming:status(), "the retail script owns an active naming session")
  Assert.equal(status.snapshot.subject.kind, "pokemon", "the task publishes the selected mon as naming subject")
  Assert.notNil(status.snapshot.subject.iconKey, "the naming subject resolves through the real mon icon contract")

  local imageAcquisitions, quadAcquisitions, cacheReads = 0, 0, 0
  local graphics = love.graphics
  local originalNewImage, originalNewQuad = graphics.newImage, graphics.newQuad
  local cacheFs = assert(state.presentationResources.cacheFs, "field presentation owns the cache filesystem")
  local originalRead = cacheFs.read
  local subjectChanged, slotChanged = false, false
  graphics.newImage = function(...)
    imageAcquisitions = imageAcquisitions + 1
    return originalNewImage(...)
  end
  graphics.newQuad = function(...)
    quadAcquisitions = quadAcquisitions + 1
    return originalNewQuad(...)
  end
  cacheFs.read = function(self, ...)
    cacheReads = cacheReads + 1
    return originalRead(self, ...)
  end
  local width, height = graphics.getDimensions()
  local canvas = scope:own(graphics.newCanvas(width, height))
  local ok, err = xpcall(function()
    local subjectBefore = renderPixels(scope, state, canvas)
    local selectedBefore = renderPixels(scope, state, canvas)
    -- Sequence 50 holds frame 1 for 20 ticks, then frame 2 for 3;
    -- tick 21 is distinct, while tick 24 has already looped to frame 1.
    for _ = 1, 21 do
      step(state)
    end
    local after = renderPixels(scope, state, canvas)
    -- The modal surface is opaque over the sampled subject/slot regions, so
    -- compare its source-logical bounds through the production pane transform.
    local placement = assert(status.presentation.panes[1].placement)
    subjectChanged = regionChanged(subjectBefore, after, placement, { x = 24, y = 8, width = 32, height = 32 })
    slotChanged = regionChanged(selectedBefore, after, placement, { x = 80, y = 39, width = 16, height = 16 })
  end, debug.traceback)
  graphics.newImage, graphics.newQuad = originalNewImage, originalNewQuad
  cacheFs.read = originalRead
  if not ok then
    error(err, 0)
  end
  local failures = {}
  if not subjectChanged then
    failures[#failures + 1] = "subject pixels do not advance at source bounds"
  end
  if not slotChanged then
    failures[#failures + 1] = "selected slot pixels do not advance at source bounds"
  end
  if cacheReads ~= 0 then
    failures[#failures + 1] = "draw read " .. cacheReads .. " generated files"
  end
  if imageAcquisitions ~= 0 then
    failures[#failures + 1] = "draw created " .. imageAcquisitions .. " images"
  end
  if quadAcquisitions ~= 0 then
    failures[#failures + 1] = "draw created " .. quadAcquisitions .. " quads"
  end
  Assert.equal(table.concat(failures, "; "), "", "production naming graphics contract")

  -- Confirm a changed nickname through the production naming input mapper,
  -- then wait for the source script to commit it through the live mon service.
  pressNamingInput(state, "south")
  local namingStatus = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
  Assert.equal(namingStatus.snapshot.grid[3][1].glyph, "K")
  runtime:pressAction()
  step(state)
  runtime:releaseAction()
  Assert.equal(state.runtime.pokemonNaming:status().text, "K", "the active task accepts the selected glyph")
  submitAtOk(state)
  local scheduler = runtime.scripts.scheduler
  local nicknameTask
  for _, task in ipairs(scheduler:tasks()) do
    if task.taskType == "pokemon_nickname_input" then
      nicknameTask = task
    end
  end
  Assert.equal(runtime.pokemonNaming:isActive(), false, "the retail nickname task closed its naming host")
  Assert.notNil(nicknameTask, "the scheduler retains the completed retail nickname task result")
  Assert.equal(nicknameTask.status, "completed", "the retail nickname task completed")
  Assert.equal(nicknameTask.result, 0, "the retail task reports changed input")
  Assert.isTrue(nicknameTask.state.closed, "the completed retail task released its naming host")
  Assert.equal(
    runtime.monService:partyMon(0).nickname,
    "K",
    "the retail script result commits the changed nickname through the live mon service"
  )
end

function T.retail_nickname_modal_draws_from_prepared_field_resources(scope)
  for _, versionId in ipairs(readyVersions()) do
    verifyVersion(scope, versionId)
  end
end

return GraphicsSmoke.suite(T, {
  capabilities = { "graphics", "rom_dump", "derived_cache" },
  tags = { "field", "naming", "starter" },
})
