-- A real starter follower starts from the player's movement-start transaction
-- through the production field runtime: after an east step and then a south
-- step, the follower is already walking toward the vacated tile while the
-- player step is still in flight, its facing matches the movement
-- direction, and the production draw path selects walk frames from the real
-- generated atlas for that facing. Every step goes through semantic input
-- and the normal update/draw ordering; no synthetic actor definition and no
-- direct mutation of follower state appear anywhere in the path.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorDraw = require("libs.hgss.src.presentation.FieldActorDraw")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_SPAWN = { fieldX = 4, fieldZ = 5, facing = "south" }
local FIXED_DT = 1 / 30
local PARTNER_ACTOR_ID = "field:partner"

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

-- The party gift goes through the production mon service before boot, the
-- same insertion the starter and field-script paths use, so the follower the
-- runtime installs on map entry is a real starter rather than a fixture.
local function giftedGame(versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
  local fontDef = FieldFontLoader.load(cacheFs)
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.empty(catalog:fingerprint(), 7),
    profile = { name = "GOLD", gender = 0, trainerId = 1 },
    game = versionId,
    language = MonCache.loadCatalog(cacheFs).version.language,
    charmap = assert(fontDef.charmap, "production font carries the charmap"),
    mapSection = function()
      return 60
    end,
    date = { year = 2000, month = 1, day = 1 },
  })
  Assert.isTrue(
    service:giveMon({ species = "CYNDAQUIL", level = 5, location = 60 }),
    "the gifted starter enters through the production service"
  )
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = {
      mapSymbol = HOUSE_1F,
      fieldX = HOUSE_SPAWN.fieldX,
      fieldZ = HOUSE_SPAWN.fieldZ,
      facing = HOUSE_SPAWN.facing,
    },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "fastest", textFrame = 0 },
    },
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = service:capture(),
  }
end

local function waitFor(state, label, predicate, bound)
  for _ = 1, bound do
    if predicate() then
      return
    end
    state:update(FIXED_DT)
    state:draw()
  end
  error("timed out waiting for " .. label, 0)
end

local function fieldSettled(runtime)
  local scheduler = assert(runtime.scripts and runtime.scripts.scheduler, "field scheduler is required")
  local dialogue = assert(runtime.dialogue, "field dialogue is required")
  return runtime.transition.phase == "idle"
    and runtime.session.mapEntryStage == nil
    and not dialogue:status().modal
    and not scheduler:playerInputOwned()
end

local function playerTile(runtime)
  return { fieldX = runtime.player.fieldX, fieldZ = runtime.player.fieldZ }
end

local function sameTile(a, b)
  return a.fieldX == b.fieldX and a.fieldZ == b.fieldZ
end

local function partnerOf(runtime)
  return assert(runtime.actors:getById(PARTNER_ACTOR_ID), "the starter follower must stay installed")
end

local function partnerRecordOf(runtime)
  for _, record in ipairs(runtime.actors:drawRecords()) do
    if record.actorId == PARTNER_ACTOR_ID then
      return {
        actorId = record.actorId,
        spriteId = record.spriteId,
        world = { x = record.world.x, y = record.world.y, z = record.world.z },
        facing = record.facing,
        pose = record.pose,
        poseTick = record.poseTick,
        visible = record.visible,
      }
    end
  end
  error("the production draw records must carry the starter follower", 0)
end

local function walkFrameSet(visual, direction)
  local pose = FieldActorPose.select(visual, direction, "walk")
  local frames = {}
  for tick = 0, pose.durationTicks - 1 do
    frames[FieldActorPose.frameIndexAt(pose, tick)] = true
  end
  return frames, pose.durationTicks
end

local function idleFrameSet(visual, direction)
  local pose = FieldActorPose.select(visual, direction, "idle")
  local frames = {}
  for tick = 0, pose.durationTicks - 1 do
    frames[FieldActorPose.frameIndexAt(pose, tick)] = true
  end
  return frames, pose.durationTicks
end

local function frameSetsDiffer(first, second)
  for frame in pairs(first) do
    if second[frame] == nil then
      return true
    end
  end
  for frame in pairs(second) do
    if first[frame] == nil then
      return true
    end
  end
  return false
end

local function countFrames(set)
  local count = 0
  for _ in pairs(set) do
    count = count + 1
  end
  return count
end

-- Drive one player step while sampling every fixed tick from the step's
-- first update until the follower settles back onto the vacated tile. When
-- `followerDirection` is given, the leg is measured: the follower performs a
-- single adjacent action whose direction is read from the observed tiles and
-- must match, with live facing, world translation, and real atlas draw
-- selection asserted along the way.
local function runLeg(state, runtime, visual, drawItemFor, playerDirection, followerDirection)
  waitFor(state, "player idle before " .. playerDirection, function()
    return runtime.player.motion == "idle"
  end, 120)
  -- Face first so the pressed step translates instead of turning in place.
  runtime.player:turn(playerDirection)
  local followerStart = { fieldX = partnerOf(runtime).fieldX, fieldZ = partnerOf(runtime).fieldZ }
  local vacated = playerTile(runtime)
  runtime:press(playerDirection)
  state:update(FIXED_DT)
  state:draw()
  runtime:release(playerDirection)
  local samples = {}
  local committed = false
  local settled = false
  for _ = 1, 240 do
    local actor = partnerOf(runtime)
    local record = partnerRecordOf(runtime)
    samples[#samples + 1] = {
      worldX = actor.worldX,
      worldZ = actor.worldZ,
      facing = actor.facing,
      pose = actor.pose,
      poseTick = actor.poseTick,
      record = record,
    }
    if runtime.player.motion == "idle" and not sameTile(playerTile(runtime), vacated) then
      committed = true
    end
    -- Settlement is logical: the follower sits on the vacated tile with no
    -- movement obligation left. A settled stationary follower presents
    -- native idle, so the pose is not part of the settle condition.
    if
      committed
      and actor.fieldX == vacated.fieldX
      and actor.fieldZ == vacated.fieldZ
      and runtime.followingMon:isMovementSettled()
    then
      settled = true
      break
    end
    state:update(FIXED_DT)
    state:draw()
  end
  Assert.isTrue(committed, "the fixture room must supply a committed " .. playerDirection .. " step")
  Assert.equal(runtime.runtimeMap.mapSymbol, HOUSE_1F, "the fixture path must not leave the fixture map")
  Assert.isTrue(settled, "the follower settles onto the vacated tile after the " .. playerDirection .. " player step")
  Assert.isNil(runtime.errorText, "field runtime faulted trailing " .. playerDirection)
  if followerDirection == nil then
    return nil
  end
  local dx = vacated.fieldX - followerStart.fieldX
  local dz = vacated.fieldZ - followerStart.fieldZ
  local observed = (dx == 1 and dz == 0) and "east"
    or (dx == -1 and dz == 0) and "west"
    or (dx == 0 and dz == 1) and "south"
    or (dx == 0 and dz == -1) and "north"
    or nil
  Assert.notNil(observed, "the follower trails onto the adjacent vacated tile")
  Assert.equal(observed, followerDirection, "the follower replays the vacated tile moving " .. followerDirection)
  local walking = {}
  for _, sample in ipairs(samples) do
    if sample.pose == "walk" then
      walking[#walking + 1] = sample
    end
  end
  Assert.isTrue(#walking > 0, "the follower walks toward the vacated tile, never teleports onto it")
  local axis = (followerDirection == "east" or followerDirection == "west") and "worldX" or "worldZ"
  local low, high = walking[1][axis], walking[1][axis]
  for _, sample in ipairs(walking) do
    Assert.equal(
      sample.facing,
      followerDirection,
      "the follower faces its " .. followerDirection .. " movement direction"
    )
    Assert.equal(sample.record.facing, sample.facing, "the draw record carries the live facing")
    Assert.equal(sample.record.pose, sample.pose, "the draw record carries the live pose")
    Assert.equal(sample.record.poseTick, sample.poseTick, "the draw record carries the live pose clock")
    Assert.isTrue(sample.record.visible, "the walking follower stays visible for draw")
    low = math.min(low, sample[axis])
    high = math.max(high, sample[axis])
  end
  Assert.isTrue(high > low, "the follower world position translates during the " .. followerDirection .. " action")
  local mid = walking[math.ceil(#walking / 2)]
  local item = drawItemFor(mid.record)
  local expectedFrame, fellBack =
    FieldActorPose.frameIndex(visual, mid.record.facing, mid.record.pose, mid.record.poseTick)
  Assert.equal(item.frameIndex, expectedFrame, "draw selects the live walk frame from the real atlas")
  Assert.isFalse(fellBack, "the walk clip exists natively, never as an idle substitution")
  Assert.isFalse(item.poseFellBack, "draw reports no pose fallback for the walking follower")
  Assert.notNil(item.mesh, "the walk frame resolves to a resident atlas mesh")
  local frames = walkFrameSet(visual, followerDirection)
  Assert.isTrue(
    frames[item.frameIndex] == true,
    "the drawn frame belongs to the " .. followerDirection .. " walk range"
  )
  return frames
end

function T.stationary_follower_idles_without_player_input(scope)
  local versions = readyVersions()
  Assert.isTrue(#versions > 0, "a ready imported game version is required")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
    local descriptor =
      assert(catalog:followerSelection({ species = "CYNDAQUIL", form = 0 }), "cyndaquil carries a follower descriptor")
    local state = assert(FieldState.new(giftedGame(versionId), {}))
    local ok, err = xpcall(function()
      local runtime = assert(state.runtime, "field state owns its runtime")
      runtime.scripts.worldState:setVar(FieldScriptSymbols.variablesByName.VAR_SCENE_PLAYERS_HOUSE_1F, 1)
      waitFor(state, "field entry", function()
        return runtime.session.mapEntryStage == nil
      end, 240)
      waitFor(state, "field ready for ordinary input", function()
        return fieldSettled(runtime)
      end, 480)
      Assert.isNil(runtime.errorText, "field runtime faulted on entry: " .. tostring(runtime.errorText))
      waitFor(state, "follower installation", function()
        return runtime.actors:partnerId() ~= nil
      end, 240)
      local visual = assert(
        cacheFs:loadLua(FieldActorCache.visualPath(descriptor.visualId)),
        "the generated starter visual loads from the derived cache"
      )
      local provider = FieldActorAssetProvider.new(cacheFs)
      scope:own({
        release = function()
          provider:dispose()
        end,
      })
      local entry = provider:acquire(descriptor.visualId)
      local function drawItemFor(record)
        local items = FieldActorDraw.itemsInto({ record }, function(spriteId)
          Assert.equal(spriteId, descriptor.visualId, "draw resolves the follower visual")
          return entry --[[@as FieldActorDraw.Entry]]
        end, { items = {}, actorSlots = {}, generation = 0 })
        Assert.equal(#items, 1, "one visible follower record draws exactly one atlas item")
        return items[1]
      end
      -- A stationary follower presents its native idle instead of starting
      -- a scripted movement action: every tick idles with no translation,
      -- the controller stays settled, the drawn frames come from the
      -- generated idle range, and the vertical offset follows the idle
      -- animation phase rather than an independent clock.
      waitFor(state, "follower native idle", function()
        return partnerOf(runtime).pose == "idle"
      end, 240)
      local following = assert(runtime.followingMon, "the field runtime owns its follower controller")
      local leader = playerTile(runtime)
      local follower = partnerOf(runtime)
      local facing = follower.facing
      local baseField = { fieldX = follower.fieldX, fieldZ = follower.fieldZ }
      local baseRecord = partnerRecordOf(runtime)
      local baseTick = follower.poseTick
      local frames = idleFrameSet(visual, facing)
      local idlePose = FieldActorPose.select(visual, facing, "idle")
      Assert.isNil(follower:scriptedMotionState(), "native idle starts no scripted movement action")
      Assert.isTrue(following:isMovementSettled(), "native idle stays logically settled")
      local sawShiftedOffset = false
      for _ = 1, 24 do
        state:update(FIXED_DT)
        state:draw()
        local actor = partnerOf(runtime)
        Assert.equal(actor.pose, "idle", "every stationary tick presents native idle, never locomotion")
        Assert.isNil(actor:scriptedMotionState(), "stationary ticks start no movement action")
        Assert.equal(actor.facing, facing, "native idle must not turn the follower")
        Assert.equal(actor.fieldX, baseField.fieldX, "native idle must not translate the follower")
        Assert.equal(actor.fieldZ, baseField.fieldZ, "native idle must not translate the follower")
        local expectedOffset = FieldActorPose.sampleAt(idlePose, actor.poseTick).displayOffsetY
        Assert.near(
          actor.presentationOffset.y,
          expectedOffset,
          1e-9,
          "the idle vertical offset follows the animation phase"
        )
        if expectedOffset ~= 0 then
          sawShiftedOffset = true
        end
        Assert.isTrue(following:isMovementSettled(), "native idle stays logically settled")
        local record = partnerRecordOf(runtime)
        Assert.equal(record.pose, "idle", "the draw record carries the native idle presentation")
        local item = drawItemFor(record)
        Assert.isTrue(frames[item.frameIndex] == true, "the drawn frame belongs to the idle range")
        Assert.isFalse(item.poseFellBack, "draw reports no pose fallback for the idling follower")
      end
      local after = partnerOf(runtime)
      Assert.isTrue(after.poseTick > baseTick, "native idle advances at its source clock, never holds frame zero")
      Assert.isTrue(sawShiftedOffset, "the sampled idle loop reaches the phase-coupled offset")
      local afterRecord = partnerRecordOf(runtime)
      Assert.near(afterRecord.world.x, baseRecord.world.x, 1e-9, "the idling follower draw anchor stays fixed")
      Assert.near(afterRecord.world.z, baseRecord.world.z, 1e-9, "the idling follower draw depth stays fixed")
      Assert.isNil(runtime.errorText, "field runtime faulted while the follower idled natively")
      Assert.isTrue(sameTile(playerTile(runtime), leader), "stationary sampling uses no player movement")
    end, debug.traceback)
    state:dispose()
    if not ok then
      error(err, 0)
    end
  end
end

function T.real_starter_follower_trails_east_then_south_with_directional_walk_frames(scope)
  local versions = readyVersions()
  Assert.isTrue(#versions > 0, "a ready imported game version is required")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
    local descriptor =
      assert(catalog:followerSelection({ species = "CYNDAQUIL", form = 0 }), "cyndaquil carries a follower descriptor")
    local state = assert(FieldState.new(giftedGame(versionId), {}))
    local ok, err = xpcall(function()
      local runtime = assert(state.runtime, "field state owns its runtime")
      -- Skip the source opening scene the way unrelated field scenarios do:
      -- seed its documented outcome before the first tick so the on-frame
      -- rule never starts it, without disabling map-init evaluation.
      runtime.scripts.worldState:setVar(FieldScriptSymbols.variablesByName.VAR_SCENE_PLAYERS_HOUSE_1F, 1)
      waitFor(state, "field entry", function()
        return runtime.session.mapEntryStage == nil
      end, 240)
      waitFor(state, "field ready for ordinary input", function()
        return fieldSettled(runtime)
      end, 480)
      Assert.isNil(runtime.errorText, "field runtime faulted on entry: " .. tostring(runtime.errorText))
      waitFor(state, "follower installation", function()
        return runtime.actors:partnerId() ~= nil
      end, 240)
      local installed = partnerOf(runtime)
      Assert.equal(
        installed.spriteId,
        descriptor.visualId,
        "the installed follower resolves to the generated starter visual, never a placeholder"
      )
      Assert.isTrue(installed.visible, "the entry-installed follower presents visibly for draw")
      local visual = assert(
        cacheFs:loadLua(FieldActorCache.visualPath(descriptor.visualId)),
        "the generated starter visual loads from the derived cache"
      )
      Assert.equal(visual.render.kind, "atlas", "the runtime follower visual is a directional atlas")
      local provider = FieldActorAssetProvider.new(cacheFs)
      scope:own({
        release = function()
          provider:dispose()
        end,
      })
      local entry = provider:acquire(descriptor.visualId)
      Assert.notNil(entry.visual, "the acquired follower entry carries its generated visual")
      local function drawItemFor(record)
        local items = FieldActorDraw.itemsInto({ record }, function(spriteId)
          Assert.equal(spriteId, descriptor.visualId, "draw resolves the follower visual")
          return entry --[[@as FieldActorDraw.Entry]]
        end, { items = {}, actorSlots = {}, generation = 0 })
        Assert.equal(#items, 1, "one visible follower record draws exactly one atlas item")
        return items[1]
      end

      -- The player path east, east, south, west across the fixture room's
      -- open floor. The follower installs behind the south-facing spawn and
      -- trails one tile behind, so each settled step queues exactly one
      -- anchor: the second east step trails east behind the player and the
      -- closing west step trails south. The measured legs read the
      -- follower's own movement direction from the observed tiles.
      local legFrames = {}
      runLeg(state, runtime, visual, drawItemFor, "east", nil)
      legFrames.east = runLeg(state, runtime, visual, drawItemFor, "east", "east")
      runLeg(state, runtime, visual, drawItemFor, "south", nil)
      legFrames.south = runLeg(state, runtime, visual, drawItemFor, "west", "south")
      for _, direction in ipairs({ "east", "south" }) do
        local frames = assert(legFrames[direction])
        Assert.isTrue(
          countFrames(frames) > 1,
          "the " .. direction .. " walk animates across source frames instead of holding one static frame"
        )
      end
      Assert.isTrue(
        frameSetsDiffer(assert(legFrames.east), assert(legFrames.south)),
        "walk frame selection changes with movement direction"
      )
    end, debug.traceback)
    state:dispose()
    if not ok then
      error(err, 0)
    end
  end
end

-- The follower walks while the player step is still in flight: after a
-- single fixed update of one ordinary east step, the follower already has
-- an active walk toward the vacated tile and keeps translating alongside
-- the player, instead of waiting for the player to settle first.
function T.follower_moves_while_the_player_step_is_in_flight()
  local versions = readyVersions()
  Assert.isTrue(#versions > 0, "a ready imported game version is required")
  for _, versionId in ipairs(versions) do
    local state = assert(FieldState.new(giftedGame(versionId), {}))
    local ok, err = xpcall(function()
      local runtime = assert(state.runtime, "field state owns its runtime")
      runtime.scripts.worldState:setVar(FieldScriptSymbols.variablesByName.VAR_SCENE_PLAYERS_HOUSE_1F, 1)
      waitFor(state, "field entry", function()
        return runtime.session.mapEntryStage == nil
      end, 240)
      waitFor(state, "field ready for ordinary input", function()
        return fieldSettled(runtime)
      end, 480)
      Assert.isNil(runtime.errorText, "field runtime faulted on entry: " .. tostring(runtime.errorText))
      waitFor(state, "follower installation", function()
        return runtime.actors:partnerId() ~= nil
      end, 240)
      local following = assert(runtime.followingMon, "the field runtime owns its follower controller")
      waitFor(state, "player idle before the measured step", function()
        return runtime.player.motion == "idle"
      end, 120)

      -- Face east first so the pressed step translates instead of turning
      -- in place, then drive exactly one fixed update of the step.
      runtime.player:turn("east")
      local vacated = playerTile(runtime)
      local followerStart = { fieldX = partnerOf(runtime).fieldX, fieldZ = partnerOf(runtime).fieldZ }
      runtime:press("east")
      state:update(FIXED_DT)
      runtime:release("east")

      Assert.isTrue(runtime.player.motion ~= "idle", "the player step is still in flight after its first update")
      local dx = vacated.fieldX - followerStart.fieldX
      local dz = vacated.fieldZ - followerStart.fieldZ
      local expected = (dx == 1 and dz == 0) and "east"
        or (dx == -1 and dz == 0) and "west"
        or (dx == 0 and dz == 1) and "south"
        or (dx == 0 and dz == -1) and "north"
        or nil
      Assert.notNil(expected, "the follower target is the adjacent vacated tile")
      Assert.isFalse(following:isMovementSettled(), "the follower starts while the player step is still in flight")
      local partner = partnerOf(runtime)
      Assert.equal(partner.pose, "walk", "the follower walks while the player step is still in flight")
      Assert.equal(partner.facing, expected, "the follower faces the vacated tile while the player is in flight")

      -- A second in-flight tick moves both actors along the same interval.
      local firstX, firstZ = partner.worldX, partner.worldZ
      state:update(FIXED_DT)
      state:draw()
      Assert.isTrue(runtime.player.motion ~= "idle", "the player is still in flight mid-step")
      partner = partnerOf(runtime)
      Assert.equal(partner.pose, "walk", "the follower is still walking mid-step")
      local axis = (expected == "east" or expected == "west") and "worldX" or "worldZ"
      local first = axis == "worldX" and firstX or firstZ
      local second = axis == "worldX" and partner.worldX or partner.worldZ
      Assert.isTrue(second ~= first, "the follower world position translates while the player is in flight")

      -- Both actors then complete the normal step with the follower on the
      -- tile the player vacated.
      waitFor(state, "player commit", function()
        return runtime.player.motion == "idle"
      end, 120)
      Assert.isNil(runtime.errorText, "field runtime faulted trailing the measured step")
      local settled = false
      for _ = 1, 240 do
        local actor = partnerOf(runtime)
        -- Settlement is logical: the follower sits on the vacated tile with
        -- no movement obligation left. A settled stationary follower
        -- presents native idle, so the pose is not part of the settle
        -- condition.
        if actor.fieldX == vacated.fieldX and actor.fieldZ == vacated.fieldZ and following:isMovementSettled() then
          settled = true
          break
        end
        state:update(FIXED_DT)
        state:draw()
      end
      Assert.isTrue(settled, "the follower settles onto the vacated tile after the measured step")
      Assert.isNil(runtime.errorText, "field runtime faulted settling the follower")
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
