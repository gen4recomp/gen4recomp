-- Authoritative validation for the generated field-bag presentation class.
-- The manifest carries the upper-pane hero (gender backdrops, description
-- frame, gender hero models with pocket-indexed animation states, normalized
-- camera/transform/light facts) plus the lower-pane controls (eight pocket
-- tabs, six item slots with icon anchors and registration markers, the count
-- readout, Cancel, semantic action text/templates, and the action/quantity/
-- confirmation overlays). Every loader, producer
-- writer, and test calls these validators, so no second interpretation of
-- the shapes exists. Unknown fields, wrong pane sizes, out-of-bounds
-- geometry, wrong tab/slot cardinality, unresolvable animation states, and
-- leaked source identities fail loudly. Love-free and filesystem-free.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

---@class BagAssetSchema
local BagAssetSchema = {}

BagAssetSchema.SCHEMA = "g4-bag-assets-v3"
BagAssetSchema.PANE_WIDTH = 256
BagAssetSchema.PANE_HEIGHT = 192
BagAssetSchema.TAB_COUNT = 8
BagAssetSchema.SLOT_COUNT = 6
BagAssetSchema.STATE_COUNT = 8

-- Source pocket keys in native order: hero animation states are selected by
-- this order.
BagAssetSchema.POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

-- Producer-only identities that must never reach the runtime manifest.
local SOURCE_KEYS = {
  narcId = true,
  memberId = true,
  fileId = true,
  bgPriority = true,
  layer = true,
  cell = true,
  animIndex = true,
  paletteSlot = true,
  oam = true,
  template = true,
}

local function fail(message, context)
  Errors.raise("BAG_MANIFEST_INVALID", message, context or {})
end

local function checkKeys(record, allowed, context, what)
  for key in pairs(record) do
    if allowed[key] == nil then
      fail(what .. " carries an unknown field " .. tostring(key), context)
    end
  end
end

local function checkRect(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { x = true, y = true, width = true, height = true }, context, what)
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 or value[axis] < 0 then
      fail(what .. "." .. axis .. " must be a non-negative integer", context)
    end
  end
  if value.width == 0 or value.height == 0 then
    fail(what .. " must have positive dimensions", context)
  end
  if value.x + value.width > BagAssetSchema.PANE_WIDTH or value.y + value.height > BagAssetSchema.PANE_HEIGHT then
    fail(what .. " escapes the canonical pane", context)
  end
end

local function checkPoint(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { x = true, y = true }, context, what)
  for _, axis in ipairs({ "x", "y" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 or value[axis] < 0 then
      fail(what .. "." .. axis .. " must be a non-negative integer", context)
    end
  end
  if value.x > BagAssetSchema.PANE_WIDTH or value.y > BagAssetSchema.PANE_HEIGHT then
    fail(what .. " escapes the canonical pane", context)
  end
end

local function checkImage(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { image = true, width = true, height = true }, context, what)
  if type(value.image) ~= "string" or value.image == "" then
    fail(what .. ".image must be a non-empty path", context)
  end
  for _, axis in ipairs({ "width", "height" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 or value[axis] <= 0 then
      fail(what .. "." .. axis .. " must be a positive integer", context)
    end
  end
end

local function checkOffset(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { x = true, y = true }, context, what)
  for _, axis in ipairs({ "x", "y" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 then
      fail(what .. "." .. axis .. " must be an integer", context)
    end
  end
end

-- Every runtime 2D visual is one static realized image with dimensions and
-- an optional blit offset. NANR selection happens producer-side; no frame
-- timeline, duration, or source identity reaches the manifest.
local function checkVisual(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a semantic visual", context)
  end
  checkKeys(value, { image = true, width = true, height = true, offset = true }, context, what)
  checkImage({ image = value.image, width = value.width, height = value.height }, context, what)
  if value.offset ~= nil then
    checkOffset(value.offset, context, what .. ".offset")
  end
end

-- Source widgets pair their static visual with producer-proven canonical
-- placement (the template sprite center) and audited state visibility.
-- A bare visual without placement/visibility fails: runtime never supplies
-- the source anchor itself.
local function checkWidget(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a semantic widget", context)
  end
  checkKeys(
    value,
    { image = true, width = true, height = true, offset = true, placement = true, states = true },
    context,
    what
  )
  checkImage({ image = value.image, width = value.width, height = value.height }, context, what)
  if value.offset ~= nil then
    checkOffset(value.offset, context, what .. ".offset")
  end
  if type(value.placement) ~= "table" then
    fail(what .. ".placement must be a record", context)
  end
  checkPoint(value.placement, context, what .. ".placement")
  if type(value.states) ~= "table" then
    fail(what .. ".states must be a record", context)
  end
  checkKeys(value.states, { browsing = true }, context, what .. ".states")
  if type(value.states.browsing) ~= "boolean" then
    fail(what .. ".states.browsing must be a boolean", context)
  end
end

local function checkFinite(value, context, what)
  if type(value) ~= "number" or value ~= value or value >= math.huge or value <= -math.huge then
    fail(what .. " must be a finite number", context)
  end
end

---@alias BagTextSegment
---| { kind: "text", value: string }
---| { kind: "item" }
---| { kind: "quantity" }

-- Semantic action text and prompt templates. Labels are non-empty localized
-- strings keyed by runtime action; templates are non-empty contiguous
-- segment arrays over the closed text/item/quantity vocabulary. Adjacent
-- text segments must have been coalesced by the producer; only the toss
-- confirmation template may carry a quantity placeholder.
local TEXT_ACTIONS = { toss = true, move = true, register = true, unregister = true, cancel = true, confirm = true }

local function checkSegment(segment, context, what, allowedKinds)
  if type(segment) ~= "table" then
    fail(what .. " must be a record", context)
  end
  if type(segment.kind) ~= "string" or allowedKinds[segment.kind] ~= true then
    fail(what .. " carries an unsupported segment kind " .. tostring(segment.kind), context)
  end
  if segment.kind == "text" then
    checkKeys(segment, { kind = true, value = true }, context, what)
    if type(segment.value) ~= "string" or segment.value == "" then
      fail(what .. ".value must be a non-empty string", context)
    end
  else
    checkKeys(segment, { kind = true }, context, what)
  end
end

local function checkTemplate(template, context, what, allowedKinds)
  if type(template) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(template, { segments = true }, context, what)
  if not Validate.isArray(template.segments) or #template.segments == 0 then
    fail(what .. ".segments must be a non-empty contiguous array", context)
  end
  for index, segment in ipairs(template.segments) do
    checkSegment(segment, context, what .. ".segments[" .. index .. "]", allowedKinds)
    if
      index > 1
      and segment.kind == "text"
      and type(template.segments[index - 1]) == "table"
      and template.segments[index - 1].kind == "text"
    then
      fail(what .. " carries adjacent text segments that must be coalesced", context)
    end
  end
end

local function checkText(text, context)
  if type(text) ~= "table" then
    fail("interactive.text must be a record", context)
  end
  checkKeys(
    text,
    { actions = true, movePrompt = true, tossQuantity = true, tossConfirm = true },
    context,
    "interactive.text"
  )
  local actions = text.actions
  if type(actions) ~= "table" then
    fail("interactive.text.actions must be a record", context)
  end
  checkKeys(actions, TEXT_ACTIONS, context, "interactive.text.actions")
  for action in pairs(TEXT_ACTIONS) do
    if type(actions[action]) ~= "string" or actions[action] == "" then
      fail("interactive.text.actions." .. action .. " must be a non-empty label", context)
    end
  end
  local itemKinds = { text = true, item = true }
  local quantityKinds = { text = true, item = true, quantity = true }
  checkTemplate(text.movePrompt, context, "interactive.text.movePrompt", itemKinds)
  checkTemplate(text.tossQuantity, context, "interactive.text.tossQuantity", itemKinds)
  checkTemplate(text.tossConfirm, context, "interactive.text.tossConfirm", quantityKinds)
end

-- Registration-slot markers: two distinct 40x16 images with the slot-local
-- blit offset. The offset must keep the marker inside every canonical item
-- slot, so validation receives the already-checked slot records.
local REGISTRATION_WIDTH = 40
local REGISTRATION_HEIGHT = 16

local function checkRegistration(registration, slots, context)
  if type(registration) ~= "table" then
    fail("interactive.itemSlots.registration must be a record", context)
  end
  checkKeys(registration, { slot1 = true, slot2 = true, offset = true }, context, "interactive.itemSlots.registration")
  for _, slot in ipairs({ "slot1", "slot2" }) do
    checkImage(registration[slot], context, "interactive.itemSlots.registration." .. slot)
    if registration[slot].width ~= REGISTRATION_WIDTH or registration[slot].height ~= REGISTRATION_HEIGHT then
      fail("interactive.itemSlots.registration." .. slot .. " must be exactly 40x16", context)
    end
  end
  checkPoint(registration.offset, context, "interactive.itemSlots.registration.offset")
  for index, slot in ipairs(slots) do
    if
      registration.offset.x + REGISTRATION_WIDTH > slot.rect.width
      or registration.offset.y + REGISTRATION_HEIGHT > slot.rect.height
    then
      fail(
        "interactive.itemSlots.registration.offset escapes item slot " .. index .. " when applied slot-locally",
        context
      )
    end
  end
end

local function checkNoSourceIdentities(value, context, what)
  if type(value) ~= "table" then
    if type(value) == "string" and value:find("NARC_", 1, true) ~= nil then
      fail(what .. " carries a source archive symbol", context)
    end
    return
  end
  for key, item in pairs(value) do
    if SOURCE_KEYS[key] then
      fail(what .. " carries a source identity field " .. tostring(key), context)
    end
    checkNoSourceIdentities(item, context, what .. "." .. tostring(key))
  end
end

local function clipBySemantic(animations, semantic, context, what)
  local found = nil
  for _, clip in ipairs(animations) do
    if type(clip) == "table" and type(clip.semanticNames) == "table" then
      for _, name in ipairs(clip.semanticNames) do
        if name == semantic then
          if found ~= nil then
            fail(what .. " resolves to more than one clip", context)
          end
          found = clip
        end
      end
    end
  end
  if found == nil then
    fail(what .. " resolves to no clip", context)
  end
end

local function clipById(animations, id, context, what)
  for _, clip in ipairs(animations) do
    if type(clip) == "table" and clip.id == id then
      return
    end
  end
  fail(what .. " resolves to no clip", context)
end

local function checkModel(descriptor, context, what)
  local ok, err = pcall(ModelAsset.validate, descriptor)
  if not ok then
    if Errors.is(err) then
      fail(what .. " is invalid: " .. Errors.format(err), context)
    end
    error(err, 0)
  end
end

local function checkAnimations(animations, model, context)
  if type(animations) ~= "table" then
    fail("animations must be a record", context)
  end
  checkKeys(animations, { states = true, material = true }, context, "animations")
  if not Validate.isArray(animations.states) or #animations.states ~= BagAssetSchema.STATE_COUNT then
    fail("animations.states must carry exactly eight pocket states", context)
  end
  local seen = {}
  for index, state in ipairs(animations.states) do
    local what = "animations.states[" .. index .. "]"
    if type(state) ~= "table" then
      fail(what .. " must be a record", context)
    end
    checkKeys(state, { pocket = true, pose = true, pattern = true }, context, what)
    if type(state.pocket) ~= "string" or state.pocket == "" then
      fail(what .. ".pocket must be a non-empty key", context)
    end
    if seen[state.pocket] then
      fail("animations.states repeats pocket " .. state.pocket, context)
    end
    seen[state.pocket] = true
    if type(state.pose) ~= "string" or state.pose == "" then
      fail(what .. ".pose must be a non-empty clip name", context)
    end
    if type(state.pattern) ~= "string" or state.pattern == "" then
      fail(what .. ".pattern must be a non-empty clip name", context)
    end
    for _, gender in ipairs({ "male", "female" }) do
      local animationsList = model[gender].animations
      clipBySemantic(animationsList, state.pose, context, what .. ".pose for " .. gender)
      clipBySemantic(animationsList, state.pattern, context, what .. ".pattern for " .. gender)
    end
  end
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    if not seen[pocket] then
      fail("animations.states is missing pocket " .. pocket, context)
    end
  end
  local material = animations.material
  if type(material) ~= "table" then
    fail("animations.material must be a record", context)
  end
  checkKeys(material, { male = true, female = true }, context, "animations.material")
  for _, gender in ipairs({ "male", "female" }) do
    if type(material[gender]) ~= "string" or material[gender] == "" then
      fail("animations.material." .. gender .. " must be a non-empty clip id", context)
    end
    clipById(model[gender].animations, material[gender], context, "animations.material." .. gender)
  end
end

local function checkCamera(camera, context)
  if type(camera) ~= "table" then
    fail("presentation.camera must be a record", context)
  end
  checkKeys(camera, {
    target = true,
    distance = true,
    angleXDegrees = true,
    angleYDegrees = true,
    perspectiveType = true,
    perspectiveAngle = true,
    clipNear = true,
    clipFar = true,
  }, context, "presentation.camera")
  local target = camera.target
  if type(target) ~= "table" then
    fail("presentation.camera.target must be a record", context)
  end
  checkKeys(target, { x = true, y = true, z = true }, context, "presentation.camera.target")
  checkFinite(target.x, context, "presentation.camera.target.x")
  checkFinite(target.y, context, "presentation.camera.target.y")
  checkFinite(target.z, context, "presentation.camera.target.z")
  checkFinite(camera.distance, context, "presentation.camera.distance")
  if camera.distance <= 0 then
    fail("presentation.camera.distance must be positive", context)
  end
  checkFinite(camera.angleXDegrees, context, "presentation.camera.angleXDegrees")
  checkFinite(camera.angleYDegrees, context, "presentation.camera.angleYDegrees")
  if type(camera.perspectiveType) ~= "number" or camera.perspectiveType % 1 ~= 0 or camera.perspectiveType < 0 then
    fail("presentation.camera.perspectiveType must be a non-negative integer", context)
  end
  if type(camera.perspectiveAngle) ~= "number" or camera.perspectiveAngle % 1 ~= 0 or camera.perspectiveAngle < 0 then
    fail("presentation.camera.perspectiveAngle must be a non-negative integer", context)
  end
  checkFinite(camera.clipNear, context, "presentation.camera.clipNear")
  checkFinite(camera.clipFar, context, "presentation.camera.clipFar")
  if camera.clipNear <= 0 or camera.clipFar <= camera.clipNear then
    fail("presentation.camera clipping range is invalid", context)
  end
end

local function checkTransform(transform, context)
  if type(transform) ~= "table" then
    fail("presentation.transform must be a record", context)
  end
  checkKeys(transform, { translation = true, rotation = true, scale = true }, context, "presentation.transform")
  for _, block in ipairs({ "translation", "scale" }) do
    if type(transform[block]) ~= "table" then
      fail("presentation.transform." .. block .. " must be a record", context)
    end
  end
  for _, axis in ipairs({ "x", "y", "z" }) do
    checkFinite(transform.translation[axis], context, "presentation.transform.translation." .. axis)
    checkFinite(transform.scale[axis], context, "presentation.transform.scale." .. axis)
  end
  if not Validate.isArray(transform.rotation) or #transform.rotation ~= 9 then
    fail("presentation.transform.rotation must carry nine matrix entries", context)
  end
  for _, entry in ipairs(transform.rotation) do
    checkFinite(entry, context, "presentation.transform.rotation entry")
  end
end

local function checkLightVector(vector, context, what)
  if type(vector) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(vector, { x = true, y = true, z = true }, context, what)
  checkFinite(vector.x, context, what .. ".x")
  checkFinite(vector.y, context, what .. ".y")
  checkFinite(vector.z, context, what .. ".z")
end

local function checkLights(lights, context)
  if type(lights) ~= "table" then
    fail("hero.presentation.lights must be a record", context)
  end
  checkKeys(lights, { count = true, color = true, vectors = true }, context, "hero.presentation.lights")
  if lights.count ~= 4 then
    fail("hero.presentation.lights.count must be exactly four", context)
  end
  if type(lights.color) ~= "table" then
    fail("hero.presentation.lights.color must be a record", context)
  end
  for _, channel in ipairs({ "r", "g", "b" }) do
    if
      type(lights.color[channel]) ~= "number"
      or lights.color[channel] % 1 ~= 0
      or lights.color[channel] < 0
      or lights.color[channel] > 31
    then
      fail("hero.presentation.lights.color." .. channel .. " must be 0..31", context)
    end
  end
  if not Validate.isArray(lights.vectors) or #lights.vectors ~= 4 then
    fail("hero.presentation.lights.vectors must carry exactly four light vectors", context)
  end
  for index, vector in ipairs(lights.vectors) do
    checkLightVector(vector, context, "hero.presentation.lights.vectors[" .. index .. "]")
  end
end

local function checkHero(hero, context)
  if type(hero) ~= "table" then
    fail("hero must be a record", context)
  end
  checkKeys(
    hero,
    { background = true, description = true, model = true, animations = true, presentation = true },
    context,
    "hero"
  )
  local background = hero.background
  if type(background) ~= "table" then
    fail("hero.background must be a record", context)
  end
  checkKeys(background, { male = true, female = true }, context, "hero.background")
  checkImage(background.male, context, "hero.background.male")
  checkImage(background.female, context, "hero.background.female")
  local description = hero.description
  if type(description) ~= "table" then
    fail("hero.description must be a record", context)
  end
  checkKeys(description, { frame = true, textRect = true }, context, "hero.description")
  if type(description.frame) ~= "table" then
    fail("hero.description.frame must be a record", context)
  end
  checkKeys(description.frame, { image = true, alternateImage = true, rect = true }, context, "hero.description.frame")
  if type(description.frame.image) ~= "string" or description.frame.image == "" then
    fail("hero.description.frame.image must be a non-empty path", context)
  end
  if type(description.frame.alternateImage) ~= "string" or description.frame.alternateImage == "" then
    fail("hero.description.frame.alternateImage must be a non-empty path", context)
  end
  checkRect(description.frame.rect, context, "hero.description.frame.rect")
  checkRect(description.textRect, context, "hero.description.textRect")
  local model = hero.model
  if type(model) ~= "table" then
    fail("hero.model must be a record", context)
  end
  checkKeys(model, { male = true, female = true }, context, "hero.model")
  checkModel(model.male, context, "hero.model.male")
  checkModel(model.female, context, "hero.model.female")
  checkAnimations(hero.animations, model, context)
  local presentation = hero.presentation
  if type(presentation) ~= "table" then
    fail("hero.presentation must be a record", context)
  end
  checkKeys(presentation, { camera = true, transform = true, lights = true }, context, "hero.presentation")
  checkCamera(presentation.camera, context)
  checkTransform(presentation.transform, context)
  checkLights(presentation.lights, context)
end

local function checkInteractive(interactive, context)
  if type(interactive) ~= "table" then
    fail("interactive must be a record", context)
  end
  checkKeys(interactive, {
    backgrounds = true,
    pocketTabs = true,
    itemSlots = true,
    widgets = true,
    pageIndicator = true,
    cancel = true,
    text = true,
    overlays = true,
  }, context, "interactive")
  local backgrounds = interactive.backgrounds
  if type(backgrounds) ~= "table" then
    fail("interactive.backgrounds must be a record", context)
  end
  checkKeys(
    backgrounds,
    { browse = true, action = true, quantity = true, confirmation = true },
    context,
    "interactive.backgrounds"
  )
  for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
    local visual = backgrounds[state]
    checkVisual(visual, context, "interactive.backgrounds." .. state)
    if visual.width ~= BagAssetSchema.PANE_WIDTH or visual.height ~= BagAssetSchema.PANE_HEIGHT then
      fail("interactive.backgrounds." .. state .. " must use the canonical pane size", context)
    end
  end
  local pocketTabs = interactive.pocketTabs
  if type(pocketTabs) ~= "table" then
    fail("interactive.pocketTabs must be a record", context)
  end
  checkKeys(pocketTabs, { rects = true, normal = true, selected = true }, context, "interactive.pocketTabs")
  if not Validate.isArray(pocketTabs.rects) or #pocketTabs.rects ~= BagAssetSchema.TAB_COUNT then
    fail("interactive.pocketTabs.rects must carry exactly eight tab rectangles", context)
  end
  for index, tab in ipairs(pocketTabs.rects) do
    checkRect(tab, context, "interactive.pocketTabs.rects[" .. index .. "]")
  end
  if not Validate.isArray(pocketTabs.normal) or #pocketTabs.normal ~= BagAssetSchema.TAB_COUNT then
    fail("interactive.pocketTabs.normal must carry exactly eight semantic visuals", context)
  end
  for index, visual in ipairs(pocketTabs.normal) do
    checkVisual(visual, context, "interactive.pocketTabs.normal[" .. index .. "]")
  end
  checkVisual(pocketTabs.selected, context, "interactive.pocketTabs.selected")
  local itemSlots = interactive.itemSlots
  if type(itemSlots) ~= "table" then
    fail("interactive.itemSlots must be a record", context)
  end
  checkKeys(itemSlots, { slots = true, focus = true, registration = true }, context, "interactive.itemSlots")
  if not Validate.isArray(itemSlots.slots) or #itemSlots.slots ~= BagAssetSchema.SLOT_COUNT then
    fail("interactive.itemSlots.slots must carry exactly six item slots", context)
  end
  for index, slot in ipairs(itemSlots.slots) do
    local what = "interactive.itemSlots.slots[" .. index .. "]"
    if type(slot) ~= "table" then
      fail(what .. " must be a record", context)
    end
    checkKeys(slot, { rect = true, iconCenter = true }, context, what)
    checkRect(slot.rect, context, what .. ".rect")
    checkPoint(slot.iconCenter, context, what .. ".iconCenter")
  end
  checkVisual(itemSlots.focus, context, "interactive.itemSlots.focus")
  local pageIndicator = interactive.pageIndicator
  if type(pageIndicator) ~= "table" then
    fail("interactive.pageIndicator must be a record", context)
  end
  checkKeys(pageIndicator, { rect = true, textAt = true }, context, "interactive.pageIndicator")
  checkRect(pageIndicator.rect, context, "interactive.pageIndicator.rect")
  checkPoint(pageIndicator.textAt, context, "interactive.pageIndicator.textAt")
  checkRect(interactive.cancel, context, "interactive.cancel")
  checkText(interactive.text, context)
  checkRegistration(itemSlots.registration, itemSlots.slots, context)
  local overlays = interactive.overlays
  if type(overlays) ~= "table" then
    fail("interactive.overlays must be a record", context)
  end
  checkKeys(
    overlays,
    { actionMenu = true, quantity = true, descriptionFallback = true },
    context,
    "interactive.overlays"
  )
  local actionMenu = overlays.actionMenu
  if type(actionMenu) ~= "table" then
    fail("interactive.overlays.actionMenu must be a record", context)
  end
  checkKeys(actionMenu, { buttons = true }, context, "interactive.overlays.actionMenu")
  if not Validate.isArray(actionMenu.buttons) or #actionMenu.buttons ~= 4 then
    fail("interactive.overlays.actionMenu.buttons must carry exactly four button rectangles", context)
  end
  for index, button in ipairs(actionMenu.buttons) do
    checkRect(button, context, "interactive.overlays.actionMenu.buttons[" .. index .. "]")
  end
  local quantity = overlays.quantity
  if type(quantity) ~= "table" then
    fail("interactive.overlays.quantity must be a record", context)
  end
  checkKeys(quantity, { digits = true }, context, "interactive.overlays.quantity")
  if not Validate.isArray(quantity.digits) or #quantity.digits ~= 3 then
    fail("interactive.overlays.quantity.digits must carry exactly three digit rectangles", context)
  end
  for index, digit in ipairs(quantity.digits) do
    checkRect(digit, context, "interactive.overlays.quantity.digits[" .. index .. "]")
  end
  local fallback = overlays.descriptionFallback
  if type(fallback) ~= "table" then
    fail("interactive.overlays.descriptionFallback must be a record", context)
  end
  checkKeys(fallback, { frame = true, textRect = true }, context, "interactive.overlays.descriptionFallback")
  checkRect(fallback.frame, context, "interactive.overlays.descriptionFallback.frame")
  checkRect(fallback.textRect, context, "interactive.overlays.descriptionFallback.textRect")
  local widgets = interactive.widgets
  if type(widgets) ~= "table" then
    fail("interactive.widgets must be a record", context)
  end
  checkKeys(widgets, { sourceStrip = true }, context, "interactive.widgets")
  checkWidget(widgets.sourceStrip, context, "interactive.widgets.sourceStrip")
end

-- Full manifest validation: shapes, canonical pane bounds, exact tab/slot/
-- state cardinality, animation-state resolution against both gender models,
-- and freedom from source identities. Raises BAG_MANIFEST_INVALID.
function BagAssetSchema.assertManifest(manifest)
  local context = {}
  if type(manifest) ~= "table" then
    fail("manifest must be a record", context)
  end
  checkKeys(manifest, { schema = true, logicalSize = true, hero = true, interactive = true }, context, "manifest")
  if manifest.schema ~= BagAssetSchema.SCHEMA then
    fail("manifest schema must be " .. BagAssetSchema.SCHEMA, context)
  end
  local logicalSize = manifest.logicalSize
  if type(logicalSize) ~= "table" then
    fail("manifest logicalSize must be a record", context)
  end
  checkKeys(logicalSize, { width = true, height = true }, context, "manifest logicalSize")
  if logicalSize.width ~= BagAssetSchema.PANE_WIDTH or logicalSize.height ~= BagAssetSchema.PANE_HEIGHT then
    fail("manifest logicalSize must be 256x192", context)
  end
  checkHero(manifest.hero, context)
  checkInteractive(manifest.interactive, context)
  checkNoSourceIdentities(manifest, context, "manifest")
  return true
end

function BagAssetSchema.isValidManifest(manifest)
  return pcall(BagAssetSchema.assertManifest, manifest)
end

return BagAssetSchema
