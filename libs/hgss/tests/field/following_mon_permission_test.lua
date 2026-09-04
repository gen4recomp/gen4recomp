-- Follower publication follows the source map/species permission: the
-- desired party lead stays separate from whether the current map may show
-- it. Maps that prevent followers publish nothing, height-restricted maps
-- admit only size-zero followers, allowed maps admit every lead, and the
-- two burrowing species stay out of the tower floors even where the map
-- mode itself allows followers. Losing permission clears the visible
-- partner without touching party identity; regaining it republishes the
-- same lead. Unknown map data fails loudly instead of silently allowing.
--
-- Map metadata arrives through an injected read-only lookup keyed by map
-- id; the behavioral assertions below are the contract, not the lookup
-- name. Follower sizes below mirror the generated catalog facts they
-- exercise (zero-size starters and burrowers, nonzero-size legendaries).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FollowingMonController = require("libs.hgss.src.field.FollowingMonController")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

-- Tower floors in source order, with the generated map ids they carry.
local TOWER_FLOORS = {
  { symbol = "MAP_BELL_TOWER_1F", mapId = 111, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_2F", mapId = 332, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_3F", mapId = 333, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_4F", mapId = 334, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_5F", mapId = 335, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_6F", mapId = 336, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_7F", mapId = 337, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_8F", mapId = 338, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_9F", mapId = 339, followMode = "ALLOW" },
  { symbol = "MAP_BELL_TOWER_ROOF", mapId = 340, followMode = "PREVENT" },
  { symbol = "MAP_BELL_TOWER_10F", mapId = 341, followMode = "ALLOW" },
}

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

local function runtimeMap(mapId, followMode, mapSymbol)
  return {
    mapId = mapId,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = followMode,
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
    mapSymbol = mapSymbol,
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

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[deepCopy(key)] = deepCopy(item)
  end
  return out
end

-- The shared synthetic catalog knows only nonzero-size starters, so the
-- size-zero and burrower branches need local species cloned from a valid
-- entry with generated-catalog facts (visual, size, object parameter).
local function catalogWithPermissionSpecies()
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local root = CatalogFixture.buildAssetRoot()
  -- The shared synthetic starter carries a nonzero placeholder size; the
  -- generated catalog fact for the starters is zero, which is what the
  -- height-restriction branch below exercises.
  root.species.CHIKORITA.forms[0].follower.size = 0
  local function addSpecies(key, nativeId, visualId, size, objectParam)
    local entry = deepCopy(assert(root.species.CHIKORITA, "the base species is required"))
    entry.nativeId = nativeId
    entry.name = key
    entry.forms[0].follower = { visualId = visualId, size = size, objectParam = objectParam }
    root.species[key] = entry
  end
  addSpecies("DIGLETT", 50, 20051, 0, 16)
  addSpecies("DUGTRIO", 51, 20052, 0, 16)
  addSpecies("LUGIA", 249, 20282, 1, 273)
  return MonCatalog.new(root)
end

local function mon(species)
  return {
    species = species,
    form = 0,
    personality = 0x12345678,
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

local KNOWN_VISUALS = { [20153] = true, [20154] = true, [20051] = true, [20052] = true, [20282] = true }

-- A world on one map with a read-only metadata lookup covering every map
-- the scenario visits. The lookup is ignored until permission lands, which
-- is exactly what makes the suppression assertions red first.
local function world(maps)
  assert(#maps >= 1, "permission scenarios need at least one map")
  local byId = {}
  for _, entry in ipairs(maps) do
    byId[entry.mapId] = runtimeMap(entry.mapId, entry.followMode, entry.mapSymbol)
  end
  local mgr = FieldActorManager.new({ assets = fakeAssets(KNOWN_VISUALS), policy = POLICY })
  mgr:enterMap(byId[maps[1].mapId], FieldEventState.new())
  local player =
    FieldPlayer.new({ currentMap = byId[maps[1].mapId], fieldX = 4, fieldZ = 5, surfaceId = 0, facing = "south" })
  local svc = service()
  local controller = FollowingMonController.new({
    service = svc,
    catalog = catalogWithPermissionSpecies(),
    actors = mgr,
    playerOf = function()
      return player
    end,
    mapOf = function(mapId)
      return byId[mapId]
    end,
  })
  return {
    mgr = mgr,
    maps = byId,
    player = player,
    svc = svc,
    controller = controller,
    enter = function(self, mapId)
      local map = assert(self.maps[mapId], "the scenario map is required")
      self.mgr:enterMap(map, FieldEventState.new())
      self.player.currentMap = map
    end,
  }
end

local function tick(w, count)
  for _ = 1, count or 1 do
    w.controller:update()
  end
end

function T.allowed_maps_publish_the_desired_lead()
  local w = world({ { mapId = 61, followMode = "ALLOW", mapSymbol = "test-allowed" } })
  w.svc:setLead(0, mon("CHIKORITA"))
  tick(w, 2)
  Assert.equal(w.mgr:partnerId(), "field:partner", "an allowed map publishes the lead")
  Assert.equal(w.mgr:getById("field:partner").spriteId, 20153, "publication keeps the lead visual")
  w.mgr:dispose()
end

function T.prevented_maps_publish_nothing_and_clear_the_partner()
  local w = world({
    { mapId = 61, followMode = "ALLOW", mapSymbol = "test-allowed" },
    { mapId = 198, followMode = "PREVENT", mapSymbol = "test-prevented" },
  })
  w.svc:setLead(0, mon("CHIKORITA"))
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "setup publishes the partner on the allowed map")
  w:enter(198)
  tick(w, 2)
  Assert.isNil(w.mgr:partnerId(), "a prevented map clears the visible partner")
  Assert.equal(w.svc:partyMon(0).species, "CHIKORITA", "suppression never mutates the party lead")
  w.mgr:dispose()
end

function T.height_restriction_admits_size_zero_followers()
  local w = world({ { mapId = 61, followMode = "HEIGHT_RESTRICT", mapSymbol = "test-lab" } })
  w.svc:setLead(0, mon("CHIKORITA"))
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "a size-zero lead stays visible under height restriction")
  w.mgr:dispose()
end

function T.height_restriction_rejects_nonzero_followers()
  local w = world({ { mapId = 61, followMode = "HEIGHT_RESTRICT", mapSymbol = "test-lab" } })
  w.svc:setLead(0, mon("LUGIA"))
  tick(w, 2)
  Assert.isNil(w.mgr:partnerId(), "a nonzero-size lead is suppressed under height restriction")
  w.mgr:dispose()
end

function T.tower_floors_deny_the_burrowers_despite_the_map_mode()
  for _, floor in ipairs(TOWER_FLOORS) do
    for _, species in ipairs({ "DIGLETT", "DUGTRIO" }) do
      local w = world({ { mapId = floor.mapId, followMode = floor.followMode, mapSymbol = floor.symbol } })
      w.svc:setLead(0, mon(species))
      tick(w, 2)
      Assert.isNil(
        w.mgr:partnerId(),
        species .. " stays unpublished on " .. floor.symbol .. " (" .. floor.followMode .. ")"
      )
      w.mgr:dispose()
    end
  end
end

function T.tower_floors_admit_an_ordinary_lead_under_the_map_mode()
  local w = world({ { mapId = 111, followMode = "ALLOW", mapSymbol = "MAP_BELL_TOWER_1F" } })
  w.svc:setLead(0, mon("CHIKORITA"))
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "an ordinary lead follows the tower floor map mode")
  w.mgr:dispose()
end

function T.returning_to_an_allowed_map_republishes_the_same_lead()
  local w = world({
    { mapId = 61, followMode = "ALLOW", mapSymbol = "test-allowed" },
    { mapId = 198, followMode = "PREVENT", mapSymbol = "test-prevented" },
  })
  w.svc:setLead(0, mon("CHIKORITA"))
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "setup publishes the partner")
  w:enter(198)
  tick(w, 2)
  Assert.isNil(w.mgr:partnerId(), "the prevented map clears the visible partner")
  w:enter(61)
  tick(w, 3)
  Assert.equal(w.mgr:partnerId(), "field:partner", "the allowed map republishes without a party change")
  Assert.equal(w.mgr:getById("field:partner").spriteId, 20153, "republication keeps the same lead visual")
  w.mgr:dispose()
end

function T.unknown_map_data_never_silently_allows()
  local w = world({ { mapId = 61, followMode = "SOMEDAY", mapSymbol = "test-unknown" } })
  w.svc:setLead(0, mon("CHIKORITA"))
  local err = Assert.throws(function()
    tick(w, 2)
  end)
  Assert.isTrue(Errors.is(err), "unknown follow data is a structured failure, not silent publication")
  Assert.isNil(w.mgr:partnerId(), "the failure publishes no partner")
  w.mgr:dispose()
end

return { tests = T }
