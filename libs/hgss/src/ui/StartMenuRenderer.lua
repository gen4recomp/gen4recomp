-- Renders the Start Menu surface through the placement record from
-- StartMenuLayout. Entry art is OBJ icon sprites, never baked background
-- rects: the generated field-UI manifest's `startMenu` section carries the
-- retail icon table (per-row art kind, shared-atlas rects, label-bank data),
-- the shared icon and selection-highlight atlases, the palette record,
-- sprite bases per destination slot, label windows, and main chrome. Each
-- draw composes chrome, then every presented action's icon quad at its sprite
-- base (the selected action draws from the highlight atlas, the Bag icon
-- follows the presentation's trainer gender), then caller-resolved labels
-- centered in their windows through the shared text collaborator, then the
-- animated cursor frame over the presented slot. A presentation without
-- actions draws the legacy background surface with the cursor (the manifest
-- without the icon contract only supports that path). Runtime code addresses
-- slots, icons, and windows by the manifest's own ids and never repeats
-- source coordinates. The cursor animation state is the controller's
-- fixed-tick concern; this renderer consumes only the frame index from the
-- presentation snapshot, so render refresh rate cannot change the animation
-- speed. An open menu always has a selection, so the presentation requires
-- the cursor slot and frame index; the nil presentation is the closed-menu
-- no-op. Drawing and hit testing consume the same StartMenuLayout placement
-- record (hostToLogical): the surface draws under translate(frame origin) +
-- scale(placement scale)
-- in canonical coordinates, so rendering and hit testing share one record
-- with no second set of scaled rectangles. The surface is not a generic
-- list menu: only the generated images are drawn, at identity tint, with no
-- theme colors or styled primitives. Construction is failure-safe: a missing
-- asset is a typed error, a later acquisition/quad failure releases every
-- image acquired so far before rethrowing, and draw() restores every
-- graphics state it touches. The runtime-validated manifest is injected
-- explicitly; this renderer never reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

---@class StartMenuRenderer
---@field _graphics love.graphics
---@field _text FieldTextRenderer? the shared text collaborator (drawText/textWidth), required by the icon contract
---@field _backgroundImage love.Image?
---@field _cursorImage love.Image?
---@field _chromeImage love.Image?
---@field _iconsImage love.Image?
---@field _highlightImage love.Image?
---@field _paletteImage love.Image?
---@field _pokeImage love.Image?
---@field _backgroundQuad love.Quad?
---@field _cursorQuads love.Quad[]? per cursor-frame quads, built once
---@field _chromeQuad love.Quad?
---@field _iconQuads table<integer, { base: love.Quad, highlight: love.Quad, female: love.Quad?, femaleHighlight: love.Quad? }>? per icon-row quads, built once
---@field _pokeQuad love.Quad?
---@field menu StartMenuRenderer.Menu the resolved manifest surface geometry
local StartMenuRenderer = {}
StartMenuRenderer.__index = StartMenuRenderer

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (Start Menu PNGs); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.text: the shared text collaborator drawing caller-resolved labels,
-- required when the manifest carries the icon contract; opts.graphics:
-- injectable LÖVE graphics namespace so tests can record draw calls; LÖVE
-- itself remains an allowed presentation-layer dependency (the PNG bytes
-- still enter through love.filesystem.newFileData).

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text?: unknown, graphics?: unknown }
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
    _text = nil,
    _backgroundImage = nil,
    _cursorImage = nil,
    _chromeImage = nil,
    _iconsImage = nil,
    _highlightImage = nil,
    _paletteImage = nil,
    _pokeImage = nil,
    _backgroundQuad = nil,
    _cursorQuads = nil,
    _chromeQuad = nil,
    _iconQuads = nil,
    _pokeQuad = nil,
    menu = {
      background = startMenu.background,
      slots = startMenu.slots,
      cursor = { frames = startMenu.cursor.frames },
      iconTable = startMenu.iconTable,
      iconBases = startMenu.iconBases,
      labelWindows = startMenu.labelWindows,
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
  if startMenu.iconTable ~= nil then
    local text = opts.text
    assert(
      text and type(text.drawText) == "function" and type(text.textWidth) == "function",
      "StartMenuRenderer requires the shared text collaborator for the icon contract"
    )
    self._text = text
    local iconOk, iconErr = pcall(function()
      self:_acquireIconContract(cacheFs, manifest, startMenu)
    end)
    if not iconOk then
      self:release()
      error(iconErr)
    end
  end
  return self
end

-- Acquires the icon-contract images and builds every icon quad. Any failure
-- releases everything acquired so far (including the background/cursor pair)
-- before the constructor rethrows.
---@param cacheFs CacheFs
---@param manifest table<string, unknown>
---@param startMenu table<string, unknown>
function StartMenuRenderer:_acquireIconContract(cacheFs, manifest, startMenu)
  local graphics = assert(self._graphics)
  local function acquire(assetId, code, what)
    local entry = assert(manifest.assets[assetId], "the field-UI manifest must carry " .. what)
    local path = assert(entry.image, what .. " must name an image path")
    local data = cacheFs:read(path)
    if not data then
      Errors.raise(code, what .. " missing at " .. path, { path = path })
    end
    data = assert(data)
    local image = graphics.newImage(love.filesystem.newFileData(data, path))
    image:setFilter("nearest", "nearest")
    return image
  end
  local chromeAsset = assert(startMenu.chrome and startMenu.chrome.main, "the icon contract must carry its chrome")
  local chromePath = assert(chromeAsset.asset, "the icon contract chrome must name an asset")
  local chromeEntry = assert(manifest.assets[chromePath], "the field-UI manifest must carry the start menu chrome")
  self._chromeImage = acquire(chromePath, FieldErrors.FIELD_UI_START_MENU_CHROME_MISSING, "the start menu chrome")
  local iconsAsset = assert(startMenu.iconAtlas and startMenu.iconAtlas.asset, "the icon contract must name its atlas")
  self._iconsImage = acquire(iconsAsset, FieldErrors.FIELD_UI_START_MENU_ICONS_MISSING, "the start menu icon atlas")
  local highlightAsset =
    assert(startMenu.iconHighlight and startMenu.iconHighlight.asset, "the icon contract must name its highlight atlas")
  self._highlightImage =
    acquire(highlightAsset, FieldErrors.FIELD_UI_START_MENU_ICON_HIGHLIGHT_MISSING, "the start menu icon highlight")
  local paletteRef = assert(startMenu.iconPalette, "the icon contract must carry its palette record")
  local paletteAsset = assert(paletteRef.asset, "the icon contract palette must name an asset")
  self._paletteImage =
    acquire(paletteAsset, FieldErrors.FIELD_UI_START_MENU_ICON_PALETTE_MISSING, "the start menu icon palette")
  if startMenu.pokeIcons ~= nil and startMenu.pokeIcons.asset ~= nil then
    local pokeAsset = startMenu.pokeIcons.asset
    if manifest.assets[pokeAsset] ~= nil then
      self._pokeImage =
        acquire(pokeAsset, FieldErrors.FIELD_UI_START_MENU_POKE_ICONS_MISSING, "the start menu poke icons")
    end
  end
  local iconsImage = assert(self._iconsImage)
  local highlightImage = assert(self._highlightImage)
  self._chromeQuad = graphics.newQuad(
    0,
    0,
    chromeEntry.width,
    chromeEntry.height,
    self._chromeImage:getWidth(),
    self._chromeImage:getHeight()
  )
  local quads = {}
  for index, row in ipairs(assert(startMenu.iconTable, "the icon contract must carry its icon table")) do
    if row.art == "sprite" then
      local rect = assert(row.rect, "icon row " .. index .. " must carry its atlas rect")
      quads[index] = {
        base = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, iconsImage:getWidth(), iconsImage:getHeight()),
        highlight = graphics.newQuad(
          rect.x,
          rect.y,
          rect.width,
          rect.height,
          highlightImage:getWidth(),
          highlightImage:getHeight()
        ),
      }
      if row.variants ~= nil and row.variants.female ~= nil then
        local female = row.variants.female
        quads[index].female = graphics.newQuad(
          female.x,
          female.y,
          female.width,
          female.height,
          iconsImage:getWidth(),
          iconsImage:getHeight()
        )
        quads[index].femaleHighlight = graphics.newQuad(
          female.x,
          female.y,
          female.width,
          female.height,
          highlightImage:getWidth(),
          highlightImage:getHeight()
        )
      end
    end
  end
  self._iconQuads = quads
  if self._pokeImage ~= nil then
    self._pokeQuad = graphics.newQuad(
      0,
      0,
      self._pokeImage:getWidth(),
      self._pokeImage:getHeight(),
      self._pokeImage:getWidth(),
      self._pokeImage:getHeight()
    )
  end
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

-- One presented action's icon draw: the icon-table quad at the action's
-- sprite base, from the selection-bank highlight atlas when the action holds
-- the cursor, through the gender-conditional variant when the row carries
-- one. Text-only rows draw no shared icon art.
---@param action table<string, unknown>
---@param selected boolean
---@param gender string?
function StartMenuRenderer:_drawActionIcon(action, selected, gender)
  local lg = assert(self._graphics)
  local iconTable = assert(self.menu.iconTable, "the icon presentation requires the icon contract")
  assert(type(action.icon) == "number" and action.icon % 1 == 0, "a presented action needs an icon index")
  local row = assert(iconTable[action.icon + 1], "icon " .. tostring(action.icon) .. " is outside the icon table")
  if row.art == "text" then
    return
  end
  local slotId = assert(action.slotId, "a presented action needs its destination slot")
  local base =
    assert(self.menu.iconBases and self.menu.iconBases[slotId], "slot " .. tostring(slotId) .. " has no sprite base")
  if row.art == "poke_icon" then
    if self._pokeImage ~= nil then
      lg.draw(self._pokeImage, assert(self._pokeQuad), base.x, base.y)
    end
    return
  end
  local quadSet = assert(
    (assert(self._iconQuads, "the icon presentation requires built icon quads"))[action.icon + 1],
    "icon " .. tostring(action.icon) .. " has no built quads"
  )
  local useFemale = gender ~= nil and row.variants ~= nil and row.variants[gender] ~= nil
  if selected then
    local image = assert(self._highlightImage)
    if useFemale then
      lg.draw(image, assert(quadSet.femaleHighlight), base.x, base.y)
    else
      lg.draw(image, quadSet.highlight, base.x, base.y)
    end
  else
    local image = assert(self._iconsImage)
    if useFemale then
      lg.draw(image, assert(quadSet.female), base.x, base.y)
    else
      lg.draw(image, quadSet.base, base.x, base.y)
    end
  end
end

-- One presented action's resolved label, centered in the action's own
-- label window: windows are keyed by destination slot id, never by
-- presentation order, so a sparse action list still labels the right row.
-- Labels arrive resolved (the dynamic player name is caller-resolved; the
-- static label bank is deferred until the message class ships it); an
-- action without a resolved label draws its icon alone.
---@param action table<string, unknown>
function StartMenuRenderer:_drawActionLabel(action)
  if action.label == nil then
    return
  end
  assert(type(action.label) == "string", "a presented label must be the caller-resolved string")
  local text = assert(self._text, "the icon presentation requires the shared text collaborator")
  local slotId = assert(action.slotId, "a presented action needs its destination slot")
  local window = assert(
    self.menu.labelWindows and self.menu.labelWindows[slotId],
    "label window " .. tostring(slotId) .. " is outside the generated window set"
  )
  local width = text:textWidth(action.label)
  text:drawText(action.label, window.x + (window.width - width) / 2, window.y)
end

-- Draws the canonical menu surface through the placement record: the icon
-- contract composes chrome, per-action icons and labels, then the cursor;
-- a presentation without actions draws the background image over the
-- manifest background rect and the cursor frame (selected by the
-- presentation's frame index, advanced by the pure fixed-tick animation
-- state the controller owns) centered over the presented manifest slot, all
-- under translate(frame origin) + scale(record scale) so the record's frame
-- is exactly where the surface lands and hostToLogical's inverse transform
-- maps hit points back onto the same canonical coordinates. No-op (and no
-- state touched) when this renderer has no images. Restores canvas, shader,
-- scissor, blend, depth, wireframe, cull, and color afterwards so the HUD
-- and host overlays draw normally.

---@param presentation { cursorSlotId: integer, cursorFrameIndex: integer, trainerGender?: string, actions?: table[] }?
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
    local actions = presentation.actions
    if actions ~= nil then
      assert(type(actions) == "table", "the start menu presentation actions must be a table")
    end
    if actions ~= nil and #actions > 0 then
      assert(self.menu.iconTable ~= nil, "the icon presentation requires the manifest icon contract")
      lg.draw(assert(self._chromeImage), assert(self._chromeQuad), 0, 0)
      for _, action in ipairs(actions) do
        self:_drawActionIcon(action, action.slotId == presentation.cursorSlotId, presentation.trainerGender)
        self:_drawActionLabel(action)
      end
    else
      lg.draw(
        assert(self._backgroundImage),
        assert(self._backgroundQuad),
        self.menu.background.x,
        self.menu.background.y
      )
    end
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
  if self._chromeImage and self._chromeImage.release then
    self._chromeImage:release()
  end
  if self._iconsImage and self._iconsImage.release then
    self._iconsImage:release()
  end
  if self._highlightImage and self._highlightImage.release then
    self._highlightImage:release()
  end
  if self._paletteImage and self._paletteImage.release then
    self._paletteImage:release()
  end
  if self._pokeImage and self._pokeImage.release then
    self._pokeImage:release()
  end
  self._backgroundImage, self._cursorImage, self._chromeImage, self._iconsImage, self._highlightImage, self._paletteImage, self._pokeImage =
    nil, nil, nil, nil, nil, nil, nil
  self._backgroundQuad, self._cursorQuads, self._chromeQuad, self._iconQuads, self._pokeQuad = nil, nil, nil, nil, nil
end

-- The resolved manifest surface: background rect, logical slot rects, the
-- cursor frames (rects plus fixed-tick durations), and, when the manifest
-- carries the icon contract, the icon table, sprite bases, and label
-- windows. Entry art lives in the shared icon atlas; the manifest carries
-- no per-action background rects.

---@class StartMenuRenderer.Menu
---@field background FieldDialogueTheme.Rect
---@field slots table<integer, FieldDialogueTheme.Rect>
---@field cursor { frames: { x: integer, y: integer, width: integer, height: integer, duration: integer }[] }
---@field iconTable table<integer, table<string, unknown>>?
---@field iconBases table<integer, { x: integer, y: integer }>?
---@field labelWindows table<integer, { x: integer, y: integer, width: integer, height: integer }>? label windows keyed by destination slot id

return StartMenuRenderer
