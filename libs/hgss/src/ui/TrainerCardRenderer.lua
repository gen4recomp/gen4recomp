-- Renders the authentic HGSS Trainer Card front into the viewport's centered
-- 4:3 reference frame: the generated card art (the manifest's
-- `hgss.trainer_card.front` asset at its front rect) plus the audited front
-- text layout from ov51_021E6F18 in asm/overlay_trainer_card_main.s at the
-- pinned decomp commit 008257708 — the front windows created from the
-- template table at 0x021E7F48 (8px/tile) and the label/value prints of the
-- source function. The front labels ("ID No.", "NAME", "MONEY", "SCORE",
-- "TIME", "ADVENTURE STARTED") are the fixed card layout (msgdata bank 727
-- messages 0..6); the player name is right-aligned to x=240 and the trainer
-- id (five digits, zero-padded per the source's String16_FormatInteger)
-- right-aligned to x=112 on the y=24 row. The presentation carries only the
-- implemented profile fields (name, trainerId), so the label rows
-- for values gameplay does not own stay empty and the source-gated POKéDEX
-- row is not drawn at all: nothing is fabricated. Text draws through the
-- shared FieldTextRenderer (owned by FieldState); this renderer owns only
-- the card front image. Construction is failure-safe: a missing card front
-- is a typed error, a quad failure after the image was created releases it
-- before rethrowing, and draw() restores every graphics state it touches.
-- The runtime-validated manifest is injected explicitly; this renderer never
-- reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

---@class TrainerCardRenderer
---@field _graphics love.graphics
---@field _text FieldTextRenderer the shared glyph atlas/text drawing collaborator
---@field _cardImage love.Image?
---@field _cardQuad love.Quad?
---@field card { front: FieldDialogueTheme.Rect } the resolved manifest front surface
local TrainerCardRenderer = {}
TrainerCardRenderer.__index = TrainerCardRenderer

-- The audited front text anchors (canonical 256x192 reference space): the
-- label origin of each front window (template table 0x021E7F48) and the
-- right edge of each right-aligned value print in ov51_021E6F18.
TrainerCardRenderer.LABEL_ANCHORS = {
  { text = "ID No.", x = 16, y = 24 },
  { text = "NAME", x = 136, y = 24 },
  { text = "MONEY", x = 16, y = 48 },
  { text = "SCORE", x = 16, y = 104 },
  { text = "TIME", x = 16, y = 128 },
  { text = "ADVENTURE STARTED", x = 16, y = 144 },
}
TrainerCardRenderer.NAME_RIGHT_EDGE = 240
TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE = 112
TrainerCardRenderer.TRAINER_ID_DIGITS = 5

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (card front PNG); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.text: the shared FieldTextRenderer (FieldState owns exactly one);
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData).

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: FieldTextRenderer, graphics?: love.graphics }
---@return TrainerCardRenderer
function TrainerCardRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "TrainerCardRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "TrainerCardRenderer requires love.graphics")
  local text = opts.text
  assert(text and type(text.drawText) == "function", "TrainerCardRenderer requires the shared FieldTextRenderer")
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "TrainerCardRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the card front PNG and its rect. The runtime boot already validates
  -- the full manifest; the renderer resolves what it draws.
  local trainerCard = assert(manifest.trainerCard, "the field-UI manifest must carry the trainer card section")
  local frontAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT],
    "the field-UI manifest must carry the trainer card front asset"
  )
  local cardPath = assert(frontAsset.image, "the trainer card front asset must name an image path")

  local self = setmetatable({
    _graphics = graphics,
    _text = text,
    _cardImage = nil,
    _cardQuad = nil,
    card = {
      front = trainerCard.front,
    },
  }, TrainerCardRenderer)

  local cardData = cacheFs:read(cardPath)
  local ok, err = pcall(function()
    if not cardData then
      self:release()
      Errors.raise(FieldErrors.FIELD_UI_TRAINER_CARD_FRONT_MISSING, "trainer card front missing at " .. cardPath, {
        path = cardPath,
      })
    end
    self._cardImage = graphics.newImage(love.filesystem.newFileData(assert(cardData), cardPath))
    self._cardImage:setFilter("nearest", "nearest")
    self:_buildQuads()
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- The card front surface quad: the manifest rect inside its atlas.
function TrainerCardRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local card = assert(self._cardImage)
  local rect = self.card.front
  self._cardQuad = lg.newQuad(rect.x, rect.y, rect.width, rect.height, card:getWidth(), card:getHeight())
end

-- Draws the canonical card front into viewport.referenceFrame: the card art
-- over the manifest front rect, then the audited labels and the two
-- authoritative values (right-aligned per the source prints). The
-- presentation carries only the implemented profile fields, so the label
-- rows for unimplemented values stay empty and nothing is fabricated.
-- No-op (and no state touched) when this renderer has no images. Restores
-- canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards.

---@param presentation table<string, unknown>?
---@param viewport { referenceFrame: FieldDialogueTheme.Rect }
function TrainerCardRenderer:draw(presentation, viewport)
  if not presentation or not self._cardImage then
    return
  end
  local lg = assert(self._graphics)
  assert(type(presentation.name) == "string", "the card presentation requires the player name")
  assert(type(presentation.visibleTrainerId) == "number", "the card presentation requires the visible trainer id")
  assert(type(presentation.money) == "number", "the card presentation requires money")
  assert(type(presentation.playTimeSeconds) == "number", "the card presentation requires play time")
  FieldDrawState.protectedDraw(lg, function()
    -- Trainer Card is an application surface, not field-attached: it keeps
    -- the existing placement contract (scale from the reference frame itself,
    -- no camera zoom) so it stays independent of field zoom.
    local ref = viewport.referenceFrame
    local appScale = ref.width / FieldDialogueTheme.referenceWidth
    local layout = {
      scale = appScale,
      origin = {
        x = ref.x + (ref.width - FieldDialogueTheme.referenceWidth * appScale) / 2,
        y = ref.y + ref.height - FieldDialogueTheme.referenceHeight * appScale,
      },
    }
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    lg.setColor(1, 1, 1, 1)
    lg.draw(assert(self._cardImage), assert(self._cardQuad), self.card.front.x, self.card.front.y)
    for _, anchor in ipairs(TrainerCardRenderer.LABEL_ANCHORS) do
      self._text:drawText(anchor.text, anchor.x, anchor.y)
    end
    local name = presentation.name
    self._text:drawText(name, TrainerCardRenderer.NAME_RIGHT_EDGE - self._text:textWidth(name), 24)
    local money = tostring(presentation.money)
    self._text:drawText(money, 152 - self._text:textWidth(money), 48)
    local totalMinutes = math.floor(presentation.playTimeSeconds / 60)
    local hours = math.floor(totalMinutes / 60)
    local minutes = totalMinutes % 60
    local playTime = string.format("%d:%02d", hours, minutes)
    self._text:drawText(playTime, 240 - self._text:textWidth(playTime), 128)
    local trainerId = string.format("%0" .. TrainerCardRenderer.TRAINER_ID_DIGITS .. "d", presentation.visibleTrainerId)
    self._text:drawText(trainerId, TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE - self._text:textWidth(trainerId), 24)
  end)
end

function TrainerCardRenderer:release()
  if self._cardImage and self._cardImage.release then
    self._cardImage:release()
  end
  self._cardImage, self._cardQuad = nil, nil
end

return TrainerCardRenderer
