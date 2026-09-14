-- Production-composed field text contracts. These flows boot the real field
-- runtime, use ROM-backed messages and scripts, and stop before rendering.
-- Audio is observed only through the production host boundary.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "field-core", "map:60" },
    tags = { "field", "dialogue", "text", "signpost", "persistence" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local WOMAN = { fieldX = 683, fieldZ = 400 }
-- The New Bark roaming object that owns bank 542 message 12 settles one tile
-- south of this standing position during fresh runtime entry.
local BOUNDARY_NPC = { fieldX = 685, fieldZ = 406 }

local function freezeAutonomousActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

local function withReadyVersion(fn, options)
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local fieldOptions = options and options.fieldOptions or nil
  local game = harness:boot({
    versionId = versionId,
    map = options and options.map or TOWN,
    save = options and options.save or "fresh",
    fieldOptions = fieldOptions,
  })
  freezeAutonomousActors(game)
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "field text acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@return { dialogue: { modal: boolean, textOriginX: integer, textOriginY: integer, contentWidth: integer, syntheticBreaks: integer } }
---@param game table
---@param target table|nil
---@param facing string|nil
local function openVanillaDialogue(game, target, facing)
  game:moveTo(target or WOMAN)
  game:face(facing or "north")
  game:pressAction()
  return game:advanceUntil("ROM-backed field interaction opens dialogue", function(snapshot)
    return snapshot.dialogue.modal
  end, 8)
end

local function advanceToDialogueWait(game)
  return game:advanceUntil("field dialogue reaches a continuation boundary", function(snapshot)
    return snapshot.dialogue.waiting
  end, 480)
end

local function pressCancel(game)
  game.runtime:pressCancel("acceptance")
  local snapshot = game:step()
  game.runtime:releaseCancel("acceptance")
  return snapshot
end

-- A held Action/Cancel state crosses the production scheduler into the
-- dialogue controller, while the final Cancel edge is consumed once by the
-- script task that owns the close boundary. The same ROM-backed opening
-- proves the source window geometry and controls.
function T.tests.production_dialogue_uses_source_geometry_and_owns_held_input_close()
  withReadyVersion(function(game)
    local opened = openVanillaDialogue(game)
    Assert.isTrue(opened.dialogue.modal, "the ROM-backed field interaction must open dialogue")
    Assert.equal(opened.dialogue.textOriginX, 0, "field text must start at the source local X origin")
    Assert.equal(opened.dialogue.textOriginY, 0, "field text must start at the source local Y origin")
    Assert.equal(opened.dialogue.contentWidth, 216, "field dialogue must use the source content width")
    Assert.equal(opened.dialogue.syntheticBreaks, 0, "vanilla text must not gain project pagination breaks")
    game.runtime:pressAction("acceptance")
    local revealing = game:step()
    Assert.isTrue(revealing.dialogue.modal, "held Action must not discard the active dialogue")
    game.runtime:releaseAction("acceptance")

    advanceToDialogueWait(game)
    local closing = pressCancel(game)
    Assert.isTrue(closing.dialogue.modal, "the task-owned final edge must hand off before close")
    Assert.isTrue(closing.fieldLocked, "the script task must retain the locked production boundary")
    game:advanceDialogue()
  end)
end

-- Confirmation at a ROM continuation boundary advances the source printer,
-- preserves the scroll/clear distinction, and advances its scroll state at
-- printer cadence rather than field cadence.
function T.tests.field_dialogue_continuation_uses_printer_cadence()
  withReadyVersion(function(game)
    Assert.isNil(
      game.runtime.scripts.composition:effective("demo.dialogue"),
      "acceptance dialogue fixtures must not be installed in the production registry"
    )
    openVanillaDialogue(game, BOUNDARY_NPC, "south")
    local waiting = advanceToDialogueWait(game)
    Assert.isTrue(
      waiting.dialogue.continuationKind == "clear" or waiting.dialogue.continuationKind == "scroll",
      "the ROM-backed continuation must identify its source boundary"
    )
    local before = waiting.dialogue.scrollOffsetY
    local confirmed = game:pressAction()
    Assert.isTrue(confirmed.dialogue.modal, "continuation confirmation must keep the production boundary locked")
    if waiting.dialogue.continuationKind == "scroll" then
      Assert.equal(
        confirmed.dialogue.scrollOffsetY,
        before,
        "confirmation must enter scrolling before moving its lines"
      )
      local first = game:step().dialogue.scrollOffsetY
      local second = game:step().dialogue.scrollOffsetY
      Assert.equal(first, before + 8, "scrolling must move four pixels per printer update")
      Assert.equal(second, before + 16, "scrolling must continue on the next printer update")
    else
      Assert.equal(confirmed.dialogue.scrollOffsetY, 0, "prompt clear must not scroll retained lines")
      Assert.equal(#confirmed.dialogue.visibleLines, 0, "prompt clear must remove both visible lines")
    end
  end)
end

-- The continuation confirmation sound is reached through normal runtime
-- composition; only the low-level audio output is an acceptance boundary.
function T.tests.production_dialogue_continuation_emits_select_sound()
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness:boot({
    versionId = versionId,
    map = TOWN,
    save = "fresh",
    fieldOptions = { audioHost = "production" },
  })
  local ok, err = xpcall(function()
    openVanillaDialogue(game)
    advanceToDialogueWait(game)
    game:pressAction()
    Assert.isTrue(
      game.runtime.audio:isEffectPlaying("SEQ_SE_DP_SELECT"),
      "continuation confirmation must emit the production select sound"
    )
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Typed Trainer Tips remain on the shared printer policy: the fresh-player
-- speed is observable through the production player-data bucket, and a held
-- confirmation cannot instantly fill a live typed tip.
function T.tests.trainer_tip_uses_shared_speed_policy_and_not_task_fill()
  withReadyVersion(function(game)
    Assert.equal(game.runtime.playerData.options.textSpeed, "fastest", "fresh player data must use fastest text speed")
    Assert.isNil(
      game.runtime.scripts.composition:effective("demo.signpost"),
      "acceptance signpost fixtures must not be installed in the production registry"
    )
    game:startScript("vanilla.hgss.scr_seq.0842.script_007")
    game:pressAction()
    game:advanceUntil("typed Trainer Tip opens", function()
      local status = game.runtime.signpost:status()
      return status.active and not status.printDone
    end, 16)
    Assert.isTrue(game.runtime.signpost:status().active, "typed Trainer Tip must remain a production script flow")

    local before = game.runtime.signpost:status()
    game.runtime:pressAction("acceptance")
    local held = game:step()
    game.runtime:releaseAction("acceptance")
    Assert.isTrue(
      held.dialogue.modal == false,
      "Trainer Tip confirmation must not create a field-dialogue side channel"
    )
    local after = game.runtime.signpost:status()
    Assert.isTrue(
      after.revealedGlyphs - before.revealedGlyphs <= 4,
      "fastest Trainer Tips must use the shared two-glyph printer budget per 60 Hz update; delta="
        .. tostring(after.revealedGlyphs - before.revealedGlyphs)
    )
  end)
end

return T
