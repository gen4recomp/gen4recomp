-- A real presentation boot proves that the fresh outdoor world exposes its
-- resident physical cells before movement. The test uses only an in-memory
-- save backend; generated maps and presentation assets remain production data.

local Assert = require("tests.support.Assert")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

-- A hand-built fresh candidate, matching the shape App.lua's New Game flow
-- finalizes: no saveStore is attached, so this boots without touching any
-- storage backend and there is nothing to reset between runs.
local function freshGame(versionId)
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = {
      mapSymbol = "MAP_NEW_BARK",
      fieldX = 10,
      fieldZ = 10,
      facing = "south",
    },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "fastest", textFrame = 0 },
    },
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(versionId),
    bag = BagSave.empty(),
  }
end

local function boot(versionId)
  local ok, state = pcall(FieldState.new, freshGame(versionId), {})
  if not ok then
    error(state, 0)
  end
  return state
end

function T.fresh_outdoor_boot_exposes_adjacent_physical_parts(_)
  for _, versionId in ipairs(readyVersions()) do
    local state = boot(versionId)
    local ok, err = xpcall(function()
      local runtime = assert(state.runtime)
      local coverage = assert(runtime.runtimeMap.coverage)
      Assert.equal(
        type(coverage.worldParts),
        "function",
        "fresh outdoor presentation must expose resident physical-cell parts"
      )
      local status = coverage:status()
      local currentHeader = assert(coverage:mapHeaderAt(status.anchorX * 32 + 1, status.anchorZ * 32 + 1))
      local westHeader = assert(coverage:mapHeaderAt((status.anchorX - 1) * 32 + 1, status.anchorZ * 32 + 1))
      Assert.isTrue(westHeader ~= currentHeader, "the adjacent west physical cell must already be Route 29")

      local parts = coverage:worldParts()
      local partKeys = {}
      for _, part in ipairs(parts) do
        partKeys[assert(part.cellKey)] = true
      end
      for _, expectedKey in ipairs(status.residentCellKeys) do
        Assert.isTrue(partKeys[expectedKey] == true, "every resident physical cell must be drawable before entry")
      end

      state:draw()
    end, debug.traceback)
    state:dispose()
    if not ok then
      error(err, 0)
    end
  end
end

function T.outdoor_presentation_keeps_the_committed_world_while_halo_work_is_bounded()
  for _, versionId in ipairs(readyVersions()) do
    local state = boot(versionId)
    local ok, err = xpcall(function()
      local runtime = assert(state.runtime)
      local coverage = assert(runtime.runtimeMap.coverage)
      local before = coverage:status()
      Assert.isTrue(before.queuedPrefetchCount > 0, "the production outdoor map must have halo work to prefetch")

      local acquisitions = 0
      local originalImage = love.graphics.newImage
      local originalMesh = love.graphics.newMesh
      rawset(love.graphics, "newImage", function(...)
        acquisitions = acquisitions + 1
        return originalImage(...)
      end)
      rawset(love.graphics, "newMesh", function(...)
        acquisitions = acquisitions + 1
        return originalMesh(...)
      end)
      local updateOk, updateErr = pcall(runtime.update, runtime, 1 / 60)
      rawset(love.graphics, "newImage", originalImage)
      rawset(love.graphics, "newMesh", originalMesh)
      if not updateOk then
        error(updateErr, 0)
      end

      local after = coverage:status()
      Assert.isTrue(acquisitions <= 1, "one production update must perform at most one atomic presentation acquisition")
      Assert.equal(after.readyPrefetchCount, 0, "a partially built production halo cell must not become ready")
      Assert.equal(after.committedCount, before.committedCount, "halo work must not replace the committed world")
      local parts = coverage:worldParts()
      local partKeys = {}
      for _, part in ipairs(parts) do
        partKeys[assert(part.cellKey)] = true
      end
      for _, expectedKey in ipairs(before.residentCellKeys) do
        Assert.isTrue(partKeys[expectedKey] == true, "committed presentation remains drawable during halo work")
      end
      state:draw()
    end, debug.traceback)
    state:dispose()
    if not ok then
      error(err, 0)
    end
  end
end

function T.everywhere_north_south_cells_draw_real_terrain(_)
  for _, versionId in ipairs(readyVersions()) do
    local state = boot(versionId)
    local ok, err = xpcall(function()
      local runtime = assert(state.runtime)
      local coverage = assert(runtime.runtimeMap.coverage)
      local status = coverage:status()
      local newBarkId = assert(MapCatalog.require("MAP_NEW_BARK").id)
      Assert.equal(
        coverage:mapHeaderAt(status.anchorX * 32 + 1, status.anchorZ * 32 + 1),
        newBarkId,
        "the fresh boot is centered on New Bark"
      )
      for _, dz in ipairs({ -1, 1 }) do
        local cx, cz = status.anchorX, status.anchorZ + dz
        Assert.equal(
          coverage:mapHeaderAt(cx * 32 + 1, cz * 32 + 1),
          0,
          string.format("EVERYWHERE cell %d:%d is committed north/south of New Bark", cx, cz)
        )
      end
      local partsByCell = {}
      for _, part in ipairs(coverage:worldParts()) do
        local cellKey = assert(part.cellKey)
        partsByCell[cellKey] = (partsByCell[cellKey] or 0) + 1
      end
      for _, dz in ipairs({ -1, 1 }) do
        local cellKey = string.format("%d:%d", status.anchorX, status.anchorZ + dz)
        Assert.isTrue(
          (partsByCell[cellKey] or 0) > 0,
          "north/south EVERYWHERE cell " .. cellKey .. " contributes real terrain draws"
        )
      end
      state:draw()
    end, debug.traceback)
    state:dispose()
    if not ok then
      error(err, 0)
    end
  end
end

function T.trainer_reveal_draws_through_the_production_effect_composition()
  for _, versionId in ipairs(readyVersions()) do
    local state = boot(versionId)
    local ok, err = xpcall(function()
      local runtime = assert(state.runtime)
      local player = assert(runtime.player)
      local controller = assert(runtime.fieldTerrainEffectController)
      local handle = controller:emit({
        kind = "trainer_reveal",
        fieldX = player.fieldX,
        fieldZ = player.fieldZ,
        worldY = player.worldY,
      })
      Assert.notNil(handle, "trainer reveal emission must return a handle")
      state:draw()
      Assert.equal(#controller:status().instances, 1, "the trainer reveal instance must stay live for draw")
    end, debug.traceback)
    state:dispose()
    if not ok then
      error(err, 0)
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
