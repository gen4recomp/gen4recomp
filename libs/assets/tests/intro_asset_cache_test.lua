-- Contract scenarios for strict validation of the generated Oak intro class.
-- These fixtures model the public schema only; ROM identities belong to the
-- producer provenance and are intentionally absent here.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")

local T = {}
local WIDGETS = {
  "ball_open",
  "female",
  "gender_female",
  "gender_male",
  "male",
  "marill",
  "marill_appear",
  "oak",
  "shrink_female",
  "shrink_male",
}

local function frame(path, width, height, duration)
  return {
    image = path,
    width = width,
    height = height,
    duration = duration,
    element = "none",
    translateX = 0,
    translateY = 0,
    scaleX = 1,
    scaleY = 1,
    rotation = 0,
    anchor = { x = 16, y = 32 },
  }
end

local function validManifest()
  local widgets = {}
  for _, id in ipairs(WIDGETS) do
    local path = "assets/generated/intro/" .. id .. ".png"
    widgets[id] = {
      image = path,
      width = 32,
      height = 32,
      anchor = { x = 16, y = 32 },
      sourceBounds = { x = 0, y = 0, width = 32, height = 32 },
      sampling = "nearest",
      provenance = { rule = "alpha-crop" },
      frames = { frame(path, 32, 32, 4) },
    }
  end
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    widgets[id].sourceCenter = { x = 160, y = 80 }
  end
  widgets.ball_open.frames = {
    frame("assets/generated/intro/ball-open-0.png", 32, 32, 1),
    frame("assets/generated/intro/ball-open-1.png", 32, 32, 4),
  }
  for _, id in ipairs({ "ball_open", "marill_appear", "marill", "gender_male", "gender_female" }) do
    widgets[id].playMode = id == "marill" and "forward_loop" or "forward"
    widgets[id].loopStartFrameIdx = 0
  end
  widgets.gender_male.sourceCenter = { x = 64, y = 104 }
  widgets.gender_female.sourceCenter = { x = 192, y = 104 }
  return {
    schemaVersion = 10,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = {
      image = "assets/generated/intro/background.png",
      width = 1,
      height = 192,
      sampling = "linear",
      provenance = { charMember = 0, screenMember = 3, paletteMember = 1 },
    },
    genderSelector = {
      defaultTone = { r = 123, g = 45, b = 67 },
      buttons = {
        male = {
          bounds = { x = 18, y = 25, width = 93, height = 148 },
        },
        female = {
          bounds = { x = 144, y = 25, width = 95, height = 148 },
        },
      },
    },
    widgets = widgets,
  }
end

local function reject(cache, mutate, label)
  local manifest = validManifest()
  mutate(manifest)
  local ok, err = cache.validateManifest(manifest)
  Assert.isFalse(ok, label .. " must be rejected")
  Assert.equal(assert(err).code, "INTRO_MANIFEST_INVALID", label .. " has a typed error")
end

function T.complete_schema_manifest_loads_and_declares_closed_inventory()
  local cache = require("libs.assets.src.newgame.IntroAssetCache")
  Assert.equal(cache.SCHEMA, "g4-intro-assets-v10")
  Assert.equal(cache.FORMAT, DerivedAssetContract.intro.cacheFormat)
  local manifest = validManifest()
  Assert.isTrue(cache.validateManifest(manifest))
  Assert.keySet(
    manifest.widgets,
    "ball_open,female,gender_female,gender_male,male,marill,marill_appear,oak,shrink_female,shrink_male"
  )
  Assert.deepEqual(manifest.widgets.gender_male.sourceCenter, { x = 64, y = 104 })
  Assert.deepEqual(manifest.widgets.gender_female.sourceCenter, { x = 192, y = 104 })
  Assert.deepEqual(manifest.genderSelector.buttons.male.bounds, { x = 18, y = 25, width = 93, height = 148 })
  Assert.isNil(manifest.genderSelector.buttons.male.hitBounds)
  Assert.isNil(manifest.profileConfirmation)
end

function T.stale_and_malformed_manifests_fail_before_composition()
  local cache = require("libs.assets.src.newgame.IntroAssetCache")
  local complete = validManifest()
  Assert.isTrue(cache.validateManifest(complete), "the complete schema fixture must be accepted first")
  reject(cache, function(manifest)
    manifest.schemaVersion = 1
  end, "stale schema")
  reject(cache, function(manifest)
    manifest.widgets.ball_open = nil
  end, "missing widget")
  reject(cache, function(manifest)
    manifest.widgets.ball = validManifest().widgets.oak
  end, "unknown widget")
  reject(cache, function(manifest)
    manifest.widgets.oak.anchor.x = 33
  end, "invalid anchor")
  reject(cache, function(manifest)
    manifest.widgets.ball_open.frames[2].width = 31
  end, "inconsistent animation")
  reject(cache, function(manifest)
    manifest.background.width = 2
  end, "incorrect gradient dimensions")
  reject(cache, function(manifest)
    manifest.variant = "unknown"
  end, "invalid variant")
  reject(cache, function(manifest)
    manifest.widgets.ball_open.sourceCenter = nil
  end, "missing ball source center")
  reject(cache, function(manifest)
    manifest.widgets.ball_open.sourceCenter.x = math.huge
  end, "non-finite ball source center")
  reject(cache, function(manifest)
    manifest.widgets.ball_open.sourceCenter.x = 257
  end, "out-of-range ball source center")
  reject(cache, function(manifest)
    manifest.schemaVersion = 9
  end, "stale v9 schema")
  reject(cache, function(manifest)
    manifest.widgets.gender_male.sourceCenter = nil
  end, "missing male selector source center")
  reject(cache, function(manifest)
    manifest.genderSelector.defaultTone = nil
  end, "missing selector default tone")
  reject(cache, function(manifest)
    manifest.genderSelector.defaultTone.r = 256
  end, "invalid selector default tone")
  reject(cache, function(manifest)
    manifest.genderSelector.buttons.male.bounds.width = 0
  end, "invalid gender button bounds")
  reject(cache, function(manifest)
    manifest.genderSelector.buttons.male.backing = "control.png"
  end, "raster gender control field")
  reject(cache, function(manifest)
    manifest.profileConfirmation = {}
  end, "raster confirmation control field")
  reject(cache, function(manifest)
    manifest.genderSelector.buttons.male.hitBounds = { x = 18, y = 25, width = 93, height = 148 }
  end, "removed gender hit bounds")
  reject(cache, function(manifest)
    manifest.widgets.confirmation_yes = {
      image = "assets/generated/intro/confirmation_yes.png",
      width = 120,
      height = 56,
      anchor = { x = 0, y = 0 },
      sourceBounds = { x = 0, y = 0, width = 120, height = 56 },
      sampling = "nearest",
      frames = { frame("assets/generated/intro/confirmation_yes.png", 120, 56, 1) },
    }
  end, "old confirmation widget is unknown")
  reject(cache, function(manifest)
    manifest.widgets.oak.contentRect = { x = 0, y = 0, width = 10, height = 10 }
  end, "obsolete contentRect is rejected")
  reject(cache, function(manifest)
    manifest.widgets.oak.contentRect = { x = 8, y = 16, width = 104, height = 24 }
  end, "obsolete contentRect is rejected")
  reject(cache, function(manifest)
    manifest.schemaVersion = 6
  end, "stale v6 schema")
  reject(cache, function(manifest)
    manifest.unexpected = true
  end, "unknown top-level field")
end

function T.reveal_playback_policy_is_required_and_bounded()
  local cache = require("libs.assets.src.newgame.IntroAssetCache")
  Assert.isTrue(cache.validateManifest(validManifest()), "the playback fixture must be accepted first")
  reject(cache, function(manifest)
    manifest.widgets.marill.playMode = nil
  end, "missing playback policy")
  reject(cache, function(manifest)
    manifest.widgets.marill.playMode = "loop_forever"
  end, "unrecognized playback policy")
  reject(cache, function(manifest)
    manifest.widgets.marill.loopStartFrameIdx = #manifest.widgets.marill.frames
  end, "loop start outside the frame table")
end

function T.semantic_records_do_not_add_files_to_cache_readiness()
  local cache = require("libs.assets.src.newgame.IntroAssetCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local manifest = validManifest()
  backend:write(cacheFs:resolve(cache.markerPath()), "ready")
  cacheFs.loadLua = function(_, path)
    if path == cache.manifestPath() then
      return manifest
    end
    return { schema = cache.PROVENANCE_SCHEMA, source = {}, dependencies = {} }
  end
  cacheFs.exists = function(_, path)
    return path:find("assets/generated/intro/", 1, true) == 1
  end
  Assert.isTrue(cache.isReady(cacheFs, "ready"), "semantic geometry does not require persisted files")
end

function T.intro_contract_revision_requires_the_new_obj_geometry()
  Assert.equal(DerivedAssetContract.revision, 10)
end

return { tests = T }
