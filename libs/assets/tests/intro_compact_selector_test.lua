-- The generated intro contract carries compact gender-selector metadata only:
-- one default tone plus the two source button bounds. Raster selector masks
-- are not a runtime contract, while the naming subject widgets remain.

local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local Cache = require("libs.assets.src.newgame.IntroAssetCache")

local T = { tests = {} }

local WIDGETS = {
  "ball_open",
  "female",
  "gender_female",
  "gender_male",
  "male",
  "marill",
  "marill_appear",
  "naming_female",
  "naming_male",
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

local function compactManifest()
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
  for _, id in ipairs({ "ball_open", "marill_appear", "marill", "gender_male", "gender_female" }) do
    widgets[id].playMode = id == "marill" and "forward_loop" or "forward"
    widgets[id].loopStartFrameIdx = 0
  end
  for _, id in ipairs({ "naming_male", "naming_female" }) do
    widgets[id].playMode = "forward"
    widgets[id].loopStartFrameIdx = 0
  end
  widgets.gender_male.sourceCenter = { x = 64, y = 104 }
  widgets.gender_female.sourceCenter = { x = 192, y = 104 }
  return {
    schemaVersion = 14,
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
        male = { bounds = { x = 18, y = 25, width = 93, height = 148 } },
        female = { bounds = { x = 144, y = 25, width = 95, height = 148 } },
      },
    },
    widgets = widgets,
  }
end

function T.tests.compact_selector_manifest_validates_with_naming_subjects()
  Assert.equal(Contract.intro.cacheFormat, "intro-cache-v14")
  Assert.equal(Contract.intro.schema, "g4-intro-assets-v14")
  Assert.equal(Cache.SCHEMA, "g4-intro-assets-v14")
  Assert.equal(Cache.FORMAT, "intro-cache-v14")
  local manifest = compactManifest()
  Assert.isTrue(Cache.validateManifest(manifest), "the compact selector manifest must validate")
  Assert.notNil(manifest.widgets.naming_male)
  Assert.notNil(manifest.widgets.naming_female)
  Assert.isNil(manifest.genderSelector.buttons.male.baseImage)
  Assert.isNil(manifest.genderSelector.unselectedRim)
end

function T.tests.selector_mask_fields_are_not_a_current_manifest_shape()
  local manifest = compactManifest()
  manifest.genderSelector.buttons.male.baseImage = "assets/generated/intro/male-base.png"
  manifest.genderSelector.buttons.male.fillMaskImage = "assets/generated/intro/male-fill.png"
  manifest.genderSelector.buttons.male.rimMaskImage = "assets/generated/intro/male-rim.png"
  manifest.genderSelector.buttons.female.baseImage = "assets/generated/intro/female-base.png"
  manifest.genderSelector.buttons.female.fillMaskImage = "assets/generated/intro/female-fill.png"
  manifest.genderSelector.buttons.female.rimMaskImage = "assets/generated/intro/female-rim.png"
  local ok, err = Cache.validateManifest(manifest)
  Assert.isFalse(ok, "selector mask images must be rejected from the compact contract")
  Assert.equal(assert(err).code, "INTRO_MANIFEST_INVALID")
end

function T.tests.previous_mask_schema_version_is_rejected()
  local manifest = compactManifest()
  manifest.schemaVersion = 13
  local ok, err = Cache.validateManifest(manifest)
  Assert.isFalse(ok, "the previous mask-shaped schema version must be rejected")
  Assert.equal(assert(err).code, "INTRO_MANIFEST_INVALID")
end

return T
