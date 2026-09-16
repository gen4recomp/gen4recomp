-- Shared HGSS card chrome for the Oak gender selector and the Main Menu.
-- It owns the exact source border/rim values and the flat generated-tone
-- face (plus the caller-supplied focus-brightness delta); geometry and
-- drawing stay with the game-independent ImageButton primitive.

local ImageButton = require("libs.ui.src.ImageButton")

---@class HgssCardTone
---@field r integer byte red 0..255
---@field g integer byte green 0..255
---@field b integer byte blue 0..255

local HgssCardButton = {}

local BORDER = { 58, 58, 58 }
local NEUTRAL_RIM = { 222, 230, 230 }
local SELECTED_RIM = { 255, 58, 58 }

local function clamp01(value)
  return math.max(0, math.min(1, value))
end

local function referenceColor(value)
  return { value[1] / 255, value[2] / 255, value[3] / 255 }
end

---@param spec { rect: { x: number, y: number, width: number, height: number }, scale: number }
---@return table<string, unknown>
function HgssCardButton.resolve(spec)
  return ImageButton.resolve(spec)
end

--- Normalized selected-rim color for overlays that must reuse the exact
--- card recipe without repainting a full card (for example a focus ring
--- around a frame whose child control stays neutral).
---@return number[] normalized RGB triple
function HgssCardButton.selectedRim()
  return referenceColor(SELECTED_RIM)
end

---@param graphics table<string, unknown>
---@param resolved table<string, unknown>
---@param options { defaultTone: HgssCardTone, selected: boolean, focusBlinkDelta?: number, contentRect: { x: number, y: number, width: number, height: number }, drawContent: fun(rect: table<string, unknown>) }
function HgssCardButton.draw(graphics, resolved, options)
  assert(type(graphics) == "table", "card button graphics is required")
  assert(type(resolved) == "table", "resolved card button is required")
  assert(type(options) == "table", "card button options are required")
  local tone = assert(options.defaultTone, "card button requires the generated default tone")
  assert(
    type(tone.r) == "number" and type(tone.g) == "number" and type(tone.b) == "number",
    "card button default tone must carry byte RGB channels"
  )
  assert(type(options.selected) == "boolean", "card button selected flag is required")
  local deltaValue = options.focusBlinkDelta or 0
  assert(type(deltaValue) == "number", "card button focus delta must be numeric")
  assert(type(options.contentRect) == "table", "card button content rectangle is required")
  assert(type(options.drawContent) == "function", "card button content callback is required")
  local delta = options.selected and deltaValue / 31 or 0
  local face = {
    clamp01(tone.r / 255 + delta),
    clamp01(tone.g / 255 + delta),
    clamp01(tone.b / 255 + delta),
  }
  ImageButton.draw(graphics, resolved, {
    selected = options.selected,
    colors = {
      face = face,
      border = referenceColor(BORDER),
      rim = referenceColor(NEUTRAL_RIM),
      selectedRim = referenceColor(SELECTED_RIM),
      innerBorder = { face[1], face[2], face[3] },
    },
    imageRect = options.contentRect,
    drawImage = options.drawContent,
  })
end

return HgssCardButton
