-- ROM-conformance facts for the canonical target BDHC payloads and New Bark's
-- east laboratory staircase. These assertions intentionally freeze normalized
-- metadata and the geometric traversal path before FieldPlayer consumes it.

local Assert = require("tests.support.Assert")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local LandData = require("romdump.src.digest.map.LandData")
local HgssBdhc = require("romdump.src.digest.map.HgssBdhc")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local Hashing = require("romdump.src.digest.Hashing")

local T = {}

local function near(actual, expected, epsilon)
  Assert.isTrue(
    math.abs(actual - expected) <= (epsilon or 1e-5),
    string.format("expected %.8f, got %.8f", expected, actual)
  )
end

local function load(romFs, symbol)
  local resolved = assert(MapResolver.resolve(romFs, symbol))
  local bytes = assert(romFs:openNarc("land_data")):readMember(resolved.landDataMemberId)
  local land = assert(
    LandData.decode(bytes, { mapId = resolved.map.id, alias = "land_data", memberId = resolved.landDataMemberId })
  )
  return assert(
    HgssBdhc.decode(
      land.bdhcBytes,
      { mapId = resolved.map.id, alias = "land_data", memberId = resolved.landDataMemberId }
    )
  ),
    resolved
end

function T.target_payloads_decode_completely(romFs)
  local newBark = load(romFs, "MAP_NEW_BARK")
  Assert.deepEqual(newBark.counts, {
    points = 37,
    slopes = 2,
    heights = 3,
    plates = 20,
    strips = 7,
    accessEntries = 47,
  })
  local lab = load(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  Assert.deepEqual(lab.counts, {
    points = 2,
    slopes = 1,
    heights = 1,
    plates = 1,
    strips = 1,
    accessEntries = 1,
  })
  Assert.equal(lab.plates[1].id, 0)
  Assert.equal(lab.plates[1].minX, 0)
  Assert.equal(lab.plates[1].minZ, 0)
  Assert.equal(lab.plates[1].maxX, 32)
  Assert.equal(lab.plates[1].maxZ, 32)
  near(lab.plates[1].distance, 0)
end

function T.every_land_member_bdhc_decodes_completely(romFs)
  local narc = assert(romFs:openNarc("land_data"))
  for memberId = 0, narc:memberCount() - 1 do
    local land =
      assert(LandData.decode(assert(narc:readMember(memberId)), { alias = "land_data", memberId = memberId }))
    local terrain = assert(HgssBdhc.decode(land.bdhcBytes, { alias = "land_data", memberId = memberId }))
    Assert.equal(terrain.counts.plates, #terrain.plates)
    Assert.equal(terrain.counts.accessEntries, #terrain.accessEntries)
  end
end

function T.target_terrain_artifacts_are_deterministic(romFs)
  for _, symbol in ipairs({ "MAP_NEW_BARK", "MAP_NEW_BARK_ELMS_LAB_1F" }) do
    local first = assert(MapAssetCompiler.compile(romFs, symbol))
    local second = assert(MapAssetCompiler.compile(romFs, symbol))
    Assert.equal(first.terrain.schema, "g4-terrain-surfaces-v1")
    Assert.equal(first.scene.terrain.file, first.scene.collision.file:gsub("collision%.g4collision$", "terrain.lua"))
    Assert.equal(Hashing.hashLua(first.terrain), Hashing.hashLua(second.terrain))
    Assert.equal(first.dependencies.bdhcSha1, first.terrain.source.bdhcSha1)
  end
end

function T.new_bark_east_staircase_facts_and_path_are_frozen(romFs)
  local artifact = load(romFs, "MAP_NEW_BARK")
  local terrain = TerrainSurface.new(artifact)
  local stair = artifact.plates[1]
  Assert.equal(stair.id, 0)
  Assert.deepEqual({ stair.minX, stair.minZ, stair.maxX, stair.maxZ }, { 16, 6, 18, 10 })
  local slope = artifact.slopes[stair.slopeIndex + 1]
  Assert.deepEqual({ slope.nxRaw, slope.nyRaw, slope.nzRaw }, { 0, 2896, 2896 })
  near(stair.normal.x, 0)
  near(stair.normal.y, math.sqrt(0.5))
  near(stair.normal.z, math.sqrt(0.5))
  near(terrain:sampleHeight(0, 16.5, 10), 1)
  near(terrain:sampleHeight(0, 16.5, 6), 5)

  -- Plate 4 joins the west half of the lower edge; plate 11 joins the east
  -- half. The upper hold step crosses X while remaining on ramp plate 0.
  near(terrain:sampleHeight(4, 16.5, 10), 1)
  near(terrain:sampleHeight(11, 17.5, 10), 1)
end

function T.field_player_traverses_new_bark_east_staircase(romFs)
  local artifact, resolved = load(romFs, "MAP_NEW_BARK")
  local terrain = TerrainSurface.new(artifact)
  local runtimeMap = {
    mapId = resolved.map.id,
    cameraType = resolved.map.cameraType,
    coordinateOrigin = { x = resolved.worldOriginX, z = resolved.worldOriginZ },
    fieldData = { events = { warps = {} } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = terrain,
    -- Mirrors the simulation-only aggregate: no presentation runtimes, so the
    -- map clock entry is a safe no-op.
    updateAnimated = function() end,
  }
  ---@cast runtimeMap RuntimeFieldMap
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = resolved.worldOriginX + 16,
    fieldZ = resolved.worldOriginZ + 10,
    surfaceId = 4,
    facing = "north",
    occupancy = function()
      return nil
    end,
  })
  local profile = {
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = -8192,
    angleYRaw = 0,
    halfFovRadians = math.rad(15),
    fullVerticalFovRadians = math.rad(30),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }
  local camera = FieldCamera.new(profile, { initialTarget = player:renderPosition() })
  local cameraSamples = {}
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("staircase fixture never starts a warp", 2)
    end,
  }
  ---@cast transition FieldTransition
  local input = {
    snapshot = function()
      return {}
    end,
    clearEdges = function() end,
  }
  ---@cast input FieldInput
  local actors = { step = function() end }
  ---@cast actors FieldActorManager
  local dialogue = {
    isModal = function()
      return false
    end,
  }
  ---@cast dialogue FieldDialogueController
  local scriptScheduler = {
    step = function() end,
    playerInputOwned = function()
      return false
    end,
    foregroundEnvironmentId = function()
      return nil
    end,
    autonomousActorsLocked = function()
      return false
    end,
    autonomousActorLocked = function()
      return false
    end,
  }
  ---@cast scriptScheduler Scheduler
  local scriptClient = { consume = function() end }
  ---@cast scriptClient ScriptInteractionClient
  local menuHost = {
    isModal = function()
      return false
    end,
    advance = function() end,
  }
  ---@cast menuHost FieldMenuHost
  local contextChoice = {
    isActive = function()
      return false
    end,
  } --[[@as ContextChoiceProvider]]
  local signpost = {
    isModal = function()
      return false
    end,
  }
  ---@cast signpost FieldSignpostController
  local interactions = {
    resolve = function()
      return nil
    end,
  }
  local session = FieldSession.new({
    versionId = "rom-conformance",
    currentMap = runtimeMap,
    player = player,
    camera = camera,
    transition = transition,
    input = input,
    actors = actors,
    dialogue = dialogue,
    scriptScheduler = scriptScheduler,
    scriptClient = scriptClient,
    menuHost = menuHost,
    contextChoice = contextChoice,
    signpost = signpost,
    applicationHost = {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function() end,
      takeReopen = function()
        return false
      end,
    },
    interactions = interactions,
    bagUnlocked = function()
      return true
    end,
    fieldEntranceIndicator = { updateFixed = function() end },
    eventResolver = {
      resolveCoordinate = function()
        return nil
      end,
      resolvePassiveSign = function()
        return nil
      end,
    },
    eventState = {
      getVar = function()
        return 0
      end,
    },
  })

  local directions = {
    "north",
    "north",
    "north",
    "north",
    "east",
    "south",
    "south",
    "south",
    "south",
  }
  local committedSurfaces = {}
  for directionIndex, direction in ipairs(directions) do
    local beforeY = player.worldY
    -- TURN_TICKS counts only the three post-init source waits. A changed
    -- direction also consumes its separate initiation tick before the next
    -- arbitration can admit the held walk.
    local turnTicks = direction == player.facing and 0 or FieldPlayer.TURN_TICKS + 1
    local commandTicks = turnTicks + FieldPlayer.WALK_STEP_TICKS
    local changesDirection = directions[directionIndex + 1] ~= direction
    for tick = 1, commandTicks do
      local heldDirection = direction ---@type FieldDirection?
      -- A completion-boundary hold is carried into the next admission tick.
      -- Release only when the next command changes direction, so this fixture
      -- does not request an extra step before that turn.
      if changesDirection and tick == commandTicks then
        heldDirection = nil
      end
      session:updateFixed({
        heldDirection = heldDirection,
        pressedDirection = tick == 1 and direction or nil,
      })
      cameraSamples[#cameraSamples + 1] = {
        sourceY = camera.cameraSourceY,
        appliedY = camera.cameraAppliedY,
      }
      if direction == "north" then
        Assert.isTrue(player.worldY >= beforeY - 1e-9, "stair ascent must be monotonic")
      elseif direction == "south" then
        Assert.isTrue(player.worldY <= beforeY + 1e-9, "stair descent must be monotonic")
      end
      beforeY = player.worldY
    end
    committedSurfaces[#committedSurfaces + 1] = player.surfaceId
  end
  Assert.deepEqual(committedSurfaces, { 0, 0, 0, 0, 0, 0, 0, 0, 11 })
  Assert.equal(player.fieldX, resolved.worldOriginX + 17)
  Assert.equal(player.fieldZ, resolved.worldOriginZ + 10)
  Assert.equal(player.motion, "idle")

  -- The east hold begins after ascent. Its source Y is flat while the recovered
  -- seven-entry history continues applying the earlier slope deltas.
  local firstHoldTick = 4 * FieldPlayer.WALK_STEP_TICKS + 1
  Assert.equal(cameraSamples[firstHoldTick].sourceY, cameraSamples[firstHoldTick - 1].sourceY)
  Assert.isTrue(
    cameraSamples[firstHoldTick].appliedY > cameraSamples[firstHoldTick - 1].appliedY,
    "camera Y should retain the delayed ascent delta"
  )
end

return require("tests.rom.support.RomSuite").fromFacts(T)
