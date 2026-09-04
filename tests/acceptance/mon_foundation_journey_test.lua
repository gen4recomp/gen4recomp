-- Integrated mon foundation journey: one production boot from the warmed
-- derived cache through field entry, the lab welcome, Elm's dispatcher, the
-- real starter script, the party screen, follower traversal, save,
-- teardown, and continue. Fixed inputs throughout: seed-7 mons bucket,
-- GOLD/gender-0/trainer-1 profile, host date 2000-01-01, lab map 61. The
-- choice cursor never moves, so the first roster slot is deterministic.
--
-- The expected native bytes below are a literal produced independently
-- from the pinned source algorithm (CreateBoxMon/CreateMon personality,
-- IV, ability, gender, move, and experience sequencing; the LCRandom
-- transition with low-draw-first personality; the BoxPokemon four-block
-- layout with PID-selected permutation, word checksum, and cipher segment)
-- against those fixed inputs, cross-checked once against the encoder and
-- frozen here. They are never computed by the codec under test.
-- Candidate bytes before selection are owned by the task-level generation
-- contract; this journey proves the transfer (exact draw count, literal
-- equality, legality) rather than re-proving pre-creation.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonCache = require("libs.assets.src.MonCache")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "mons", "journey" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local FLAG_PREVENT_ESCAPE = FieldScriptSymbols.flagsByName.FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE
local FLAG_GOT_STARTER = FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER
local ELM_SCRIPT = "vanilla.hgss.scr_seq.0843.script_000"
local STARTER_SCRIPT = "vanilla.hgss.scr_seq.0843.script_012"
local SEED = 7
local EXPECTED_DRAWS_PER_CANDIDATE = 4
-- First roster candidate (seed 7, GOLD/trainer 1, 2000-01-01, map 61).
local EXPECTED_HEX =
  "6cccf03b00009004e71873ef1e90542f38b61e8010d325ccf6b473f9d7755134e1f338a11ffc394f02a43e93ac09a343e167698bc92de1a5cacda9c8949631903b1f2503ff39671fd8e7b16645fcfc7c358a5a03737a075bea41c89f5000995e16f22865dbba6a1895e94fa0a65898a354ae125a77c6d0796befb11cdcad98e28c8b3aaebd0c601c"
local POKEMON_ACTION = "vanilla.pokemon"
local PARTY_APPLICATION = "pokemon"

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId, SEED),
      }
    end,
  })
end

local function productionContext(service, versionId)
  local fontDef = FieldFontLoader.load(CacheFs.forVersion(versionId))
  return {
    catalog = service:catalog(),
    charmap = assert(fontDef.charmap, "production font carries the encoding charmap"),
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
    items = HgssMonService.ITEMS,
    balls = HgssMonService.BALLS,
  }
end

local function toHex(bytes)
  local parts = {}
  for index = 1, #bytes do
    parts[#parts + 1] = string.format("%02x", string.byte(bytes, index))
  end
  return table.concat(parts)
end

local function boxedHex(service, versionId, slot0)
  return toHex(BoxCodec.encode(service:partyMon(slot0), productionContext(service, versionId)))
end

-- Bounded semantic drive: confirm open dialogue, otherwise advance the
-- simulation. In `modal` mode an action edge also nudges a blocking choice
-- application, so a genuine choice completes at its opening cursor without
-- scripting exact bindings.
local function pump(game, ticks, stop, modal)
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
  end
  if stop ~= nil and stop() then
    return { stopped = true }
  end
  return { stopped = false }
end

local function partyCount(game)
  return game.runtime.monService:partyCount()
end

local function rngCalls(game)
  return game.runtime.monService:capture().rng.calls
end

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

-- Stand on a tile adjacent to the named actor, facing it, through
-- production movement resolution only.
local function standNextTo(game, actorId)
  local actors = game:snapshot().actors
  local target = assert(actors[actorId], "actor is not visible: " .. actorId)
  local neighbors = {
    { fieldX = target.fieldX + 1, fieldZ = target.fieldZ },
    { fieldX = target.fieldX - 1, fieldZ = target.fieldZ },
    { fieldX = target.fieldX, fieldZ = target.fieldZ + 1 },
    { fieldX = target.fieldX, fieldZ = target.fieldZ - 1 },
  }
  local routed = false
  for _, tile in ipairs(neighbors) do
    local ok = pcall(function()
      game:moveTo(tile)
    end)
    if ok then
      local now = game:snapshot()
      local distance = math.abs(now.player.fieldX - target.fieldX) + math.abs(now.player.fieldZ - target.fieldZ)
      if distance == 1 then
        routed = true
        game:face(directionToward(now.player.fieldX, now.player.fieldZ, target.fieldX, target.fieldZ))
        break
      end
    end
  end
  Assert.isTrue(routed, "production movement must reach a tile adjacent to " .. actorId)
end

-- The same FieldState callbacks production dispatches. No synthetic input
-- behavior of its own.
local function hostCallbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function hostPhase(game)
  return game.runtime.applicationHost:status().phase
end

local function openStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  return game:advanceUntil("start menu becomes modal", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 120)
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the start menu must own the tick")
  return assert(status.menu, "the menu phase must expose the controller status")
end

local function actionById(status, id)
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.id == id then
      return action
    end
  end
  return nil
end

local function cursorActionId(status)
  local position = assert(status.cursorSlotId, "menu status must expose the cursor slot") - 2
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.position == position then
      return action.id
    end
  end
  error("start menu cursor does not resolve to a visible action", 0)
end

local function navigateTo(game, state, id)
  for _ = 1, #menuStatus(game).actions + 1 do
    if cursorActionId(menuStatus(game)) == id then
      return
    end
    state:keypressed("s")
    game:step()
    state:keyreleased("s")
  end
  error("start menu never focuses the party action", 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function playerTile(snapshot)
  return { fieldX = snapshot.player.fieldX, fieldZ = snapshot.player.fieldZ }
end

local function sameTile(a, b)
  return a.fieldX == b.fieldX and a.fieldZ == b.fieldZ
end

-- One facing-resolved production step; true only when the player committed
-- to a new tile.
local function tryStep(game, direction)
  game:face(direction)
  local before = playerTile(game:snapshot())
  game:move(direction)
  game:advanceUntil("movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  return not sameTile(playerTile(game:snapshot()), before)
end

function T.tests.elm_starter_to_continue_preserves_the_chosen_mon()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.equal(partyCount(game), 0, "a fresh save starts with an empty party")
    Assert.equal(rngCalls(game), 0, "no creation draw precedes the starter flow")
    Assert.isNil(game.runtime.actors:partnerId(), "an empty party installs no follower")

    -- Welcome scene through its own source conclusion.
    local baselineStarts = #game:recordsNamed("script.started")
    game:moveTo({ fieldX = 4, fieldZ = 10 })
    game:advanceUntil("the welcome scene starts", function()
      return #game:recordsNamed("script.started") > baselineStarts
    end, 60)
    local starts = game:recordsNamed("script.started")
    local welcomeScriptId = starts[#starts].payload.scriptId
    local welcome = pump(game, 1500, function()
      for _, record in ipairs(game:recordsNamed("script.ended")) do
        if record.payload.scriptId == welcomeScriptId then
          return record.payload.completed == true
        end
      end
      return false
    end)
    Assert.isNil(welcome.fault, "the welcome scene must run without a runtime fault")
    Assert.isTrue(welcome.stopped, "the welcome scene must conclude before starter choice")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(FLAG_PREVENT_ESCAPE),
      "the welcome scene's own final flag must run before it ends"
    )
    Assert.isFalse(game:snapshot().fieldLocked, "the welcome scene must release the field")

    -- Elm's dispatcher through its own source conclusion.
    local actorIds = {}
    for actorId in pairs(game:snapshot().actors) do
      if not actorId:find("player", 1, true) then
        actorIds[#actorIds + 1] = actorId
      end
    end
    table.sort(actorIds)
    local elmReached = false
    for _, actorId in ipairs(actorIds) do
      if not elmReached and pcall(standNextTo, game, actorId) then
        game:pressAction()
        if game:interaction().scriptId == ELM_SCRIPT then
          elmReached = true
        else
          local drained = pump(game, 200, function()
            return not game:snapshot().dialogue.modal
          end)
          if drained.fault ~= nil then
            error("runtime fault while driving " .. actorId .. ": " .. tostring(drained.fault))
          end
        end
      end
    end
    Assert.isTrue(elmReached, "Elm must start his generated dispatcher script")
    local elmDone = pump(game, 1500, function()
      for _, record in ipairs(game:recordsNamed("script.ended")) do
        if record.payload.scriptId == ELM_SCRIPT then
          return record.payload.completed == true
        end
      end
      return false
    end)
    Assert.isNil(elmDone.fault, "Elm's dispatcher must run without a runtime fault")
    Assert.isTrue(elmDone.stopped, "Elm's dispatcher must conclude before the table owns the choice")

    -- Ball table background trigger: probe neighbor geometry facing the
    -- counter until the generated starter script starts.
    local triggered = false
    for _, tile in ipairs({
      { fieldX = 8, fieldZ = 5 },
      { fieldX = 7, fieldZ = 4 },
      { fieldX = 9, fieldZ = 4 },
      { fieldX = 8, fieldZ = 3 },
    }) do
      if not triggered and pcall(function()
        game:moveTo(tile)
      end) then
        for _, facing in ipairs({ "north", "south", "east", "west" }) do
          if not triggered then
            game:face(facing)
            game:pressAction()
            triggered = game:interaction().scriptId == STARTER_SCRIPT
          end
        end
      end
    end
    Assert.isTrue(triggered, "the ball table must start the generated starter script")

    -- Blocking choice at the opening cursor: one pre-created candidate
    -- enters the party with no reroll.
    local sawFade = false
    local chosen = pump(game, 1200, function()
      if game.runtime.screenFade:status().active then
        sawFade = true
      end
      return partyCount(game) == 1
    end, true)
    Assert.isNil(chosen.fault, "the starter flow must choose without a runtime fault")
    Assert.isTrue(chosen.stopped, "the starter flow must add exactly one mon to the party")
    Assert.isFalse(game.runtime.starterChoice:isActive(), "the choice modal closes on publication")
    local awarded = game.runtime.monService:partyMon(0)
    Assert.equal(awarded.species, "CHIKORITA", "the opening cursor holds the first roster slot")
    Assert.equal(rngCalls(game), 3 * EXPECTED_DRAWS_PER_CANDIDATE, "creation draws exactly three candidates")
    Assert.isTrue(game.runtime.monService:partyLegal(), "the chosen starter passes native legality")
    Assert.equal(awarded.met.location, 61, "the candidate met on the lab map")
    Assert.equal(awarded.met.date.year, 2000, "the candidate met on the fixed host date")
    Assert.equal(awarded.met.date.month, 1, "the candidate met on the fixed host date")
    Assert.equal(awarded.met.date.day, 1, "the candidate met on the fixed host date")
    Assert.equal(boxedHex(game.runtime.monService, versionId, 0), EXPECTED_HEX, "party bytes equal the fixed vector")

    -- The script continues past the choice: the 605 follow-up tail runs,
    -- then the script halts on the explicitly deferred 608 neighbor while
    -- the field recovers cleanly.
    local continued = pump(game, 3000, function()
      local snapshot = game:snapshot()
      return game.runtime.scripts.worldState:isFlagSet(FLAG_GOT_STARTER)
        and not snapshot.fieldLocked
        and not snapshot.dialogue.modal
        and snapshot.transition.phase == "idle"
    end)
    Assert.isNil(continued.fault, "the resumed starter script must run without a runtime fault")
    Assert.isTrue(continued.stopped, "the source script must continue and set its own starter flag")
    local params = assert(game.runtime.followingMon:lastParams(), "the follow-up tail records its parameters")
    Assert.equal(params.a, 3, "the follow-up tail carries the source first parameter")
    Assert.equal(params.b, 2, "the follow-up tail carries the source second parameter")
    Assert.isTrue(sawFade, "the starter flow must pass through the source fade order")
    Assert.isTrue(game.runtime.screenFade:status().completed, "the field fade must complete")
    local halted = false
    for _, record in ipairs(game:recordsNamed("script.ended")) do
      if record.payload.scriptId == STARTER_SCRIPT then
        halted = record.payload.completed == false and record.payload.reason == "SCRIPT_UNSUPPORTED_REACHABLE"
      end
    end
    Assert.isTrue(halted, "the starter script ends on the explicitly deferred halt after the tail")
    Assert.isNil(game.runtime.errorText, "the halt releases the field without a runtime fault")
    Assert.equal(game:snapshot().mapSymbol, MAP, "the flow restores the same lab map")
    Assert.equal(game.runtime.actors:partnerId(), "field:partner", "the awarded lead installs its follower")
    local partnerId = assert(game.runtime.actors:partnerId(), "the partner installs with the starter")

    -- Party screen through the start menu: the awarded instance is
    -- inspectable, and closing leaves the party untouched.
    do
      local state = hostCallbacks(game)
      local revision = game.runtime.monService:partyRevision()
      openStartMenu(game)
      local action = actionById(menuStatus(game), POKEMON_ACTION)
      Assert.isTrue(action ~= nil and action.enabled == true, "an owned party enables the party action")
      navigateTo(game, state, POKEMON_ACTION)
      confirm(game)
      game:advanceUntil("party application launches", function()
        return hostPhase(game) == FieldApplicationHost.PHASES.application
      end, 180)
      local shown = game.runtime.applicationHost:status()
      Assert.equal(shown.applicationId, PARTY_APPLICATION, "confirming the route launches the party screen")
      local view = assert(shown.application.view, "the party screen exposes its view")
      Assert.equal(view.slots[1].occupied, true, "the awarded mon occupies the lead slot")
      Assert.equal(view.slots[1].displayName, "CHIKORITA", "the party screen shows the awarded instance")
      Assert.equal(view.slots[1].level, 5, "the party screen shows the source creation level")
      game.runtime:pressCancel()
      game:step()
      game.runtime:releaseCancel()
      game:advanceUntil("party screen closes", function()
        local phase = hostPhase(game)
        return phase == FieldApplicationHost.PHASES.menu or phase == FieldApplicationHost.PHASES.closed
      end, 120)
      if hostPhase(game) == FieldApplicationHost.PHASES.menu then
        game.runtime:pressMenu()
        game:step()
        game.runtime:releaseMenu()
        game:advanceUntil("start menu closes", function()
          return hostPhase(game) == FieldApplicationHost.PHASES.closed
        end, 120)
      end
      Assert.equal(game.runtime.monService:partyRevision(), revision, "inspection alone never reorders")
      Assert.equal(boxedHex(game.runtime.monService, versionId, 0), EXPECTED_HEX, "inspection never recalculates")
    end

    -- Walk and turn with the follower in the open east pocket: committed
    -- steps, a turn in place, and settlement onto a live anchor. Map
    -- transitions with a follower are owned by the warp-traversal
    -- contract; the lab door is not reachable on foot once the partner
    -- trails (it shadows reversals in the room's pinches and the planner
    -- refuses coordinate-event transit), so this journey proves the fade,
    -- application, and teardown/continue transitions instead.
    local function drainIfLocked()
      local snapshot = game:snapshot()
      if snapshot.fieldLocked or snapshot.dialogue.modal then
        local release = pump(game, 1500, function()
          local candidate = game:snapshot()
          return not candidate.fieldLocked and not candidate.dialogue.modal
        end)
        Assert.isNil(release.fault, "a fired trigger must run without a runtime fault")
        Assert.isTrue(release.stopped, "a fired trigger must release the field")
      end
    end
    local committed = 0
    for _, direction in ipairs({ "north", "south", "east", "west", "north", "south", "east", "west" }) do
      drainIfLocked()
      if committed < 2 and tryStep(game, direction) then
        committed = committed + 1
      end
    end
    Assert.equal(committed, 2, "the pocket must supply two committed steps")
    drainIfLocked()
    game:face("north")
    Assert.equal(game:snapshot().player.facing, "north", "turn input resolves without stepping")
    local settled = game:advanceUntil("partner settles onto a live anchor", function(snapshot)
      return snapshot.actors[partnerId] ~= nil
    end, 180)
    Assert.notNil(settled.actors[partnerId], "the settled partner stays a real actor")
    Assert.isNil(game.runtime.errorText, "traversal runs without a runtime fault")

    -- Save through the production store, tear the runtime down, continue
    -- from storage, and verify identity on the other side.
    Assert.isTrue(game.runtime.monService:partyLegal(), "the party is legal before save")
    local bytesBefore = boxedHex(game.runtime.monService, versionId, 0)
    Assert.isTrue(game.runtime:captureGameSave() ~= nil, "quit-save requires a stable captured game")
    game:save()
    game:restart()
    game:waitForFieldEntry()
    Assert.equal(game.lifecycle.runtimeDisposals, 1, "continue tears the previous runtime down exactly once")
    game:advanceUntil("partner reinstalls after continue", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 120)
    Assert.equal(partyCount(game), 1, "continue restores exactly the chosen mon")
    Assert.equal(game.runtime.monService:partyMon(0).species, "CHIKORITA", "continue restores the chosen species")
    Assert.equal(boxedHex(game.runtime.monService, versionId, 0), EXPECTED_HEX, "continue preserves exact bytes")
    Assert.equal(boxedHex(game.runtime.monService, versionId, 0), bytesBefore, "save/continue changes no byte")
    Assert.isTrue(game.runtime.monService:partyLegal(), "the restored mon passes native legality")
    Assert.equal(rngCalls(game), 3 * EXPECTED_DRAWS_PER_CANDIDATE, "continue restores the exact generator state")
    Assert.isNil(game.runtime.errorText, "continue runs without a runtime fault")
    Assert.equal(game:renderAttempts(), 0, "the journey must stop before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.equal(game.lifecycle.runtimeDisposals, 2, "restart and close each dispose exactly once")
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

-- Lower-level probe through the public creation seam: the same fixed seed,
-- profile, date, and map reproduce the pre-selection trio without any
-- field boot, so the journey's transfer claim rests on production
-- determinism rather than re-encoded output.
function T.tests.preselection_trio_reproduces_through_the_public_creation_seam()
  local versionId = AcceptanceHarness.defaultVersion()
  local cacheFs = CacheFs.forVersion(versionId)
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local MonsSave = require("libs.mons.src.MonsSave")
  local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.empty(catalog:fingerprint(), SEED),
    profile = { name = "GOLD", gender = 0, trainerId = 1 },
    game = versionId,
    language = MonCache.loadCatalog(cacheFs).version.language,
    charmap = assert(FieldFontLoader.load(cacheFs).charmap, "production font carries the charmap"),
    mapSection = function()
      return 61
    end,
    date = function()
      return { year = 2000, month = 1, day = 1 }
    end,
  })
  local hexes = {}
  for _, speciesKey in ipairs({ "CHIKORITA", "CYNDAQUIL", "TOTODILE" }) do
    local candidate = service:buildStarter(speciesKey)
    Assert.equal(candidate.met.location, 61, "probe candidates share the journey map")
    hexes[#hexes + 1] = toHex(BoxCodec.encode(candidate, productionContext(service, versionId)))
  end
  Assert.equal(service:partyCount(), 0, "generation never publishes into the party")
  Assert.equal(service:capture().rng.calls, 3 * EXPECTED_DRAWS_PER_CANDIDATE, "generation draws exactly thrice")
  Assert.equal(#hexes, 3, "all three candidates encode")
  Assert.isTrue(hexes[1] ~= hexes[2] and hexes[1] ~= hexes[3] and hexes[2] ~= hexes[3], "candidates are distinct")
  Assert.equal(hexes[1], EXPECTED_HEX, "the first candidate equals the fixed vector")
end

-- Content identity at the product boundary: a stored bucket written against
-- foreign generated content fails continue before any field state
-- publishes, and the valid record still boots afterwards.
function T.tests.continue_rejects_a_foreign_catalog_fingerprint_before_publication()
  local versionId = AcceptanceHarness.defaultVersion()
  local valid = harness():boot({ versionId = versionId, map = "MAP_BURNED_TOWER_1F", save = "fresh" })
  valid:waitForFieldEntry()
  local record = assert(valid.runtime:captureGameSave(), "continue requires a stable captured game")
  local namespace = valid.saveNamespace
  valid:close()
  Assert.isNil(love.filesystem.getInfo(namespace), "the valid boot cleans its namespace")

  record.mons.catalogFingerprint = "00000000"
  local tampered = AcceptanceHarness.new({
    gameFactory = function()
      return record
    end,
  })
  local ok, err = pcall(function()
    tampered:boot({ versionId = versionId, map = "MAP_BURNED_TOWER_1F", save = "fresh" })
  end)
  Assert.isFalse(ok, "a foreign fingerprint must fail continue")
  Assert.isTrue(
    tostring(err):find("MONS_SAVE_FINGERPRINT_MISMATCH", 1, true) ~= nil,
    "the failure names the fingerprint mismatch: " .. tostring(err):sub(1, 160)
  )

  local again = harness():boot({ versionId = versionId, map = "MAP_BURNED_TOWER_1F", save = "fresh" })
  local againOk, againErr = xpcall(function()
    again:waitForFieldEntry()
    Assert.equal(again:renderAttempts(), 0, "the mismatch probe must stop before GPU rendering")
  end, debug.traceback)
  again:close()
  if not againOk then
    error(againErr, 0)
  end
end

return T
