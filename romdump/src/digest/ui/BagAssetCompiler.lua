-- Compiles the generated field-bag presentation class: upper-pane hero
-- backdrops and description frame, lower-pane list/action/quantity/
-- confirmation screens, one pocket strip per active pocket replaying the
-- retail tab palette state plus the movable focus sprite visuals, the two
-- registration-slot markers cropped from the marker source bitmap, semantic
-- action labels and prompt templates lowered from the message banks, the
-- retail hero edge-color table as semantic records, and
-- both gender hero
-- models with pocket-indexed animation states. Source member selection and
-- geometry live in romdump/src/config/BagSources.lua; this module owns the
-- decode, rasterization, model/animation delegation, and the normalized
-- bundle. 2D mechanics reuse G2dDecoder/G2dRasterizer/PngWriter; model
-- conversion delegates to the digest/model compilers (Nsbmd decode,
-- MapPropAnimCompiler clips, DynamicModelCompiler descriptors) rather than
-- duplicating them. Item icons resolve through the item class and are never
-- read here. The runtime consumes only the manifest and the generated
-- files, never this module. Pure module: no love dependency.
-- Source basis: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- asm/overlay_15.s.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local BagSources = require("romdump.src.config.BagSources")
local BagPresentationCompiler = require("romdump.src.digest.ui.BagPresentationCompiler")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.reference.hgss.charmap")

---@class BagAssetCompiler
local BagAssetCompiler = {}

-- Named ownership of the compiler protocol error code; tests assert the
-- constant, never the raw string.
BagAssetCompiler.ERROR = {
  SOURCE_INVALID = "BAG_SOURCE_INVALID",
}

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

local function sourceError(message, context)
  error(Errors.new(BagAssetCompiler.ERROR.SOURCE_INVALID, "bag " .. message, context or {}), 0)
end

-- The single model-space normalization boundary: a source model-unit length
-- becomes the tile-space runtime unit the compiled meshes already use.
-- Angles, perspective, rotation, scales, and light vectors never cross it.
---@param raw number
---@return number
local function modelUnits(raw)
  return raw / MapUnits.MODEL_UNITS_PER_TILE
end

local function readMember(archive, memberId, role, dependencies, archiveLabel)
  local member, err = archive:readMember(memberId)
  if not member then
    sourceError("member " .. memberId .. " is unreadable: " .. Errors.format(err), { role = role, memberId = memberId })
  end
  assert(member ~= nil, "unreadable members fail above")
  dependencies[#dependencies + 1] =
    { name = (archiveLabel or "bag_ui") .. ":member:" .. memberId, role = role, sha1 = Hashing.sha1hex(member) }
  if string.byte(member, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(member)
    if not plain then
      error(lzErr, 0)
    end
    member = plain
  end
  return member
end

local function decode(kind, bytes, role)
  local record, err = G2dDecoder[kind](bytes, { label = "bag:" .. role })
  if not record then
    assert(err)
    sourceError(role .. " does not decode: " .. err.message, { role = role, cause = err.code })
  end
  return record
end

local function rasterizeScreen(charData, palette, screen, role)
  local ok, image = pcall(G2dRasterizer.renderScreen, charData, { colors = palette }, screen, { role = role })
  if not ok then
    if Errors.is(image) then
      ---@cast image Errors.Error
      sourceError(role .. " does not rasterize: " .. image.message, { role = role, cause = image.code })
    end
    error(image, 0)
  end
  return image
end

-- Upper-pane screens share one char/palette pair; lower-pane screens share
-- another. Every screen renders with native entry palette indices, matching
-- the retail layer binding the audit recovered.
local SCREEN_ROLES = {
  { role = "upper-base", member = BagSources.screens.upperBase, upper = true },
  { role = "upper-alternate", member = BagSources.screens.upperAlternate, upper = true },
  { role = "upper-backdrop-male", member = BagSources.screens.upperBackdropMale, upper = true },
  { role = "upper-backdrop-female", member = BagSources.screens.upperBackdropFemale, upper = true },
  { role = "list-slots", member = BagSources.screens.listSlots, upper = false },
  { role = "list-wash", member = BagSources.screens.listWash, upper = false },
  { role = "action-slots", member = BagSources.screens.actionSlots, upper = false },
  { role = "action-wash", member = BagSources.screens.actionWash, upper = false },
  { role = "confirmation", member = BagSources.screens.confirmation, upper = false },
  { role = "quantity", member = BagSources.screens.quantity, upper = false },
}

local function compileScreens(archive, dependencies, assets)
  local upperChar =
    decode("decodeChar", readMember(archive, BagSources.chars.upper, "upper-char", dependencies), "upper-char")
  local upperPalette = decode(
    "decodePalette",
    readMember(archive, BagSources.palettes.upper, "upper-palette", dependencies),
    "upper-palette"
  )
  local lowerChar =
    decode("decodeChar", readMember(archive, BagSources.chars.lower, "lower-char", dependencies), "lower-char")
  local lowerPalette = decode(
    "decodePalette",
    readMember(archive, BagSources.palettes.lower, "lower-palette", dependencies),
    "lower-palette"
  )
  local references = {}
  local lowerScreens = {}
  for _, spec in ipairs(SCREEN_ROLES) do
    local screen = decode("decodeScreen", readMember(archive, spec.member, spec.role, dependencies), spec.role)
    if spec.upper then
      local image = rasterizeScreen(upperChar, upperPalette.colors, screen, spec.role)
      image = BagPresentationCompiler.cropImage(image, 256, 192, spec.role)
      local path = BagCache.assetDir() .. "/" .. spec.role .. ".png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      references[spec.role] = { image = path, width = image.width, height = image.height }
    else
      for _, entry in ipairs(screen.entries) do
        if entry.palette > 3 then
          sourceError("lower screen references palette bank outside the reproduced 0..3 setup", {
            role = spec.role,
            bank = entry.palette,
          })
        end
      end
      lowerScreens[spec.role] = screen
    end
  end
  return references, {
    charData = lowerChar,
    colors = lowerPalette.colors,
    screens = lowerScreens,
  }
end

local function compileSpriteData(archive, group, role, dependencies)
  local charData = decode("decodeChar", readMember(archive, group.char, role .. "-char", dependencies), role .. "-char")
  local paletteData =
    decode("decodePalette", readMember(archive, group.palette, role .. "-palette", dependencies), role .. "-palette")
  local cellData = decode("decodeCell", readMember(archive, group.cell, role .. "-cell", dependencies), role .. "-cell")
  local animation =
    decode("decodeAnimation", readMember(archive, group.anim, role .. "-anim", dependencies), role .. "-anim")
  return charData, paletteData, cellData, animation
end

local function writeSpriteFrame(rendered, path, assets)
  assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
  local visual = { image = path, width = rendered.width, height = rendered.height }
  if rendered.offset.x ~= 0 or rendered.offset.y ~= 0 then
    visual.offset = rendered.offset
  end
  return visual
end

local function renderStaticFrame(spriteData, selector, role)
  local charData, paletteData, cellData, animation = unpack(spriteData)
  local sequence = animation.anims[selector.animation + 1]
  if sequence == nil then
    sourceError(role .. " selects a missing animation sequence", { animation = selector.animation })
  end
  assert(sequence ~= nil, "missing animation sequences fail above")
  if #sequence.frames ~= 1 then
    sourceError(role .. " selects an animated sequence; the bag contract publishes static realizations only", {
      animation = selector.animation,
      frames = #sequence.frames,
    })
  end
  return G2dRasterizer.renderAnimationFrame(
    charData,
    paletteData,
    cellData,
    sequence,
    1,
    { role = role, animation = selector.animation, frame = 0 },
    selector.palette
  )
end

local function compileVisual(spriteData, selector, role, assets)
  local ok, rendered = pcall(renderStaticFrame, spriteData, selector, role)
  if not ok then
    if Errors.is(rendered) then
      ---@cast rendered Errors.Error
      sourceError(role .. " does not rasterize: " .. rendered.message, { role = role, cause = rendered.code })
    end
    error(rendered, 0)
  end
  assert(type(rendered) == "table", "static visual rasterization returns an image")
  return writeSpriteFrame(rendered, BagCache.assetDir() .. "/" .. role .. "-frame-1.png", assets)
end

local function sameRenderedFrame(first, second)
  return first.width == second.width
    and first.height == second.height
    and first.offset.x == second.offset.x
    and first.offset.y == second.offset.y
    and first.pixels == second.pixels
end

local function compilePressedPair(spriteData, normalSelector, pressedSelector, role, assets)
  local charData, paletteData, cellData, animation = unpack(spriteData)
  local normalSequence = animation.anims[normalSelector.animation + 1]
  local pressedSequence = animation.anims[pressedSelector.animation + 1]
  if normalSequence == nil or pressedSequence == nil then
    sourceError(role .. " selects a missing animation sequence", {})
  end
  assert(normalSequence ~= nil and pressedSequence ~= nil, "missing animation sequences fail above")
  if #normalSequence.frames ~= 1 or #pressedSequence.frames ~= 2 then
    sourceError(role .. " must have one normal frame and two pressed frames", {
      normalFrames = #normalSequence.frames,
      pressedFrames = #pressedSequence.frames,
    })
  end
  local pressTicks = pressedSequence.frames[1].duration
  if type(pressTicks) ~= "number" or pressTicks <= 0 or pressTicks % 1 ~= 0 then
    sourceError(role .. " has no positive first-frame duration", { duration = pressTicks })
  end
  local normal = G2dRasterizer.renderAnimationFrame(
    charData,
    paletteData,
    cellData,
    normalSequence,
    1,
    { role = role .. "-normal", animation = normalSelector.animation, frame = 0 },
    normalSelector.palette
  )
  local pressed = G2dRasterizer.renderAnimationFrame(
    charData,
    paletteData,
    cellData,
    pressedSequence,
    1,
    { role = role .. "-pressed", animation = pressedSelector.animation, frame = 0 },
    pressedSelector.palette
  )
  local returned = G2dRasterizer.renderAnimationFrame(
    charData,
    paletteData,
    cellData,
    pressedSequence,
    2,
    { role = role .. "-return", animation = pressedSelector.animation, frame = 1 },
    pressedSelector.palette
  )
  if not sameRenderedFrame(normal, returned) then
    sourceError(role .. " pressed sequence does not return to its normal visual", {})
  end
  return {
    normal = writeSpriteFrame(normal, BagCache.assetDir() .. "/" .. role .. "-normal.png", assets),
    pressed = writeSpriteFrame(pressed, BagCache.assetDir() .. "/" .. role .. "-pressed.png", assets),
    pressTicks = pressTicks,
  }
end

-- Derive one active pocket's effective tab palette: clone the base sprite
-- palette, then replay the audited OBJ bank transfers in source order. Bank
-- availability is validated before any copy; a short palette fails instead
-- of wrapping or borrowing another bank.
---@param baseColors { r: integer, g: integer, b: integer }[]
---@param stateColors { r: integer, g: integer, b: integer }[]
---@param pocketIndex integer
---@return { colors: { r: integer, g: integer, b: integer }[] }
local function effectiveTabPalette(baseColors, stateColors, pocketIndex)
  local facts = BagSources.tabPaletteState
  if type(facts) ~= "table" or type(facts.bankSize) ~= "number" or facts.bankSize % 1 ~= 0 or facts.bankSize <= 0 then
    sourceError("tab palette state carries no positive integer bank size", { pocket = pocketIndex })
  end
  local bankSize = facts.bankSize
  if type(facts.transfers) ~= "table" or #facts.transfers ~= 2 then
    sourceError("tab palette state carries no ordered two-transfer replay", { pocket = pocketIndex })
  end
  local resolved = {}
  for position, transfer in ipairs(facts.transfers) do
    if type(transfer) ~= "table" then
      sourceError("tab palette state carries a malformed bank transfer", { pocket = pocketIndex, transfer = position })
    end
    local sourceFirst = transfer.sourceBank == "pocket" and pocketIndex or transfer.sourceBank
    local destFirst = transfer.destBank == "pocket" and pocketIndex or transfer.destBank
    if type(sourceFirst) ~= "number" or sourceFirst % 1 ~= 0 or sourceFirst < 0 then
      sourceError("tab palette state names no source bank", { pocket = pocketIndex, transfer = position })
    end
    if type(destFirst) ~= "number" or destFirst % 1 ~= 0 or destFirst < 0 then
      sourceError("tab palette state names no destination bank", { pocket = pocketIndex, transfer = position })
    end
    if type(transfer.bankCount) ~= "number" or transfer.bankCount % 1 ~= 0 or transfer.bankCount <= 0 then
      sourceError("tab palette state names no positive bank count", { pocket = pocketIndex, transfer = position })
    end
    if #stateColors < (sourceFirst + transfer.bankCount) * bankSize then
      sourceError("tab state palette carries no source bank for the pocket realization", {
        pocket = pocketIndex,
        bank = sourceFirst + transfer.bankCount - 1,
        available = #stateColors,
      })
    end
    if #baseColors < (destFirst + transfer.bankCount) * bankSize then
      sourceError("tab base palette carries no destination bank for the pocket realization", {
        pocket = pocketIndex,
        bank = destFirst + transfer.bankCount - 1,
        available = #baseColors,
      })
    end
    resolved[position] = { sourceFirst = sourceFirst, destFirst = destFirst, bankCount = transfer.bankCount }
  end
  local effective = {}
  for index, color in ipairs(baseColors) do
    effective[index] = color
  end
  for _, transfer in ipairs(resolved) do
    for bankOffset = 0, transfer.bankCount - 1 do
      local sourceBank = transfer.sourceFirst + bankOffset
      local destBank = transfer.destFirst + bankOffset
      for entry = 0, bankSize - 1 do
        effective[destBank * bankSize + entry + 1] = stateColors[sourceBank * bankSize + entry + 1]
      end
    end
  end
  return { colors = effective }
end

-- Composite the eight realized normal frames into one transparent 256x32
-- strip at the canonical tab anchors: each frame draws at its tab-rect
-- center plus its own raster offset, in pocket order, with alpha-zero
-- pixels preserving the strip beneath. Out-of-bounds placement fails
-- instead of clipping silently. Rasterized sprite pixels carry binary
-- alpha, so opaque pixels copy verbatim.
local function compositeTabStrip(frames, rects, pocket)
  local width, height = 256, 32
  local buffer = {}
  for index = 1, width * height * 4 do
    buffer[index] = 0
  end
  for position, frame in ipairs(frames) do
    local rect = rects[position]
    if type(rect) ~= "table" then
      sourceError("tab strip is missing its canonical placement", { pocket = pocket, tab = position })
    end
    local destX = rect.x + rect.width / 2 + frame.offset.x
    local destY = rect.y + rect.height / 2 + frame.offset.y
    if
      destX % 1 ~= 0
      or destY % 1 ~= 0
      or destX < 0
      or destY < 0
      or destX + frame.width > width
      or destY + frame.height > height
    then
      sourceError("tab strip placement escapes the canonical strip", { pocket = pocket, tab = position })
    end
    for y = 0, frame.height - 1 do
      for x = 0, frame.width - 1 do
        local sourceOffset = (y * frame.width + x) * 4 + 1
        if string.byte(frame.pixels, sourceOffset + 3) ~= 0 then
          local targetOffset = ((destY + y) * width + (destX + x)) * 4
          buffer[targetOffset + 1], buffer[targetOffset + 2], buffer[targetOffset + 3], buffer[targetOffset + 4] =
            string.byte(frame.pixels, sourceOffset, sourceOffset + 3)
        end
      end
    end
  end
  local out = {}
  for index = 1, #buffer, 4096 do
    out[#out + 1] = string.char(unpack(buffer, index, math.min(index + 4095, #buffer)))
  end
  return { width = width, height = height, pixels = table.concat(out) }
end

-- Normalize the raw hero edge RGB555 words to semantic channel records.
-- Values outside the 15-bit domain fail; black entries are valid source.
local function normalizeEdgeColors(rawWords)
  if type(rawWords) ~= "table" or #rawWords ~= 8 then
    sourceError("hero edge facts carry no eight-entry table", {})
  end
  local out = {}
  for index, word in ipairs(rawWords) do
    if type(word) ~= "number" or word % 1 ~= 0 or word < 0 or word > 0x7FFF then
      sourceError("hero edge entry is not an RGB555 word", { entry = index })
    end
    out[index] = { r = word % 32, g = math.floor(word / 32) % 32, b = math.floor(word / 1024) % 32 }
  end
  return out
end

local function compileSprites(archive, dependencies, assets)
  local charData, basePalette, cellData, animation =
    compileSpriteData(archive, BagSources.sprites.tabs, "tabs", dependencies)
  local tabsData = { charData, basePalette, cellData, animation }
  local statePalette = decode(
    "decodePalette",
    readMember(archive, BagSources.palettes.tabState, "tabs-state-palette", dependencies),
    "tabs-state-palette"
  )
  local selectors = BagSources.spriteStates.tabs.normal
  if type(selectors) ~= "table" or #selectors ~= 8 then
    sourceError("tab normal selectors carry no eight pocket states", {})
  end
  local placements = BagSources.geometry.tabs
  if type(placements) ~= "table" or #placements ~= 8 then
    sourceError("tab strips carry no eight canonical placements", {})
  end
  local strips = {}
  for _, pocketState in ipairs(BagSources.hero.states) do
    if
      type(pocketState.slot) ~= "number"
      or pocketState.slot % 1 ~= 0
      or pocketState.slot < 0
      or pocketState.slot > 7
    then
      sourceError("tab strip carries no zero-based pocket index", { pocket = pocketState.pocket })
    end
    local effective = effectiveTabPalette(basePalette.colors, statePalette.colors, pocketState.slot)
    local frames = {}
    for position, selector in ipairs(selectors) do
      local sequence = animation.anims[selector.animation + 1]
      if sequence == nil then
        sourceError("tab strip selects a missing animation sequence", {
          pocket = pocketState.pocket,
          animation = selector.animation,
        })
      end
      assert(sequence ~= nil, "missing tab sequences fail above")
      if #sequence.frames ~= 1 then
        sourceError(
          "tab strip selects an animated sequence; the bag contract publishes static realizations only",
          { pocket = pocketState.pocket, animation = selector.animation, frames = #sequence.frames }
        )
      end
      frames[position] = G2dRasterizer.renderAnimationFrame(
        charData,
        effective,
        cellData,
        sequence,
        1,
        { role = "tab-strip-" .. pocketState.pocket, animation = selector.animation, frame = 0 },
        selector.palette
      )
    end
    local strip = compositeTabStrip(frames, placements, pocketState.pocket)
    local path = BagCache.assetDir() .. "/tabs-" .. pocketState.pocket .. ".png"
    assets[path] = PngWriter.encode(strip.width, strip.height, strip.pixels)
    strips[pocketState.pocket] = { image = path, width = strip.width, height = strip.height }
  end
  local focusStates = BagSources.spriteStates.focus
  local actionFace = compileVisual(tabsData, BagSources.spriteStates.actionFace, "action-face", assets)
  local increment = compilePressedPair(
    tabsData,
    BagSources.spriteStates.quantity.increment.normal,
    BagSources.spriteStates.quantity.increment.pressed,
    "quantity-increment",
    assets
  )
  local decrement = compilePressedPair(
    tabsData,
    BagSources.spriteStates.quantity.decrement.normal,
    BagSources.spriteStates.quantity.decrement.pressed,
    "quantity-decrement",
    assets
  )
  if increment.pressTicks ~= decrement.pressTicks then
    sourceError("quantity controls have mismatched press durations", {
      increment = increment.pressTicks,
      decrement = decrement.pressTicks,
    })
  end
  return {
    strips = strips,
    focus = {
      tabs = compileVisual(tabsData, focusStates.tabs, "focus-tabs", assets),
      items = compileVisual(tabsData, focusStates.items, "focus-items", assets),
      cancel = compileVisual(tabsData, focusStates.cancel, "focus-cancel", assets),
      actions = compileVisual(tabsData, focusStates.actions, "focus-actions", assets),
    },
    actionFace = actionFace,
    quantity = {
      increment = { normal = increment.normal, pressed = increment.pressed },
      decrement = { normal = decrement.normal, pressed = decrement.pressed },
      pressTicks = increment.pressTicks,
      confirm = compileVisual(tabsData, BagSources.spriteStates.quantity.confirm, "quantity-confirm", assets),
    },
    -- The unselected Cancel face is realized for finalized-background
    -- composition below; it is never written to the bundle as a runtime
    -- asset.
    cancelFace = renderStaticFrame(tabsData, BagSources.spriteStates.cancelFace, "cancel-face"),
  }
end

-- Realize one pocket's lower background palette: destination banks 0..3 copy
-- the audited source banks relative to the zero-based pocket index. The
-- effective palette is a private compile-time value; only rasterized pixels
-- reach the bundle.
---@param sourceColors { r: integer, g: integer, b: integer }[]
---@param pocketIndex integer
---@return { colors: { r: integer, g: integer, b: integer }[] }
local function effectiveLowerPalette(sourceColors, pocketIndex)
  local remap = BagSources.lowerPaletteBanks
  local bankSize = remap.bankSize
  local highestBank = pocketIndex
  for _, offset in ipairs(remap.offsets) do
    highestBank = math.max(highestBank, pocketIndex + offset)
  end
  if #sourceColors < (highestBank + 1) * bankSize then
    sourceError("lower palette carries no source bank for the pocket realization", {
      pocket = pocketIndex,
      bank = highestBank,
      available = #sourceColors,
    })
  end
  local effective = {}
  for index, color in ipairs(sourceColors) do
    effective[index] = color
  end
  for destination = 0, 3 do
    local sourceBank = pocketIndex + remap.offsets[destination + 1]
    for entry = 0, bankSize - 1 do
      effective[destination * bankSize + entry + 1] = sourceColors[sourceBank * bankSize + entry + 1]
    end
  end
  return { colors = effective }
end

-- Copy one decoded screen's entries so count-specific tilemap replay starts
-- from the pristine decode for every count and pocket. Later count variants
-- must never observe an earlier variant's mutations.
local function copyScreenEntries(screen)
  local entries = {}
  for index, entry in ipairs(screen.entries) do
    entries[index] = { tile = entry.tile, flipH = entry.flipH, flipV = entry.flipV, palette = entry.palette }
  end
  return { width = screen.width, height = screen.height, entries = entries }
end

local function checkTileField(value, what, context)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    sourceError("browse " .. what .. " is not a non-negative tile integer", context)
  end
end

-- Replay one audited count block against mutable tile entries in place.
-- Coordinates are tile-grid positions; fills clear to the blank entry and
-- copies duplicate a source rectangle through a snapshot so overlapping
-- regions keep copy (rather than move) semantics.
local function applyBrowseCountBlock(screen, block, count)
  if type(block) ~= "table" or #block ~= 4 then
    sourceError("browse count carries no complete four-operation mutation block", { count = count })
  end
  local columns = screen.width / 8
  local rows = screen.height / 8
  local context = { count = count }
  for _, op in ipairs(block) do
    if type(op) ~= "table" then
      sourceError("browse count carries a malformed tilemap operation", context)
    end
    if op.kind == "nop" then
      -- No replay for this slot.
    elseif op.kind == "fill" then
      checkTileField(op.x, "fill x", context)
      checkTileField(op.y, "fill y", context)
      checkTileField(op.width, "fill width", context)
      checkTileField(op.height, "fill height", context)
      if op.x + op.width > columns or op.y + op.height > rows then
        sourceError("browse fill escapes the decoded browse screen", context)
      end
      for ty = 0, op.height - 1 do
        for tx = 0, op.width - 1 do
          screen.entries[(op.y + ty) * columns + (op.x + tx) + 1] =
            { tile = 0, flipH = false, flipV = false, palette = 0 }
        end
      end
    elseif op.kind == "copy" then
      checkTileField(op.srcX, "copy srcX", context)
      checkTileField(op.srcY, "copy srcY", context)
      checkTileField(op.destX, "copy destX", context)
      checkTileField(op.destY, "copy destY", context)
      checkTileField(op.width, "copy width", context)
      checkTileField(op.height, "copy height", context)
      if op.srcX + op.width > columns or op.srcY + op.height > rows then
        sourceError("browse copy source escapes the decoded browse screen", context)
      end
      if op.destX + op.width > columns or op.destY + op.height > rows then
        sourceError("browse copy destination escapes the decoded browse screen", context)
      end
      local snapshot = {}
      for ty = 0, op.height - 1 do
        for tx = 0, op.width - 1 do
          local entry = screen.entries[(op.srcY + ty) * columns + (op.srcX + tx) + 1]
          snapshot[ty * op.width + tx + 1] =
            { tile = entry.tile, flipH = entry.flipH, flipV = entry.flipV, palette = entry.palette }
        end
      end
      for ty = 0, op.height - 1 do
        for tx = 0, op.width - 1 do
          screen.entries[(op.destY + ty) * columns + (op.destX + tx) + 1] = snapshot[ty * op.width + tx + 1]
        end
      end
    else
      sourceError("browse count carries an unknown tilemap operation " .. tostring(op.kind), context)
    end
  end
end

-- Realize the browse slot screen for one visible occupied-item count from
-- an independent copy of the decoded source. Count 6 replays no mutation;
-- any other count outside 0..6 is invalid producer data.
local function browseScreenForCount(slots, count)
  if count == 6 then
    return copyScreenEntries(slots)
  end
  if type(count) ~= "number" or count % 1 ~= 0 or count < 0 or count > 5 then
    sourceError("browse count is outside the replayed 0..6 range", { count = count })
  end
  local screen = copyScreenEntries(slots)
  applyBrowseCountBlock(screen, BagSources.browseCountBlocks[count + 1], count)
  return screen
end

-- The unselected Cancel face is a sprite in retail, so finalized browse and
-- action backgrounds carry its static pixels composited at the audited
-- Cancel anchor; runtime never replays the sprite.
local function compositeCancelChrome(image, cancelFace)
  local cancelAnchor = BagSources.focusTargets.cancel
  local faceX = cancelAnchor.x + cancelFace.offset.x
  local faceY = cancelAnchor.y + cancelFace.offset.y
  if faceX < 0 or faceY < 0 or faceX + cancelFace.width > 256 or faceY + cancelFace.height > 192 then
    sourceError("cancel face placement escapes the canonical pane", { x = faceX, y = faceY })
  end
  local spans = {}
  local cursor = 1
  for row = 0, cancelFace.height - 1 do
    local targetOffset = ((faceY + row) * image.width + faceX) * 4 + 1
    spans[#spans + 1] = image.pixels:sub(cursor, targetOffset - 1)
    local blended = {}
    for col = 0, cancelFace.width - 1 do
      local sourceOffset = (row * cancelFace.width + col) * 4 + 1
      local sourceA = string.byte(cancelFace.pixels, sourceOffset + 3)
      if sourceA == 0 then
        blended[#blended + 1] = image.pixels:sub(targetOffset, targetOffset + 3)
      else
        local sourceR, sourceG, sourceB = string.byte(cancelFace.pixels, sourceOffset, sourceOffset + 2)
        if sourceA == 255 then
          blended[#blended + 1] = string.char(sourceR, sourceG, sourceB, 255)
        else
          local destinationR, destinationG, destinationB, destinationA =
            string.byte(image.pixels, targetOffset, targetOffset + 3)
          local outputA = sourceA + math.floor(destinationA * (255 - sourceA) / 255 + 0.5)
          blended[#blended + 1] = string.char(
            math.floor((sourceR * sourceA + destinationR * destinationA * (255 - sourceA) / 255) / outputA + 0.5),
            math.floor((sourceG * sourceA + destinationG * destinationA * (255 - sourceA) / 255) / outputA + 0.5),
            math.floor((sourceB * sourceA + destinationB * destinationA * (255 - sourceA) / 255) / outputA + 0.5),
            outputA
          )
        end
      end
      targetOffset = targetOffset + 4
    end
    spans[#spans + 1] = table.concat(blended)
    cursor = targetOffset
  end
  spans[#spans + 1] = image.pixels:sub(cursor)
  return { width = image.width, height = image.height, pixels = table.concat(spans) }
end

local function compileFixedBackgrounds(lower, screenRoles, cancelFace, assets)
  local backgrounds = {}
  for _, state in ipairs({ "action", "quantity", "confirmation" }) do
    local pockets = {}
    for pocketIndex, pocketState in ipairs(BagSources.hero.states) do
      local palette = effectiveLowerPalette(lower.colors, pocketIndex - 1)
      local layers = {}
      for _, sourceName in ipairs(BagSources.lowerLayers[state]) do
        local role = assert(screenRoles[sourceName], "audited Bag layer has no semantic role: " .. sourceName)
        local screen = assert(lower.screens[role], "audited Bag layer was not decoded: " .. sourceName)
        layers[#layers + 1] = rasterizeScreen(lower.charData, palette.colors, screen, role)
      end
      local image = BagPresentationCompiler.composeImages(layers, "interactive background " .. state)
      image = BagPresentationCompiler.cropImage(image, 256, 192, "interactive background " .. state)
      if state == "action" then
        image = compositeCancelChrome(image, cancelFace)
      end
      local path = BagCache.assetDir() .. "/background-" .. state .. "-" .. pocketState.pocket .. ".png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      pockets[pocketState.pocket] = { image = path, width = image.width, height = image.height }
    end
    backgrounds[state] = pockets
  end
  return backgrounds
end

-- Browse backgrounds carry one realized variant per pocket and visible
-- occupied-item count 0..6: each variant replays its audited tilemap block
-- against an independent copy of the decoded slot screen before
-- rasterization and Cancel composition.
local function compileBrowseBackgrounds(lower, screenRoles, cancelFace, assets)
  local washRole = assert(screenRoles.listWash, "audited Bag browse wash has no semantic role")
  local slotsRole = assert(screenRoles.listSlots, "audited Bag browse slots have no semantic role")
  local pockets = {}
  for pocketIndex, pocketState in ipairs(BagSources.hero.states) do
    local palette = effectiveLowerPalette(lower.colors, pocketIndex - 1)
    local wash = rasterizeScreen(lower.charData, palette.colors, assert(lower.screens[washRole]), washRole)
    local variants = {}
    for count = 0, 6 do
      local slots = browseScreenForCount(assert(lower.screens[slotsRole]), count)
      local slotLayer = rasterizeScreen(lower.charData, palette.colors, slots, slotsRole)
      local image = BagPresentationCompiler.composeImages({ wash, slotLayer }, "interactive background browse")
      image = BagPresentationCompiler.cropImage(image, 256, 192, "interactive background browse")
      image = compositeCancelChrome(image, cancelFace)
      local path = BagCache.assetDir() .. "/background-browse-" .. pocketState.pocket .. "-count-" .. count .. ".png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      variants[count + 1] = { image = path, width = image.width, height = image.height }
    end
    pockets[pocketState.pocket] = variants
  end
  return pockets
end

local function compileLowerBackgrounds(lower, cancelFace, assets)
  local screenRoles = {
    listWash = "list-wash",
    listSlots = "list-slots",
    actionWash = "action-wash",
    actionSlots = "action-slots",
    quantity = "quantity",
    confirmation = "confirmation",
  }
  local backgrounds = compileFixedBackgrounds(lower, screenRoles, cancelFace, assets)
  backgrounds.browse = compileBrowseBackgrounds(lower, screenRoles, cancelFace, assets)
  return backgrounds
end

-- Semantic message lowering. The pinned Bag messages carry two STRVAR
-- placeholders: the item-name reference (STRVAR_1 field 8) and the toss
-- quantity reference (STRVAR_1 field 52). Labels accept display glyphs and
-- line breaks only; templates additionally accept those two placeholders.
-- Every other substitution or control is malformed source, never a runtime
-- marker to interpret.
local ITEM_SUBSTITUTION = FieldMessageText.STRVAR_1 + 8
local QUANTITY_SUBSTITUTION = FieldMessageText.STRVAR_1 + 52

local function readMessageBank(archive, bankId, role, dependencies)
  local bytes, err = archive:readMember(bankId)
  if not bytes then
    sourceError("message bank " .. bankId .. " is unreadable: " .. Errors.format(err), { role = role, bank = bankId })
  end
  assert(bytes ~= nil, "unreadable message banks fail above")
  dependencies[#dependencies + 1] = { name = "messages:member:" .. bankId, role = role, sha1 = Hashing.sha1hex(bytes) }
  local bank, bankErr = FieldMessageBank.decode(bytes, { label = "bag-message-bank-" .. bankId })
  if not bank then
    assert(bankErr)
    sourceError("message bank " .. bankId .. " does not decode: " .. bankErr.message, {
      role = role,
      bank = bankId,
      cause = bankErr.code,
    })
  end
  return bank
end

local function messageTokens(bank, bankId, index, role)
  local message = bank.messages[index + 1]
  if not message then
    sourceError(
      "message bank " .. bankId .. " carries no message " .. index,
      { role = role, bank = bankId, index = index }
    )
  end
  local tokens, err = FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = bankId, messageId = index })
  if not tokens then
    assert(err)
    sourceError("bag message does not tokenize: " .. err.message, { role = role, bank = bankId, index = index })
  end
  assert(tokens ~= nil, "untokenizable bag messages fail above")
  return tokens
end

local function lowerLabel(bank, bankId, index, role)
  local parts = {}
  for _, token in ipairs(messageTokens(bank, bankId, index, role)) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      parts[#parts + 1] = token.text
    elseif token.kind == "line_break" then
      parts[#parts + 1] = "\n"
    else
      sourceError("bag label carries a non-display token " .. tostring(token.kind), {
        role = role,
        bank = bankId,
        index = index,
        kind = token.kind,
        control = token.control,
      })
    end
  end
  local label = table.concat(parts)
  if label == "" then
    sourceError("bag label has no display text", { role = role, bank = bankId, index = index })
  end
  return label
end

local function lowerTemplate(bank, bankId, index, role)
  local segments = {}
  local pending = {}
  local function flush()
    if #pending > 0 then
      segments[#segments + 1] = { kind = "text", value = table.concat(pending) }
      pending = {}
    end
  end
  for _, token in ipairs(messageTokens(bank, bankId, index, role)) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      pending[#pending + 1] = token.text
    elseif token.kind == "line_break" then
      pending[#pending + 1] = "\n"
    elseif token.kind == "substitution" and token.control == ITEM_SUBSTITUTION then
      flush()
      segments[#segments + 1] = { kind = "item" }
    elseif token.kind == "substitution" and token.control == QUANTITY_SUBSTITUTION then
      flush()
      segments[#segments + 1] = { kind = "quantity" }
    else
      sourceError("bag template carries an unsupported token " .. tostring(token.kind), {
        role = role,
        bank = bankId,
        index = index,
        kind = token.kind,
        control = token.control,
      })
    end
  end
  flush()
  if #segments == 0 then
    sourceError("bag template has no segments", { role = role, bank = bankId, index = index })
  end
  return { segments = segments }
end

local function compileText(messageArchive, dependencies)
  local banks = {}
  local function bankOf(bankId)
    if banks[bankId] == nil then
      banks[bankId] = readMessageBank(messageArchive, bankId, "message-bank-" .. bankId, dependencies)
    end
    return banks[bankId]
  end
  local labels = {}
  for _, action in ipairs({ "toss", "move", "register", "unregister", "cancel", "confirm" }) do
    local selector = BagSources.messages.actionLabels[action]
    labels[action] = lowerLabel(bankOf(selector.bank), selector.bank, selector.index, "label:" .. action)
  end
  local templates = {}
  for _, name in ipairs({ "movePrompt", "tossQuantity", "tossConfirm" }) do
    local selector = BagSources.messages.templates[name]
    templates[name] = lowerTemplate(bankOf(selector.bank), selector.bank, selector.index, "template:" .. name)
  end
  return {
    actions = labels,
    movePrompt = templates.movePrompt,
    tossQuantity = templates.tossQuantity,
    tossConfirm = templates.tossConfirm,
  }
end

local function compileMoveSummary(moveArchive, messageArchive, dependencies, assets)
  local facts = assert(BagSources.moveSummary)
  local function materializeMovePalette(palette)
    -- The retail loader places the packed NARC8 palette at VRAM bank 4; the
    -- source selects banks 4..6 after applying the per-icon override. The
    -- generic rasterizer indexes one flat palette, so preserve that loader
    -- base explicitly at the producer boundary.
    local colors = {}
    for index = 1, 4 * 16 do
      colors[index] = { r = 0, g = 0, b = 0 }
    end
    for index, color in ipairs(palette.colors) do
      colors[4 * 16 + index] = color
    end
    return { colors = colors }
  end
  local shared = {
    materializeMovePalette(
      decode(
        "decodePalette",
        readMember(moveArchive, facts.shared.palette, "move-summary-palette", dependencies, "narc8"),
        "move-summary-palette"
      )
    ),
    decode(
      "decodeCell",
      readMember(moveArchive, facts.shared.cell, "move-summary-cell", dependencies, "narc8"),
      "move-summary-cell"
    ),
    decode(
      "decodeAnimation",
      readMember(moveArchive, facts.shared.animation, "move-summary-animation", dependencies, "narc8"),
      "move-summary-animation"
    ),
  }
  local typeIcons, categoryIcons = {}, {}
  local MonSources = require("romdump.src.config.MonSources")
  for typeId, key in pairs(MonSources.typeKeys) do
    local memberId = assert(facts.typeChars[typeId], "move type source member is missing")
    local sprite = {
      decode(
        "decodeChar",
        readMember(moveArchive, memberId, "move-type-" .. key, dependencies, "narc8"),
        "move-type-" .. key
      ),
      shared[1],
      shared[2],
      shared[3],
    }
    typeIcons[key] = compileVisual(
      sprite,
      { animation = facts.shared.frame, palette = 4 + facts.typePaletteOverrides[typeId + 1] },
      "move-type-" .. key,
      assets
    )
  end
  for categoryId, key in pairs(MonSources.damageCategories) do
    local memberId = assert(facts.categoryChars[categoryId], "move category source member is missing")
    local sprite = {
      decode(
        "decodeChar",
        readMember(moveArchive, memberId, "move-category-" .. key, dependencies, "narc8"),
        "move-category-" .. key
      ),
      shared[1],
      shared[2],
      shared[3],
    }
    categoryIcons[key] = compileVisual(
      sprite,
      { animation = facts.shared.frame, palette = 4 + facts.categoryPaletteOverrides[categoryId + 1] },
      "move-category-" .. key,
      assets
    )
  end
  local labels = {}
  local messageBanks = {}
  local function bankOf(bankId)
    if messageBanks[bankId] == nil then
      messageBanks[bankId] = readMessageBank(messageArchive, bankId, "move-summary-bank-" .. bankId, dependencies)
    end
    return messageBanks[bankId]
  end
  for key, selector in pairs(facts.messages) do
    labels[key] = lowerLabel(bankOf(selector.bank), selector.bank, selector.index, "move-summary-label:" .. key)
  end
  return {
    labels = labels,
    text = facts.text,
    typeCenter = facts.typeCenter,
    categoryCenter = facts.categoryCenter,
    typeIcons = typeIcons,
    categoryIcons = categoryIcons,
  }
end

-- Registration marker rasterization: decode the audited source bitmap once,
-- render it through the shared lower-Bag palette path, and crop the two
-- audited slot regions. The tile count must match the audited bitmap exactly;
-- no generic blitter is reconstructed here.
local function compileRegistrationMarkers(archive, lowerColors, dependencies, assets)
  local registration = BagSources.registration
  assert(
    registration.bitmapWidth % 8 == 0 and registration.bitmapHeight % 8 == 0,
    "audited marker bitmap is tile-aligned"
  )
  assert(
    registration.slot1X + registration.markerWidth <= registration.bitmapWidth
      and registration.slot2X + registration.markerWidth <= registration.bitmapWidth,
    "audited marker crops fit the source bitmap"
  )
  local charData = decode(
    "decodeChar",
    readMember(archive, BagSources.chars.registrationMarker, "registration-marker-char", dependencies),
    "registration-marker-char"
  )
  if charData.depth ~= 3 then
    sourceError("registration marker source is not 4bpp character data", { depth = charData.depth })
  end
  local tilesWide = registration.bitmapWidth / 8
  local tilesHigh = registration.bitmapHeight / 8
  if #charData.tiles / 32 ~= tilesWide * tilesHigh then
    sourceError("registration marker source carries an unexpected tile count", {
      tiles = #charData.tiles / 32,
      required = tilesWide * tilesHigh,
    })
  end
  local entries = {}
  for tile = 0, tilesWide * tilesHigh - 1 do
    entries[tile + 1] = { tile = tile, flipH = false, flipV = false, palette = 0 }
  end
  local bitmap = rasterizeScreen(charData, lowerColors, {
    width = registration.bitmapWidth,
    height = registration.bitmapHeight,
    entries = entries,
  }, "registration-marker-bitmap")
  local function crop(sourceX, role)
    local rows = {}
    for y = 0, registration.markerHeight - 1 do
      local rowBase = (registration.sourceY + y) * registration.bitmapWidth * 4
      rows[#rows + 1] = bitmap.pixels:sub(rowBase + sourceX * 4 + 1, rowBase + (sourceX + registration.markerWidth) * 4)
    end
    local path = BagCache.assetDir() .. "/" .. role .. ".png"
    assets[path] = PngWriter.encode(registration.markerWidth, registration.markerHeight, table.concat(rows))
    return { image = path, width = registration.markerWidth, height = registration.markerHeight }
  end
  return {
    slot1 = crop(registration.slot1X, "registration-slot-1"),
    slot2 = crop(registration.slot2X, "registration-slot-2"),
  }
end

local function decodeModel(bytes, memberId, role)
  local ok, model = pcall(Nsbmd.decode, bytes, { alias = BagSources.archive.symbol, memberId = memberId })
  if not ok then
    sourceError(role .. " is not a decodable model: " .. tostring(model), { memberId = memberId, role = role })
  end
  if type(model) ~= "table" then
    sourceError(role .. " is not a decodable model", { memberId = memberId, role = role })
  end
  assert(type(model) == "table", "undecodable models fail above")
  if type(model.models) ~= "table" then
    sourceError(role .. " is not a decodable model", { memberId = memberId, role = role })
  end
  assert(type(model.models) == "table", "undecodable models fail above")
  if #model.models ~= 1 then
    sourceError(role .. " carries an unexpected model count", {
      memberId = memberId,
      role = role,
      modelCount = #model.models,
    })
  end
  return model
end

local function compileClip(bytes, memberId, role, clipId, semanticName)
  local decoded, err = NitroAnimation.decode(bytes, { alias = BagSources.archive.symbol, memberId = memberId })
  if not decoded then
    sourceError(role .. " is not decodable: " .. tostring(err), { memberId = memberId, role = role })
  end
  assert(type(decoded) == "table", "undecodable animations fail above")
  assert(type(decoded.animations) == "table", "undecodable animations fail above")
  assert(decoded.animations[1] ~= nil, "undecodable animations fail above")
  if #decoded.animations ~= 1 then
    sourceError(role .. " carries an unexpected animation count", {
      memberId = memberId,
      role = role,
      animationCount = #decoded.animations,
    })
  end
  -- The addressable clip name is the semantic clip id, not the embedded
  -- Nitro dictionary name: the pattern and joint members of one pocket
  -- share one embedded animation name, so the source name cannot
  -- distinguish the two clips of a pocket pair. The pocket role stays on
  -- semanticNames; id and name carry the same semantic clip id.
  local ok, clip = pcall(MapPropAnimCompiler.compileDecoded, decoded, {
    name = clipId,
    id = clipId,
    source = { type = "nitro", format = decoded.format },
  })
  if not ok then
    if Errors.is(clip) then
      ---@cast clip Errors.Error
      sourceError(role .. " failed to compile: " .. clip.message, {
        memberId = memberId,
        role = role,
        cause = clip.code,
      })
    end
    error(clip, 0)
  end
  assert(type(clip) == "table", "uncompilable clips fail above")
  clip.semanticNames = { semanticName }
  return clip
end

-- Compile one gender hero: the model plus eight pocket pattern/joint pairs
-- and the shared material clip, all through the existing model compilers.
-- Clip ids are semantic; opaque member identities never leave this module.
local function compileHero(archive, gender, dependencies, textures, meshes)
  local selection = BagSources.hero[gender]
  local modelBytes = readMember(archive, selection.model, "hero-" .. gender .. "-model", dependencies)
  local decoded = decodeModel(modelBytes, selection.model, "hero-" .. gender .. "-model")
  local clips = {}
  for _, state in ipairs(BagSources.hero.states) do
    local patternMember = selection.patternBase + state.slot
    local jointMember = selection.jointBase + state.slot
    clips[#clips + 1] = compileClip(
      readMember(archive, patternMember, "hero-" .. gender .. "-pattern-" .. state.pocket, dependencies),
      patternMember,
      "hero-" .. gender .. "-pattern-" .. state.pocket,
      "bag." .. gender .. ".pattern." .. state.pocket,
      "pocket." .. state.pocket .. ".pattern"
    )
    clips[#clips + 1] = compileClip(
      readMember(archive, jointMember, "hero-" .. gender .. "-joint-" .. state.pocket, dependencies),
      jointMember,
      "hero-" .. gender .. "-joint-" .. state.pocket,
      "bag." .. gender .. ".pose." .. state.pocket,
      "pocket." .. state.pocket .. ".pose"
    )
  end
  clips[#clips + 1] = compileClip(
    readMember(archive, selection.material, "hero-" .. gender .. "-material", dependencies),
    selection.material,
    "hero-" .. gender .. "-material",
    "bag." .. gender .. ".material",
    "bag.material"
  )
  local model = decoded.models[1]
  assert(type(model) == "table", "single-model heroes fail above")
  local pack = decoded.embeddedTextures
  if pack == nil then
    pack = { textureByName = {}, paletteByName = {} }
  end
  local descriptor, unresolved = DynamicModelCompiler.compile(model, decoded, pack, { clips = clips }, {
    role = "bag-hero-" .. gender,
    modelArchive = BagSources.archive.alias,
    modelMemberId = selection.model,
    modelName = model.name,
  }, selection.model, textures, meshes)
  for _, entry in ipairs(unresolved) do
    sourceError("hero-" .. gender .. " texture binding has no source texture: " .. tostring(entry.name), {
      role = "bag-hero-" .. gender,
      material = entry.material,
      kind = entry.kind,
      name = entry.name,
    })
  end
  descriptor.memberId = nil
  local ok, err = pcall(ModelAsset.validate, descriptor)
  if not ok then
    if Errors.is(err) then
      sourceError("hero-" .. gender .. " descriptor is invalid: " .. err.message, { cause = err.code })
    end
    error(err, 0)
  end
  return descriptor
end

-- Normalize one raw framing record into manifest values: u16 angles convert
-- over the full circle while fixed-point lengths normalize once into the
-- tile unit shared with compiled geometry and the static camera.
local function normalizeFramingRecord(raw, gender, label)
  local context = { gender = gender, pocket = label }
  for _, field in ipairs({ "angleX", "angleY", "distance", "modelY" }) do
    if type(raw[field]) ~= "number" or raw[field] % 1 ~= 0 then
      sourceError("hero framing record carries no integer source " .. field, context)
    end
  end
  return {
    angleXDegrees = raw.angleX / 65536 * 360,
    angleYDegrees = raw.angleY / 65536 * 360,
    distance = modelUnits(raw.distance / 4096),
    modelY = modelUnits(raw.modelY / 4096),
  }
end

-- Publish the pocket framing contract: the neutral baseline plus one record
-- per canonical pocket for both genders with the fixed-tick transition
-- duration. Missing or incomplete source records fail compilation.
local function compileFraming()
  local facts = BagSources.presentation.framing
  if type(facts) ~= "table" then
    sourceError("hero framing facts are missing", {})
  end
  assert(type(facts) == "table", "missing framing facts fail above")
  if facts.transitionTicks ~= 7 then
    sourceError("hero framing transition duration is not the audited seven ticks", {
      transitionTicks = facts.transitionTicks,
    })
  end
  local baseline, byGender = {}, {}
  for _, gender in ipairs({ "male", "female" }) do
    local records = facts[gender]
    if type(records) ~= "table" or #records ~= 9 then
      sourceError("hero framing carries incomplete gender records", { gender = gender })
    end
    baseline[gender] = normalizeFramingRecord(records[1], gender, "baseline")
    local pockets = {}
    for index, state in ipairs(BagSources.hero.states) do
      local raw = records[index + 1]
      if raw == nil then
        sourceError("hero framing is missing a pocket record", { gender = gender, pocket = state.pocket })
      end
      pockets[state.pocket] = normalizeFramingRecord(raw, gender, state.pocket)
    end
    byGender[gender] = pockets
  end
  return { transitionTicks = 7, baseline = baseline, byGender = byGender }
end

local function _compile(romFs)
  assert(
    romFs and type(romFs.metadata) == "function" and type(romFs.openNarc) == "function",
    "bag compilation requires source metadata and archive reader"
  )
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "bag source metadata must carry sha1")
  local dependencies = {
    { name = "assetContract", sha1 = BagCache.FORMAT .. ":" .. BagCache.SCHEMA .. ":" .. ModelAsset.SCHEMA },
  }
  local archive, archiveErr = romFs:openNarc(BagSources.archive.alias)
  if archive == nil then
    error(
      archiveErr
        or Errors.new(
          BagAssetCompiler.ERROR.SOURCE_INVALID,
          "bag archive is unavailable",
          { alias = BagSources.archive.alias }
        ),
      0
    )
  end
  assert(archive ~= nil, "unavailable archives fail above")
  local info = must(romFs:resolvedNarc(BagSources.archive.alias), "bag archive has no resolution")
  local archiveBytes = must(romFs:read(info.fileId), "bag archive bytes are unavailable")
  dependencies[#dependencies + 1] = { name = BagSources.archive.alias .. ":narc", sha1 = Hashing.sha1hex(archiveBytes) }

  local assets = {}
  local screenReferences, lower = compileScreens(archive, dependencies, assets)
  local messageArchive, messageArchiveErr = romFs:openNarc("messages")
  if messageArchive == nil then
    error(
      messageArchiveErr
        or Errors.new(
          BagAssetCompiler.ERROR.SOURCE_INVALID,
          "bag message archive is unavailable",
          { alias = "messages" }
        ),
      0
    )
  end
  assert(messageArchive ~= nil, "unavailable message archives fail above")
  local text = compileText(messageArchive, dependencies)
  local moveArchive, moveArchiveErr = romFs:openNarc(BagSources.moveSummary.archive.symbol)
  if moveArchive == nil then
    error(
      moveArchiveErr
        or Errors.new(
          BagAssetCompiler.ERROR.SOURCE_INVALID,
          "move summary archive is unavailable",
          { alias = BagSources.moveSummary.archive.symbol }
        ),
      0
    )
  end
  assert(moveArchive ~= nil, "unavailable move summary archive fails above")
  local moveInfo =
    must(romFs:resolvedNarc(BagSources.moveSummary.archive.symbol), "move summary archive has no resolution")
  local moveBytes = must(romFs:read(moveInfo.fileId), "move summary archive bytes are unavailable")
  dependencies[#dependencies + 1] = { name = "narc8:narc", sha1 = Hashing.sha1hex(moveBytes) }
  local moveSummary = compileMoveSummary(moveArchive, messageArchive, dependencies, assets)
  moveSummary.background = screenReferences["upper-alternate"]
  local sprites = compileSprites(archive, dependencies, assets)
  local backgrounds = compileLowerBackgrounds(lower, sprites.cancelFace, assets)
  local markers = compileRegistrationMarkers(archive, lower.colors, dependencies, assets)
  local textures, meshes = {}, {}
  local male = compileHero(archive, "male", dependencies, textures, meshes)
  local female = compileHero(archive, "female", dependencies, textures, meshes)
  for sha1, batch in pairs(meshes) do
    assets[MapAssetCache.geometryPath(sha1)] = MeshWriter.encode(batch)
  end
  do
    local keys = {}
    for sha1 in pairs(textures) do
      keys[#keys + 1] = sha1
    end
    table.sort(keys)
    for _, sha1 in ipairs(keys) do
      local texture = textures[sha1]
      assets[MapAssetCache.texturePath(sha1)] = assert(texture.data, "compiled texture is missing finalized PNG Data")
    end
  end

  local geometry = BagPresentationCompiler.compileGeometry(BagSources)
  local states = BagPresentationCompiler.compileStates(BagSources)
  local materials = BagPresentationCompiler.compileMaterials(BagSources)
  local framing = compileFraming()
  local presentation = BagSources.presentation
  local manifest = {
    schema = BagCache.SCHEMA,
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = screenReferences["upper-backdrop-male"],
        female = screenReferences["upper-backdrop-female"],
      },
      description = {
        frame = {
          image = screenReferences["upper-base"].image,
          rect = geometry.descriptionFrame,
        },
        textRect = geometry.descriptionText,
      },
      moveSummary = moveSummary,
      model = { male = male, female = female },
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
      presentation = {
        camera = {
          target = {
            x = modelUnits(presentation.camera.target.x),
            y = modelUnits(presentation.camera.target.y),
            z = modelUnits(presentation.camera.target.z),
          },
          distance = modelUnits(presentation.camera.distance),
          angleXDegrees = presentation.camera.angleXDegrees,
          angleYDegrees = presentation.camera.angleYDegrees,
          perspectiveType = presentation.camera.perspectiveType,
          perspectiveAngle = presentation.camera.perspectiveAngle,
          clipNear = modelUnits(presentation.camera.clipNear),
          clipFar = modelUnits(presentation.camera.clipFar),
        },
        transform = {
          translation = {
            x = modelUnits(presentation.transform.translation.x),
            y = modelUnits(presentation.transform.translation.y),
            z = modelUnits(presentation.transform.translation.z),
          },
          rotation = {
            presentation.transform.rotation[1],
            presentation.transform.rotation[2],
            presentation.transform.rotation[3],
            presentation.transform.rotation[4],
            presentation.transform.rotation[5],
            presentation.transform.rotation[6],
            presentation.transform.rotation[7],
            presentation.transform.rotation[8],
            presentation.transform.rotation[9],
          },
          scale = {
            x = presentation.transform.scale.x,
            y = presentation.transform.scale.y,
            z = presentation.transform.scale.z,
          },
        },
        lights = {
          count = presentation.lights.count,
          color = {
            r = presentation.lights.color.r,
            g = presentation.lights.color.g,
            b = presentation.lights.color.b,
          },
          vectors = {
            {
              x = presentation.lights.vectors[1].x,
              y = presentation.lights.vectors[1].y,
              z = presentation.lights.vectors[1].z,
            },
            {
              x = presentation.lights.vectors[2].x,
              y = presentation.lights.vectors[2].y,
              z = presentation.lights.vectors[2].z,
            },
            {
              x = presentation.lights.vectors[3].x,
              y = presentation.lights.vectors[3].y,
              z = presentation.lights.vectors[3].z,
            },
            {
              x = presentation.lights.vectors[4].x,
              y = presentation.lights.vectors[4].y,
              z = presentation.lights.vectors[4].z,
            },
          },
        },
        materials = materials,
        framing = framing,
        edgeColors = normalizeEdgeColors(BagSources.presentation.edgeColors),
      },
    },
    interactive = {
      backgrounds = backgrounds,
      pocketTabs = {
        rects = geometry.tabs,
        strips = sprites.strips,
      },
      itemSlots = {
        slots = geometry.slots,
        registration = {
          slot1 = markers.slot1,
          slot2 = markers.slot2,
          offset = { x = BagSources.registration.offset.x, y = BagSources.registration.offset.y },
        },
      },
      focus = {
        tabs = { visual = sprites.focus.tabs, targets = geometry.focus.tabs },
        items = { visual = sprites.focus.items, targets = geometry.focus.items },
        cancel = { visual = sprites.focus.cancel, target = geometry.focus.cancel },
        actions = { visual = sprites.focus.actions, targets = geometry.focus.actions },
      },
      pageIndicator = geometry.pageIndicator,
      cancel = geometry.cancel,
      text = text,
      overlays = {
        actionMenu = { face = sprites.actionFace, slots = geometry.actionSlots },
        quantity = {
          digits = geometry.quantityDigits,
          controls = geometry.quantityControls,
          visuals = {
            increment = sprites.quantity.increment,
            decrement = sprites.quantity.decrement,
          },
          pressTicks = sprites.quantity.pressTicks,
          confirm = {
            visual = sprites.quantity.confirm,
            center = geometry.quantityConfirm.center,
            hitRect = geometry.quantityConfirm.hitRect,
          },
          cancelHitRect = geometry.quantityCancelHitRect,
        },
        descriptionFallback = { frame = geometry.descriptionFrame, textRect = geometry.descriptionText },
      },
    },
  }
  local ok, err = pcall(BagAssetSchema.assertManifest, manifest)
  if not ok then
    sourceError("compiled bag manifest is invalid: " .. Errors.format(err), {})
  end

  local dependencyRecord = {
    cacheFormat = BagCache.FORMAT,
    schema = BagCache.SCHEMA,
    modelSchema = ModelAsset.SCHEMA,
    versionRomSha1 = metadata.sha1,
    source = BagSources.provenance,
    selection = {
      archive = BagSources.archive,
      moveSummary = BagSources.moveSummary,
      screens = BagSources.screens,
      chars = BagSources.chars,
      palettes = BagSources.palettes,
      sprites = BagSources.sprites,
      spriteStates = BagSources.spriteStates,
      tabPaletteState = BagSources.tabPaletteState,
      focusTargets = BagSources.focusTargets,
      itemIconCenters = BagSources.itemIconCenters,
      lowerLayers = BagSources.lowerLayers,
      browseCountBlocks = BagSources.browseCountBlocks,
      hero = BagSources.hero,
      messages = BagSources.messages,
      registration = BagSources.registration,
    },
    presentation = BagSources.presentation,
    geometry = BagSources.geometry,
    dependencies = dependencies,
  }
  return {
    marker = BagCache.marker(metadata.sha1, Hashing.hashLua(dependencyRecord)),
    manifest = manifest,
    dependencies = dependencyRecord,
    assets = assets,
  }
end

---@param romFs RomFs
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function BagAssetCompiler.compile(romFs)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  local ok, result = xpcall(_compile, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return BagAssetCompiler
