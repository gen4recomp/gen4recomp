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

local function starterBallCount(game)
  local runtimeMap = assert(game.runtime.runtimeMap, "Elm's lab runtime map is loaded")
  local selections = assert(runtimeMap.runtimePropSelections, "starter-ball runtime selections are published")
  return #assert(selections.starter_balls, "the starter-ball owner publishes its selected placements")
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
    Assert.equal(starterBallCount(game), 3, "a fresh lab initializes all three source starter-ball placements")

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
    local partner = assert(game:snapshot().actors[partnerId], "the starter follower remains installed after 605")
    local player = game:snapshot().player
    Assert.equal(partner.fieldX, player.fieldX + 1, "605 places the follower one tile east of the player")
    Assert.equal(partner.fieldZ, player.fieldZ, "605 preserves the player's row")
    Assert.equal(partner.facing, "west", "605 faces the follower back toward the player")
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
      local function starterEnded()
        for _, record in ipairs(recordsNamed(game, "script.ended")) do
          if record.payload.scriptId == STARTER_SCRIPT then
            return record.payload.completed == true
          end
        end
        return false
      end

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
          and starterEnded()
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
        and starterEnded()
      then
        return { stopped = true }
      end
      return { stopped = false }
    end)()
    Assert.isNil(continued.fault, "the resumed starter script must run without a runtime fault")
    Assert.isTrue(continued.stopped, "the source script must continue and set its own starter flag")
    local starterEnd = nil
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == STARTER_SCRIPT then
        starterEnd = record.payload
      end
    end
    Assert.notNil(starterEnd, "the starter script must reach its source End")
    local completedEnd = assert(starterEnd) ---@type { completed: boolean?, reason: string? }
    Assert.isTrue(completedEnd.completed == true, "the starter script must complete normally")
    Assert.isFalse(
      completedEnd.reason == "SCRIPT_UNSUPPORTED_REACHABLE",
      "the journey must not halt on an unsupported command"
    )
    Assert.isTrue(sawFade, "the starter flow must pass through the source fade order")
    Assert.isTrue(
      game.runtime.screenFade:status().completed,
      "the field fade must complete before the script continues"
    )
    Assert.equal(partyCount(game), 1, "restoration keeps exactly the chosen mon")
    Assert.isTrue(game.runtime.monService:partyLegal(), "the chosen starter passes native legality after the full flow")
    Assert.equal(game:snapshot().mapSymbol, MAP, "the flow restores the same lab map")

    game:save()
    game:restart()
    game:waitForFieldEntry()
    Assert.equal(partyCount(game), 1, "the chosen starter survives a normal production restart")
    Assert.equal(starterBallCount(game), 2, "lab reload reconstructs two balls from the party story state")
  end)
end

-- Elm's post-choice choreography keeps one stable visible follower through
-- scripted walking, field release, and free-field standing: every adjacent
-- scripted player tile is trailed step-for-step in the same epoch it
-- starts (walking, never jumping, onto the vacated tile), the field
-- release restores ordinary same-tick following, and the free stationary
-- follower idles natively with zero logical displacement while movement
-- pause and modal dialogue leave that idle presentation alone. Real
-- ROM-derived maps, the real generated starter script, and the production
-- field runtime stay in the path; only host boundaries (audio, saves,
-- clock) are faked by the harness.
function T.tests.elm_choreography_trails_releases_and_idles_the_stable_follower()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()

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
      for _, actorId in ipairs(actorIds) do
        local reached = pcall(standNextTo, game, actorId)
        if reached then
          game:pressAction()
          local interaction = game:interaction()
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
        end
      end
      Assert.notNil(elmActor, "Elm must start his generated dispatcher script")
    end
    local elmDone = pump(game, 1500, function()
      for _, record in ipairs(recordsNamed(game, "script.ended")) do
        if record.payload.scriptId == ELM_SCRIPT then
          return record.payload.completed == true
        end
      end
      return false
    end)
    Assert.isTrue(elmDone.stopped, "Elm's dispatcher must conclude before the table owns the choice")

    local STARTER_SCRIPT = "vanilla.hgss.scr_seq.0843.script_012"
    local triggered = false
    for _, tile in ipairs({
      { fieldX = 8, fieldZ = 5 },
      { fieldX = 7, fieldZ = 4 },
      { fieldX = 9, fieldZ = 4 },
      { fieldX = 8, fieldZ = 3 },
    }) do
      if not triggered then
        local reached = pcall(function()
          game:moveTo(tile)
        end)
        if reached then
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

    local chosen = pump(game, 1200, function()
      return partyCount(game) == 1
    end, true)
    Assert.isTrue(chosen.stopped, "the starter flow must add exactly one mon to the party")
    Assert.isTrue(VANILLA_TRIO[game.runtime.monService:partyMon(0).species] == true, "the added mon is a lab candidate")

    local partnerId = game.runtime.actors:partnerId()
    game:advanceUntil("starter follower publication", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 120)
    partnerId = assert(game.runtime.actors:partnerId(), "the starter follower must install")
    game:advanceUntil("the captured follower reveals", function()
      return game.runtime.actors:isVisible(partnerId)
    end, 9000)
    Assert.isNil(game.runtime.errorText, "field runtime faulted while revealing the follower")
    Assert.isTrue(
      game.runtime.actors:isVisible(partnerId),
      "the captured follower reveals before the scripted return walk"
    )

    -- The scripted return walk: every player walking episode that displaces
    -- the player must already have the same stable partner walking toward
    -- the vacated tile on its first tick, keep it walking without jumping
    -- for the whole episode, and settle it onto the vacated tile.
    local function starterEnded()
      for _, record in ipairs(recordsNamed(game, "script.ended")) do
        if record.payload.scriptId == STARTER_SCRIPT then
          return record.payload.completed == true
        end
      end
      return false
    end
    local seenMessages = {}
    local seenMessageOrder = {}
    local scriptedCommits = 0
    local trailedCommits = 0
    local sawTransitionMode = false
    local prevMotion = "idle"
    local prevTile = nil
    local episode = nil
    local function noteMessage(snapshot)
      if snapshot.dialogue.modal and snapshot.dialogue.bankId ~= nil and snapshot.dialogue.messageId ~= nil then
        local key = snapshot.dialogue.bankId .. ":" .. snapshot.dialogue.messageId
        if seenMessages[key] == nil then
          seenMessages[key] = true
          seenMessageOrder[#seenMessageOrder + 1] = key
        end
      end
    end
    local function closeEpisode(endTile)
      local current = episode
      episode = nil
      if current == nil then
        return
      end
      if endTile.fieldX == current.startTile.fieldX and endTile.fieldZ == current.startTile.fieldZ then
        return
      end
      scriptedCommits = scriptedCommits + 1
      if current.startMode == "follow_transition_a" then
        sawTransitionMode = true
      end
      Assert.isTrue(
        current.startedUnsettled,
        "the stable follower starts its trail on the first tick of scripted step " .. scriptedCommits
      )
      Assert.isTrue(
        current.alwaysUnsettled,
        "the follower keeps trailing for the whole scripted step " .. scriptedCommits
      )
      Assert.isTrue(current.idStable, "the scripted trail keeps the stable actor on step " .. scriptedCommits)
      Assert.isTrue(
        current.maxHeightDeviation < 0.15,
        "the scripted trail holds its height instead of jumping on step " .. scriptedCommits
      )
      Assert.equal(
        current.startAction,
        "walk",
        "the scripted trail walks toward the vacated tile on step " .. scriptedCommits
      )
      local partner =
        assert(game.runtime.actors:getById(partnerId), "the partner survives scripted step " .. scriptedCommits)
      Assert.equal(
        partner:getFieldPosition().fieldX,
        current.startTile.fieldX,
        "the follower settles onto the vacated tile on step " .. scriptedCommits
      )
      Assert.equal(
        partner:getFieldPosition().fieldZ,
        current.startTile.fieldZ,
        "the follower settles onto the vacated tile on step " .. scriptedCommits
      )
      Assert.equal(
        game.runtime.actors:partnerId(),
        partnerId,
        "no clear/reinstall crosses scripted step " .. scriptedCommits
      )
      trailedCommits = trailedCommits + 1
    end
    local tail = (function()
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
          and starterEnded()
        then
          closeEpisode({ fieldX = snapshot.player.fieldX, fieldZ = snapshot.player.fieldZ })
          return { stopped = true }
        end
        noteMessage(snapshot)
        local motion = snapshot.player.motion
        local tile = { fieldX = snapshot.player.fieldX, fieldZ = snapshot.player.fieldZ }
        if not starterEnded() then
          if prevMotion == "idle" and motion ~= "idle" then
            local live = game.runtime.actors:getById(partnerId)
            local startAction = nil
            local startMotion = live and live:scriptedMotionState() or nil
            if startMotion ~= nil then
              startAction = startMotion.action
            end
            episode = {
              startTile = prevTile or tile,
              startedUnsettled = not game.runtime.followingMon:isMovementSettled(),
              alwaysUnsettled = not game.runtime.followingMon:isMovementSettled(),
              idStable = game.runtime.actors:partnerId() == partnerId,
              startAction = startAction,
              startMode = game.runtime.followingMon._movementType,
              startHeight = live and live:getWorldPosition().y or 0,
              maxHeightDeviation = 0,
            }
          elseif episode ~= nil and motion ~= "idle" then
            if game.runtime.followingMon:isMovementSettled() then
              episode.alwaysUnsettled = false
            end
            if game.runtime.actors:partnerId() ~= partnerId then
              episode.idStable = false
            end
            local live = game.runtime.actors:getById(partnerId)
            if live ~= nil and type(live:getWorldPosition().y) == "number" then
              local deviation = math.abs(live:getWorldPosition().y - episode.startHeight)
              if deviation > episode.maxHeightDeviation then
                episode.maxHeightDeviation = deviation
              end
            end
          elseif episode ~= nil and motion == "idle" then
            closeEpisode(tile)
          end
        end
        prevMotion = motion
        prevTile = tile
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
        and starterEnded()
      then
        closeEpisode({ fieldX = snapshot.player.fieldX, fieldZ = snapshot.player.fieldZ })
        return { stopped = true }
      end
      return { stopped = false }
    end)()
    Assert.isNil(tail.fault, "the resumed starter script must run without a runtime fault")
    Assert.isTrue(tail.stopped, "the source script must continue and set its own starter flag")
    Assert.isTrue(scriptedCommits >= 6, "the scripted return walk must commit its south/west tiles")
    Assert.equal(
      trailedCommits,
      scriptedCommits,
      "every scripted player tile is trailed step-for-step onto the vacated tile"
    )
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(FLAG_GOT_STARTER),
      "the source script sets its own starter flag"
    )
    Assert.isFalse(game:snapshot().fieldLocked, "the source script releases the field at its End")
    Assert.isTrue(
      sawTransitionMode,
      "the scripted return walk runs under the transition movement mode before restoration"
    )
    Assert.equal(
      game.runtime.followingMon._movementType,
      "follow_player",
      "the script restores ordinary free following after its transition segment"
    )
    local remembered = assert(
      game.runtime.followingMon._lastFollowerCommand,
      "the scripted transition segment leaves a remembered follower command"
    )
    Assert.equal(remembered.direction, "west", "the remembered command keeps the last executed walk direction")
    Assert.equal(remembered.speed, "normal", "the remembered command keeps the last executed walk speed")

    -- Ordinary following after the release: one normal player step into a
    -- reachable tile starts the same stable partner in the same epoch and
    -- settles it onto the pre-step tile.
    local stepped = false
    for _, direction in ipairs({ "south", "east", "north", "west" }) do
      game:face(direction)
      local before = { fieldX = game:snapshot().player.fieldX, fieldZ = game:snapshot().player.fieldZ }
      game:move(direction)
      local mid = game:snapshot()
      if mid.player.fieldX ~= before.fieldX or mid.player.fieldZ ~= before.fieldZ or mid.player.motion ~= "idle" then
        Assert.isFalse(
          game.runtime.followingMon:isMovementSettled(),
          "the follower starts while the ordinary step is still in flight"
        )
        local actor = assert(game.runtime.actors:getById(partnerId), "the partner survives the step start")
        Assert.equal(actor.pose, "walk", "the follower walks while the ordinary step is in flight")
        Assert.equal(
          game.runtime.actors:partnerId(),
          partnerId,
          "ordinary following after release keeps the stable actor"
        )
        game:advanceUntil("ordinary step resolves", function(snapshot)
          return snapshot.player.motion == "idle"
        end, 120)
        game:advanceUntil("ordinary trail settles", function()
          return game.runtime.followingMon:isMovementSettled()
        end, 120)
        local after = game:snapshot()
        if after.player.fieldX ~= before.fieldX or after.player.fieldZ ~= before.fieldZ then
          local partner = assert(game.runtime.actors:getById(partnerId), "the partner survives the committed step")
          Assert.equal(partner:getFieldPosition().fieldX, before.fieldX, "the follower settles onto the pre-step tile")
          Assert.equal(partner:getFieldPosition().fieldZ, before.fieldZ, "the follower settles onto the pre-step tile")
          stepped = true
          break
        end
      else
        game:advanceUntil("blocked movement resolves", function(snapshot)
          return snapshot.player.motion == "idle"
        end, 120)
      end
    end
    Assert.isTrue(stepped, "the lab must supply one committed ordinary step after release")

    -- Free standing: the visible follower idles natively with zero
    -- logical displacement, staying settled and interactable.
    local home = game:snapshot()
    local homePartner = assert(game.runtime.actors:getById(partnerId), "the partner is required")
    local homeTile = homePartner:getFieldPosition()
    Assert.isTrue(game.runtime.followingMon:isMovementSettled(), "the free follower is settled before idling")
    for _ = 1, 30 do
      game:step()
      local actor = assert(game.runtime.actors:getById(partnerId), "the partner survives stationary ticks")
      Assert.equal(actor.pose, "idle", "every free stationary tick presents native idle, never locomotion")
      Assert.isNil(actor:scriptedMotionState(), "stationary ticks start no movement action")
      Assert.equal(actor:getFieldPosition().fieldX, homeTile.fieldX, "native idle never changes the logical tile")
      Assert.equal(actor:getFieldPosition().fieldZ, homeTile.fieldZ, "native idle never changes the logical tile")
      Assert.isTrue(game.runtime.followingMon:isMovementSettled(), "native idle stays settled")
      Assert.isTrue(
        game.runtime.followingMon:isEventTrigger(1, 0),
        "the idling follower stays available for interaction"
      )
    end
    Assert.isTrue(home.player.fieldX ~= nil, "the home snapshot is well formed")

    -- Movement pause: pausing a stationary follower changes nothing visual
    -- and release starts no movement action.
    game.runtime.followingMon:setMovementPaused(true)
    game:step()
    game:step()
    do
      local actor = assert(game.runtime.actors:getById(partnerId), "the partner survives the pause")
      Assert.equal(actor.pose, "idle", "pausing a stationary follower changes nothing visual")
      Assert.isNil(actor:scriptedMotionState(), "no movement action exists while paused")
      Assert.equal(actor:getFieldPosition().fieldX, homeTile.fieldX, "pausing never displaces the logical tile")
      Assert.equal(actor:getFieldPosition().fieldZ, homeTile.fieldZ, "pausing never displaces the logical tile")
      Assert.isTrue(game.runtime.followingMon:isMovementSettled(), "a paused follower never hangs a wait")
    end
    for _ = 1, 10 do
      game:step()
      Assert.isTrue(game.runtime.followingMon:isMovementSettled(), "the paused follower stays settled")
    end
    game.runtime.followingMon:setMovementPaused(false)
    for _ = 1, 3 do
      game:step()
    end
    do
      local actor = assert(game.runtime.actors:getById(partnerId), "the partner survives the release")
      Assert.equal(actor.pose, "idle", "release starts no movement action")
      Assert.isNil(actor:scriptedMotionState(), "the released follower holds no scripted motion")
      Assert.equal(actor:getFieldPosition().fieldX, homeTile.fieldX, "release never displaces the logical tile")
      Assert.equal(actor:getFieldPosition().fieldZ, homeTile.fieldZ, "release never displaces the logical tile")
    end

    -- Modal dialogue: the follower keeps idling natively while the box is
    -- open and after it closes, through the production dialogue composition.
    local dialogueRef = nil
    for _, key in ipairs(seenMessageOrder) do
      local bankId, messageId = key:match("^(%d+):(%d+)$")
      bankId, messageId = tonumber(bankId), tonumber(messageId)
      local provider = game.runtime.messageProvider
      local bank = provider:acquireBank(bankId)
      if bank ~= nil then
        local template = provider:get(bankId, messageId)
        provider:releaseBank(bankId)
        if template ~= nil then
          local hasSubstitution = false
          for _, token in ipairs(template.tokens) do
            if token.kind == "substitution" then
              hasSubstitution = true
              break
            end
          end
          if not hasSubstitution then
            dialogueRef = string.format("msg.hgss.%d.%d", bankId, messageId)
            break
          end
        end
      end
    end
    Assert.notNil(dialogueRef, "the journey must surface one substitution-free production message")
    local host = assert(game.runtime.scripts.dialogueHost, "the production dialogue host is required")
    host:openMessage({ message = assert(dialogueRef, "a production message reference is required") })
    host:startPrint(assert(dialogueRef, "a production message reference is required"), {}, {})
    game:step()
    Assert.isTrue(game:snapshot().dialogue.modal, "the production message box opens modal")
    do
      local actor = assert(game.runtime.actors:getById(partnerId), "the partner survives the dialogue")
      Assert.equal(actor.pose, "idle", "modal dialogue leaves native idle alone")
      Assert.equal(
        actor:getFieldPosition().fieldX,
        homeTile.fieldX,
        "an open dialogue never displaces the logical tile"
      )
      Assert.equal(
        actor:getFieldPosition().fieldZ,
        homeTile.fieldZ,
        "an open dialogue never displaces the logical tile"
      )
      Assert.isTrue(game.runtime.followingMon:isMovementSettled(), "a follower stays settled under dialogue")
    end
    for _ = 1, 10 do
      game:step()
      Assert.isTrue(game:snapshot().dialogue.modal, "the box stays open without script input")
    end
    host:close(true)
    game:step()
    Assert.isFalse(game:snapshot().dialogue.modal, "closing releases the modal box")
    for _ = 1, 12 do
      game:step()
    end
    do
      local actor = assert(game.runtime.actors:getById(partnerId), "the partner survives the closed dialogue")
      Assert.equal(actor.pose, "idle", "the follower idles natively after dialogue closes")
      Assert.equal(
        actor:getFieldPosition().fieldX,
        homeTile.fieldX,
        "closing dialogue never displaces the logical tile"
      )
      Assert.equal(
        actor:getFieldPosition().fieldZ,
        homeTile.fieldZ,
        "closing dialogue never displaces the logical tile"
      )
    end

    Assert.equal(game:renderAttempts(), 0, "follower-trail acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
