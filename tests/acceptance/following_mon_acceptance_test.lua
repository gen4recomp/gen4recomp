-- Production-composed following-mon contracts: the live party's first
-- eligible mon appears as the reserved partner actor, replays committed
-- player anchors, survives warps, tracks party changes, interacts cleanly,
-- and reconstructs after save/continue. Real ROM-derived maps, the real
-- field runtime, and the real mon service stay in the path; only host
-- boundaries (audio, saves, clock) are faked by the harness. Party setup
-- goes through the production script-gift operation, the same insertion the
-- starter and field-script paths use.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "following-mon", "partner" },
  },
  tests = {},
}

local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local HOUSE_SPAWN = { fieldX = 4, fieldZ = 5, facing = "south" }
local HOUSE_WARP_TILE = { fieldX = 3, fieldZ = 3 }
local HOUSE_2F_ARRIVAL = { fieldX = 3, fieldZ = 4 }

local DIRECTIONS = { "north", "south", "east", "west" }

local function withHouseGame(fn)
  local versionId = AcceptanceHarness.defaultVersion()
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(versionIdOverride, map)
    local game = defaultFactory(versionIdOverride, map)
    if map == HOUSE_1F then
      game.location.fieldX = HOUSE_SPAWN.fieldX
      game.location.fieldZ = HOUSE_SPAWN.fieldZ
      game.location.facing = HOUSE_SPAWN.facing
    end
    return game
  end
  local game = harness:boot({
    versionId = versionId,
    map = HOUSE_1F,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  OpeningLifecycle.seedPostOpeningHouseState(game)
  game:waitForFieldReady()
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "following-mon acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function gift(game, species)
  local added = game.runtime.monService:giveMon({ species = species, level = 5, form = 0 })
  Assert.isTrue(added, "setup gift must enter the party: " .. tostring(species))
end

local function partnerId(game)
  return game.runtime.actors:partnerId()
end

local function waitForPartner(game)
  return game:advanceUntil("follower installation after party gift", function()
    return partnerId(game) ~= nil
  end, 120)
end

local function assertNoFault(game, where)
  Assert.isNil(game.runtime.errorText, "field runtime faulted " .. where .. ": " .. tostring(game.runtime.errorText))
end

local function playerTile(snapshot)
  return { fieldX = snapshot.player.fieldX, fieldZ = snapshot.player.fieldZ }
end

local function sameTile(a, b)
  return a.fieldX == b.fieldX and a.fieldZ == b.fieldZ
end

-- One facing-resolved production step; true only when the player committed
-- to a new tile (turns in place and blocked input report false).
local function tryStep(game, direction)
  game:face(direction)
  local before = playerTile(game:snapshot())
  game:move(direction)
  game:advanceUntil("movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  return not sameTile(playerTile(game:snapshot()), before)
end

-- Deterministic probes only: gather up to `count` committed tiles without
-- any wall-clock wait, erroring loudly when the fixture room cannot supply
-- them rather than wandering the map.
local function committedTrail(game, count)
  local trail = { playerTile(game:snapshot()) }
  for _ = 1, 4 do
    if #trail > count then
      break
    end
    for _, direction in ipairs(DIRECTIONS) do
      if #trail > count then
        break
      end
      if tryStep(game, direction) then
        trail[#trail + 1] = playerTile(game:snapshot())
      end
    end
  end
  Assert.isTrue(
    #trail > count,
    "the fixture room must supply " .. count .. " committed steps, gathered " .. (#trail - 1)
  )
  Assert.equal(game:snapshot().mapSymbol, HOUSE_1F, "probing must not leave the fixture map")
  return trail
end

local function blockedDirection(game)
  -- The spawn's immediate neighbours are all open floor, so walk west to
  -- the room's west wall first: the two setup steps commit normally (the
  -- partner trails them), and the third west probe is blocked by the wall.
  for _ = 1, 4 do
    game:face("west")
    local before = playerTile(game:snapshot())
    game:move("west")
    game:advanceUntil("movement resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    if sameTile(playerTile(game:snapshot()), before) then
      return "west"
    end
    Assert.equal(game:snapshot().mapSymbol, HOUSE_1F, "probing must not leave the fixture map")
  end
  error("the fixture room offers no blocked neighbour for the phantom-step probe", 0)
end

function T.tests.gifted_lead_appears_as_the_reserved_partner_actor()
  withHouseGame(function(game)
    Assert.isNil(partnerId(game), "an empty party installs no partner")
    gift(game, "CHIKORITA")
    local settled = waitForPartner(game)
    assertNoFault(game, "while installing the follower")
    local id = assert(partnerId(game), "the lead gift must install one partner actor")
    Assert.notNil(settled.actors[id], "the partner must be a real actor in the draw/interaction set")
    Assert.equal(id, "field:partner", "the partner keeps its stable actor identity")
    Assert.isTrue(game.runtime.monService:partyCount() == 1, "the party still holds exactly the gifted lead")
  end)
end

function T.tests.partner_replays_committed_player_anchors_in_order()
  withHouseGame(function(game)
    gift(game, "CHIKORITA")
    waitForPartner(game)
    local trail = committedTrail(game, 3)
    local id = assert(partnerId(game), "the partner must survive player movement")
    local vacated = trail[#trail - 1]
    local arrived = game:advanceUntil("partner settles onto the last vacated anchor", function(snapshot)
      local actor = snapshot.actors[id]
      return actor ~= nil and actor.fieldX == vacated.fieldX and actor.fieldZ == vacated.fieldZ
    end, 180)
    assertNoFault(game, "while trailing the player")
    Assert.notNil(arrived.actors[id], "the settled partner stays a real actor")
    local partner = arrived.actors[id]
    Assert.isTrue(
      partner.facing == "north" or partner.facing == "south" or partner.facing == "east" or partner.facing == "west",
      "the settled partner carries a real facing"
    )
  end)
end

function T.tests.blocked_steps_enqueue_no_follower_movement()
  withHouseGame(function(game)
    gift(game, "CHIKORITA")
    waitForPartner(game)
    local id = assert(partnerId(game), "the partner must exist before the blocked probe")
    local wall = blockedDirection(game)
    local playerBefore = playerTile(game:snapshot())
    local partnerBefore = game:snapshot().actors[id]
    Assert.notNil(partnerBefore, "the partner must be observable before blocked input")
    for _ = 1, 3 do
      game:move(wall)
      game:advanceUntil("blocked movement resolves", function(snapshot)
        return snapshot.player.motion == "idle"
      end, 120)
    end
    assertNoFault(game, "while holding into the obstacle")
    Assert.isTrue(sameTile(playerTile(game:snapshot()), playerBefore), "blocked input commits no player step")
    local partnerAfter = game:snapshot().actors[partnerId(game) or id]
    Assert.notNil(partnerAfter, "the partner must still be installed after blocked input")
    Assert.equal(partnerAfter.fieldX, partnerBefore.fieldX, "blocked input moves the partner nowhere")
    Assert.equal(partnerAfter.fieldZ, partnerBefore.fieldZ, "blocked input moves the partner nowhere")
  end)
end

function T.tests.warp_clears_stale_actor_and_reconciles_on_arrival()
  withHouseGame(function(game)
    gift(game, "CHIKORITA")
    waitForPartner(game)
    local before = assert(partnerId(game), "the partner must exist before the warp")
    game:moveTo(HOUSE_WARP_TILE)
    game:advanceUntil("player reaches the stair tile", function(snapshot)
      return snapshot.player.motion == "idle"
        and snapshot.player.fieldX == HOUSE_WARP_TILE.fieldX
        and snapshot.player.fieldZ == HOUSE_WARP_TILE.fieldZ
    end, 120)
    game:step({ direction = "west" })
    local completed = game:waitForTransition()
    assertNoFault(game, "across the stair transition")
    Assert.equal(completed.destination.mapSymbol, HOUSE_2F, "the stairs must land on the upper floor")
    Assert.deepEqual(
      { completed.destination.player.fieldX, completed.destination.player.fieldZ },
      { HOUSE_2F_ARRIVAL.fieldX, HOUSE_2F_ARRIVAL.fieldZ }
    )
    -- Actor entry runs on the map-entry stages after the transition
    -- completes, so the reinstall lands a few ticks after the transition
    -- boundary; wait for it the same way every other scenario does.
    game:advanceUntil("partner reinstalls on the arrival map", function()
      return partnerId(game) ~= nil
    end, 120)
    local after = partnerId(game)
    Assert.notNil(after, "a permitted indoor arrival reinstalls the partner")
    Assert.equal(after, before, "the partner keeps its stable identity across the transition")
    Assert.notNil(game:snapshot().actors[after], "the reinstalled partner is a real actor on the new map")
  end)
end

function T.tests.party_swap_atomically_replaces_the_partner()
  withHouseGame(function(game)
    gift(game, "CHIKORITA")
    gift(game, "TOTODILE")
    waitForPartner(game)
    local before = assert(partnerId(game), "the partner must exist before the swap")
    local tileBefore = game:snapshot().actors[before]
    Assert.notNil(tileBefore, "the partner tile must be observable before the swap")
    local revision = game.runtime.monService:partyRevision()
    game.runtime.monService:swapPartyMons(0, 1)
    Assert.equal(game.runtime.monService:partyRevision(), revision + 1, "the swap publishes one party revision")
    game:step()
    game:step()
    assertNoFault(game, "while replacing the partner visual")
    local after = partnerId(game)
    Assert.notNil(after, "the swapped lead keeps exactly one partner installed")
    Assert.equal(after, before, "replacement reuses the stable partner identity, never a second actor")
    local tileAfter = game:snapshot().actors[after]
    Assert.notNil(tileAfter, "the replaced partner is a real actor")
    Assert.equal(game.runtime.monService:partyMon(0).species, "TOTODILE", "the partner now trails the swapped lead")
  end)
end

function T.tests.lost_lead_clears_the_partner_without_ghosts()
  withHouseGame(function(game)
    gift(game, "CHIKORITA")
    local id = assert(
      (function()
        waitForPartner(game)
        return partnerId(game)
      end)(),
      "the partner must exist before the lead is lost"
    )
    game.runtime.monService:removeMon(0)
    Assert.equal(game.runtime.monService:partyCount(), 0, "the removal empties the party")
    game:advanceUntil("partner clears after the lead is lost", function()
      return partnerId(game) == nil
    end, 120)
    assertNoFault(game, "while clearing the partner")
    Assert.isNil(game:snapshot().actors[id], "the cleared partner leaves no drawable ghost")
  end)
end

function T.tests.facing_the_partner_never_traps_the_field()
  withHouseGame(function(game)
    gift(game, "CHIKORITA")
    waitForPartner(game)
    committedTrail(game, 1)
    local id = assert(partnerId(game), "the partner must be discoverable before interaction")
    for _ = 1, 3 do
      local snapshot = game:snapshot()
      local actor = snapshot.actors[id]
      Assert.notNil(actor, "the partner stays discoverable across interactions")
      local dx = actor.fieldX - snapshot.player.fieldX
      local dz = actor.fieldZ - snapshot.player.fieldZ
      if dx ~= 0 or dz ~= 0 then
        if math.abs(dx) >= math.abs(dz) then
          game:face(dx > 0 and "east" or "west")
        else
          game:face(dz > 0 and "south" or "north")
        end
      end
      game:pressAction()
      game:advanceUntil("interaction settles without a stuck dialogue", function(candidate)
        return not candidate.dialogue.modal and not candidate.fieldLocked
      end, 120)
      assertNoFault(game, "across repeated partner interaction")
    end
    Assert.isFalse(game:snapshot().dialogue.modal, "no empty partner dialogue may persist")
  end)
end

function T.tests.save_and_continue_reconstructs_the_partner()
  withHouseGame(function(game)
    gift(game, "CHIKORITA")
    waitForPartner(game)
    local before = game.runtime.monService:capture()
    local keys = {}
    for key in pairs(before) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    Assert.deepEqual(
      keys,
      { "catalogFingerprint", "party", "rng", "schema" },
      "the saved mons bucket carries party state only, never follower presentation"
    )
    game:save()
    game:restart()
    game:waitForFieldEntry()
    waitForPartner(game)
    assertNoFault(game, "while reconstructing the follower after continue")
    local after = game.runtime.monService:capture()
    Assert.deepEqual(after, before, "save/continue preserves the exact mon identity and party bytes")
    Assert.notNil(partnerId(game), "continue reconstructs exactly one partner from party state")
  end)
end

return T
