-- Field-bag renderer: draws one controller presentation snapshot through
-- the resolved layout. The hero pane shows the gender-selected source
-- backdrop, the borrowed 3D hero model clipped to the hero placement, the
-- description frame, and the state-specific contextual text in the
-- source font; the interactive pane composites the semantic state background,
-- source tabs, six-cell item grid with icons, names, quantities, and
-- registration markers, the selected-tab highlight beneath its icon, the
-- shared item focus outline, the derived page, and the
-- generated cancel label. Empty cells paint no icons, so the source cell art
-- stays authentic. The constrained description
-- overlay fills the canonical fallback frame with the selected icon, name,
-- description, and back hint; the same fallback surface carries the
-- contextual text when no hero pane exists. Action labels and move/toss
-- prompts come from the generated semantic text record, never from internal
-- action ids. The renderer owns no selection, layout, or
-- icon-selection policy and never queries the live bag service: quads
-- arrive through the icon provider, glyphs through the shared text
-- renderer. Draw advances no simulation state and restores every graphics
-- state it touches.

local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")
local FocusOutline = require("libs.ui.src.FocusOutline")
local BagSave = require("libs.hgss.src.save.BagSave")

---@class BagRenderer
---@field _graphics love.graphics
---@field _text table<string, unknown> the shared glyph atlas/text drawing collaborator
---@field _heroRenderer table<string, unknown> the borrowed hero model renderer owned by field presentation resources
---@field _manifest table<string, unknown>
---@field _images table<string, love.Image>
---@field _visuals table<string, table<string, unknown>>
local BagRenderer = {}
BagRenderer.__index = BagRenderer

local LINE_HEIGHT = 16
local WHITE = { 1, 1, 1, 1 }
local FALLBACK_COLORS = {
  fill = { 0.12, 0.12, 0.18, 1 },
  border = { 0.75, 0.75, 0.85, 1 },
}

---@param graphics love.graphics
---@param color number[]
local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4])
end

-- Source text forms carry import-time control tags (pocket names); plain
-- glyph output strips them so only readable text reaches the panes.
---@param value string
---@return string
local function plainText(value)
  return (value:gsub("{[^}]*}", ""))
end

-- Formats one generated prompt template over display facts the controller
-- already projected. Text segments contribute their generated literal, item
-- segments the selected display name, and quantity segments the validated
-- decimal amount. The closed three-kind vocabulary keeps bag prompts free
-- of a general control-code interpreter.
---@param template table<string, unknown>
---@param selected table<string, unknown>
---@param quantity integer?
---@return string
local function formatBagTemplate(template, selected, quantity)
  assert(type(template) == "table", "the bag prompt needs its generated template")
  local segments = assert(template.segments, "the bag prompt template carries its segments")
  assert(type(segments) == "table" and #segments >= 1, "the bag prompt template carries its segments")
  local parts = {}
  for _, segment in ipairs(segments) do
    assert(type(segment) == "table", "prompt segments are records")
    if segment.kind == "text" then
      assert(type(segment.value) == "string" and segment.value ~= "", "text segments carry a literal")
      parts[#parts + 1] = segment.value
    elseif segment.kind == "item" then
      local name = assert(selected.name, "item segments need the selected display name")
      assert(type(name) == "string" and name ~= "", "item segments need the selected display name")
      parts[#parts + 1] = name
    elseif segment.kind == "quantity" then
      assert(type(quantity) == "number", "quantity segments need the picked amount")
      assert(
        quantity == math.floor(quantity) and quantity >= 1 and quantity <= 999,
        "the picked amount fits three digit cells"
      )
      parts[#parts + 1] = tostring(quantity)
    else
      error("unknown bag prompt segment: " .. tostring(segment.kind), 0)
    end
  end
  return table.concat(parts)
end

-- Selects the one contextual string for the current state: the selected
-- description while browsing or choosing an action, otherwise the generated
-- move/toss prompt formatted over the projected selection. A missing
-- selection outside a prompt state simply carries no text.
---@param presentation table<string, unknown>
---@param manifest table<string, unknown>
---@return string?
local function contextualText(presentation, manifest)
  local state = presentation.state
  local interactive = assert(manifest.interactive, "the bag manifest must carry its interactive pane")
  local generated = assert(interactive.text, "the bag manifest must carry its semantic text")
  if state == "move_select" then
    local selected = assert(presentation.selected, "the move prompt needs its selected item")
    return formatBagTemplate(assert(generated.movePrompt, "the bag manifest carries its move prompt"), selected)
  elseif state == "toss_quantity" then
    local selected = assert(presentation.selected, "the toss prompt needs its selected item")
    return formatBagTemplate(assert(generated.tossQuantity, "the bag manifest carries its toss prompt"), selected)
  elseif state == "toss_confirm" then
    local selected = assert(presentation.selected, "the toss prompt needs its selected item")
    local quantity = assert(presentation.quantity, "the confirmation prompt carries its amount")
    return formatBagTemplate(
      assert(generated.tossConfirm, "the bag manifest carries its confirmation prompt"),
      selected,
      quantity
    )
  end
  local selected = presentation.selected
  if selected == nil then
    return nil
  end
  assert(type(selected.description) == "string", "selected slots carry a description")
  return selected.description
end

---@param graphics love.graphics
---@param path string
---@param data string
---@param images table<string, love.Image>
---@param key string
---@return love.Image
local function loadImage(graphics, path, data, images, key)
  local image = graphics.newImage(love.filesystem.newFileData(data, path))
  images[key] = image
  image:setFilter("nearest", "nearest")
  return image
end

---@param graphics love.graphics
---@param cacheFs CacheFs
---@param visual table<string, unknown>
---@param key string
---@param images table<string, love.Image>
---@return table<string, unknown>
local function loadVisual(graphics, cacheFs, visual, key, images)
  assert(type(visual) == "table", key .. " must be a semantic visual")
  local function acquire(path, imageKey)
    assert(type(path) == "string" and path ~= "", key .. " carries an image path")
    local data = cacheFs:read(path)
    assert(data, "bag image missing at " .. path)
    return loadImage(graphics, path, data, images, imageKey)
  end
  if visual.image ~= nil then
    return {
      image = acquire(visual.image, key),
      width = assert(visual.width, key .. " carries its image width"),
      height = assert(visual.height, key .. " carries its image height"),
      offset = visual.offset,
    }
  end
  error(key .. " carries no realized static image", 0)
end

-- Draws one realized static visual at its placement point plus its generated
-- offset, which already positions the image relative to the anchor the
-- producer composed it against. Placement points are sprite anchors (tab
-- rect centers) or pane origins, never image centers.
---@param graphics love.graphics
---@param visual table<string, unknown>
---@param x number
---@param y number
local function drawVisual(graphics, visual, x, y)
  local image = assert(visual.image, "static visuals carry their realized image")
  local offset = visual.offset or { x = 0, y = 0 }
  setColor(graphics, WHITE)
  graphics.draw(assert(image), x + offset.x, y + offset.y)
end

-- Resolves one zero-based field-font palette slot to byte-valued RGB, exactly
-- like the Oak confirmation path: ROM palettes are byte-valued while
-- normalized fixture palettes may already be unit-scaled.
---@param fontDef table<string, unknown>
---@param slot integer
---@return { r: number, g: number, b: number }
local function fontSlot(fontDef, slot)
  local palette = assert(fontDef.palette, "bag text needs the shared field font palette")
  local color = assert(palette[slot + 1], "bag text needs field font palette slot " .. slot)
  local r, g, b =
    assert(tonumber(color.r or color[1])), assert(tonumber(color.g or color[2])), assert(tonumber(color.b or color[3]))
  if r > 1 or g > 1 or b > 1 then
    r, g, b = r / 255, g / 255, b / 255
  end
  return { r = r * 255, g = g * 255, b = b * 255 }
end

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: table<string, unknown>, heroRenderer: table<string, unknown>, graphics?: love.graphics }
---@return BagRenderer
function BagRenderer.new(opts)
  assert(type(opts) == "table", "bag renderer options must be a table")
  local cacheFs = assert(opts.cacheFs, "BagRenderer requires a CacheFs")
  local manifest = assert(opts.manifest, "BagRenderer requires the validated bag manifest")
  local text = assert(opts.text, "BagRenderer requires the shared text renderer")
  local heroRenderer = assert(opts.heroRenderer, "BagRenderer requires its borrowed hero model renderer")
  assert(type(heroRenderer.draw) == "function", "the borrowed hero model renderer draws the hero model")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.push and graphics.setScissor, "BagRenderer requires love.graphics")
  local hero = assert(manifest.hero, "the bag manifest must carry its hero pane")
  local interactive = assert(manifest.interactive, "the bag manifest must carry its interactive pane")
  local self = setmetatable({
    _graphics = graphics,
    _text = text,
    _manifest = manifest,
    _heroRenderer = heroRenderer,
    _images = {},
    _visuals = {},
  }, BagRenderer)
  local ok, err = pcall(function()
    local function acquire(key, visual)
      self._visuals[key] = loadVisual(graphics, cacheFs, visual, key, self._images)
    end
    acquire("heroMale", hero.background.male)
    acquire("heroFemale", hero.background.female)
    acquire("descriptionFrame", {
      image = hero.description.frame.image,
      width = 256,
      height = 192,
    })
    for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
      local pockets = assert(interactive.backgrounds[state], "the bag manifest carries its " .. state .. " backgrounds")
      for _, pocket in ipairs(BagSave.POCKET_ORDER) do
        acquire("background:" .. state .. ":" .. pocket, assert(pockets[pocket], state .. " carries " .. pocket))
      end
    end
    for index, visual in ipairs(interactive.pocketTabs.normal) do
      acquire("tabNormal:" .. index, visual)
    end
    acquire("tabHighlight", interactive.pocketTabs.highlight)
    local registration =
      assert(interactive.itemSlots.registration, "the bag manifest must carry its registration markers")
    local slot1 = assert(registration.slot1, "the bag manifest must carry its first registration marker")
    local slot2 = assert(registration.slot2, "the bag manifest must carry its second registration marker")
    assert(
      type(slot1.image) == "string" and slot1.image ~= "",
      "the first registration marker carries its generated image"
    )
    assert(
      type(slot2.image) == "string" and slot2.image ~= "",
      "the second registration marker carries its generated image"
    )
    assert(type(registration.offset) == "table", "the registration markers carry their generated offset")
    acquire("registrationSlot1", slot1)
    acquire("registrationSlot2", slot2)
  end)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

---@param text string
---@param x number
---@param y number
---@param maxLines integer?
function BagRenderer:_drawLines(text, x, y, maxLines)
  local drawn = 0
  for line in (plainText(text) .. "\n"):gmatch("([^\n]*)\n") do
    if maxLines ~= nil and drawn >= maxLines then
      break
    end
    self._text:drawText(line, x, y + drawn * LINE_HEIGHT)
    drawn = drawn + 1
  end
end

---@param text string
---@param x number
---@param y number
---@param palette { foreground: { r: number, g: number, b: number }, shadow: { r: number, g: number, b: number }, background: { r: number, g: number, b: number, a: number } }
---@param maxLines integer?
function BagRenderer:_drawPaletteLines(text, x, y, palette, maxLines)
  local drawn = 0
  for line in (plainText(text) .. "\n"):gmatch("([^\n]*)\n") do
    if maxLines ~= nil and drawn >= maxLines then
      break
    end
    self._text:drawTextWithPalette(line, x, y + drawn * LINE_HEIGHT, palette)
    drawn = drawn + 1
  end
end

---@param text string
---@param rect table<string, number>
function BagRenderer:_drawCentered(text, rect)
  local content = plainText(text)
  local width = self._text:textWidth(content)
  self._text:drawText(content, rect.x + (rect.width - width) / 2, rect.y + 2)
end

---@param text string
---@param rect table<string, number>
---@param palette { foreground: { r: number, g: number, b: number }, shadow: { r: number, g: number, b: number }, background: { r: number, g: number, b: number, a: number } }
function BagRenderer:_drawCenteredWithPalette(text, rect, palette)
  local content = plainText(text)
  local width = self._text:textWidth(content)
  self._text:drawTextWithPalette(content, rect.x + (rect.width - width) / 2, rect.y + 2, palette)
end

-- The three field-font slot triples the Bag uses: item rows, the count
-- readout, and the description window (whose colors Cancel shares). The
-- background role stays transparent so generated pixels remain visible
-- beneath glyph masks. Built once per draw, never per glyph.
---@return { item: table<string, unknown>, count: table<string, unknown>, description: table<string, unknown> }
function BagRenderer:_palettes()
  local fontDef = assert(self._text.fontDef, "bag text needs the shared field font definition")
  local function record(foregroundSlot, shadowSlot)
    local background = fontSlot(fontDef, 0)
    return {
      foreground = fontSlot(fontDef, foregroundSlot),
      shadow = fontSlot(fontDef, shadowSlot),
      background = { r = background.r, g = background.g, b = background.b, a = 0 },
    }
  end
  return {
    item = record(1, 2),
    count = record(15, 1),
    description = record(15, 14),
  }
end

-- The hero background beneath the 3D model: the gender-selected source
-- backdrop in canonical coordinates.
---@param presentation table<string, unknown>
function BagRenderer:_drawHeroBackground(presentation)
  local graphics = self._graphics
  local gender = assert(presentation.heroGender, "the bag presentation names its hero gender")
  assert(gender == "male" or gender == "female", "the hero gender selects its backdrop")
  local key = gender == "male" and "heroMale" or "heroFemale"
  drawVisual(graphics, assert(self._visuals[key]), 0, 0)
end

-- The hero foreground above the 3D model: the description frame with the
-- state-specific contextual text in canonical coordinates, printed through
-- the description window colors.
---@param presentation table<string, unknown>
---@param descriptionPalette table<string, unknown>
function BagRenderer:_drawHeroForeground(presentation, descriptionPalette)
  local graphics = self._graphics
  local manifest = self._manifest
  drawVisual(graphics, assert(self._visuals.descriptionFrame), 0, 0)
  local textRect = manifest.hero.description.textRect
  local contextual = contextualText(presentation, manifest)
  if contextual ~= nil then
    setColor(graphics, WHITE)
    self:_drawPaletteLines(contextual, textRect.x, textRect.y, descriptionPalette, 3)
  end
end

-- Draws the one generated lower-pane background for the current state and
-- pocket. Every image is asserted at construction, so an unknown
-- state/pocket fails instead of borrowing another pocket's screen.
---@param state string
---@param pocket string
function BagRenderer:_drawStateBackground(state, pocket)
  local backgroundByState = {
    browsing = "browse",
    description_overlay = "browse",
    move_select = "browse",
    action_menu = "action",
    toss_quantity = "quantity",
    toss_confirm = "confirmation",
  }
  local background = assert(backgroundByState[state], "the bag renderer draws a known lower-pane state")
  local key = "background:" .. background .. ":" .. pocket
  drawVisual(self._graphics, assert(self._visuals[key], "the bag presentation names its pocket"), 0, 0)
end

-- Item selection reuses the shared button focus outline over the full item
-- control rect at pane scale. Only item cells ever carry this treatment.
---@param rect table<string, number>
function BagRenderer:_drawFocus(rect)
  FocusOutline.draw(self._graphics, rect, { scale = 1 })
end

---@param presentation table<string, unknown>
---@param icons table<string, unknown>
---@param layout table<string, unknown>
---@param palettes { item: table<string, unknown>, count: table<string, unknown>, description: table<string, unknown> }
function BagRenderer:_drawInteractive(presentation, icons, layout, palettes)
  local graphics = self._graphics
  local manifest = self._manifest
  local interactive = manifest.interactive
  local state = assert(presentation.state, "the bag presentation names its state")
  local pocket = assert(presentation.pocket, "the bag presentation names its pocket")
  self:_drawStateBackground(state, pocket)
  local tabs = interactive.pocketTabs.rects
  local selectedTab = nil
  for index, tab in ipairs(presentation.pockets) do
    if tab.pocket == pocket then
      selectedTab = assert(tabs[index], "each pocket has a generated tab rectangle")
    end
  end
  if selectedTab == nil then
    error("the current pocket has no generated tab", 0)
  end
  -- The highlight draws beneath the icons: highlight first, then every
  -- normal icon including the selected pocket's own.
  drawVisual(
    graphics,
    assert(self._visuals.tabHighlight),
    selectedTab.x + selectedTab.width / 2,
    selectedTab.y + selectedTab.height / 2
  )
  for index = 1, 8 do
    local rect = assert(tabs[index], "each pocket has a generated tab rectangle")
    drawVisual(
      graphics,
      assert(self._visuals["tabNormal:" .. index]),
      rect.x + rect.width / 2,
      rect.y + rect.height / 2
    )
  end
  local slots = interactive.itemSlots.slots
  local visibleSlots = assert(presentation.visibleSlots, "the bag presentation lists its visible cells")
  assert(type(visibleSlots) == "table" and #visibleSlots == 6, "the presentation carries six visible cells")
  local registrationOffset = assert(
    interactive.itemSlots.registration and interactive.itemSlots.registration.offset,
    "the registration markers carry their generated offset"
  )
  local iconImage = icons:image()
  for index = 1, 6 do
    local cell = visibleSlots[index]
    local slot = assert(slots[index], "the presentation carries six generated cells")
    local rect = assert(slot.rect, "every cell needs its control rectangle")
    if cell ~= nil and cell.empty ~= true then
      local registrationSlot = cell.registrationSlot
      if registrationSlot ~= nil then
        assert(
          registrationSlot == 1 or registrationSlot == 2,
          "occupied cells carry a registration slot of 1, 2, or nil"
        )
        local marker = registrationSlot == 1 and self._images.registrationSlot1 or self._images.registrationSlot2
        drawVisual(
          graphics,
          { image = marker, width = 40, height = 16 },
          rect.x + registrationOffset.x,
          rect.y + registrationOffset.y
        )
      end
      local iconKey = assert(cell.icon, "occupied cells carry an icon key")
      local quad = icons:quadFor(iconKey)
      local dims = icons:dimensions(iconKey)
      local center = assert(slot.iconCenter, "every cell needs its icon center")
      setColor(graphics, WHITE)
      graphics.draw(iconImage, quad, center.x - dims.width / 2, center.y - dims.height / 2)
      setColor(graphics, WHITE)
      -- Item strings come from the text window and its explicit anchors,
      -- never from the control rect.
      local textRect = assert(slot.textRect, "every cell needs its text window")
      local nameAt = assert(slot.nameAt, "every cell needs its name anchor")
      local quantityAt = assert(slot.quantityAt, "every cell needs its quantity anchor")
      assert(type(cell.name) == "string", "occupied cells carry a name")
      self._text:drawTextWithPalette(plainText(cell.name), textRect.x + nameAt.x, textRect.y + nameAt.y, palettes.item)
      assert(type(cell.quantity) == "number", "occupied cells carry a quantity")
      self._text:drawTextWithPalette(
        "x" .. cell.quantity,
        textRect.x + quantityAt.x,
        textRect.y + quantityAt.y,
        palettes.item
      )
    end
  end
  local focus = presentation.focus
  if focus == "items" and presentation.selected ~= nil then
    local absolute = assert(presentation.selectedAbsoluteIndex, "the presentation carries its selection index")
    local start = assert(presentation.visibleStart, "the presentation carries its window start")
    assert(type(absolute) == "number" and type(start) == "number", "selection indexes are numbers")
    local cell = absolute - start + 1
    if cell >= 1 and cell <= 6 then
      local focused = visibleSlots[cell]
      if focused ~= nil and focused.empty ~= true then
        self:_drawFocus(assert(slots[cell].rect, "every cell needs its control rectangle"))
      end
    end
  end
  local page = assert(presentation.page, "the bag presentation derives its page")
  setColor(graphics, WHITE)
  self:_drawCenteredWithPalette(page.current .. "/" .. page.count, interactive.pageIndicator.rect, palettes.count)
  local cancelLabel = assert(interactive.text.actions.cancel, "the bag manifest carries its cancel label")
  -- Cancel chrome lives in the selected background pixels; only the label
  -- prints, placed by the label window rather than the control rect.
  self:_drawCenteredWithPalette(cancelLabel, interactive.cancel.textRect, palettes.description)
  if presentation.state == "description_overlay" and layout.mode == "interactive_only" then
    self:_drawDescriptionOverlay(presentation, icons, iconImage)
  elseif presentation.state == "action_menu" then
    self:_drawActionMenu(presentation)
  elseif presentation.state == "toss_quantity" then
    self:_drawQuantityState(presentation)
  elseif presentation.state == "toss_confirm" then
    self:_drawConfirmationState(presentation)
  elseif presentation.state == "move_select" then
    self:_drawMoveHighlight(presentation)
  end
  self:_drawConstrainedContextual(presentation, layout, palettes.description)
end

-- The action menu draws the generated semantic label for each offered
-- action into its generated button rectangle. An offered action without a
-- generated label, or more actions than generated buttons, fails instead
-- of printing an internal id or inventing geometry.
---@param presentation table<string, unknown>
function BagRenderer:_drawActionMenu(presentation)
  local graphics = self._graphics
  local actions = assert(presentation.actions, "the action menu carries its actions")
  assert(type(actions) == "table" and #actions >= 1, "the action menu carries its actions")
  local manifest = self._manifest
  local menu = assert(manifest.interactive.overlays.actionMenu, "the action menu needs its generated button geometry")
  local buttons = assert(menu.buttons, "the action menu needs its generated button geometry")
  assert(type(buttons) == "table", "the action menu needs its generated button geometry")
  assert(#actions <= #buttons, "the offered actions fit their generated buttons")
  local labels = assert(
    manifest.interactive.text and manifest.interactive.text.actions,
    "the action menu needs its generated labels"
  )
  for index, action in ipairs(actions) do
    local rect = assert(buttons[index], "the offered actions fit their generated buttons")
    assert(type(action.id) == "string", "menu actions carry a semantic id")
    local label = labels[action.id]
    assert(type(label) == "string" and label ~= "", "every offered action carries a generated label")
    setColor(graphics, WHITE)
    self._text:drawText(label, rect.x + 4, rect.y + 2)
  end
end

-- Responsive pointer affordances reuse the generated action-button
-- rectangles for centered labels. The confirm
-- label is the generated semantic action text shared with the action menu.
---@param buttons table<integer, table<string, number>>
---@param labeled table<integer, string>
function BagRenderer:_drawResponsiveButtons(buttons, labeled)
  local indexes = {}
  for index in pairs(labeled) do
    indexes[#indexes + 1] = index
  end
  table.sort(indexes)
  for _, index in ipairs(indexes) do
    local label = labeled[index]
    local rect = assert(buttons[index], "responsive affordances reuse generated buttons")
    setColor(self._graphics, WHITE)
    self:_drawCentered(label, rect)
  end
end

---@return table<integer, table<string, number>>
function BagRenderer:_actionButtons()
  local menu = assert(self._manifest.interactive.overlays.actionMenu, "the nested states need their generated buttons")
  local buttons = assert(menu.buttons, "the nested states need their generated buttons")
  assert(type(buttons) == "table" and #buttons == 4, "the nested states need their four generated buttons")
  return buttons
end

---@return string
function BagRenderer:_confirmLabel()
  local text = assert(self._manifest.interactive.text, "the nested states need their generated text")
  local actions = assert(text.actions, "the nested states need their generated labels")
  local confirm = assert(actions.confirm, "the nested states need their generated confirm label")
  assert(type(confirm) == "string" and confirm ~= "", "the generated confirm label is visible text")
  return confirm
end

-- The quantity picker draws the picked decimal amount right-aligned over
-- the three generated digit cells; unused leading cells stay blank. Amounts
-- outside the controller's validated range or beyond three cells fail
-- instead of clipping into the generated art.
---@param presentation table<string, unknown>
function BagRenderer:_drawQuantityState(presentation)
  local quantity = assert(presentation.quantity, "the quantity picker carries its amount")
  assert(type(quantity) == "number", "the quantity picker carries its amount")
  assert(
    quantity == math.floor(quantity) and quantity >= 1 and quantity <= 999,
    "the picked amount fits three digit cells"
  )
  local quantityMax = presentation.quantityMax
  if quantityMax ~= nil then
    assert(
      type(quantityMax) == "number" and quantity <= quantityMax,
      "the picked amount stays within its validated range"
    )
  end
  local digits = assert(
    self._manifest.interactive.overlays.quantity.digits,
    "the quantity picker needs its generated digit geometry"
  )
  local picked = tostring(quantity)
  assert(#picked <= #digits, "the picked amount fits three digit cells")
  for position = 1, #picked do
    local glyph = picked:sub(position, position)
    local cell = digits[#digits - #picked + position]
    local width = self._text:textWidth(glyph)
    self._text:drawText(glyph, cell.x + (cell.width - width) / 2, cell.y + 2)
  end
  self:_drawResponsiveButtons(self:_actionButtons(), { "-", "+", self:_confirmLabel() })
end

-- The toss confirmation rests on its distinct generated screen; the item
-- and amount it confirms travel in the contextual prompt, so no digit
-- widgets or quantity layers belong here.
---@param presentation table<string, unknown>
function BagRenderer:_drawConfirmationState(presentation)
  assert(presentation.quantity ~= nil, "the toss confirmation carries its amount")
  assert(presentation.selected ~= nil, "the toss confirmation needs its selected item")
  self:_drawResponsiveButtons(self:_actionButtons(), { [3] = self:_confirmLabel() })
end

-- Without a hero pane the state-specific contextual text would be lost, so
-- the constrained single-pane mode keeps it in the canonical fallback
-- region with the existing constrained overlay treatment. This is the only
-- mode where that fallback surface is valid; two-pane modes already carry
-- the same text in the hero description rect.
---@param presentation table<string, unknown>
---@param layout table<string, unknown>
---@param descriptionPalette table<string, unknown>
function BagRenderer:_drawConstrainedContextual(presentation, layout, descriptionPalette)
  if layout.mode ~= "interactive_only" then
    return
  end
  if presentation.state == "description_overlay" then
    return
  end
  local contextual = contextualText(presentation, self._manifest)
  if contextual == nil then
    return
  end
  local graphics = self._graphics
  local frame = assert(layout.descriptionFallback, "the constrained layout carries its fallback frame")
  setColor(graphics, FALLBACK_COLORS.fill)
  graphics.rectangle("fill", frame.x, frame.y, frame.width, frame.height)
  setColor(graphics, FALLBACK_COLORS.border)
  graphics.rectangle("line", frame.x, frame.y, frame.width, frame.height)
  setColor(graphics, WHITE)
  self:_drawPaletteLines(contextual, frame.x + 4, frame.y + 2, descriptionPalette, 2)
end

-- The move target keeps its explicit confirm affordance; the controller
-- drives the window with the target, so the cell is always among the
-- visible six.
---@param presentation table<string, unknown>
function BagRenderer:_drawMoveHighlight(presentation)
  assert(presentation.moveTarget ~= nil, "move selection carries its target")
  assert(presentation.visibleStart ~= nil, "the presentation carries its window start")
  self:_drawResponsiveButtons(self:_actionButtons(), { [3] = self:_confirmLabel() })
end

---@param presentation table<string, unknown>
---@param icons table<string, unknown>
---@param iconImage love.Image
function BagRenderer:_drawDescriptionOverlay(presentation, icons, iconImage)
  local graphics = self._graphics
  local manifest = self._manifest
  local frame = assert(manifest.interactive.overlays.descriptionFallback.frame, "the overlay needs its frame")
  local selected = assert(presentation.selected, "the description overlay needs its selected item")
  setColor(graphics, FALLBACK_COLORS.fill)
  graphics.rectangle("fill", frame.x, frame.y, frame.width, frame.height)
  setColor(graphics, FALLBACK_COLORS.border)
  graphics.rectangle("line", frame.x, frame.y, frame.width, frame.height)
  local iconKey = assert(selected.icon, "the overlay item carries an icon key")
  local quad = icons:quadFor(iconKey)
  local dims = icons:dimensions(iconKey)
  setColor(graphics, { 1, 1, 1, 1 })
  graphics.draw(iconImage, quad, frame.x + 4, frame.y + (frame.height - dims.height) / 2)
  setColor(graphics, WHITE)
  assert(type(selected.name) == "string", "the overlay item carries a name")
  self._text:drawText(plainText(selected.name), frame.x + 44, frame.y + 2)
  assert(type(selected.description) == "string", "the overlay item carries a description")
  self:_drawLines(selected.description, frame.x + 44, frame.y + 2 + LINE_HEIGHT, 2)
  local hint = "B Back"
  self._text:drawText(hint, frame.x + frame.width - self._text:textWidth(hint) - 4, frame.y + frame.height - 14)
end

-- Draws one presentation snapshot through the resolved layout with quads
-- from the icon provider. A closed presentation is a no-op. Each pane
-- draws clipped to its host frame under its own placement transform, so
-- icons, text, and cursors never escape their logical pane. Restores the
-- graphics color, scissor, and transform state afterwards.
---@param presentation table<string, unknown>
---@param layout table<string, unknown>
---@param collaborators { icons: table<string, unknown> }
function BagRenderer:draw(presentation, layout, collaborators)
  assert(type(presentation) == "table", "the bag renderer requires a presentation")
  assert(type(layout) == "table", "the bag renderer requires a resolved layout")
  if not presentation.open then
    return
  end
  local icons = assert(collaborators and collaborators.icons, "occupied cells need the icon provider")
  local graphics = self._graphics
  local palettes = self:_palettes()
  FieldDrawState.protectedDraw(graphics, function()
    local mode = assert(layout.mode, "the bag layout names its mode")
    if mode ~= "interactive_only" then
      local hero = assert(layout.hero, "two-pane modes place the hero pane")
      local frame = assert(hero.frame, "the hero placement carries its frame")
      local function drawHeroScope(draw)
        graphics.push()
        local ok, err = pcall(draw)
        graphics.pop()
        if not ok then
          error(err, 0)
        end
      end
      drawHeroScope(function()
        graphics.setScissor(math.floor(frame.x), math.floor(frame.y), math.floor(frame.width), math.floor(frame.height))
        graphics.translate(frame.x, frame.y)
        graphics.scale(hero.scale, hero.scale)
        self:_drawHeroBackground(presentation)
      end)
      -- The borrowed 3D hero renders in host coordinates through its own
      -- placement viewport: the canonical transform must not apply twice.
      drawHeroScope(function()
        graphics.setScissor(math.floor(frame.x), math.floor(frame.y), math.floor(frame.width), math.floor(frame.height))
        local heroRenderer = assert(self._heroRenderer, "the hero pane borrows its model renderer")
        heroRenderer:draw(
          assert(presentation.heroGender, "the bag presentation names its hero gender"),
          assert(presentation.hero, "the bag presentation carries its hero status"),
          hero
        )
      end)
      drawHeroScope(function()
        graphics.setScissor(math.floor(frame.x), math.floor(frame.y), math.floor(frame.width), math.floor(frame.height))
        graphics.translate(frame.x, frame.y)
        graphics.scale(hero.scale, hero.scale)
        self:_drawHeroForeground(presentation, palettes.description)
      end)
    end
    local interactive = assert(layout.interactive, "every mode places the interactive pane")
    local frame = assert(interactive.frame, "the interactive placement carries its frame")
    graphics.push()
    local ok, err = pcall(function()
      graphics.setScissor(math.floor(frame.x), math.floor(frame.y), math.floor(frame.width), math.floor(frame.height))
      graphics.translate(frame.x, frame.y)
      graphics.scale(interactive.scale, interactive.scale)
      self:_drawInteractive(presentation, icons, layout, palettes)
    end)
    graphics.pop()
    if not ok then
      error(err, 0)
    end
  end)
end

function BagRenderer:release()
  local images = self._images
  self._images = {}
  self._visuals = {}
  for _, image in pairs(images) do
    if image ~= nil and image.release then
      image:release()
    end
  end
end

return BagRenderer
