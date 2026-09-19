-- Renders the Start Menu SUB selector through the placement record from
-- StartMenuLayout. Entry art is OBJ icon sprites, never baked background
-- rects: the generated field-UI manifest's `startMenu` section carries the
-- retail icon table (per-row art kind with source-composed normal/selected
-- visual records, label-bank data, the conditional female variant), the
-- shared icon atlas, and the SUB chrome behind the entry windows. Each draw
-- composes the SUB background at the canonical origin, then every presented
-- action's icon at its source anchor plus the visual's source-relative
-- offset (the selected action draws its selected visual, the Bag icon
-- follows the presentation's trainer gender), then caller-resolved labels in
-- their source label windows through the shared text collaborator. There is
-- no movable cursor: selection is the selected icon visual itself. Runtime
-- code addresses icons and windows by the manifest's own records and never
-- repeats source coordinates. An open menu always has a selection, so the
-- presentation requires the selected source position; the nil presentation
-- is the closed-menu no-op. Drawing and hit testing consume the same
-- StartMenuLayout placement record (hostToLogical): the surface draws under
-- translate(frame origin) + scale(placement scale)
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
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

---@class StartMenuRenderer
---@field _graphics love.graphics
---@field _text FieldTextRenderer the shared text collaborator (drawText/textWidth)
---@field _images love.Image[] every acquired image, released exactly once
---@field _imageByAsset table<string, love.Image> acquired images by manifest asset id
---@field _quads table<string, love.Quad> quads by asset id plus rect
---@field _subImage love.Image?
---@field _subQuad love.Quad?
---@field _pokeImage love.Image?
---@field _pokeQuad love.Quad?
---@field menu StartMenuRenderer.Menu the resolved manifest surface geometry
local StartMenuRenderer = {}
StartMenuRenderer.__index = StartMenuRenderer

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (Start Menu PNGs); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.text: the shared text collaborator drawing caller-resolved labels;
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData).

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: unknown, graphics?: unknown }
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
  local text = opts.text
  assert(
    text and type(text.drawText) == "function" and type(text.textWidth) == "function",
    "StartMenuRenderer requires the shared text collaborator"
  )

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the SUB chrome and every icon visual atlas. The runtime boot
  -- already validated the full manifest; the renderer resolves what it
  -- draws.
  local startMenu = assert(manifest.startMenu, "the field-UI manifest must carry the start menu section")
  local interactive =
    assert(startMenu.interactive, "the field-UI manifest must carry the start menu interactive record")
  local iconTable = assert(startMenu.iconTable, "the field-UI manifest must carry the start menu icon table")
  local chrome = assert(startMenu.chrome and startMenu.chrome.sub, "the start menu must carry its sub chrome")
  local chromeAsset = assert(chrome.asset, "the start menu sub chrome must name an asset")

  local self = setmetatable({
    _graphics = graphics,
    _text = text,
    _images = {},
    _imageByAsset = {},
    _quads = {},
    _subImage = nil,
    _subQuad = nil,
    _pokeImage = nil,
    _pokeQuad = nil,
    menu = {
      interactive = interactive,
      iconTable = iconTable,
    },
  }, StartMenuRenderer)

  local ok, err = pcall(function()
    self:_acquire(cacheFs, manifest, startMenu, chromeAsset)
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- Acquires the SUB chrome, every icon visual atlas, and the optional
-- poke-icon image, then builds every visual quad. Any failure releases
-- everything acquired so far before the constructor rethrows.
---@param cacheFs CacheFs
---@param manifest table<string, unknown>
---@param startMenu table<string, unknown>
---@param chromeAsset string
function StartMenuRenderer:_acquire(cacheFs, manifest, startMenu, chromeAsset)
  local graphics = assert(self._graphics)
  local function acquire(assetId, code, what)
    if self._imageByAsset[assetId] ~= nil then
      return assert(self._imageByAsset[assetId])
    end
    local entry = assert(manifest.assets[assetId], "the field-UI manifest must carry " .. what)
    local path = assert(entry.image, what .. " must name an image path")
    local data = cacheFs:read(path)
    if not data then
      Errors.raise(code, what .. " missing at " .. path, { path = path })
    end
    data = assert(data)
    local image = graphics.newImage(love.filesystem.newFileData(data, path))
    image:setFilter("nearest", "nearest")
    self._images[#self._images + 1] = image
    self._imageByAsset[assetId] = image
    return image
  end
  local subImage = acquire(chromeAsset, FieldErrors.FIELD_UI_START_MENU_CHROME_MISSING, "the start menu sub chrome")
  self._subImage = subImage
  self._subQuad =
    graphics.newQuad(0, 0, subImage:getWidth(), subImage:getHeight(), subImage:getWidth(), subImage:getHeight())
  local function quadFor(assetId, rect)
    local key = assetId .. "\0" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "," .. rect.height
    local quad = self._quads[key]
    if quad == nil then
      local image = acquire(assetId, FieldErrors.FIELD_UI_START_MENU_ICONS_MISSING, "the start menu icon atlas")
      quad = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, image:getWidth(), image:getHeight())
      self._quads[key] = quad
    end
    return quad
  end
  for _, row in ipairs(assert(startMenu.iconTable, "the start menu must carry its icon table")) do
    if row.art == "sprite" then
      local visual = assert(row.visual, "a sprite icon row must carry its composed visual")
      for _, state in ipairs({ visual.normal, visual.selected }) do
        quadFor(assert(state.asset, "an icon visual must name its atlas"), assert(state.rect))
      end
      if row.variants ~= nil and row.variants.female ~= nil then
        for _, state in ipairs({ row.variants.female.normal, row.variants.female.selected }) do
          quadFor(assert(state.asset, "an icon visual must name its atlas"), assert(state.rect))
        end
      end
    end
  end
  if startMenu.pokeIcons ~= nil and startMenu.pokeIcons.asset ~= nil then
    local pokeAsset = startMenu.pokeIcons.asset
    if manifest.assets[pokeAsset] ~= nil then
      self._pokeImage =
        acquire(pokeAsset, FieldErrors.FIELD_UI_START_MENU_POKE_ICONS_MISSING, "the start menu poke icons")
      local pokeImage = assert(self._pokeImage)
      self._pokeQuad =
        graphics.newQuad(0, 0, pokeImage:getWidth(), pokeImage:getHeight(), pokeImage:getWidth(), pokeImage:getHeight())
    end
  end
end

---@param assetId string
---@param rect FieldDialogueTheme.Rect
---@return love.Quad
function StartMenuRenderer:_quadFor(assetId, rect)
  local key = assetId .. "\0" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "," .. rect.height
  return assert(self._quads[key], "a start menu icon visual must have a built quad")
end

-- One presented action's icon draw: the composed visual for the action's
-- source position at the position's source anchor plus the visual's
-- source-relative offset, through the gender-conditional variant when the
-- row carries one and the presentation selects the female art. The selected
-- action draws its selected visual; every other action draws its normal
-- visual. Text-only rows draw no shared icon art.
---@param action table<string, unknown>
---@param selectedPosition integer
---@param gender string?
function StartMenuRenderer:_drawActionIcon(action, selectedPosition, gender)
  local lg = assert(self._graphics)
  local menu = self.menu
  local iconTable = assert(menu.iconTable, "the icon presentation requires the icon contract")
  local positions = assert(menu.interactive and menu.interactive.positions, "the icon presentation requires positions")
  assert(type(action.icon) == "number" and action.icon % 1 == 0, "a presented action needs an icon index")
  assert(type(action.position) == "number" and action.position % 1 == 0, "a presented action needs its position")
  local row = assert(iconTable[action.icon + 1], "icon " .. tostring(action.icon) .. " is outside the icon table")
  if row.art == "text" then
    return
  end
  local record =
    assert(positions[action.position], "position " .. tostring(action.position) .. " is outside the position set")
  if row.art == "poke_icon" then
    if self._pokeImage ~= nil then
      lg.draw(self._pokeImage, assert(self._pokeQuad), record.anchor.x, record.anchor.y)
    end
    return
  end
  local visual = assert(row.visual, "a sprite icon row must carry its composed visual")
  if gender == "female" and row.variants ~= nil and row.variants.female ~= nil then
    visual = row.variants.female
  end
  local state = action.position == selectedPosition and visual.selected or visual.normal
  local asset = assert(state.asset, "an icon visual must name its atlas")
  local rect = assert(state.rect, "an icon visual must carry its atlas rect")
  local offset = assert(state.offset, "an icon visual must carry its frame offset")
  lg.draw(
    assert(self._imageByAsset[asset]),
    self:_quadFor(asset, rect),
    record.anchor.x + offset.x,
    record.anchor.y + offset.y
  )
end

-- One presented action's resolved label in the action's own source label
-- window: windows are keyed by source position, never by presentation
-- order, so a sparse action list still labels the right row. Labels arrive
-- resolved (the dynamic player name is caller-resolved; the static label
-- bank is deferred until the message class ships it); an action without a
-- resolved label draws its icon alone.
---@param action table<string, unknown>
function StartMenuRenderer:_drawActionLabel(action)
  if action.label == nil then
    return
  end
  assert(type(action.label) == "string", "a presented label must be the caller-resolved string")
  local text = assert(self._text, "the icon presentation requires the shared text collaborator")
  local positions =
    assert(self.menu.interactive and self.menu.interactive.positions, "the icon presentation requires positions")
  assert(type(action.position) == "number" and action.position % 1 == 0, "a presented action needs its position")
  local window = assert(
    positions[action.position] and positions[action.position].labelWindow,
    "label window for position " .. tostring(action.position) .. " is outside the generated window set"
  )
  local width = text:textWidth(action.label)
  text:drawText(action.label, window.x + (window.width - width) / 2, window.y)
end

-- Draws the canonical menu surface through the placement record: the SUB
-- chrome at the canonical origin, then per-action icons and labels keyed by
-- the same generated position records pointer input and navigation consume,
-- all under translate(frame origin) + scale(record scale) so the record's
-- frame is exactly where the surface lands and hostToLogical's inverse
-- transform maps hit points back onto the same canonical coordinates.
-- No-op (and no state touched) when this renderer has no images. Restores
-- canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards so the HUD and host overlays draw normally.

---@param presentation { selectedPosition: integer, trainerGender?: string, actions?: table[] }?
---@param placement StartMenuLayout.Placement
function StartMenuRenderer:draw(presentation, placement)
  if not presentation or not self._subImage then
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
    -- has a selection, so the presentation's selected position is validated
    -- before anything reaches the graphics namespace.
    lg.translate(placement.frame.x, placement.frame.y)
    lg.scale(placement.scale, placement.scale)
    lg.setColor(1, 1, 1, 1)
    assert(
      type(presentation.selectedPosition) == "number" and presentation.selectedPosition % 1 == 0,
      "the start menu presentation requires the selected source position"
    )
    local positions = assert(
      self.menu.interactive and self.menu.interactive.positions,
      "the start menu presentation requires the generated positions"
    )
    assert(
      positions[presentation.selectedPosition] ~= nil,
      "selected position " .. tostring(presentation.selectedPosition) .. " is outside the generated position set"
    )
    local actions = presentation.actions
    if actions ~= nil then
      assert(type(actions) == "table", "the start menu presentation actions must be a table")
    end
    -- Presentation-dependent faults (unknown positions, unknown icons) are
    -- rejected before anything reaches the graphics namespace: a rejected
    -- draw draws nothing.
    if actions ~= nil then
      local iconTable = assert(self.menu.iconTable, "the start menu presentation requires the icon table")
      for _, action in ipairs(actions) do
        assert(
          type(action.position) == "number" and positions[action.position] ~= nil,
          "action position " .. tostring(action.position) .. " is outside the generated position set"
        )
        assert(
          type(action.icon) == "number" and iconTable[action.icon + 1] ~= nil,
          "action icon " .. tostring(action.icon) .. " is outside the icon table"
        )
      end
    end
    lg.draw(assert(self._subImage), assert(self._subQuad), 0, 0)
    if actions ~= nil then
      for _, action in ipairs(actions) do
        self:_drawActionIcon(action, presentation.selectedPosition, presentation.trainerGender)
        self:_drawActionLabel(action)
      end
    end
  end)
end

function StartMenuRenderer:release()
  for _, image in ipairs(self._images) do
    if image.release then
      image:release()
    end
  end
  self._images = {}
  self._imageByAsset = {}
  self._quads = {}
  self._subImage, self._subQuad, self._pokeImage, self._pokeQuad = nil, nil, nil, nil
end

-- The resolved manifest surface: the SUB chrome asset, the icon table with
-- composed visuals, and the interactive position records. Entry art lives in
-- the shared icon atlas; the manifest carries no per-action background
-- rects.

---@class StartMenuRenderer.Position
---@field anchor { x: integer, y: integer }
---@field labelWindow FieldDialogueTheme.Rect
---@field hitRect FieldDialogueTheme.Rect
---@field navigation { up: integer[], down: integer[], left: integer[], right: integer[] }

---@class StartMenuRenderer.Interactive
---@field cancelHitRect FieldDialogueTheme.Rect
---@field positions table<integer, StartMenuRenderer.Position>

---@class StartMenuRenderer.Menu
---@field interactive StartMenuRenderer.Interactive the generated interactive record (cancel bound plus positions 0..6)
---@field iconTable table<integer, table<string, unknown>>

return StartMenuRenderer
