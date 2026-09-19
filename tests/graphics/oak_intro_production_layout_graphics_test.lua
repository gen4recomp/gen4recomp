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
local REQUIRED_HOSTS = {
  { 640, 480 },
  { 1280, 720 },
  { 1920, 1080 },
  { 2560, 1440 },
  { 512, 768 },
}

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
      Assert.isTrue(
        inside(layout.selectorRegion, layout.viewport),
        entry.versionId .. " selector region leaves the drawable"
      )
      if layout.oakRegion ~= nil then
        Assert.isTrue(inside(layout.oakRegion, layout.viewport), entry.versionId .. " Oak region leaves the drawable")
        Assert.isTrue(
          disjoint(layout.oakRegion, layout.selectorRegion),
          entry.versionId .. " Oak and selector regions overlap"
        )
      else
        Assert.equal(layout.selectorRegion.x, layout.scene.x)
        Assert.equal(layout.selectorRegion.width, layout.scene.width)
      end
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

T.tests.gender_selection_contains_both_cards_and_hit_regions_at_supported_hosts = function()
  for _, entry in ipairs(readyManifests()) do
    for _, size in ipairs(REQUIRED_HOSTS) do
      local view = {
        phase = "gender_select",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = 0,
        genderCompositionProgress = 1,
        oakBgScrollX = 0,
      }
      local layout = layoutForHost(size[1], size[2], view, entry.manifest)
      local viewport = assert(layout.viewport)
      local selector = assert(layout.selectorRegion)
      ---@type { scale: number, rect: { x: number, y: number, width: number, height: number }, portraitRect: { x: number, y: number, width: number, height: number } }
      local first = assert(layout.genderButtons and layout.genderButtons[0])
      ---@type { scale: number, rect: { x: number, y: number, width: number, height: number }, portraitRect: { x: number, y: number, width: number, height: number } }
      local second = assert(layout.genderButtons and layout.genderButtons[1])
      Assert.isTrue(first.scale > 0 and first.scale == math.floor(first.scale), "selector scale must be integral")
      Assert.equal(second.scale, first.scale, "gender cards must share one selector scale")
      for _, card in ipairs({ first, second }) do
        local label = string.format("%s at %dx%d", entry.versionId, size[1], size[2])
        Assert.isTrue(inside(card.rect, viewport), label .. " gender card must stay inside the logical viewport")
        Assert.isTrue(inside(card.rect, selector), label .. " gender card hit region must stay inside selector region")
        Assert.isTrue(
          inside(card.portraitRect, viewport),
          label .. " gender portrait must stay inside the logical viewport"
        )
        Assert.isTrue(inside(card.portraitRect, card.rect), label .. " gender portrait must stay inside its card")
      end
      Assert.isTrue(disjoint(first.rect, second.rect), "gender card hit regions must remain disjoint")
    end
  end
end

-- the generated intro holds Oak vertically still while the reveal swaps
-- from ball to Marill appearances and away, and keeps both gender cards
-- portrait-complete and clear of dialogue on wide hosts.
local openingLifecycle = {
  { phase = "oak_world_inhabited", revealWidget = nil },
  { phase = "ball_open_wait", revealWidget = "ball_open" },
  { phase = "scene_flash", revealWidget = "ball_open" },
  { phase = "marill_appear", revealWidget = "marill_appear" },
  { phase = "marill_brightness_fade", revealWidget = "marill_appear" },
  { phase = "marill_cry_wait", revealWidget = "marill" },
  { phase = "oak_live_alongside", revealWidget = "marill" },
  { phase = "marill_hide", revealWidget = "marill" },
  { phase = "marill_hide_wait", revealWidget = nil },
  { phase = "oak_slide_left", revealWidget = nil },
  { phase = "oak_tell_about_yourself", revealWidget = nil },
}

T.tests.opening_lifecycle_keeps_production_oak_stable_and_cards_clear = function()
  for _, entry in ipairs(readyManifests()) do
    for _, size in ipairs({ { 1920, 1080 }, { 2560, 1440 } }) do
      local label = string.format("%s at %dx%d", entry.versionId, size[1], size[2])
      local baseline = nil
      for _, step in ipairs(openingLifecycle) do
        local view = { phase = step.phase, visual = "oak", primaryWidget = "oak", oakBgScrollX = 0 }
        if step.revealWidget ~= nil then
          view.revealWidget = step.revealWidget
        end
        local layout = layoutForHost(size[1], size[2], view, entry.manifest)
        local subject = assert(layout.subject, label .. " Oak must stay visible during " .. step.phase)
        if baseline == nil then
          baseline = subject
        else
          Assert.equal(
            subject.y,
            baseline.y,
            label .. " Oak Y must not move across reveal changes (" .. step.phase .. ")"
          )
          Assert.equal(
            subject.height,
            baseline.height,
            label .. " Oak height must not change across reveal changes (" .. step.phase .. ")"
          )
          Assert.equal(
            subject.scale,
            baseline.scale,
            label .. " Oak scale must not change across reveal changes (" .. step.phase .. ")"
          )
        end
      end
      for _, phase in ipairs({ "gender_select", "gender_confirm" }) do
        local view = {
          phase = phase,
          visual = "oak",
          primaryWidget = "oak",
          genderFocus = 0,
          genderCompositionProgress = 1,
          oakBgScrollX = 0,
        }
        if phase == "gender_confirm" then
          view.confirmationChoice = { kind = "gender", selected = 0 }
        end
        local layout = layoutForHost(size[1], size[2], view, entry.manifest)
        local dialogueRect =
          assert(assert(layout.dialogue).outerRect, label .. " selector must reserve dialogue (" .. phase .. ")")
        local selector = assert(layout.selectorRegion, label .. " selector must publish a region (" .. phase .. ")")
        local cards = {}
        if phase == "gender_select" then
          cards = { assert(layout.genderButtons[0]), assert(layout.genderButtons[1]) }
          Assert.isTrue(disjoint(cards[1].rect, cards[2].rect), label .. " gender cards must remain disjoint")
        else
          cards = { assert(layout.selectedProfileButton) }
        end
        for _, card in ipairs(cards) do
          Assert.isTrue(
            inside(card.rect, selector),
            label .. " gender card must stay inside the selector region (" .. phase .. ")"
          )
          Assert.isTrue(
            inside(card.portraitRect, card.rect),
            label .. " gender portrait must stay inside its card (" .. phase .. ")"
          )
          Assert.isTrue(
            card.rect.y + card.rect.height < dialogueRect.y,
            label .. " gender card must keep clearance above dialogue (" .. phase .. ")"
          )
        end
      end
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
