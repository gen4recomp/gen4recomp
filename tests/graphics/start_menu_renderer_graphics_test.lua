-- Graphics smoke tests for the Start Menu renderer: the canonical 256x192
-- surface renders pixel-exact against an independently composed reference
-- (the fixture's own slot art with the cursor frame centered over the
-- presented slot, and the real generated assets from the shared derived
-- cache when a UI class is present), the surface also renders pixel-exact
-- through a non-canonical placement record from the real layout module (the
-- record transform drives the draw, not a second set of scaled rectangles),
-- every graphics state the draw touched is proven restored against the real
-- driver, and release frees the owned images. The construction/draw failure
-- paths are injected fakes and stay in start_menu_renderer_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PngWriter = require("libs.assets.src.PngWriter")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")
local StartMenuRenderer = require("libs.hgss.src.ui.StartMenuRenderer")

local T = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

-- The placement record for a canonical 256x192 host, resolved through the
-- real pure layout module: the same record hit testing maps through.
local function canonicalPlacement()
  return StartMenuLayout.resolve(
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = CANONICAL_WIDTH, height = CANONICAL_HEIGHT },
      touch = false,
      role = "world",
    }),
    { x = 0, y = 0, width = CANONICAL_WIDTH, height = CANONICAL_HEIGHT },
    1
  )
end

local SUB_R, SUB_G, SUB_B = 20, 40, 160
local NORMAL_R, NORMAL_G, NORMAL_B = 200, 40, 40
local SELECTED_R, SELECTED_G, SELECTED_B = 255, 220, 120

local function recordingText()
  local text = {
    draws = {},
    fontDef = {
      palette = { [15] = { r = 1, g = 2, b = 3 }, [3] = { r = 4, g = 5, b = 6 }, [1] = { r = 7, g = 8, b = 9 } },
    },
  }
  function text.drawText(_, str, x, y)
    text.draws[#text.draws + 1] = { text = str, x = x, y = y }
  end
  function text.drawTextWithPalette(_, str, x, y, palette)
    text.draws[#text.draws + 1] = { text = str, x = x, y = y, palette = palette }
  end
  function text.textWidth(_, str)
    return #str * 8
  end
  return text
end

-- The shared selector fixture: the icon-contract manifest plus the SUB
-- chrome and a banded icon atlas (normal visuals sample the top band,
-- selected visuals the bottom band, so the selected-state swap is
-- pixel-visible). The SUB color appears nowhere else in the fixture art.
local function selectorCacheAndManifest()
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addStartMenuIconContract(manifest)
  local cache = FieldUiFixture.startMenuCache()
  local bands = {}
  for y = 0, 79 do
    local r, g, b = NORMAL_R, NORMAL_G, NORMAL_B
    if y >= 40 then
      r, g, b = SELECTED_R, SELECTED_G, SELECTED_B
    end
    bands[#bands + 1] = string.rep(string.char(r, g, b, 255), 352)
  end
  cache:write("assets/generated/field/ui/start-menu-icons.png", PngWriter.encode(352, 80, table.concat(bands)))
  cache:write(
    "assets/generated/field/ui/start-menu-icon-palette.png",
    PngWriter.encode(16, 2, string.rep(string.char(10, 10, 10, 255), 16 * 2))
  )
  cache:write(
    "assets/generated/field/ui/start-menu-chrome-sub.png",
    PngWriter.encode(256, 256, string.rep(string.char(SUB_R, SUB_G, SUB_B, 255), 256 * 256))
  )
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  return cache, manifest
end

-- Compares two ImageData buffers 8-bit channel by 8-bit channel; a single
-- differing pixel fails with its canonical coordinates.
local function assertPixelsEqual(expected, actual, label)
  Assert.equal(expected:getWidth(), actual:getWidth(), label .. " width")
  Assert.equal(expected:getHeight(), actual:getHeight(), label .. " height")
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local er, eg, eb, ea = expected:getPixel(x, y)
      local ar, ag, ab, aa = actual:getPixel(x, y)
      if
        quantize(er) ~= quantize(ar)
        or quantize(eg) ~= quantize(ag)
        or quantize(eb) ~= quantize(ab)
        or quantize(ea) ~= quantize(aa)
      then
        error(
          string.format(
            "%s: pixel mismatch at (%d,%d): expected (%d,%d,%d,%d) got (%d,%d,%d,%d)",
            label,
            x,
            y,
            quantize(er),
            quantize(eg),
            quantize(eb),
            quantize(ea),
            quantize(ar),
            quantize(ag),
            quantize(ab),
            quantize(aa)
          )
        )
      end
    end
  end
end

-- The independent fixture reference: the slot-colored surface plus the

-- Renders one selector presentation into a real canvas through the
-- placement record and returns its ImageData. The manifest drives the
-- rects, so the caller passes the manifest the cache belongs to.
---@param scope GraphicsScope
---@param cacheFs CacheFs
---@param manifest table
---@param selectedPosition integer
---@param placement StartMenuLayout.Placement
---@param width integer
---@param height integer
---@return love.ImageData
local function selectorRenderInto(scope, cacheFs, manifest, selectedPosition, placement, width, height)
  local lg = love.graphics
  local renderer = scope:own(StartMenuRenderer.new({ cacheFs = cacheFs, manifest = manifest, text = recordingText() }))
  local canvas = scope:own(lg.newCanvas(width, height))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  renderer:draw({
    selectedPosition = selectedPosition,
    trainerGender = "male",
    actions = {
      { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" },
      { id = "vanilla.pokemon", position = 1, icon = 1, label = "POKEMON" },
    },
  }, placement)
  lg.setCanvas()
  return scope:own(canvas:newImageData())
end

-- The independent selector reference: the SUB chrome color everywhere, with
-- each presented action's visual band color pasted at its source anchor plus
-- the visual offset. Built without the renderer, so a wrong background, a
-- wrong visual state, or a wrong draw position is a mismatch. Normal visuals
-- sample the top atlas band, selected visuals the bottom band.
---@param manifest table
---@param selectedPosition integer
---@return love.ImageData
local function selectorReference(manifest, selectedPosition)
  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      reference:setPixel(x, y, SUB_R / 255, SUB_G / 255, SUB_B / 255, 1)
    end
  end
  local interactive = assert(manifest.startMenu.interactive, "the fixture manifest must carry positions")
  local iconTable = assert(manifest.startMenu.iconTable, "the fixture manifest must carry the icon table")
  local presented = {
    { position = 0, icon = 0 },
    { position = 1, icon = 1 },
  }
  for _, action in ipairs(presented) do
    local record = assert(interactive.positions[action.position])
    local row = assert(iconTable[action.icon + 1])
    local visual = assert(row.visual)
    local state = action.position == selectedPosition and visual.selected or visual.normal
    local rect = assert(state.rect)
    local offset = assert(state.offset)
    local selected = action.position == selectedPosition
    local r, g, b = NORMAL_R, NORMAL_G, NORMAL_B
    if selected then
      r, g, b = SELECTED_R, SELECTED_G, SELECTED_B
    end
    for y = 0, rect.height - 1 do
      for x = 0, rect.width - 1 do
        reference:setPixel(record.anchor.x + offset.x + x, record.anchor.y + offset.y + y, r / 255, g / 255, b / 255, 1)
      end
    end
  end
  return reference
end

-- The independent reference at a non-canonical host resolution: the
-- canonical reference replicated into scale x scale blocks per canonical
-- pixel (the deterministic nearest output of an integer-scale record
-- transform). Built without the renderer and without the layout module, so
-- a wrong record frame/scale in the render path is a mismatch.
---@param manifest table
---@param selectedPosition integer
---@param scale integer
---@return love.ImageData
local function scaledSelectorReference(manifest, selectedPosition, scale)
  local flat = selectorReference(manifest, selectedPosition)
  local width, height = CANONICAL_WIDTH * scale, CANONICAL_HEIGHT * scale
  local reference = love.image.newImageData(width, height)
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local r, g, b, a = flat:getPixel(x, y)
      for dy = 0, scale - 1 do
        for dx = 0, scale - 1 do
          reference:setPixel(x * scale + dx, y * scale + dy, r, g, b, a)
        end
      end
    end
  end
  return reference
end

-- Canonical golden: the SUB selector surface from the fixture assets matches
-- the independent reference pixel for pixel, with the selected action
-- drawing its selected visual at its anchor plus offset.
function T.canonical_selector_matches_the_fixture_surface_pixel_for_pixel(scope)
  local cache, manifest = selectorCacheAndManifest()
  local rendered = selectorRenderInto(scope, cache, manifest, 0, canonicalPlacement(), 256, 192)
  assertPixelsEqual(selectorReference(manifest, 0), rendered, "selector surface golden")
end

-- The selected visual is state, not placement: selecting the other action
-- swaps which icon draws from the selected band while the background stays
-- put.
function T.selection_swaps_the_selected_visual_while_the_background_stays_put(scope)
  local cache, manifest = selectorCacheAndManifest()
  local first = selectorRenderInto(scope, cache, manifest, 0, canonicalPlacement(), 256, 192)
  local second = selectorRenderInto(scope, cache, manifest, 1, canonicalPlacement(), 256, 192)
  assertPixelsEqual(selectorReference(manifest, 1), second, "reselected surface golden")
  local different = false
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local r0, g0, b0, a0 = first:getPixel(x, y)
      local r1, g1, b1, a1 = second:getPixel(x, y)
      if r0 ~= r1 or g0 ~= g1 or b0 ~= b1 or a0 ~= a1 then
        different = true
        break
      end
    end
    if different then
      break
    end
  end
  Assert.isTrue(different, "changing selection swaps the selected action visual")
end

-- Record-transform golden: at a non-canonical host resolution the selector
-- renders pixel-exact through the placement record resolved by the real
-- layout module -- the record's frame and scale drive the draw, and the
-- canonical surface never reflows internally.
function T.scaled_selector_matches_through_the_record_transform(scope)
  local placement = StartMenuLayout.resolve(
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      touch = false,
      role = "world",
    }),
    { x = 0, y = 0, width = 512, height = 384 },
    2
  )
  Assert.equal(placement.scale, 2, "the 512x384 host resolves an integer scale of 2")
  Assert.deepEqual(placement.frame, { x = 0, y = 0, width = 512, height = 384 })
  local cache, manifest = selectorCacheAndManifest()
  local rendered = selectorRenderInto(scope, cache, manifest, 0, placement, 512, 384)
  assertPixelsEqual(scaledSelectorReference(manifest, 0, 2), rendered, "scaled selector golden")
end

-- The real generated surface is checked before it reaches the renderer so a
-- cursor-only production result cannot be mistaken for a renderer golden.
-- Source conformance for the replacement icon contract (the single
-- intentionally-paused assertion for this phase): the generated class must
-- carry the 13-row retail icon table (sprite rows with art, text-only rows
-- 9-10, poke-icon row 11), non-blank icon art, main chrome transparent
-- above the panel band, and a non-blank cursor. This fails until the
-- producer emits the retail icon contract; it must not be weakened to pass.
function T.real_generated_start_menu_icons_match_the_retail_source_contract(scope)
  for _, versionId in ipairs(GameVersion.ORDER) do
    local cache = CacheFs.forVersion(versionId)
    if RomImporter.isReady(versionId, cache) then
      local manifest = assert(cache:loadLua(FieldUiAssetCache.manifestPath()), "the manifest must load")
      local startMenu = assert(manifest.startMenu, "the generated class carries the start menu section")
      local iconTable = assert(
        startMenu.iconTable,
        versionId .. " start menu section must carry the retail icon table: the producer does not emit it yet"
      )
      Assert.equal(#iconTable, 13, versionId .. " icon table carries all thirteen retail rows")
      for _, index in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 12, 13 }) do
        Assert.equal((iconTable[index] or {}).art, "sprite", versionId .. " icon row " .. index .. " is a sprite")
      end
      Assert.equal((iconTable[9] or {}).art, "text", versionId .. " icon row 9 is text-only")
      Assert.equal((iconTable[10] or {}).art, "text", versionId .. " icon row 10 is text-only")
      Assert.equal((iconTable[11] or {}).art, "poke_icon", versionId .. " icon row 11 is the poke-icon path")

      local iconsAsset =
        assert(manifest.assets["hgss.start_menu.icons"], versionId .. " generated class indexes the shared icon atlas")
      local iconPixels = scope:own(
        love.image.newImageData(love.filesystem.newFileData(assert(cache:read(iconsAsset.image)), iconsAsset.image))
      )
      local opaque = 0
      for y = 0, iconPixels:getHeight() - 1 do
        for x = 0, iconPixels:getWidth() - 1 do
          local _, _, _, alpha = iconPixels:getPixel(x, y)
          if alpha > 0 then
            opaque = opaque + 1
          end
        end
      end
      Assert.isTrue(opaque > 0, versionId .. " retail icon atlas must contain art")

      local chrome = assert(
        startMenu.chrome and startMenu.chrome.main,
        versionId .. " start menu section must carry its main chrome"
      )
      local chromeAsset =
        assert(manifest.assets[chrome.asset], versionId .. " generated class indexes the main chrome image")
      local chromePixels = scope:own(
        love.image.newImageData(love.filesystem.newFileData(assert(cache:read(chromeAsset.image)), chromeAsset.image))
      )
      local _, _, _, topAlpha = chromePixels:getPixel(0, 0)
      Assert.equal(topAlpha, 0, versionId .. " main chrome is transparent above the panel band")
      local panelOpaque = 0
      for y = 136, chromePixels:getHeight() - 1 do
        for x = 0, chromePixels:getWidth() - 1 do
          local _, _, _, alpha = chromePixels:getPixel(x, y)
          if alpha > 0 then
            panelOpaque = panelOpaque + 1
          end
        end
      end
      Assert.isTrue(panelOpaque > 0, versionId .. " main chrome panel band must contain art")

      local cursor = assert(
        manifest.assets[FieldUiAssetCache.ASSET.START_MENU_CURSOR],
        "the generated class indexes the start menu cursor"
      )
      local cursorPixels =
        scope:own(love.image.newImageData(love.filesystem.newFileData(assert(cache:read(cursor.image)), cursor.image)))
      local cursorOpaque = false
      for y = 0, cursorPixels:getHeight() - 1 do
        for x = 0, cursorPixels:getWidth() - 1 do
          local _, _, _, alpha = cursorPixels:getPixel(x, y)
          if alpha > 0 then
            cursorOpaque = true
            break
          end
        end
        if cursorOpaque then
          break
        end
      end
      Assert.isTrue(cursorOpaque, versionId .. " cursor must contain art")
    end
  end
end

-- The canonical selector surface uses the retail sub-side composition: the
-- sub chrome is the interactive background and no movable main-side cursor
-- sprite travels with the selection. The sub image below is a solid color
-- found nowhere else in the fixture art, and the fixture magenta/cyan cursor
-- frames stay in the legacy surface art, so a main-background pixel or a
-- single cursor pixel anywhere is a surface-ownership mismatch. Selection
-- still has a visible effect (the selected action visual swaps) while the
-- background stays put.
---@param scope GraphicsScope
---@param cache CacheFs
---@param manifest table
---@param selectedPosition integer
---@return love.ImageData
local function selectorRender(scope, cache, manifest, selectedPosition)
  local lg = love.graphics
  local renderer = scope:own(StartMenuRenderer.new({ cacheFs = cache, manifest = manifest, text = recordingText() }))
  local canvas = scope:own(lg.newCanvas(CANONICAL_WIDTH, CANONICAL_HEIGHT))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  renderer:draw({
    selectedPosition = selectedPosition,
    trainerGender = "male",
    actions = {
      { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" },
      { id = "vanilla.pokemon", position = 1, icon = 1, label = "POKEMON" },
    },
  }, canonicalPlacement())
  lg.setCanvas()
  return scope:own(canvas:newImageData())
end

function T.selector_draws_the_sub_background_with_no_movable_main_cursor(scope)
  local cache, manifest = selectorCacheAndManifest()
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  local renders = {}
  for _, selectedPosition in ipairs({ 0, 1 }) do
    local rendered = selectorRender(scope, cache, manifest, selectedPosition)
    renders[#renders + 1] = rendered
    local r, g, b, a = rendered:getPixel(250, 180)
    Assert.deepEqual(
      { quantize(r), quantize(g), quantize(b), quantize(a) },
      { SUB_R, SUB_G, SUB_B, 255 },
      "the selector background is the sub chrome with selection at position " .. selectedPosition
    )
    local cursorPixels = 0
    for y = 0, CANONICAL_HEIGHT - 1 do
      for x = 0, CANONICAL_WIDTH - 1 do
        local pr, pg, pb = rendered:getPixel(x, y)
        local qr, qg, qb = quantize(pr), quantize(pg), quantize(pb)
        if (qr == 255 and qg == 0 and qb == 255) or (qr == 0 and qg == 255 and qb == 255) then
          cursorPixels = cursorPixels + 1
        end
      end
    end
    Assert.equal(
      cursorPixels,
      0,
      "no movable main cursor pixel travels with selection at position " .. selectedPosition
    )
  end
  local different = false
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local r0, g0, b0, a0 = renders[1]:getPixel(x, y)
      local r1, g1, b1, a1 = renders[2]:getPixel(x, y)
      if r0 ~= r1 or g0 ~= g1 or b0 ~= b1 or a0 ~= a1 then
        different = true
        break
      end
    end
    if different then
      break
    end
  end
  Assert.isTrue(different, "changing selection swaps the selected action visual")
end

function T.restores_graphics_state_after_draw(scope)
  local lg = love.graphics
  local cache, manifest = selectorCacheAndManifest()
  local renderer = scope:own(StartMenuRenderer.new({ cacheFs = cache, manifest = manifest, text = recordingText() }))

  local canvas = scope:own(lg.newCanvas(64, 64))
  local shader = lg.getShader()
  lg.setCanvas(canvas)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  renderer:draw(
    {
      selectedPosition = 0,
      actions = { { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" } },
    },
    StartMenuLayout.resolve(
      ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 1280, height = 720 },
        touch = false,
        role = "world",
      }),
      { x = 0, y = 0, width = 1280, height = 720 },
      3
    )
  )

  local function assertRestored(canvasExpected, shaderExpected)
    Assert.equal(lg.getCanvas(), canvasExpected)
    Assert.equal(lg.getShader(), shaderExpected)
    local blend, alpha = lg.getBlendMode()
    Assert.equal(blend, "add")
    Assert.equal(alpha, "alphamultiply")
    local depthMode, depthWrite = lg.getDepthMode()
    Assert.equal(depthMode, "lequal")
    Assert.equal(depthWrite, true)
    Assert.equal(lg.isWireframe(), true)
    Assert.equal(lg.getMeshCullMode(), "back")
    local r, g, b, a = lg.getColor()
    Assert.near(r, 0.2, 1e-6)
    Assert.near(g, 0.4, 1e-6)
    Assert.near(b, 0.6, 1e-6)
    Assert.near(a, 0.8, 1e-6)
    local sx, sy, sw, sh = lg.getScissor()
    Assert.equal(sx, 4)
    Assert.equal(sy, 8)
    Assert.equal(sw, 32)
    Assert.equal(sh, 16)
  end
  assertRestored(canvas, shader)
end

-- Release is the contract here; it is still scoped so a failed assertion does
-- not leak the renderer. The scope's later release exercises repeat safety.
function T.release_frees_the_owned_images(scope)
  local cache, manifest = selectorCacheAndManifest()
  local renderer = scope:own(StartMenuRenderer.new({ cacheFs = cache, manifest = manifest, text = recordingText() }))

  renderer:release()

  Assert.isNil(renderer._subImage)
  Assert.isNil(next(renderer._imageByAsset))
end

return GraphicsSmoke.suite(T, {
  capabilities = { "graphics", "rom_dump", "derived_cache" },
  tags = { "field", "menu", "real-cache" },
})
