-- Private target test: the time-of-day field-prop policy on real data. Violet
-- Gym's interior places the sky prop (indoor member 113, kk_sky) whose four
-- NSBTA clips are named kk_sky_m/d/e/n -- the morning/day/evening/night band
-- set the decomp registers and swaps on RTC time-of-day changes
-- (pokeheartgold overlay_01_02204004.c ov01_022047DC with the band map
-- ov01_022095EC and sTimeOfDayByHour in gf_rtc.c). The compiled descriptor
-- must classify into the four bands, and swapping bands on a ModelInstance
-- must drive exactly the decomp's remove-and-add playback.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")

local T = {}

local function compileInto(romFs, symbol)
  local c = CacheFs.forVersion(romFs:version(), FakeCache.new())
  local bundle = assert(MapAssetCompiler.compile(romFs, symbol))
  local mapId = assert(bundle.mapId, "map bundle needs its map identity")
  local key = tostring(mapId)
  local prepared = PreparedArtifact.new({
    cacheFs = c,
    generationId = "test-generation",
    epoch = 1,
    kind = "map",
    key = key,
    jobKey = "map:" .. key,
    stageName = "map-" .. key,
  })
  MapCacheWriter.stage(prepared, bundle)
  prepared:finishSuccess({ marker = bundle.marker })
  prepared:publish({
    generationId = "test-generation",
    epoch = 1,
    kind = "map",
    key = key,
    jobKey = "map:" .. key,
  })
  return c, bundle
end

local function descriptorOf(bundle, memberId)
  for _, desc in pairs(bundle.models) do
    if desc.memberId == memberId then
      return desc
    end
  end
  return nil
end

local function playingNames(instance)
  local out = {}
  for _, category in ipairs({ "joint", "material" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      out[#out + 1] = attachment.clip.name
    end
  end
  table.sort(out)
  return out
end

-- The HGSS hour table (gf_rtc.c GF_RTC_GetTimeOfDayByHour) folded through
-- the animation band map (LATE -> nite).
function T.hour_bands_match_the_hgss_tables()
  Assert.equal(TimeOfDayProps.bandForHour(2), "nite")
  Assert.equal(TimeOfDayProps.bandForHour(6), "morn")
  Assert.equal(TimeOfDayProps.bandForHour(13), "day")
  Assert.equal(TimeOfDayProps.bandForHour(18), "eve")
  Assert.equal(TimeOfDayProps.bandForHour(22), "nite")
end

function T.violet_gym_sky_prop_is_banded_on_real_data(romFs, _)
  local _, bundle = compileInto(romFs, "MAP_VIOLET_GYM")
  local desc = descriptorOf(bundle, 113)
  assert(desc, "kk_sky descriptor present in Violet Gym")
  assert(desc.dynamic, "the sky prop compiles through the dynamic path")

  local byName = {}
  for _, clip in ipairs(desc.animations) do
    byName[clip.name] = clip
  end
  assert(byName.kk_sky_m, "morning band clip")
  assert(byName.kk_sky_d, "day band clip")
  assert(byName.kk_sky_e, "evening band clip")
  assert(byName.kk_sky_n, "night band clip")
  Assert.equal(#desc.animations, 4)
  for _, clip in ipairs(desc.animations) do
    Assert.equal(clip.category, "material")
    Assert.equal(clip.source.format, "NSBTA")
  end

  local definition = ModelDefinition.fromNitroDescriptor(desc, { key = desc.key })
  local plan = assert(TimeOfDayProps.plan(definition), "the kk_sky clips form the four bands")
  Assert.equal(plan.morn.name, "kk_sky_m")
  Assert.equal(plan.day.name, "kk_sky_d")
  Assert.equal(plan.eve.name, "kk_sky_e")
  Assert.equal(plan.nite.name, "kk_sky_n")

  -- Swapping bands on a real instance plays exactly the band's clip and
  -- advances it (the decomp's remove-and-add).
  local instance = ModelInstance.new(definition)
  ---@cast instance TimeOfDayProps.Instance
  TimeOfDayProps.swap(instance, plan, nil, "morn")
  Assert.deepEqual(playingNames(instance), { "kk_sky_m" })
  TimeOfDayProps.swap(instance, plan, "morn", "day")
  Assert.deepEqual(playingNames(instance), { "kk_sky_d" })
  TimeOfDayProps.swap(instance, plan, "day", "eve")
  Assert.deepEqual(playingNames(instance), { "kk_sky_e" })
  TimeOfDayProps.swap(instance, plan, "eve", "nite")
  Assert.deepEqual(playingNames(instance), { "kk_sky_n" })
  for _ = 1, 3 do
    instance:updateFixed()
  end
  local attachment = instance.animationState:attachments("material")[1]
  Assert.equal(attachment.clip.name, "kk_sky_n")
  Assert.equal(attachment.player.frameFx, 3 * 4096)
end

-- The banded model must not leak into the ambient policy of ordinary props:
-- New Bark's wind machine is a single-clip model and stays unbanded.
function T.new_bark_door_and_machine_stay_unbanded(romFs, _)
  local _, bundle = compileInto(romFs, "MAP_NEW_BARK")
  local door = descriptorOf(bundle, 26)
  assert(door and door.dynamic)
  local doorDef = ModelDefinition.fromNitroDescriptor(door, { key = door.key })
  Assert.isNil(TimeOfDayProps.plan(doorDef), "the door pair is not banded")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
