-- Direct follower placement through the script runtime: the source
-- reposition command moves the real partner actor to the player-relative
-- tile named by its first byte and faces it per its second byte, in the
-- same tick, with no retained operand state. Selectors past the four
-- cardinal directions keep the copied player tile; an absent partner is a
-- same-tick no-op; stale trail state clears before the direct placement
-- publishes.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FollowingMonController = require("libs.hgss.src.field.FollowingMonController")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local PLAYER_TILE = { fieldX = 4, fieldZ = 5 }

-- First-byte selector to tile delta: north, south, west, east.
local SELECTOR_DELTAS = {
  [0] = { x = 0, z = -1 },
  [1] = { x = 0, z = 1 },
  [2] = { x = -1, z = 0 },
  [3] = { x = 1, z = 0 },
}

-- Second-byte direction mapping shared with field actors.
local DIRECTIONS = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" }

local function terrain()
  return TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
end

local function runtimeMap(mapId)
  return {
    mapId = mapId or 61,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = { events = { objects = {}, background = {}, warps = {}, coordinates = {} } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
      getLocal = function()
        return { blocked = false, behavior = 0 }
      end,
    },
    terrain = terrain(),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    mapSymbol = "test-map",
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
end

local function fakeAssets(known)
  local assets = {
    references = {},
    knows = function(_, spriteId)
      return known[spriteId] == true
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced release of spriteId " .. spriteId)
      self.references[spriteId] = count - 1
    end,
  }
  return assets
end

local function mon(species, personality)
  return {
    species = species or "CHIKORITA",
    form = 0,
    personality = personality or 0x12345678,
    isEgg = false,
    condition = { status = 0, currentHp = 20 },
  }
end

local function service()
  return {
    _revision = 0,
    _slot = nil,
    _mons = {},
    partyRevision = function(self)
      return self._revision
    end,
    leadAliveSlot = function(self)
      return self._slot
    end,
    partyMon = function(self, slot)
      return self._mons[slot]
    end,
    partyCount = function(self)
      local count = 0
      for _ in pairs(self._mons) do
        count = count + 1
      end
      return count
    end,
    setLead = function(self, slot, record)
      self._slot = slot
      if slot ~= nil then
        self._mons[slot] = record
      end
      self._revision = self._revision + 1
    end,
    clearLead = function(self)
      self._slot = nil
      self._revision = self._revision + 1
    end,
  }
end

local function world()
  local map = runtimeMap(61)
  local mgr = FieldActorManager.new({ assets = fakeAssets({ [20153] = true, [20154] = true }), policy = POLICY })
  mgr:enterMap(map, FieldEventState.new())
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = PLAYER_TILE.fieldX,
    fieldZ = PLAYER_TILE.fieldZ,
    surfaceId = 0,
    facing = "south",
  })
  local svc = service()
  local controller = FollowingMonController.new({
    service = svc,
    catalog = CatalogFixture.makeCatalog(),
    actors = mgr,
    playerOf = function()
      return player
    end,
  })
  return { mgr = mgr, map = map, player = player, svc = svc, controller = controller }
end

local function tick(w, count)
  for _ = 1, count or 1 do
    w.controller:update()
  end
end

local function install(w)
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "setup installs the partner")
end

-- Execute the source reposition command through the production script
-- runtime against the live controller. The same-tick outcome and the actor
-- assertions are the contract.
local function place(w, selector, direction)
  local run = {
    instance = { scriptId = "probe.direct-placement", locals = {}, textArgs = {} },
    services = { followingMon = w.controller },
    semantics = RuntimeValues,
    tick = 1,
    input = {},
  }
  local outcome = Runtime.executeNode({ op = "follower_reposition", a = selector, b = direction }, run)
  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE, "the placement resolves in the same tick")
end

local function partnerTile(w)
  local actor = assert(w.mgr:getById("field:partner"), "the partner must be installed")
  return actor
end

function T.selector_matrix_places_the_partner_on_the_expected_tile()
  local w = world()
  install(w)
  for selector = 0, 3 do
    for direction = 0, 3 do
      place(w, selector, direction)
      local delta = assert(SELECTOR_DELTAS[selector], "selector delta is required")
      local actor = partnerTile(w)
      Assert.equal(
        actor:getFieldPosition().fieldX,
        PLAYER_TILE.fieldX + delta.x,
        "selector " .. selector .. " places fieldX"
      )
      Assert.equal(
        actor:getFieldPosition().fieldZ,
        PLAYER_TILE.fieldZ + delta.z,
        "selector " .. selector .. " places fieldZ"
      )
      Assert.equal(actor.facing, DIRECTIONS[direction], "direction byte " .. direction .. " faces the partner")
    end
  end
  w.mgr:dispose()
end

function T.oversized_selector_keeps_the_copied_player_tile()
  local w = world()
  install(w)
  place(w, 4, 1)
  local actor = partnerTile(w)
  Assert.equal(actor:getFieldPosition().fieldX, PLAYER_TILE.fieldX, "an out-of-range selector keeps the player fieldX")
  Assert.equal(actor:getFieldPosition().fieldZ, PLAYER_TILE.fieldZ, "an out-of-range selector keeps the player fieldZ")
  Assert.equal(actor.facing, "south", "the direction byte still faces the partner")
  place(w, 255, 0)
  actor = partnerTile(w)
  Assert.equal(actor:getFieldPosition().fieldX, PLAYER_TILE.fieldX, "the largest byte keeps the player fieldX")
  Assert.equal(actor:getFieldPosition().fieldZ, PLAYER_TILE.fieldZ, "the largest byte keeps the player fieldZ")
  Assert.equal(actor.facing, "north", "the direction byte still faces the partner")
  w.mgr:dispose()
end

function T.vanilla_tail_leaves_the_partner_east_facing_west()
  local w = world()
  install(w)
  place(w, 3, 2)
  local actor = partnerTile(w)
  Assert.equal(actor:getFieldPosition().fieldX, PLAYER_TILE.fieldX + 1, "the tail places the partner one tile east")
  Assert.equal(actor:getFieldPosition().fieldZ, PLAYER_TILE.fieldZ, "the tail keeps the player row")
  Assert.equal(actor.facing, "west", "the tail faces the partner west")
  w.mgr:dispose()
end

function T.absent_partner_makes_the_command_a_same_tick_noop()
  local w = world()
  tick(w, 2)
  Assert.isNil(w.mgr:partnerId(), "an empty party installs no partner")
  place(w, 3, 2)
  Assert.isNil(w.mgr:partnerId(), "the command without a partner installs nothing")
  w.mgr:dispose()
end

function T.direct_placement_clears_stale_trail_state()
  local w = world()
  install(w)
  Assert.isTrue(w.player:tryStep("south"), "the fixture step must commit")
  for _ = 1, 10 do
    w.player:updateFixed({})
  end
  tick(w, 2)
  Assert.isFalse(w.controller:isMovementSettled(), "the queued anchor keeps the follower busy")
  place(w, 1, 1)
  local actor = partnerTile(w)
  Assert.equal(actor:getFieldPosition().fieldX, PLAYER_TILE.fieldX, "the placement recomputes from the player column")
  Assert.equal(
    actor:getFieldPosition().fieldZ,
    PLAYER_TILE.fieldZ + 2,
    "the placement lands one tile south of the moved player"
  )
  Assert.equal(actor.facing, "south", "the placement faces the partner per the direction byte")
  Assert.isTrue(w.controller:isMovementSettled(), "the placement drops the stale trail")
  w.mgr:dispose()
end

return { tests = T }
