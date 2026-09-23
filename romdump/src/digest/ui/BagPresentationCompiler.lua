-- Translates the audited field-bag overlay tables into canonical pane
-- rectangles and pocket-indexed animation states. The source geometry lives
-- in romdump/src/config/BagSources.lua; this module owns the translation
-- and the structural validation (exactly eight tabs, six slots, eight
-- states, every rectangle inside its 256x192 pane) so malformed producer
-- data fails here with an attributed error instead of reaching the schema.
-- Pure module: no love dependency, no I/O.

local Errors = require("libs.errors.src.Errors")

---@class BagPresentationCompiler
local BagPresentationCompiler = {}

BagPresentationCompiler.ERROR = {
  GEOMETRY_INVALID = "BAG_GEOMETRY_INVALID",
}

BagPresentationCompiler.PANE_WIDTH = 256
BagPresentationCompiler.PANE_HEIGHT = 192

local function rgbaBuffer(pixels)
  local buffer = {}
  for index = 1, #pixels do
    buffer[index] = string.byte(pixels, index)
  end
  return buffer
end

local function rgbaPixels(buffer)
  local bytes = {}
  for index, value in ipairs(buffer) do
    bytes[index] = string.char(value)
  end
  return table.concat(bytes)
end

local function blendOver(buffer, offset, sourceR, sourceG, sourceB, sourceA)
  if sourceA == 0 then
    return
  end
  if sourceA == 255 then
    buffer[offset + 1], buffer[offset + 2], buffer[offset + 3], buffer[offset + 4] = sourceR, sourceG, sourceB, 255
    return
  end
  local destinationA = buffer[offset + 4]
  local outputA = sourceA + math.floor(destinationA * (255 - sourceA) / 255 + 0.5)
  if outputA == 0 then
    return
  end
  buffer[offset + 1] =
    math.floor((sourceR * sourceA + buffer[offset + 1] * destinationA * (255 - sourceA) / 255) / outputA + 0.5)
  buffer[offset + 2] =
    math.floor((sourceG * sourceA + buffer[offset + 2] * destinationA * (255 - sourceA) / 255) / outputA + 0.5)
  buffer[offset + 3] =
    math.floor((sourceB * sourceA + buffer[offset + 3] * destinationA * (255 - sourceA) / 255) / outputA + 0.5)
  buffer[offset + 4] = outputA
end

-- Compose decoded source surfaces in bottom-to-top order and keep the result
-- source-independent. Transparent source pixels leave lower layers intact.
---@param layers { width: integer, height: integer, pixels: string }[]
---@param role string
---@return { width: integer, height: integer, pixels: string }
function BagPresentationCompiler.composeImages(layers, role)
  if type(layers) ~= "table" or #layers == 0 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, role .. " has no source layers", {})
  end
  local first = layers[1]
  if
    type(first) ~= "table"
    or type(first.width) ~= "number"
    or type(first.height) ~= "number"
    or type(first.pixels) ~= "string"
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, role .. " has a malformed source layer", {})
  end
  local width, height = first.width, first.height
  if #first.pixels ~= width * height * 4 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, role .. " has malformed source pixels", {})
  end
  local output = rgbaBuffer(first.pixels)
  for layerIndex = 2, #layers do
    local layer = layers[layerIndex]
    if
      type(layer) ~= "table"
      or layer.width ~= width
      or layer.height ~= height
      or type(layer.pixels) ~= "string"
      or #layer.pixels ~= width * height * 4
    then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        role .. " has incompatible source layers",
        { layer = layerIndex }
      )
    end
    for pixel = 0, width * height - 1 do
      local sourceOffset = pixel * 4
      blendOver(
        output,
        sourceOffset,
        string.byte(layer.pixels, sourceOffset + 1),
        string.byte(layer.pixels, sourceOffset + 2),
        string.byte(layer.pixels, sourceOffset + 3),
        string.byte(layer.pixels, sourceOffset + 4)
      )
    end
  end
  return { width = width, height = height, pixels = rgbaPixels(output) }
end

---@param image { width: integer, height: integer, pixels: string }
---@param width integer
---@param height integer
---@param role string
---@return { width: integer, height: integer, pixels: string }
function BagPresentationCompiler.cropImage(image, width, height, role)
  if
    type(image) ~= "table"
    or image.width < width
    or image.height < height
    or #image.pixels ~= image.width * image.height * 4
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, role .. " cannot be cropped to the canonical pane", {})
  end
  local rows = {}
  for y = 0, height - 1 do
    rows[#rows + 1] = image.pixels:sub(y * image.width * 4 + 1, (y + 1) * image.width * 4)
  end
  return { width = width, height = height, pixels = table.concat(rows) }
end

local function checkRect(value, what)
  if
    type(value) ~= "table"
    or type(value.x) ~= "number"
    or type(value.y) ~= "number"
    or type(value.width) ~= "number"
    or type(value.height) ~= "number"
    or value.x % 1 ~= 0
    or value.y % 1 ~= 0
    or value.width % 1 ~= 0
    or value.height % 1 ~= 0
    or value.x < 0
    or value.y < 0
    or value.width <= 0
    or value.height <= 0
    or value.x + value.width > BagPresentationCompiler.PANE_WIDTH
    or value.y + value.height > BagPresentationCompiler.PANE_HEIGHT
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. " is not a pane-fitting rectangle", {})
  end
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function checkPoint(value, what)
  if
    type(value) ~= "table"
    or type(value.x) ~= "number"
    or type(value.y) ~= "number"
    or value.x % 1 ~= 0
    or value.y % 1 ~= 0
    or value.x < 0
    or value.y < 0
    or value.x > BagPresentationCompiler.PANE_WIDTH
    or value.y > BagPresentationCompiler.PANE_HEIGHT
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. " is not a pane-fitting point", {})
  end
  return { x = value.x, y = value.y }
end

-- Translate the source tab/slot/cursor/readout/overlay tables into the
-- manifest-ready geometry record.
---@param config table<string, unknown>
---@return table<string, unknown>
function BagPresentationCompiler.compileGeometry(config)
  assert(type(config) == "table" and type(config.geometry) == "table", "compileGeometry requires a source config")
  local geometry = config.geometry
  if type(geometry.tabs) ~= "table" or #geometry.tabs ~= 8 then
    Errors.raise(
      BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
      "bag geometry must carry exactly eight pocket tabs",
      {}
    )
  end
  if type(geometry.slots) ~= "table" or #geometry.slots ~= 6 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry must carry exactly six item slots", {})
  end
  local tabs = {}
  for index, tab in ipairs(geometry.tabs) do
    tabs[index] = checkRect(tab, "pocket tab " .. index)
  end
  local placements = config.itemIconCenters
  if type(placements) ~= "table" or #placements ~= 6 then
    Errors.raise(
      BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
      "bag source config must carry exactly six item-icon placements",
      {}
    )
  end
  local slots = {}
  for index, slot in ipairs(geometry.slots) do
    if type(slot) ~= "table" then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "item slot " .. index .. " is malformed", {})
    end
    local full = checkRect(slot.rect, "item slot " .. index)
    local window = checkRect(slot.textRect, "item slot " .. index .. " text window")
    if
      window.x < full.x
      or window.y < full.y
      or window.x + window.width > full.x + full.width
      or window.y + window.height > full.y + full.height
    then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        "item slot " .. index .. " text window escapes its touch rect",
        {}
      )
    end
    slots[index] = {
      rect = full,
      textRect = window,
      iconCenter = checkPoint(placements[index], "item slot " .. index .. " icon center"),
      nameAt = checkPoint(slot.nameAt, "item slot " .. index .. " name anchor"),
      quantityAt = checkPoint(slot.quantityAt, "item slot " .. index .. " quantity anchor"),
    }
  end
  local cursor = geometry.cursorAnchor
  if type(cursor) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no cursor anchor", {})
  end
  for _, field in ipairs({ "size", "y", "xBase", "xStep", "count" }) do
    if type(cursor[field]) ~= "number" or cursor[field] % 1 ~= 0 or cursor[field] < 0 then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "cursor anchor field " .. field .. " is invalid", {})
    end
  end
  if cursor.origin ~= "center" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "cursor anchor origin must be center", {})
  end
  local countReadout = geometry.countReadout
  if type(countReadout) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no count readout", {})
  end
  if type(geometry.actionSlots) ~= "table" or #geometry.actionSlots ~= 4 then
    Errors.raise(
      BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
      "bag geometry must carry exactly four action slots",
      {}
    )
  end
  local actionSlots = {}
  for index, slot in ipairs(geometry.actionSlots) do
    if type(slot) ~= "table" then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "action slot " .. index .. " is malformed", {})
    end
    actionSlots[index] = {
      center = checkPoint(slot.center, "action slot " .. index .. " center"),
      textRect = checkRect(slot.textRect, "action slot " .. index .. " text window"),
      hitRect = checkRect(slot.hitRect, "action slot " .. index .. " hit rect"),
    }
  end
  if type(geometry.quantityDigits) ~= "table" or #geometry.quantityDigits ~= 3 then
    Errors.raise(
      BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
      "bag geometry must carry exactly three quantity digits",
      {}
    )
  end
  local quantityDigits = {}
  for index, digit in ipairs(geometry.quantityDigits) do
    quantityDigits[index] = checkRect(digit, "quantity digit " .. index)
  end
  if type(geometry.quantityControls) ~= "table" or #geometry.quantityControls ~= 6 then
    Errors.raise(
      BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
      "bag geometry must carry exactly six quantity controls",
      {}
    )
  end
  local quantityControls = {}
  local expectedControls = {
    { delta = 100, role = "increment" },
    { delta = 10, role = "increment" },
    { delta = 1, role = "increment" },
    { delta = -100, role = "decrement" },
    { delta = -10, role = "decrement" },
    { delta = -1, role = "decrement" },
  }
  for index, control in ipairs(geometry.quantityControls) do
    local expected = expectedControls[index]
    if type(control) ~= "table" or control.delta ~= expected.delta or control.role ~= expected.role then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        "quantity control " .. index .. " has the wrong role",
        {}
      )
    end
    quantityControls[index] = {
      delta = control.delta,
      role = control.role,
      center = checkPoint(control.center, "quantity control " .. index .. " center"),
      hitRect = checkRect(control.hitRect, "quantity control " .. index .. " hit rect"),
    }
  end
  if type(geometry.quantityConfirm) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no quantity confirm", {})
  end
  local quantityConfirm = {
    center = checkPoint(geometry.quantityConfirm.center, "quantity confirm center"),
    hitRect = checkRect(geometry.quantityConfirm.hitRect, "quantity confirm hit rect"),
  }
  local quantityCancelHitRect = checkRect(geometry.quantityCancelHitRect, "quantity cancel hit rect")
  local cancelSource = geometry.cancel
  if type(cancelSource) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no cancel affordance", {})
  end
  local cancelRect = checkRect(cancelSource.rect, "cancel")
  local cancelText = checkRect(cancelSource.textRect, "cancel text window")
  if
    cancelText.x < cancelRect.x
    or cancelText.y < cancelRect.y
    or cancelText.x + cancelText.width > cancelRect.x + cancelRect.width
    or cancelText.y + cancelText.height > cancelRect.y + cancelRect.height
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "cancel text window escapes its button rect", {})
  end
  if type(cancelSource.labelRect) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no cancel label area", {})
  end
  local cancelLabel = checkRect(cancelSource.labelRect, "cancel label area")
  if
    cancelLabel.x < cancelRect.x
    or cancelLabel.y < cancelRect.y
    or cancelLabel.x + cancelLabel.width > cancelRect.x + cancelRect.width
    or cancelLabel.y + cancelLabel.height > cancelRect.y + cancelRect.height
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "cancel label area escapes its button rect", {})
  end
  local focusSource = config.focusTargets
  if type(focusSource) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag source config carries no focus targets", {})
  end
  if type(focusSource.tabs) ~= "table" or #focusSource.tabs ~= 8 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "focus targets must carry exactly eight tabs", {})
  end
  if type(focusSource.items) ~= "table" or #focusSource.items ~= 6 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "focus targets must carry exactly six items", {})
  end
  if type(focusSource.actions) ~= "table" or #focusSource.actions ~= 4 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "focus targets must carry exactly four actions", {})
  end
  local focusTabs = {}
  for index, target in ipairs(focusSource.tabs) do
    focusTabs[index] = checkPoint(target, "tab focus target " .. index)
  end
  local focusItems = {}
  for index, target in ipairs(focusSource.items) do
    focusItems[index] = checkPoint(target, "item focus target " .. index)
  end
  local focusActions = {}
  for index, target in ipairs(focusSource.actions) do
    focusActions[index] = checkPoint(target, "action focus target " .. index)
  end
  local focus = {
    tabs = focusTabs,
    items = focusItems,
    cancel = checkPoint(focusSource.cancel, "cancel focus target"),
    actions = focusActions,
  }
  return {
    tabs = tabs,
    slots = slots,
    focus = focus,
    cursor = {
      size = cursor.size,
      anchorY = cursor.y,
      anchorXBase = cursor.xBase,
      anchorXStep = cursor.xStep,
      anchorCount = cursor.count,
      origin = cursor.origin,
    },
    pageIndicator = {
      rect = checkRect(countReadout.rect, "count readout"),
      textAt = checkPoint(countReadout.textAt, "count readout text"),
    },
    cancel = { rect = cancelRect, textRect = cancelText, labelRect = cancelLabel },
    descriptionFrame = checkRect(geometry.descriptionFrame, "description frame"),
    descriptionText = checkRect(geometry.descriptionText, "description text"),
    actionSlots = actionSlots,
    quantityDigits = quantityDigits,
    quantityControls = quantityControls,
    quantityConfirm = quantityConfirm,
    quantityCancelHitRect = quantityCancelHitRect,
  }
end

-- Name one pose and one pattern clip per pocket state. The names resolve
-- against the compiled hero clips by semantic name; opaque member identities
-- never leave producer code.
---@param config table<string, unknown>
---@return table<string, unknown>
function BagPresentationCompiler.compileStates(config)
  assert(type(config) == "table" and type(config.hero) == "table", "compileStates requires a source config")
  local states = config.hero.states
  if type(states) ~= "table" or #states ~= 8 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag hero must carry exactly eight pocket states", {})
  end
  local out = {}
  for index, state in ipairs(states) do
    if type(state) ~= "table" or type(state.pocket) ~= "string" or state.pocket == "" then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "hero state " .. index .. " is malformed", {})
    end
    out[index] = {
      pocket = state.pocket,
      pose = "pocket." .. state.pocket .. ".pose",
      pattern = "pocket." .. state.pocket .. ".pattern",
    }
  end
  return out
end

-- Publish the audited global material registers in manifest-ready
-- semantic form. The source facts are raw RGB555 words from the setup
-- immediates; each register normalizes to its 0..31 channel triple here
-- so no RGB555 packing reaches the runtime manifest.
---@param config table<string, unknown>
---@return table<string, unknown>
function BagPresentationCompiler.compileMaterials(config)
  assert(type(config) == "table" and type(config.presentation) == "table", "compileMaterials requires a source config")
  local materials = config.presentation.materials
  if type(materials) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag presentation carries no material registers", {})
  end
  for key in pairs(materials) do
    if key ~= "diffuse" and key ~= "ambient" and key ~= "specular" and key ~= "emission" then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        "bag material register " .. tostring(key) .. " is not audited",
        {}
      )
    end
  end
  local out = {}
  for _, register in ipairs({ "diffuse", "ambient", "specular", "emission" }) do
    local word = materials[register]
    if type(word) ~= "number" or word % 1 ~= 0 or word < 0 or word > 0x7FFF then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        "bag material register " .. register .. " is not an RGB555 word",
        {}
      )
    end
    out[register] = {
      r = word % 32,
      g = math.floor(word / 32) % 32,
      b = math.floor(word / 1024) % 32,
    }
  end
  return out
end

return BagPresentationCompiler
