-- Renders the modal dialogue box into the viewport's centered 4:3 reference
-- frame: the authentic HGSS user-frame strip (the player's selected frame
-- index resolved from the generated field-UI manifest and drawn by the
-- DrawFrameAndWindow2 tilemap), the extracted glyph atlas text (ink and
-- shadow baked at import time), and a blinking continue cursor. It owns the
-- frame strip image and builds frame quads lazily per frame index; the
-- shared FieldTextRenderer (owned by FieldState) draws the glyph text. It
-- draws after the 3D world pass and restores every graphics state it
-- touches (canvas, shader, scissor, blend, depth, color). Presentation-only
-- by design: FieldFontLoader owns runtime font definitions and the generated
-- manifest owns frame rects. Construction is failure-safe: a missing frame
-- strip is a typed error, a quad failure after the images were created
-- releases the acquired images before rethrowing, and draw() balances its
-- transform push even when drawing raises. The runtime-validated manifest is
-- injected explicitly; this renderer never reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

---@class FieldDialogueRenderer
---@field _theme FieldDialogueTheme
---@field _graphics love.Graphics|love.graphics
---@field _text FieldDialogueRenderer.TextRenderer the shared glyph atlas/line drawing collaborator
---@field _manifest table<string, unknown> the generated field-UI manifest
---@field _focusIndicatorEnabled boolean whether the source focus indicator is composed
---@field _window FieldWindowRenderer? shared user-frame image/quads plus content fill
---@field _cursorImage love.Image?
---@field _cursorQuadCache table<integer, table<integer, love.Quad>>|nil
local FieldDialogueRenderer = {}
FieldDialogueRenderer.__index = FieldDialogueRenderer

---@alias FieldDialogueRenderer.Layout FieldDialogueTheme.Layout|DialoguePresentationLayout.Presentation

---@class FieldDialogueRenderer.TextRenderer
---@field fontDef FieldFontDef
---@field _atlas love.Image?
---@field drawLine fun(self: FieldDialogueRenderer.TextRenderer, tokens: MessageToken[], x: number, y: number)
---@field drawFocusIndicator fun(self: FieldDialogueRenderer.TextRenderer, field: integer, x: number, y: number)
---@field windowBackgroundColor fun(self: FieldDialogueRenderer.TextRenderer): number[]

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (frame strip PNGs); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.text: the shared FieldTextRenderer (FieldState owns exactly one);
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData); opts.theme:
-- geometry record.

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: unknown, theme?: FieldDialogueTheme, graphics?: unknown, drawFocusIndicator?: boolean }
---@return FieldDialogueRenderer
function FieldDialogueRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldDialogueRenderer requires a CacheFs-shaped object"
  )
  local theme = opts.theme or FieldDialogueTheme
  local graphics = opts.graphics
  if graphics == nil then
    graphics = assert(love.graphics)
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldDialogueRenderer requires love.graphics")
  ---@cast graphics love.Graphics|love.graphics
  local text = opts.text
  assert(
    text and type(text.drawLine) == "function" and type(text.drawFocusIndicator) == "function",
    "FieldDialogueRenderer requires the shared FieldTextRenderer"
  )
  ---@cast text FieldDialogueRenderer.TextRenderer
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "FieldDialogueRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the window
  -- primitive resolves the frame strip named by the manifest, and the cursor
  -- below resolves the continuation atlas. The runtime boot already validated
  -- the full manifest, so the renderer only resolves what it draws.

  local self = setmetatable({
    _theme = theme,
    _graphics = graphics,
    _text = text,
    _manifest = manifest,
    _focusIndicatorEnabled = opts.drawFocusIndicator ~= false,
    _window = nil,
    _cursorImage = nil,
    _cursorQuadCache = nil,
  }, FieldDialogueRenderer)

  local windowOk, windowErr = pcall(function()
    self._window = FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = manifest, graphics = graphics })
  end)
  if not windowOk then
    self:release()
    error(windowErr)
  end
  local cursor = assert(manifest.dialogueFrames.continueCursor)
  local cursorAsset = assert(manifest.assets[cursor.asset])
  local cursorData = cacheFs:read(cursorAsset.image)
  if not cursorData then
    self:release()
    Errors.raise(
      FieldErrors.FIELD_UI_CONTINUE_CURSOR_MISSING,
      "dialogue continuation cursor missing at " .. cursorAsset.image,
      { path = cursorAsset.image }
    )
  end
  cursorData = assert(cursorData)
  local cursorOk, cursorErr = pcall(function()
    self._cursorImage = graphics.newImage(love.filesystem.newFileData(cursorData, assert(cursorAsset.image)))
    self._cursorImage:setFilter("nearest", "nearest")
    self._cursorQuadCache = {}
    for style, styleEntry in pairs(cursor.styles) do
      local phases = assert(styleEntry).phases
      local quads = {}
      for phase = 0, 2 do
        local rect = assert(phases[phase])
        quads[phase] = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, cursorAsset.width, cursorAsset.height)
      end
      self._cursorQuadCache[style] = quads
    end
  end)
  if not cursorOk then
    self:release()
    error(cursorErr)
  end
  return self
end

-- Draws the player's selected HGSS user-frame through the shared window
-- primitive: the content-background fill plus the strip row named by the
-- manifest rect for the status frame index, composed by the audited
-- DrawFrameAndWindow2 tilemap around the content box. A status without a
-- frame index (a host that carries no player options) draws the fill with no
-- frame tiles rather than inventing one.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueRenderer.Layout
function FieldDialogueRenderer:_drawFrame(status, layout)
  local background = self._text:windowBackgroundColor()
  assert(self._window, "dialogue renderer owns no window primitive"):drawWindow(
    layout.box,
    status.frameIndex,
    background
  )
end

-- Draws the generated continuation phase while the controller waits at a
-- boundary. Timing and phase selection belong to the controller.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueRenderer.Layout
function FieldDialogueRenderer:_drawCursor(status, layout)
  if not status.waiting or status.cursorPhase == nil then
    return
  end
  local lg = assert(self._graphics)
  local frameIndex = status.frameIndex
  if frameIndex == nil then
    return
  end
  assert(self._manifest.dialogueFrames.continueCursor)
  local quads = assert(self._cursorQuadCache)[frameIndex]
  local quad = assert(quads)[status.cursorPhase]
  local placement = assert(layout.cursor, "dialogue layout must supply a cursor rectangle")
  lg.setColor(1, 1, 1, 1)
  lg.draw(assert(self._cursorImage), quad, placement.x, placement.y)
end

-- Draws the source screen-focus indicator (the YESNO printer control
-- graphic) once, when the reveal has reached a focus_indicator token: the
-- last visible control in source order wins. Placement is window-relative,
-- not a text-cursor advance: the right edge of the content window, without
-- subtracting the text inset. The indicator and the continuation cursor are
-- distinct source concepts and never suppress each other.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueRenderer.Layout
function FieldDialogueRenderer:_drawFocusIndicator(status, layout)
  if not self._focusIndicatorEnabled then
    return
  end
  local lines = status.scrollLines or status.visibleLines
  local tokensByLine = {}
  for _, line in ipairs(lines) do
    tokensByLine[#tokensByLine + 1] = line.tokens or line
  end
  local field = FieldTextRenderer.lastVisibleFocusField(tokensByLine)
  if field ~= nil then
    self._text:drawFocusIndicator(
      field,
      layout.box.x + layout.box.width - FieldFontCache.FOCUS_FRAME_WIDTH,
      layout.box.y
    )
  end
end

-- Draws the dialogue from a compact host presentation or into
-- viewport.referenceFrame at the field logical pixel scale
-- (viewport:logicalPixelScale(camera.zoom)). No-op (and no state touched)
-- when the controller is closed or this renderer is disposed.
-- Restores canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards so the HUD and host overlays draw normally. The fieldScale is
-- presentation state, not controller state; it bottom-centers the 256x192
-- surface and matches the world logical pixel scale.

---@param controller FieldDialogueController
---@param viewportOrPresentation { referenceFrame: FieldDialogueTheme.Rect }|FieldDialogueTheme.Layout|DialoguePresentationLayout.Presentation|nil
---@param fieldScale number|nil field logical pixel scale (viewport:logicalPixelScale(camera.zoom))
---@param presentation DialoguePresentationLayout.Presentation|nil compact host-owned dialogue placement
function FieldDialogueRenderer:draw(controller, viewportOrPresentation, fieldScale, presentation)
  -- Inactive (closed) is a pure no-op and checks no scale precondition; an
  -- inactive draw must not touch graphics state or require presentation
  -- parameters. The scale is only required for the active path.
  if not controller or not controller:isModal() or not self._window then
    return
  end
  ---@type FieldDialogueRenderer.Layout
  local layout
  if presentation ~= nil then
    DialoguePresentationLayout.validate(presentation)
    layout = presentation
  elseif fieldScale == nil and viewportOrPresentation and viewportOrPresentation.bounds ~= nil then
    ---@cast viewportOrPresentation DialoguePresentationLayout.Presentation
    DialoguePresentationLayout.validate(viewportOrPresentation)
    layout = viewportOrPresentation
  elseif fieldScale == nil then
    assert(viewportOrPresentation, "FieldDialogueRenderer:draw requires a layout or presentation")
    -- Compact presentation can arrive as the second arg when fieldScale is
    -- omitted; detect it by its bounds field. Theme layouts for dialogue must
    -- already carry the generated cursor placement.
    if viewportOrPresentation.bounds ~= nil then
      layout = viewportOrPresentation --[[@as DialoguePresentationLayout.Presentation]]
      DialoguePresentationLayout.validate(layout)
    else
      local themeLayout = viewportOrPresentation --[[@as FieldDialogueTheme.Layout]]
      layout = themeLayout
      assert(layout.cursor, "dialogue theme layout must carry generated cursor placement")
    end
  else
    assert(
      type(fieldScale) == "number"
        and fieldScale > 0
        and fieldScale == fieldScale
        and fieldScale ~= math.huge
        and fieldScale ~= -math.huge,
      "FieldDialogueRenderer:draw requires a finite positive field scale"
    )
    local cursorPlacement = assert(self._manifest.dialogueFrames.continueCursor).placement
    layout = self._theme.layout(assert(viewportOrPresentation).referenceFrame, fieldScale, cursorPlacement)
  end
  local lg = assert(self._graphics)
  local status = controller:status()
  FieldDrawState.protectedDraw(lg, function()
    -- Everything draws in reference-canvas coordinates under one
    -- translate(origin) + scale transform; the theme never returns
    -- screen-mapped rects, so nothing is scaled twice.
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    self:_drawFrame(status, layout)
    local lines = status.scrollLines or status.visibleLines
    local scrollOffset = status.scrollLines and status.scrollOffsetY or 0
    local lineY = layout.text.y - scrollOffset
    for _, line in ipairs(lines) do
      local tokens = line.tokens or line
      self._text:drawLine(tokens, layout.text.x, lineY)
      lineY = lineY + status.lineHeight + status.lineSpacing
    end
    self:_drawFocusIndicator(status, layout)
    self:_drawCursor(status, layout)
  end)
end

function FieldDialogueRenderer:release()
  if self._window ~= nil then
    self._window:release()
    self._window = nil
  end
  if self._cursorImage and self._cursorImage.release then
    self._cursorImage:release()
  end
  self._cursorImage = nil
  self._cursorQuadCache = nil
end

return FieldDialogueRenderer
