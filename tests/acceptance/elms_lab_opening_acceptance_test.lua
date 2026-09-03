-- Production-composed contract for Elm's Lab opening welcome: a fresh save
-- walking into the lab's entry hallway must run the real generated scene all
-- the way through the email chime, Elm's post-chime `ApplyMovement`, its
-- `WaitMovement`, and the following dialogue/state change -- without ever
-- releasing player input early or losing the Elm actor mid-sequence. Real
-- ROM-derived maps, scripts, and the scheduler stay in the path; only the
-- host audio boundary is faked (deterministic recording).

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "opening", "elm" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local ELM_ACTOR_ID = "map:61:object:0"
local VAR_SCENE_ELMS_LAB = FieldScriptSymbols.variablesByName.VAR_SCENE_ELMS_LAB
local FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE = FieldScriptSymbols.flagsByName.FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE

-- A custom harness so the fresh save starts inside Elm's Lab at its real
-- spawn/exit-warp tile (4,13), the same passable cell the ROM-conformance
-- traversal contract already pins, facing into the room.
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
    Assert.equal(game:renderAttempts(), 0, "elm-lab acceptance must stop before GPU rendering")
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

-- The exact generated coordinate-trigger record for the fresh-scene welcome,
-- read straight from the runtime's own compiled field data (not guessed):
-- HGSS's zone-event coordinate rectangle over the lab's entry hallway, gated
-- on the fresh (0) value of VAR_SCENE_ELMS_LAB.
local function welcomeCoordinateEvent(game)
  for _, event in ipairs(game.runtime.runtimeMap.fieldData.events.coordinates) do
    if event.variableId == VAR_SCENE_ELMS_LAB and event.requiredValue == 0 then
      return event
    end
  end
  return nil
end

local function elmPose(game)
  local elm = assert(game:snapshot().actors[ELM_ACTOR_ID], "Elm must remain a live, drawable actor")
  return { fieldX = elm.fieldX, fieldZ = elm.fieldZ, facing = elm.facing }
end

local function elmDrawRecord(game)
  for _, record in ipairs(game.runtime.actors:drawRecords()) do
    if record.actorId == ELM_ACTOR_ID then
      return {
        world = { x = record.world.x, y = record.world.y, z = record.world.z },
        facing = record.facing,
        pose = record.pose,
        poseTick = record.poseTick,
        visible = record.visible,
      }
    end
  end
  return nil
end

local function samePose(a, b)
  return a.fieldX == b.fieldX and a.fieldZ == b.fieldZ and a.facing == b.facing
end

function T.tests.fresh_entry_triggers_the_welcome_scene_through_elms_post_chime_movement()
  withGame(function(game)
    local world = game.runtime.scripts.worldState
    Assert.equal(world:getVar(VAR_SCENE_ELMS_LAB), 0, "a genuinely fresh save starts Elm's Lab scene at 0")
    Assert.isFalse(
      world:isFlagSet(FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE),
      "a fresh save must not already carry the mid-scene escape lock"
    )

    local welcomeEvent = assert(
      welcomeCoordinateEvent(game),
      "the compiled lab record must declare the fresh-scene entry coordinate trigger"
    )
    -- Coordinate events preserve the raw 1-based source script index; the
    -- same identity formatter every vanilla script consumer shares
    -- (`libs/hgss/src/script/Bindings.lua`) converts bank id + zero-based
    -- index into the canonical resource id actually started at runtime.
    local expectedScriptId =
      ScriptIdentity.formatVanilla(game.runtime.runtimeMap.fieldData.scriptBankId, welcomeEvent.scriptId - 1)

    game:waitForFieldEntry()
    Assert.notNil(game:snapshot().actors[ELM_ACTOR_ID], "Elm must be a live, drawable actor before the scene starts")
    local initialDraw =
      assert(elmDrawRecord(game), "Elm must have a production actor draw record before the scene starts")
    Assert.isTrue(initialDraw.visible, "Elm's production draw record must be visible before the scene starts")
    -- The lab's own on-load lifecycle rule already repositions Elm at map
    -- entry (HGSS `MovePersonFacing` at fresh scene value 0); only the
    -- welcome scene's own foreground script is under test here, so record
    -- the baseline instead of assuming Elm's zone-event spawn tile.
    local baselineStarts = #recordsNamed(game, "script.started")

    -- Walk from the real spawn/exit-warp tile north into the entry hallway;
    -- production movement/collision resolves every intermediate step.
    game:moveTo({ fieldX = 4, fieldZ = 10 })

    game:advanceUntil("the welcome scene starts", function()
      return #recordsNamed(game, "script.started") > baselineStarts
    end, 60)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(#starts - baselineStarts, 1, "the welcome scene must start exactly one foreground script")
    Assert.equal(
      starts[baselineStarts + 1].payload.scriptId,
      expectedScriptId,
      "the generated coordinate trigger must own the field"
    )
    Assert.isTrue(game:snapshot().fieldLocked, "the welcome scene must lock player input")

    -- Drive real dialogue/script advancement (never a blind sleep) until the
    -- source email chime plays: the scene's own preceding `GenderMsgBox`
    -- requires the same semantic confirm edge every other dialogue scenario
    -- in this suite uses.
    local chimeSeen = false
    local poseAtChime
    for _ = 1, 400 do
      if game.runtime.errorText then
        error("runtime fault: " .. tostring(game.runtime.errorText))
      end
      for _, effect in ipairs(game:hostEffects()) do
        if effect == "audio:SEQ_SE_GS_PHONE0" then
          chimeSeen = true
        end
      end
      if chimeSeen then
        break
      end
      if game:snapshot().dialogue.modal then
        game.runtime:pressAction()
        game:step()
        game.runtime:releaseAction()
      else
        game:step()
      end
    end
    Assert.isTrue(chimeSeen, "the source email chime must play before Elm's post-chime movement")
    Assert.isTrue(game:snapshot().fieldLocked, "the field stays locked through the chime")
    poseAtChime = elmPose(game)
    local drawAtChime = assert(elmDrawRecord(game), "Elm must retain a draw record at the scripted movement boundary")
    Assert.isTrue(drawAtChime.visible, "Elm's scripted movement must begin with a visible draw record")

    -- `ApplyMovement`/`WaitMovement` for object 0 must actually run: Elm's
    -- pose changes from its at-chime snapshot before the scene concludes.
    -- The actor world must resolve Elm as a live actor throughout (never
    -- lost mid-sequence, and any genuine actor/script fault surfaces loudly
    -- rather than the sequence silently completing or releasing control).
    local moved = false
    local drawMoved = false
    for _ = 1, 600 do
      if game.runtime.errorText then
        error("runtime fault: " .. tostring(game.runtime.errorText))
      end
      if not samePose(elmPose(game), poseAtChime) then
        moved = true
      end
      local draw = assert(elmDrawRecord(game), "Elm must remain in the production draw list during movement")
      if
        draw.world.x ~= drawAtChime.world.x
        or draw.world.y ~= drawAtChime.world.y
        or draw.world.z ~= drawAtChime.world.z
        or draw.facing ~= drawAtChime.facing
        or draw.pose ~= drawAtChime.pose
        or draw.poseTick ~= drawAtChime.poseTick
      then
        drawMoved = true
      end
      if world:isFlagSet(FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE) and not game:snapshot().fieldLocked then
        break
      end
      if game:snapshot().dialogue.modal then
        game.runtime:pressAction()
        game:step()
        game.runtime:releaseAction()
      else
        game:step()
      end
    end
    Assert.isTrue(moved, "Elm's post-chime `ApplyMovement` must actually displace/turn him, not silently no-op")
    Assert.isTrue(drawMoved, "Elm's post-chime movement must update the production presentation record")

    -- The welcome scene must run through its own source conclusion (the
    -- final `SetFlag`/`ReleaseAll`), not stall or silently fault partway
    -- through Elm's post-chime movement. A fault's own recorded reason is
    -- surfaced in the assertion message so a regression names its actual
    -- broken boundary instead of only "timed out".
    local welcomeEnd
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedScriptId then
        welcomeEnd = record
      end
    end
    Assert.notNil(welcomeEnd, "the welcome scene script must end (looping forever is not source-correct either)")
    Assert.isTrue(
      welcomeEnd.payload.completed,
      "the welcome scene must reach its scripted conclusion, not fault: " .. tostring(welcomeEnd.payload.reason)
    )
    Assert.isTrue(
      world:isFlagSet(FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE),
      "the welcome scene's own final SetFlag must run before it ends"
    )
    Assert.isFalse(game:snapshot().fieldLocked, "ReleaseAll must return field ownership once the scene completes")
  end)
end

return T
