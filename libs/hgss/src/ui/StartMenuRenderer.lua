-- Renders the authentic Start Menu surface through the placement record from
-- StartMenuLayout: the generated menu background (the icon art is baked into
-- the compiled PNG) and the animated cursor frame over the presented action
-- slot. The generated field-UI manifest's `startMenu` section is the single
-- geometry authority: the background rect, the logical slot rects, and the
-- cursor frames with their durations. Runtime code
-- addresses slots by the manifest's own slot ids and never repeats source
-- coordinates. The cursor animation state is the controller's fixed-tick
-- concern; this renderer consumes only the frame index from the
-- presentation snapshot, so render refresh rate cannot change the animation
-- speed. An open menu always has a selection, so the presentation requires
-- the cursor slot and frame index; the nil presentation is the closed-menu
-- no-op. Drawing and hit testing consume the same StartMenuLayout placement
-- record (hostToLogical): the surface draws under translate(frame origin) +
-- scale(placement scale)
-- in canonical coordinates, so rendering and hit testing share one record
-- with no second set of scaled rectangles. The surface is not a generic
-- list menu: only the two generated images are drawn, at identity tint, with
-- no theme colors or styled primitives. Construction is failure-safe: a
-- missing background or cursor asset is a typed error, a quad failure after
-- the images were created releases them before rethrowing, and draw()
-- restores every graphics state it touches. The runtime-validated manifest
-- is injected explicitly; this renderer never reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

---@class StartMenuRenderer
---@field _graphics love.graphics
---@field _backgroundImage love.Image?
---@field _cursorImage love.Image?
---@field _backgroundQuad love.Quad?
---@field _cursorQuads love.Quad[]? per cursor-frame quads, built once
---@field menu StartMenuRenderer.Menu the resolved manifest surface geometry
local StartMenuRenderer = {}
StartMenuRenderer.__index = StartMenuRenderer

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (Start Menu PNGs); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData).

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, graphics?: unknown }
---@return StartMenuRenderer
function StartMenuRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "StartMenuRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "StartMenuRenderer requires love.graphics")
  ---@cast graphics love.graphics
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "StartMenuRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the Start Menu background/cursor PNGs and every rect. The runtime
  -- boot already validated the full manifest; the renderer resolves what it
  -- draws.
  local startMenu = assert(manifest.startMenu, "the field-UI manifest must carry the start menu section")
  local backgroundAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.START_MENU_BACKGROUND],
    "the field-UI manifest must carry the start menu background asset"
  )
  local cursorAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.START_MENU_CURSOR],
    "the field-UI manifest must carry the start menu cursor asset"
  )
  local backgroundPath = assert(backgroundAsset.image, "the start menu background asset must name an image path")
  local cursorPath = assert(cursorAsset.image, "the start menu cursor asset must name an image path")

  local self = setmetatable({
    _graphics = graphics,
    _backgroundImage = nil,
    _cursorImage = nil,
    _backgroundQuad = nil,
    _cursorQuads = nil,
    menu = {
      background = startMenu.background,
      slots = startMenu.slots,
      cursor = { frames = startMenu.cursor.frames },
    },
  }, StartMenuRenderer)

  local backgroundData = cacheFs:read(backgroundPath)
  if not backgroundData then
    Errors.raise(
      FieldErrors.FIELD_UI_START_MENU_BACKGROUND_MISSING,
      "start menu background missing at " .. backgroundPath,
      {
        path = backgroundPath,
      }
    )
  end
  backgroundData = assert(backgroundData)
  self._backgroundImage = graphics.newImage(love.filesystem.newFileData(backgroundData, backgroundPath))
  local cursorData = cacheFs:read(cursorPath)
  if not cursorData then
    self:release()
    Errors.raise(FieldErrors.FIELD_UI_START_MENU_CURSOR_MISSING, "start menu cursor missing at " .. cursorPath, {
      path = cursorPath,
    })
  end
  cursorData = assert(cursorData)
  local ok, err = pcall(function()
    self._backgroundImage:setFilter("nearest", "nearest")
    self._cursorImage = graphics.newImage(love.filesystem.newFileData(cursorData, cursorPath))
    self._cursorImage:setFilter("nearest", "nearest")
    self:_buildQuads()
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- The quads are the manifest rects inside their atlases: one for the
-- background surface, one per cursor frame.
function StartMenuRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local background = assert(self._backgroundImage)
  local backgroundRect = self.menu.background
  self._backgroundQuad = lg.newQuad(
    backgroundRect.x,
    backgroundRect.y,
    backgroundRect.width,
    backgroundRect.height,
    background:getWidth(),
    background:getHeight()
  )
  local cursor = assert(self._cursorImage)
  local quads = {}
  for index, frame in ipairs(self.menu.cursor.frames) do
    quads[index] = lg.newQuad(frame.x, frame.y, frame.width, frame.height, cursor:getWidth(), cursor:getHeight())
  end
  self._cursorQuads = quads
end

-- The cursor frame's reference position for a presented slot: centered on
-- the slot rect from the manifest, sized by the frame rect. Derived purely
-- from the manifest geometry; no source coordinates are repeated.
---@param slot FieldDialogueTheme.Rect
---@param frame FieldDialogueTheme.Rect
---@return number x
---@return number y
function StartMenuRenderer:_cursorPosition(slot, frame)
  return slot.x + slot.width / 2 - frame.width / 2, slot.y + slot.height / 2 - frame.height / 2
end

-- Draws the canonical menu surface through the placement record: the
-- background image over the manifest background rect and the cursor frame
-- (selected by the presentation's frame index, advanced by the pure
-- fixed-tick animation state the controller owns) centered over the
-- presented manifest slot, all under translate(frame origin) + scale(record
-- scale) so the record's frame is exactly where the surface lands and
-- hostToLogical's inverse transform maps hit points back onto the same
-- canonical coordinates. No-op (and no state touched) when this renderer
-- has no images. Restores canvas, shader, scissor, blend, depth, wireframe,
-- cull, and color afterwards so the HUD and host overlays draw normally.

---@param presentation { cursorSlotId: integer, cursorFrameIndex: integer }?
---@param placement StartMenuLayout.Placement
function StartMenuRenderer:draw(presentation, placement)
  if not presentation or not self._backgroundImage then
    return
  end
  assert(
    placement ~= nil and type(placement.frame) == "table" and type(placement.scale) == "number",
    "the start menu surface requires the placement record"
  )
  local lg = assert(self._graphics)
  FieldDrawState.protectedDraw(lg, function()
    -- Everything draws in canonical coordinates under the placement record's
    -- transform: translate(frame origin) + scale(record scale). The manifest
    -- rects are canonical, so nothing is scaled twice. An open menu always
    -- has a selection, so the presentation's cursor slot and frame are
    -- validated before anything reaches the graphics namespace.
    lg.translate(placement.frame.x, placement.frame.y)
    lg.scale(placement.scale, placement.scale)
    lg.setColor(1, 1, 1, 1)
    assert(
      type(presentation.cursorSlotId) == "number" and presentation.cursorSlotId % 1 == 0,
      "the start menu cursor requires a slot id"
    )
    local slot = assert(
      self.menu.slots[presentation.cursorSlotId],
      "cursor slot " .. tostring(presentation.cursorSlotId) .. " is outside the generated slot set"
    )
    assert(
      type(presentation.cursorFrameIndex) == "number" and presentation.cursorFrameIndex % 1 == 0,
      "the start menu cursor requires a frame index"
    )
    local frame = assert(
      self.menu.cursor.frames[presentation.cursorFrameIndex + 1],
      "cursor frame " .. tostring(presentation.cursorFrameIndex) .. " is outside the generated frame set"
    )
    ---@cast frame FieldDialogueTheme.Rect
    lg.draw(assert(self._backgroundImage), assert(self._backgroundQuad), self.menu.background.x, self.menu.background.y)
    local x, y = self:_cursorPosition(slot, frame)
    lg.draw(assert(self._cursorImage), assert(self._cursorQuads[presentation.cursorFrameIndex + 1]), x, y)
  end)
end

function StartMenuRenderer:release()
  if self._backgroundImage and self._backgroundImage.release then
    self._backgroundImage:release()
  end
  if self._cursorImage and self._cursorImage.release then
    self._cursorImage:release()
  end
  self._backgroundImage, self._cursorImage = nil, nil
  self._backgroundQuad, self._cursorQuads = nil, nil
end

-- The resolved manifest surface: background rect, logical slot rects, and
-- the cursor frames (rects plus fixed-tick durations). The action-icon art
-- is baked into the background PNG; the manifest carries no icon mapping.

---@class StartMenuRenderer.Menu
---@field background FieldDialogueTheme.Rect
---@field slots table<integer, FieldDialogueTheme.Rect>
---@field cursor { frames: { x: integer, y: integer, width: integer, height: integer, duration: integer }[] }

return StartMenuRenderer
