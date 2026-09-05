-- Production-composed contract for Elm's Lab starter choice: a fresh save
-- that finishes the lab welcome and interacts with the lab must run the
-- real generated starter flow all the way from field fade-out, through the
-- blocking choice of one pre-created candidate, to party insertion, field
-- restoration, fade-in, and the source script's own continuation. Real
-- ROM-derived maps, scripts, and the scheduler stay in the path; only the
-- host audio boundary is faked (deterministic recording).

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "starter", "elms-lab" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local FLAG_PREVENT_ESCAPE = FieldScriptSymbols.flagsByName.FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE
local FLAG_GOT_STARTER = FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER

local VANILLA_TRIO = { CHIKORITA = true, CYNDAQUIL = true, TOTODILE = true }

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
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
      }
    end,
  })
end

local function withGame(fn)
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "starter acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
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

-- Bounded semantic drive: confirm open dialogue, otherwise advance the
-- simulation. Never a blind sleep; every bound names its behavior. In
-- `modal` mode the driver also nudges a blocking choice application: action
-- edges confirm while periodic directional steps move its cursor, so a
-- genuine choice can complete without scripting its exact bindings.
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
  local player = game:snapshot().player
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
        player = now.player
        break
      end
    end
  end
  Assert.isTrue(routed, "production movement must reach a tile adjacent to " .. actorId)
  game:face(directionToward(player.fieldX, player.fieldZ, target.fieldX, target.fieldZ))
end

function T.tests.elms_lab_starter_choice_adds_the_chosen_mon_and_continues_the_script()
  withGame(function(game)
    game:waitForFieldEntry()
    Assert.equal(partyCount(game), 0, "a fresh save starts Elm's Lab with an empty party")

    -- Finish the genuine welcome scene first: walk the real spawn into
    -- the lab's entry-hallway trigger, then drive the started foreground
    -- script through its own source conclusion. The starter flow is only
    -- reachable once the opening script ends and releases the field.
    local baselineStarts = #recordsNamed(game, "script.started")
    game:moveTo({ fieldX = 4, fieldZ = 10 })
    game:advanceUntil("the welcome scene starts", function()
      return #recordsNamed(game, "script.started") > baselineStarts
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
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(FLAG_PREVENT_ESCAPE),
      "the welcome scene's own final flag must run before it ends"
    )
    Assert.isFalse(game:snapshot().fieldLocked, "the welcome scene must release the field")

    -- Talk to Elm first: his dispatcher script runs the pre-starter
    -- conversation through its own source conclusion and releases the
    -- field. Only then does the ball table own the starter trigger.
    local ELM_SCRIPT = "vanilla.hgss.scr_seq.0843.script_000"
    local elmActor = nil
    do
      local actorIds = {}
      for actorId in pairs(game:snapshot().actors) do
        if not actorId:find("player", 1, true) then
          actorIds[#actorIds + 1] = actorId
        end
      end
      table.sort(actorIds)
      Assert.isTrue(#actorIds > 0, "the lab must publish interactable objects")
      local seen = {}
      for _, actorId in ipairs(actorIds) do
        local ok = pcall(standNextTo, game, actorId)
        if ok then
          game:pressAction()
          local interaction = game:interaction()
          seen[#seen + 1] = actorId .. "->" .. tostring(interaction.kind) .. ":" .. tostring(interaction.scriptId)
          if interaction.scriptId == ELM_SCRIPT then
            elmActor = actorId
            break
          end
          local drained = pump(game, 200, function()
            return not game:snapshot().dialogue.modal
          end)
          if drained.fault ~= nil then
            error("runtime fault while driving " .. actorId .. ": " .. tostring(drained.fault))
          end
        else
          seen[#seen + 1] = actorId .. "->unreachable"
        end
      end
      Assert.notNil(elmActor, "Elm must start his generated dispatcher script; saw " .. table.concat(seen, ", "))
    end

    local elmDone = pump(game, 1500, function()
      for _, record in ipairs(recordsNamed(game, "script.ended")) do
        if record.payload.scriptId == ELM_SCRIPT then
          return record.payload.completed == true
        end
      end
      return false
    end)
    if elmDone.fault ~= nil then
      error("runtime fault in Elm's dispatcher: " .. tostring(elmDone.fault))
    end
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == ELM_SCRIPT and record.payload.completed ~= true then
        error("Elm's dispatcher did not conclude: " .. tostring(record.payload.reason))
      end
    end
    Assert.isTrue(elmDone.stopped, "Elm's dispatcher must conclude before the table owns the choice")

    -- Take the ball table through its background counter event: the
    -- production room record binds tile (8,4) to the generated script
    -- that runs the source starter opcode. Probe every reachable
    -- neighbor geometry facing the counter; the first Action that
    -- resolves to the starter script owns the rest of the flow.
    local STARTER_SCRIPT = "vanilla.hgss.scr_seq.0843.script_012"
    local attempts = {}
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
              local probeInteraction = game:interaction()
              attempts[#attempts + 1] = tile.fieldX
                .. ","
                .. tile.fieldZ
                .. "/"
                .. facing
                .. "->"
                .. tostring(probeInteraction.kind)
                .. ":"
                .. tostring(probeInteraction.scriptId)
              if probeInteraction.scriptId == STARTER_SCRIPT then
                triggered = true
              end
            end
          end
        else
          attempts[#attempts + 1] = tile.fieldX .. "," .. tile.fieldZ .. "->unreachable"
        end
      end
    end
    Assert.isTrue(
      triggered,
      "the ball table must start the generated starter script; saw " .. table.concat(attempts, ", ")
    )

    -- Drive the starter flow through the blocking choice: the modal opens
    -- after the field fade, one pre-created candidate enters the party on
    -- confirmation, and no reroll or reconstruction may intervene.
    local sawFade = false
    local chosen = pump(game, 1200, function()
      local probe = game:snapshot()
      if game.runtime.screenFade:status().active or probe.transition.phase ~= "idle" then
        sawFade = true
      end
      return partyCount(game) == 1
    end, true)
    if chosen.fault ~= nil then
      error("runtime fault in the starter script: " .. tostring(chosen.fault))
    end
    Assert.isTrue(chosen.stopped, "the Elm's Lab starter flow must add exactly one mon to the party")
    Assert.equal(partyCount(game), 1, "starter choice adds one mon, never more")

    local species = game.runtime.monService:partyMon(0).species
    Assert.isTrue(VANILLA_TRIO[species] == true, "the added mon is one of the three lab candidates")

    -- The party publication is the source-hidden birth boundary. The
    -- following transition then owns only the effect and reveals the same
    -- actor at its second fixed update.
    local partnerId = game.runtime.actors:partnerId()
    game:advanceUntil("starter follower publication", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 120)
    Assert.equal(game.runtime.actors:partnerId(), partnerId or "field:partner")
    Assert.isFalse(
      game.runtime.actors:isVisible("field:partner"),
      "the newly acquired starter follower is hidden before its reveal transition"
    )

    local prelude = game:advanceUntil("follower transition reaches its first update", function()
      local instances = game.runtime.followingMonTransition:status().instances
      return #instances == 1 and instances[1].phase == "prelude" and instances[1].preludeAge == 1
    end, 9000)
    Assert.isFalse(
      game.runtime.actors:isVisible("field:partner"),
      "the captured follower stays hidden after the first transition update"
    )
    Assert.equal(prelude.transition.phase, "idle", "the follower effect does not own the field transition")

    game:step()
    local revealed = game.runtime.followingMonTransition:status().instances
    Assert.equal(#revealed, 1, "the follower effect remains live at its reveal boundary")
    Assert.equal(revealed[1].phase, "animated", "the second update switches to the animated phase")
    Assert.equal(revealed[1].frame, 0, "the animated phase starts at frame zero")
    Assert.isTrue(
      game.runtime.actors:isVisible("field:partner"),
      "the captured follower reveals at exactly the second transition update"
    )

    -- The field script, not the application, owns story continuation: the
    -- source sets its own starter flag and releases the field only after
    -- presentation is restored. The resumed tail runs 605/608, the nickname
    -- menu (declined deterministically through the contextual cancel edge,
    -- the source no-nickname branch), follower movements, and the closing
    -- scene updates, so the driver must answer the context menu the same
    -- way instead of pumping dialogue alone.
    local continued = (function()
      for _ = 1, 9000 do
        if game.runtime.errorText then
          return { fault = game.runtime.errorText }
        end
        local snapshot = game:snapshot()
        if
          game.runtime.scripts.worldState:isFlagSet(FLAG_GOT_STARTER)
          and not snapshot.fieldLocked
          and not snapshot.dialogue.modal
          and snapshot.transition.phase == "idle"
        then
          return { stopped = true }
        end
        if game:contextChoiceStatus() ~= nil then
          game.runtime:pressCancel()
          game:step()
          game.runtime:releaseCancel()
        elseif snapshot.dialogue.modal then
          game.runtime:pressAction()
          game:step()
          game.runtime:releaseAction()
        elseif game.runtime.starterChoice:isActive() then
          game.runtime:pressAction()
          game:step()
          game.runtime:releaseAction()
        else
          game:step()
        end
      end
      local snapshot = game:snapshot()
      if
        game.runtime.scripts.worldState:isFlagSet(FLAG_GOT_STARTER)
        and not snapshot.fieldLocked
        and not snapshot.dialogue.modal
        and snapshot.transition.phase == "idle"
      then
        return { stopped = true }
      end
      return { stopped = false }
    end)()
    Assert.isNil(continued.fault, "the resumed starter script must run without a runtime fault")
    Assert.isTrue(continued.stopped, "the source script must continue and set its own starter flag")
    Assert.isTrue(sawFade, "the starter flow must pass through the source fade order")
    Assert.isTrue(
      game.runtime.screenFade:status().completed,
      "the field fade must complete before the script continues"
    )
    Assert.equal(partyCount(game), 1, "restoration keeps exactly the chosen mon")
    Assert.isTrue(game.runtime.monService:partyLegal(), "the chosen starter passes native legality after the full flow")
    Assert.equal(game:snapshot().mapSymbol, MAP, "the flow restores the same lab map")
  end)
end

return T
