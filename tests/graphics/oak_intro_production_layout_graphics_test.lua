-- Production Oak composition proofs against the real generated intro
-- manifest: one responsive host scene at representative wide/tall drawable
-- sizes, host-rendered controls with source-backed portraits, and
-- every generated ball/Marill animation frame free of corrupt/empty pixels.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local PixelScale = require("libs.ui.src.PixelScale")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {
  metadata = {
    capabilities = { "graphics", "derived_cache" },
    tags = { "oak", "responsive", "generated-assets" },
  },
  tests = {},
}

local WIDE = { 1920, 1080 }
local TALL = { 390, 844 }

local function layoutForHost(width, height, view, manifest)
  local bounds = { x = 0, y = 0, width = width, height = height }
  local preferredScale = math.max(1, math.floor(height / 192 + 0.5))
  local outputScale = PixelScale.fitPreferred(bounds, 256, 192, preferredScale)
  local surface = PixelScale.cover(bounds, outputScale)
  return OakIntroLayout.compute(
    surface.logicalViewport.width,
    surface.logicalViewport.height,
    view,
    {},
    manifest,
    outputScale
  )
end

---@param inner { x: number, y: number, width: number, height: number }
---@param outer { x: number, y: number, width: number, height: number }
---@return boolean
local function inside(inner, outer)
  assert(inner and outer)
  local epsilon = 1e-9
  return inner.x >= outer.x - epsilon
    and inner.y >= outer.y - epsilon
    and inner.x + inner.width <= outer.x + outer.width + epsilon
    and inner.y + inner.height <= outer.y + outer.height + epsilon
end

---@param first { x: number, y: number, width: number, height: number }
---@param second { x: number, y: number, width: number, height: number }
---@return boolean
local function disjoint(first, second)
  assert(first and second)
  return first.x + first.width <= second.x
    or second.x + second.width <= first.x
    or first.y + first.height <= second.y
    or second.y + second.height <= first.y
end

local function readyManifests()
  local manifests = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      local manifest = assert(cache:loadLua(IntroAssetCache.manifestPath()))
      Assert.isTrue(IntroAssetCache.validateManifest(manifest), "the generated intro manifest must be schema-valid")
      manifests[#manifests + 1] = { versionId = versionId, manifest = manifest }
    end
  end
  Assert.isTrue(#manifests > 0, "derived-cache capability promised a ready game version")
  return manifests
end

-- the world-inhabited/Marill scene is one responsive host surface
-- at wide and tall drawable sizes: the scene spans the full drawable width
-- with no synthetic dual-screen split, and the reveal subject stays framed.
T.tests.reveal_scene_is_one_surface_at_wide_and_tall_sizes = function()
  for _, entry in ipairs(readyManifests()) do
    for _, size in ipairs({ WIDE, TALL }) do
      local view = {
        phase = "oak_world_inhabited",
        visual = "oak",
        primaryWidget = "oak",
        revealWidget = "ball_open",
        oakBgScrollX = -52,
      }
      local layout = layoutForHost(size[1], size[2], view, entry.manifest)
      -- The scene spans the full logical viewport width: no top/bottom DS split.
      Assert.equal(layout.scene.x, 0)
      Assert.equal(layout.scene.width, layout.viewport.width)
      Assert.isTrue(inside(layout.subject, layout.viewport), entry.versionId .. " Oak subject leaves the drawable")
      Assert.isTrue(inside(layout.reveal, layout.viewport), entry.versionId .. " reveal widget leaves the drawable")
    end
  end
end

-- gender selection uses the real generated manifest at wide and
-- tall sizes: regions are contained/disjoint and portraits remain sourced
-- from generated cell-animation assets while their controls are logical.
T.tests.gender_selection_uses_the_production_manifest_at_representative_sizes = function()
  for _, entry in ipairs(readyManifests()) do
    for _, size in ipairs({ WIDE, TALL }) do
      local view = {
        phase = "gender_select",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = 0,
        genderCompositionProgress = 1,
        oakBgScrollX = 0,
      }
      local layout = layoutForHost(size[1], size[2], view, entry.manifest)
      Assert.isTrue(inside(layout.oakRegion, layout.viewport), entry.versionId .. " Oak region leaves the drawable")
      Assert.isTrue(
        inside(layout.selectorRegion, layout.viewport),
        entry.versionId .. " selector region leaves the drawable"
      )
      Assert.isTrue(
        disjoint(layout.oakRegion, layout.selectorRegion),
        entry.versionId .. " Oak and selector regions overlap"
      )
      for gender = 0, 1 do
        if layout.selectorRegion.width >= 256 then
          Assert.isTrue(
            inside(layout.genderButtons[gender].rect, layout.selectorRegion),
            string.format(
              "%s gender choice %d (%.3f,%.3f %.3fx%.3f) leaves the selector panel (%.3f,%.3f %.3fx%.3f)",
              entry.versionId,
              gender,
              layout.genderButtons[gender].rect.x,
              layout.genderButtons[gender].rect.y,
              layout.genderButtons[gender].rect.width,
              layout.genderButtons[gender].rect.height,
              layout.selectorRegion.x,
              layout.selectorRegion.y,
              layout.selectorRegion.width,
              layout.selectorRegion.height
            )
          )
        end
      end
      Assert.isTrue(
        disjoint(layout.genderButtons[0].rect, layout.genderButtons[1].rect),
        entry.versionId .. " gender choices overlap"
      )
      -- Provenance ties each selector widget to a real cell/animation, never
      -- a raw character sheet.
      local male = entry.manifest.widgets.gender_male
      local female = entry.manifest.widgets.gender_female
      Assert.equal(male.provenance.rule, "stable-oam-origin")
      Assert.equal(female.provenance.rule, "stable-oam-origin")
    end
  end
end

-- every ball/Marill animation frame for both ready versions has
-- visible, chromatic pixels; the pinned source center resolves through
-- generated metadata rather than a generic host center.
T.tests.every_ball_and_marill_frame_is_visible_chromatic_and_source_centered = function()
  for _, entry in ipairs(readyManifests()) do
    local cache = CacheFs.forVersion(entry.versionId)
    for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
      local widget = assert(entry.manifest.widgets[id])
      Assert.deepEqual(widget.sourceCenter, { x = 160, y = 80 }, entry.versionId .. " " .. id .. " source center")
      for index, frameEntry in ipairs(widget.frames) do
        local bytes = assert(cache:read(frameEntry.image), "missing " .. id .. " frame " .. index)
        local data = love.image.newImageData(love.filesystem.newFileData(bytes, frameEntry.image))
        local visible, chromatic = false, false
        for y = 0, data:getHeight() - 1 do
          for x = 0, data:getWidth() - 1 do
            local r, g, b, a = data:getPixel(x, y)
            if a > 0 then
              visible = true
              if math.max(r, g, b) - math.min(r, g, b) > 0 then
                chromatic = true
              end
            end
          end
        end
        data:release()
        Assert.isTrue(visible, entry.versionId .. " " .. id .. " frame " .. index .. " is empty")
        Assert.isTrue(chromatic, entry.versionId .. " " .. id .. " frame " .. index .. " is monochrome")
      end
    end
  end
end

return T
