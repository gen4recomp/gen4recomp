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

-- Renders one surface presentation into a real canvas through the placement
-- record and returns its ImageData. The manifest drives the rects, so the
-- caller passes the manifest the cache belongs to (the fixture manifest for
-- fixture caches, the real generated manifest for the shared derived cache).
---@param scope GraphicsScope
---@param cacheFs CacheFs
---@param manifest table
---@param cursorSlotId integer
---@param cursorFrameIndex integer
---@param placement StartMenuLayout.Placement
---@param width integer
---@param height integer
---@return love.ImageData
local function canonicalRender(scope, cacheFs, manifest, cursorSlotId, cursorFrameIndex, placement, width, height)
  local lg = love.graphics
  local renderer = scope:own(StartMenuRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local canvas = scope:own(lg.newCanvas(width, height))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  renderer:draw({ cursorSlotId = cursorSlotId, cursorFrameIndex = cursorFrameIndex }, placement)
  lg.setCanvas()
  return scope:own(canvas:newImageData())
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
-- presented cursor frame's solid color centered over the presented slot.
-- Built without the renderer, so a draw regression (wrong rect, wrong
-- position, wrong frame, wrong scale) is a mismatch.
---@param cursorSlotId integer
---@param cursorFrameIndex integer
---@return love.ImageData
local function fixtureReference(cursorSlotId, cursorFrameIndex)
  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local function paste(x, y, r, g, b, a)
    reference:setPixel(math.floor(x), math.floor(y), r, g, b, a)
  end
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local slotId = FieldUiFixture.slotIdAt(x, y)
      if slotId then
        local r, g, b = FieldUiFixture.startMenuSlotColor(slotId)
        paste(x, y, r / 255, g / 255, b / 255, 1)
      end
    end
  end
  local slot = FieldUiFixture.START_MENU_SLOTS[cursorSlotId]
  local frame = FieldUiFixture.START_MENU_CURSOR_FRAMES[cursorFrameIndex + 1]
  local r, g, b = FieldUiFixture.startMenuCursorColor(cursorFrameIndex + 1)
  local originX = slot.x + slot.width / 2 - frame.width / 2
  local originY = slot.y + slot.height / 2 - frame.height / 2
  for y = 0, frame.height - 1 do
    for x = 0, frame.width - 1 do
      paste(originX + x, originY + y, r / 255, g / 255, b / 255, 1)
    end
  end
  return reference
end

-- The independent reference at a non-canonical host resolution: the fixture
-- surface replicated into scale x scale blocks per canonical pixel (the
-- deterministic nearest output of an integer-scale record transform). Built
-- without the renderer and without the layout module, so a wrong record
-- frame/scale in the render path is a mismatch.
---@param cursorSlotId integer
---@param cursorFrameIndex integer
---@param scale integer
---@return love.ImageData
local function scaledFixtureReference(cursorSlotId, cursorFrameIndex, scale)
  local width, height = CANONICAL_WIDTH * scale, CANONICAL_HEIGHT * scale
  local reference = love.image.newImageData(width, height)
  local function block(x, y, r, g, b, a)
    for dy = 0, scale - 1 do
      for dx = 0, scale - 1 do
        reference:setPixel(math.floor(x * scale + dx), math.floor(y * scale + dy), r, g, b, a)
      end
    end
  end
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local slotId = FieldUiFixture.slotIdAt(x, y)
      if slotId then
        local sr, sg, sb = FieldUiFixture.startMenuSlotColor(slotId)
        block(x, y, sr / 255, sg / 255, sb / 255, 1)
      else
        block(x, y, 0, 0, 0, 0)
      end
    end
  end
  local slot = FieldUiFixture.START_MENU_SLOTS[cursorSlotId]
  local frame = FieldUiFixture.START_MENU_CURSOR_FRAMES[cursorFrameIndex + 1]
  local cr, cg, cb = FieldUiFixture.startMenuCursorColor(cursorFrameIndex + 1)
  local originX = slot.x + slot.width / 2 - frame.width / 2
  local originY = slot.y + slot.height / 2 - frame.height / 2
  for y = 0, frame.height - 1 do
    for x = 0, frame.width - 1 do
      block(originX + x, originY + y, cr / 255, cg / 255, cb / 255, 1)
    end
  end
  return reference
end

-- Canonical golden: the full Start Menu surface from the fixture assets
-- matches the independent reference pixel for pixel, with the cursor frame
-- centered over the default (first) slot.
function T.canonical_golden_matches_the_fixture_surface_pixel_for_pixel(scope)
  local rendered = canonicalRender(
    scope,
    FieldUiFixture.startMenuCache(),
    FieldUiFixture.manifest(),
    1,
    0,
    canonicalPlacement(),
    256,
    192
  )
  assertPixelsEqual(fixtureReference(1, 0), rendered, "fixture surface golden")
end

-- The fixture's two cursor frames are distinct artwork at the same slot
-- position: the frame index selects the atlas row, never the placement.
function T.cursor_frames_are_distinct_artwork_at_the_same_position(scope)
  local frame0 = canonicalRender(
    scope,
    FieldUiFixture.startMenuCache(),
    FieldUiFixture.manifest(),
    4,
    0,
    canonicalPlacement(),
    256,
    192
  )
  local frame1 = canonicalRender(
    scope,
    FieldUiFixture.startMenuCache(),
    FieldUiFixture.manifest(),
    4,
    1,
    canonicalPlacement(),
    256,
    192
  )
  assertPixelsEqual(fixtureReference(4, 1), frame1, "fixture cursor frame 1 golden")

  local quantize = function(v)
    return math.floor(v * 255 + 0.5)
  end
  local function pixel(data, x, y)
    local r, g, b, a = data:getPixel(math.floor(x), math.floor(y))
    return quantize(r), quantize(g), quantize(b), quantize(a)
  end
  local slot = FieldUiFixture.START_MENU_SLOTS[4]
  local sampleX = slot.x + slot.width / 2
  local sampleY = slot.y + slot.height / 2
  local f0r, f0g, f0b, f0a = pixel(frame0, sampleX, sampleY)
  local f1r, f1g, f1b, f1a = pixel(frame1, sampleX, sampleY)
  Assert.equal(f0a, 255, "the cursor pixel is opaque")
  Assert.isTrue(f0r ~= f1r or f0g ~= f1g or f0b ~= f1b, "cursor frames have distinct artwork")
  Assert.equal(f0a, f1a, "the cursor frames occupy the same position")
end

-- Record-transform golden: at a non-canonical host resolution the surface
-- renders pixel-exact through the placement record resolved by the real
-- layout module -- the record's frame and scale drive the draw, and the
-- canonical surface never reflows internally.
function T.scaled_golden_matches_the_fixture_surface_through_the_record_transform(scope)
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
  local rendered =
    canonicalRender(scope, FieldUiFixture.startMenuCache(), FieldUiFixture.manifest(), 1, 0, placement, 512, 384)
  assertPixelsEqual(scaledFixtureReference(1, 0, 2), rendered, "scaled record golden")
end

-- The real generated surface is checked before it reaches the renderer so a
-- cursor-only production result cannot be mistaken for a renderer golden.
function T.real_generated_surface_contains_the_retail_background_and_cursor(scope)
  for _, versionId in ipairs(GameVersion.ORDER) do
    local cache = CacheFs.forVersion(versionId)
    if RomImporter.isReady(versionId, cache) then
      local manifest = assert(cache:loadLua(FieldUiAssetCache.manifestPath()), "the manifest must load")
      local background = assert(
        manifest.assets[FieldUiAssetCache.ASSET.START_MENU_BACKGROUND],
        "the generated class indexes the start menu background"
      )
      local cursor = assert(
        manifest.assets[FieldUiAssetCache.ASSET.START_MENU_CURSOR],
        "the generated class indexes the start menu cursor"
      )
      local startMenu = assert(manifest.startMenu, "the generated class carries the start menu section")
      local slots = assert(startMenu.slots, "the start menu section carries slots")
      local frames =
        assert(startMenu.cursor and startMenu.cursor.frames, "the start menu section carries cursor frames")
      local backgroundPixels = scope:own(
        love.image.newImageData(love.filesystem.newFileData(assert(cache:read(background.image)), background.image))
      )
      local cursorPixels =
        scope:own(love.image.newImageData(love.filesystem.newFileData(assert(cache:read(cursor.image)), cursor.image)))
      Assert.equal(backgroundPixels:getWidth(), CANONICAL_WIDTH, versionId .. " background width")
      Assert.equal(backgroundPixels:getHeight(), CANONICAL_HEIGHT, versionId .. " background height")

      local bands = {
        { y = 0, height = 38 },
        { y = 38, height = 38 },
        { y = 76, height = 38 },
        { y = 114, height = 38 },
        { y = 152, height = 38 },
      }
      for _, band in ipairs(bands) do
        local opaque = 0
        for y = band.y, band.y + band.height - 1 do
          for x = 0, CANONICAL_WIDTH - 1 do
            local _, _, _, alpha = backgroundPixels:getPixel(x, y)
            if alpha > 0 then
              opaque = opaque + 1
            end
          end
        end
        Assert.isTrue(opaque > 0, versionId .. " retail background band " .. band.y .. " must contain art")
      end

      local rendered = canonicalRender(scope, cache, manifest, 1, 0, canonicalPlacement(), 256, 192)
      local slot = slots[1]
      local frame = frames[1]
      local originX = slot.x + slot.width / 2 - frame.width / 2
      local originY = slot.y + slot.height / 2 - frame.height / 2
      local cursorVisible = false
      for y = 0, cursorPixels:getHeight() - 1 do
        for x = 0, cursorPixels:getWidth() - 1 do
          local _, _, _, alpha = cursorPixels:getPixel(x, y)
          if alpha > 0 then
            local _, _, _, renderedAlpha = rendered:getPixel(originX + x, originY + y)
            cursorVisible = renderedAlpha > 0
            if cursorVisible then
              break
            end
          end
        end
        if cursorVisible then
          break
        end
      end
      Assert.isTrue(cursorVisible, versionId .. " cursor must be drawn over the selected slot")
    end
  end
end

function T.restores_graphics_state_after_draw(scope)
  local lg = love.graphics
  local renderer = scope:own(
    StartMenuRenderer.new({ cacheFs = FieldUiFixture.startMenuCache(), manifest = FieldUiFixture.manifest() })
  )

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
    { cursorSlotId = 1, cursorFrameIndex = 0 },
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
  local renderer = scope:own(
    StartMenuRenderer.new({ cacheFs = FieldUiFixture.startMenuCache(), manifest = FieldUiFixture.manifest() })
  )

  renderer:release()

  Assert.isNil(renderer._backgroundImage)
  Assert.isNil(renderer._cursorImage)
end

return GraphicsSmoke.suite(T, {
  capabilities = { "graphics", "rom_dump", "derived_cache" },
  tags = { "field", "menu", "real-cache" },
})
