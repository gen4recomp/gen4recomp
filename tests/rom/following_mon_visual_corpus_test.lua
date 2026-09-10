-- Assertions that require the all-reachable-follower producer: the
-- follower visual compiler enumerates every reachable species, form, and
-- gender variant before compiling, so any test that calls it pays the whole
-- follower-corpus cost even when it inspects only one species. The bounded
-- cache-backed representative resolution checks stay in the default tier;
-- everything here runs only when the slow tier is selected.

local Assert = require("tests.support.Assert")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")
local FollowingMonVisualCompiler = require("romdump.src.digest.actor.FollowingMonVisualCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local MonSources = require("romdump.src.config.MonSources")
local manifest = require("romdump.src.config.FieldActors")

local T = {}

local compiledByRomFs = {}

local function compiledFor(romFs)
  local existing = compiledByRomFs[romFs]
  if existing ~= nil then
    return existing
  end
  local compiled = assert(FollowingMonVisualCompiler.compile(romFs))
  compiledByRomFs[romFs] = compiled
  return compiled
end

local CARDINAL_DIRECTIONS = { "north", "south", "west", "east" }
local LOCOMOTION_POSES = { "idle", "walk" }

-- Pokemon field visuals idle from their own source animation: the compiled
-- directional idle pose runs the same facing animation on the same clock as
-- the walk pose instead of a one-frame hold, with the source vertical offset
-- coupled to the animation phase.
local function assertIdleUsesSourceRange(visual, label)
  Assert.deepEqual(visual.idlePresentation, { mode = "animated", cadence = 1 }, label .. " native idle presentation")
  for _, direction in ipairs(manifest.directionOrder) do
    local set = assert(visual.directions[direction], label .. " " .. direction .. " pose set is required")
    local idle = assert(set.idle, label .. " " .. direction .. " idle pose is required")
    local walk = assert(set.walk, label .. " " .. direction .. " walk pose is required")
    Assert.equal(idle.durationTicks, walk.durationTicks, label .. " " .. direction .. " idle keeps source duration")
    Assert.equal(idle.loop, walk.loop, label .. " " .. direction .. " idle keeps source looping")
    Assert.isTrue(idle.durationTicks > 1 and #idle.frames > 1, label .. " " .. direction .. " idle animates")
    local idleFrames, walkFrames = {}, {}
    for _, segment in ipairs(idle.frames) do
      for _ = 1, segment.ticks do
        idleFrames[#idleFrames + 1] = segment.frameIndex
      end
    end
    for _, segment in ipairs(walk.frames) do
      for _ = 1, segment.ticks do
        walkFrames[#walkFrames + 1] = segment.frameIndex
      end
    end
    Assert.deepEqual(idleFrames, walkFrames, label .. " " .. direction .. " idle runs the facing animation")
    local offsets = {}
    for _, segment in ipairs(idle.frames) do
      offsets[segment.displayOffsetY] = true
      Assert.isTrue(
        segment.displayOffsetY == 0 or segment.displayOffsetY < 0,
        label .. " " .. direction .. " idle offset stays grounded"
      )
    end
    Assert.isTrue(offsets[0] == true, label .. " " .. direction .. " idle rests at zero offset")
    local shifted = false
    for offset in pairs(offsets) do
      if offset ~= 0 then
        shifted = true
      end
    end
    Assert.isTrue(shifted, label .. " " .. direction .. " idle couples a vertical offset to its phase")
  end
end

-- One vertical offset observation per normalized idle tick, expanded from
-- the generated segments so uneven source timing cannot hide a phase shift.
local function idleOffsetsPerTick(pose)
  local offsets = {}
  for _, segment in ipairs(pose.frames) do
    for _ = 1, segment.ticks do
      offsets[#offsets + 1] = segment.displayOffsetY
    end
  end
  return offsets
end

local function tickSet(ticks)
  local set = {}
  for _, tick in ipairs(ticks) do
    set[tick] = true
  end
  return set
end

local DEFAULT_SHIFTED_TICKS = tickSet({ 5, 6, 7, 8, 9, 15, 16, 17, 18, 19 })
local PARTNER_SOUTH_SHIFTED_TICKS = tickSet({ 0, 1, 2, 3, 4, 15, 16, 17, 18, 19 })
local PARTNER_SIDE_SHIFTED_TICKS = tickSet({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 })

local function assertIdleShiftWindow(visual, direction, expected, label)
  local pose = assert(visual.directions[direction].idle, label .. " " .. direction .. " idle pose is required")
  local offsets = idleOffsetsPerTick(pose)
  Assert.equal(#offsets, 20, label .. " " .. direction .. " idle runs on the 20-tick clock")
  local magnitudes = {}
  for tick = 0, 19 do
    local offset = offsets[tick + 1]
    local shifted = offset ~= 0
    local want = expected[tick] == true
    Assert.equal(shifted, want, label .. " " .. direction .. " tick " .. tick .. " shift placement")
    if shifted then
      Assert.isTrue(offset < 0, label .. " " .. direction .. " tick " .. tick .. " shift stays grounded")
      magnitudes[offset] = true
    else
      Assert.equal(offset, 0, label .. " " .. direction .. " tick " .. tick .. " rest offset")
    end
  end
  local count = 0
  for _ in pairs(magnitudes) do
    count = count + 1
  end
  Assert.equal(count, 1, label .. " " .. direction .. " idle reuses one bob magnitude")
end

T["starter follower visuals are directional atlases with cardinal idle and walk poses"] = function(romFs)
  local compiled = compiledFor(romFs)
  local starters = {
    { name = "CHIKORITA", speciesId = 152 },
    { name = "CYNDAQUIL", speciesId = 155 },
    { name = "TOTODILE", speciesId = 158 },
  }
  for _, starter in ipairs(starters) do
    local species = starter.name
    local paramIndex =
      assert(MonSources.followerParamIndex(starter.speciesId, 0, false), species .. " resolves a follower parameter")
    local visualId = MonSources.followerVisualId(paramIndex)
    local visual = assert(
      compiled.visuals[visualId],
      species .. " follower visual " .. visualId .. " is compiled by the follower producer"
    )
    Assert.equal(
      visual.render.kind,
      "atlas",
      species .. " follower presents as a directional atlas, never a static model"
    )
    Assert.isTrue(
      FieldActorCache.isValidVisual(visual, visualId),
      species .. " follower visual stays structurally valid"
    )
    Assert.isTrue(visual.render.frameCount > 1, species .. " follower atlas carries more than one frame")
    local observedFrames = {}
    for _, direction in ipairs(CARDINAL_DIRECTIONS) do
      for _, poseName in ipairs(LOCOMOTION_POSES) do
        local pose, fellBack = FieldActorPose.select(visual, direction, poseName)
        Assert.isFalse(
          fellBack,
          species .. " " .. direction .. " " .. poseName .. " is a compiled clip, never an idle substitution"
        )
        for tick = 0, pose.durationTicks - 1 do
          local frameIndex = FieldActorPose.frameIndexAt(pose, tick)
          Assert.isTrue(
            frameIndex >= 1 and frameIndex <= visual.render.frameCount,
            species .. " " .. direction .. " " .. poseName .. " selects a resident atlas frame"
          )
          observedFrames[frameIndex] = true
        end
      end
      local walk = FieldActorPose.select(visual, direction, "walk")
      Assert.isTrue(walk.durationTicks > 1, species .. " " .. direction .. " walk animates across ticks")
    end
    local distinct = 0
    for _ in pairs(observedFrames) do
      distinct = distinct + 1
    end
    Assert.isTrue(
      distinct > 1,
      species
        .. " follower varies atlas frames across facing and locomotion instead of aliasing every pose to one static frame"
    )
  end
end

-- A normal follower species reaches the follower producer through the
-- follower visual pipeline, keyed by its production visual id. (The
-- ordinary Marill/Kyogre/actor assertions over the bounded field-actor
-- compiler stay in the default tier.)
function T.follower_species_reaches_the_follower_producer_with_source_idle(romFs)
  local follower = compiledFor(romFs)
  local chikoritaSprite = assert(
    MonSources.followerSpriteId(152, 0, false),
    "chikorita resolves a source follower sprite through follow_mon selection"
  )
  local chikoritaVisualId =
    MonSources.followerVisualId(assert(MonSources.followerParamIndex(152, 0, false), "chikorita param index"))
  local chikorita = assert(
    follower.visuals[chikoritaVisualId],
    "chikorita follower visual " .. chikoritaVisualId .. " (source sprite " .. chikoritaSprite .. ") must be compiled"
  )
  assertIdleUsesSourceRange(chikorita, "chikorita follower")
end

-- Follower idle-bob phase assertions that require the all-follower
-- compile. (The ordinary Marill control over the bounded field-actor
-- compiler stays in the default tier.)
function T.follower_idle_bob_phase_matches_facing_for_the_flagged_species(romFs)
  local follower = compiledFor(romFs)

  -- A follower without the source flag keeps the generic windows.
  local chikoritaParam =
    assert(MonSources.followerParamIndex(152, 0, false), "chikorita resolves a follower parameter index")
  local chikorita =
    assert(follower.visuals[MonSources.followerVisualId(chikoritaParam)], "chikorita follower visual must be compiled")
  assertIdleUsesSourceRange(chikorita, "chikorita follower")
  for _, direction in ipairs(manifest.directionOrder) do
    assertIdleShiftWindow(chikorita, direction, DEFAULT_SHIFTED_TICKS, "chikorita follower")
  end

  -- A follower carrying the source flag bobs on the facing-specific retail
  -- schedule while running the same facing animation on the same clock.
  local butterfreeParam =
    assert(MonSources.followerParamIndex(12, 0, false), "butterfree resolves a follower parameter index")
  local butterfreeVisualId = MonSources.followerVisualId(butterfreeParam)
  local butterfree = assert(
    follower.visuals[butterfreeVisualId],
    "butterfree follower visual " .. butterfreeVisualId .. " must be compiled"
  )
  assertIdleUsesSourceRange(butterfree, "butterfree follower")
  assertIdleShiftWindow(butterfree, "south", PARTNER_SOUTH_SHIFTED_TICKS, "butterfree follower")
  for _, direction in ipairs({ "north", "west", "east" }) do
    assertIdleShiftWindow(butterfree, direction, PARTNER_SIDE_SHIFTED_TICKS, "butterfree follower")
  end
end

function T.follower_visual_dependencies_track_the_follower_parameter_source(romFs)
  local follower = compiledFor(romFs)
  local resolved = assert(romFs:resolvedNarc("follower_params"), "follower parameter archive must resolve")
  local raw = assert(romFs:read(resolved.fileId), "follower parameter archive bytes must be readable")
  local record =
    assert(follower.dependencies.followerParams, "follower dependencies must name the follower parameter archive")
  Assert.equal(record.symbol, resolved.symbol, "follower parameter symbol")
  Assert.equal(record.alias, resolved.alias, "follower parameter alias")
  Assert.equal(record.narcId, resolved.narcId, "follower parameter narc id")
  Assert.equal(record.fileId, resolved.fileId, "follower parameter file id")
  Assert.equal(record.path, resolved.path, "follower parameter path")
  Assert.equal(record.sha1, Hashing.sha1hex(raw), "follower parameter content hash")
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.slow = true
suite.metadata.tags = { "mon", "following-mon", "visual", "corpus" }
suite.metadata.capabilities = { "rom_dump" }
return suite
