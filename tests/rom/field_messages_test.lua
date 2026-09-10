-- ROM-conformance checks for raw message/font facts. Decodes and compiles
-- directly from the ROM without the prepared generated cache; cache-backed
-- message facts live in the sibling cache suite.

local Assert = require("tests.support.Assert")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldFontCompiler = require("romdump.src.digest.ui.FieldFontCompiler")
local FieldFontDecoder = require("romdump.src.digest.ui.FieldFontDecoder")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Hashing = require("romdump.src.digest.Hashing")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local charmap = require("romdump.src.reference.hgss.charmap")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local PngReader = require("tests.support.PngReader")

local T = {}

function T.known_yesno_and_color_messages_carry_the_expected_controls(romFs)
  -- Known target-message control facts for bank 543, verified from the raw
  -- ROM code units: messages 8/9/27/92 end with a YESNO field 0, and messages
  -- 79/80 carry the COLOR 1 -> 0 transition around the highlighted span.
  -- Structural facts only; no retail message text is asserted.
  local messages = assert(romFs:openNarc("messages"))
  local bank = assert(FieldMessageBank.decode(messages:readMember(543), {}))
  local function controlsOf(messageId)
    local tokens = assert(FieldMessageTokenizer.tokenize(bank.messages[messageId + 1].raw, charmap, {}))
    local controls = {}
    for _, token in ipairs(tokens) do
      if token.kind ~= "glyph" and token.kind ~= "eos" then
        controls[#controls + 1] = token
      end
    end
    return controls
  end
  for _, messageId in ipairs({ 8, 9, 27, 92 }) do
    local yesno = {}
    for _, token in ipairs(controlsOf(messageId)) do
      if token.control == FieldMessageText.YESNO then
        yesno[#yesno + 1] = token
      end
    end
    Assert.equal(#yesno, 1, "bank 543 message " .. messageId .. " has exactly one YESNO")
    Assert.equal(yesno[1].kind, "focus_indicator")
    Assert.equal(yesno[1].name, "YESNO")
    Assert.deepEqual(yesno[1].args, { 0 })
  end
  for _, messageId in ipairs({ 79, 80 }) do
    local colorArgs = {}
    for _, token in ipairs(controlsOf(messageId)) do
      if token.control == FieldMessageText.COLOR then
        colorArgs[#colorArgs + 1] = token.args[1]
      end
    end
    Assert.equal(#colorArgs, 2, "bank 543 message " .. messageId .. " has two COLOR controls")
    Assert.equal(colorArgs[1], 1, "message " .. messageId .. " opens the color span at 1")
    Assert.equal(colorArgs[2], 0, "message " .. messageId .. " closes the color span back to 0")
  end
end

function T.target_glyph_set_resolves_in_the_font(romFs)
  local messages = assert(romFs:openNarc("messages"))
  local font = assert(FieldFontDecoder.decodeMember(assert(romFs:openNarc("font")):readMember(0)))
  -- Collect glyph codes from the token streams: control arguments in the raw
  -- units are data, not characters.
  local glyphs = {}
  for _, bankId in ipairs({ 542, 543 }) do
    local bank = assert(FieldMessageBank.decode(messages:readMember(bankId), {}))
    for _, message in ipairs(bank.messages) do
      local tokens = assert(FieldMessageTokenizer.tokenize(message.raw, charmap, {}))
      for _, token in ipairs(tokens) do
        if token.kind == "glyph" then
          glyphs[token.code] = true
        end
      end
    end
  end
  local glyphCount = 0
  for _ in pairs(glyphs) do
    glyphCount = glyphCount + 1
  end
  Assert.isTrue(glyphCount > 60)
  for code in pairs(glyphs) do
    Assert.notNil(charmap.glyphs[code], string.format("unmapped glyph 0x%04X", code))
    Assert.isTrue(code <= font.numGlyphs, string.format("glyph 0x%04X beyond font", code))
  end
end

function T.map_header_bank_associations_are_emitted(romFs)
  local associations = {}
  for _, mapId in ipairs({ 60, 61 }) do
    local field = assert(FieldMapDataCompiler.compile(romFs, mapId)).field
    associations[mapId] = field.messageBankId
  end
  Assert.equal(associations[60], 542)
  Assert.equal(associations[61], 543)
end

function T.opposite_protagonist_name_bank_is_selected_for_the_derived_cache(_)
  -- The field name-resolution boundary reads the opposite protagonist's
  -- canonical name from generated bank 445, so the message compiler must
  -- select that bank for the derived cache like any other runtime-read bank.
  local selected = {}
  for _, bankId in ipairs(FieldMessageCompiler.requiredBankIds()) do
    selected[bankId] = true
  end
  Assert.isTrue(selected[445] == true, "the derived message cache must select bank 445")
end

function T.opposite_protagonist_name_bank_holds_two_plain_name_messages(romFs)
  -- The source bank behind the gender-selected counterpart names decodes to
  -- at least the two plain name messages the runtime selects between. Only
  -- structural facts are pinned here: glyph-only streams with distinct
  -- non-empty text, no retail wording.
  local messages = assert(romFs:openNarc("messages"))
  local bank = assert(FieldMessageBank.decode(messages:readMember(445), { label = "msgdata-member-445" }))
  Assert.isTrue(bank.messageCount >= 2, "bank 445 must hold at least the two counterpart names")
  local texts = {}
  for _, messageId in ipairs({ 0, 1 }) do
    local tokens = assert(FieldMessageTokenizer.tokenize(bank.messages[messageId + 1].raw, charmap, {
      bankId = 445,
      messageId = messageId,
    }))
    local glyphs = 0
    for _, token in ipairs(tokens) do
      Assert.isTrue(
        token.kind == "glyph" or token.kind == "eos",
        "bank 445 message " .. messageId .. " must be a plain name, not a control stream"
      )
      if token.kind == "glyph" then
        glyphs = glyphs + 1
      end
    end
    Assert.isTrue(glyphs > 0, "bank 445 message " .. messageId .. " must name someone")
    texts[#texts + 1] = FieldMessageText.tokensToText(tokens)
  end
  Assert.isTrue(texts[1] ~= texts[2], "the two counterpart names must differ")
end

function T.font_palette_matches_the_rom_member(romFs)
  local palette = assert(FieldFontDecoder.decodePalette(assert(romFs:openNarc("font")):readMember(7)))
  Assert.equal(palette.colorCount, 16)
  Assert.equal(palette.depth, 3)
  -- Slot 1 = foreground ink, slot 2 = shadow, slot 15 = white background.
  local fg = palette.colors[2]
  Assert.isTrue(fg.r < 120 and fg.g < 120 and fg.b < 120, "fg must be dark")
  Assert.deepEqual(palette.colors[16], { r = 255, g = 255, b = 255 })
end

function T.standard_menu_bank_holds_the_vanilla_list_menu_ids(romFs)
  -- Source-faithful 749 menus resolve item ids against the standard list-menu
  -- bank (MenuProtocol.STANDARD_MESSAGE_BANK). The scr_seq corpus references
  -- ids up to 475 (member 3's mart menus use 321/322/323, the info menu 324),
  -- so the standard bank must cover every id the runtime will resolve.
  local messages = assert(romFs:openNarc("messages"))
  local menu = assert(
    FieldMessageBank.decode(messages:readMember(MenuProtocol.STANDARD_MESSAGE_BANK), {}),
    "standard menu bank must exist"
  )
  for _, id in ipairs({ 321, 322, 323, 324, 475 }) do
    Assert.isTrue(menu.messages[id + 1] ~= nil, "standard menu bank must hold list-menu message " .. tostring(id))
  end
end

function T.font_focus_indicator_member_is_a_four_frame_24x32_4bpp_ncgr(romFs)
  -- Font NARC member 6 is the screen-focus indicator set (the
  -- GfGfxLoader_GetCharData payload the text printer blits next to YESNO
  -- prompts). These are structural facts about the real member: the NCGR char
  -- data is 4bpp and forms exactly FOCUS_INDICATOR_COUNT 24x32 frames (12
  -- tiles each), reserving the background index for transparency.
  local member = assert(assert(romFs:openNarc("font")):readMember(6))
  local char, charErr = G2dDecoder.decodeChar(member, { label = "font-focus-indicator" })
  Assert.notNil(char, charErr and charErr.message or "font member 6 must decode as NCGR char data")
  local chars = assert(char, "font member 6 decodes as NCGR char data")
  Assert.equal(chars.depth, 3, "the indicator set is 4bpp")
  local tiles = math.floor(#chars.tiles / 32)
  Assert.equal(
    tiles,
    FieldMessageText.FOCUS_INDICATOR_COUNT * 12,
    "24x32 at 4bpp is 12 8x8 tiles per frame; the member must hold exactly the protocol frame count"
  )
  local function tileValue(tile, tx, ty)
    local byte = chars.tiles:byte(tile * 32 + ty * 4 + math.floor(tx / 2) + 1)
    local lo = byte % 16
    return tx % 2 == 0 and lo or math.floor(byte / 16)
  end
  local function frameValue(frame, x, y)
    local tileY = math.floor(y / 8)
    local tileX = math.floor(x / 8)
    return tileValue(frame * 12 + tileY * 3 + tileX, x % 8, y % 8)
  end
  local used = {}
  for frame = 0, FieldMessageText.FOCUS_INDICATOR_COUNT - 1 do
    for y = 0, 31 do
      for x = 0, 23 do
        used[frameValue(frame, x, y)] = true
      end
    end
  end
  -- Palette-index interpretation: index 0 is the transparent background; the
  -- visible indicator uses slots 0x0B..0x0E and never the font background slot.
  local expected = { [0] = true, [0x0B] = true, [0x0C] = true, [0x0D] = true, [0x0E] = true }
  for index in pairs(expected) do
    Assert.isTrue(used[index], "the indicator set must use palette index " .. string.format("0x%02X", index))
  end
  for index in pairs(used) do
    Assert.isTrue(expected[index] == true, "unexpected indicator index " .. string.format("0x%02X", index))
  end
  -- The four source frames are pairwise distinct, so a degenerate payload that
  -- collapsed frames cannot pass as the protocol shape.
  local frames = {}
  for frame = 0, FieldMessageText.FOCUS_INDICATOR_COUNT - 1 do
    local bytes = {}
    for y = 0, 31 do
      for x = 0, 23, 2 do
        bytes[#bytes + 1] = string.char(frameValue(frame, x, y) * 16 + frameValue(frame, x + 1, y))
      end
    end
    frames[frame] = table.concat(bytes)
  end
  for a = 0, FieldMessageText.FOCUS_INDICATOR_COUNT - 1 do
    for b = a + 1, FieldMessageText.FOCUS_INDICATOR_COUNT - 1 do
      Assert.isFalse(frames[a] == frames[b], "focus frames " .. a .. " and " .. b .. " must be distinct")
    end
  end
end

function T.compiled_font_def_matches_the_real_focus_and_color_contract(romFs, _)
  -- The compiled field-font definition and its cache marker must reflect the
  -- ROM's font member 6: seven color bands (the protocol COLOR_VARIANT_COUNT),
  -- four 24x32 focus frames with in-bounds rects, and the member bytes
  -- participating in the dependency record.
  local bundle = assert(FieldFontCompiler.compile(romFs)) --[[@as table]]
  local def = bundle.fonts[0].font
  local variants = def.colorVariants
  Assert.notNil(variants, "the compiled font must expose colorVariants")
  Assert.equal(variants.count, FieldMessageText.COLOR_VARIANT_COUNT)
  Assert.isTrue(variants.strideY > 0, "the color stride must be positive")
  Assert.equal(def.atlas.height, def.atlas.baseHeight * variants.count)

  local focus = def.focusIndicators
  Assert.notNil(focus, "the compiled font must expose focusIndicators")
  Assert.equal(focus.count, FieldMessageText.FOCUS_INDICATOR_COUNT)
  Assert.equal(focus.width, 24)
  Assert.equal(focus.height, 32)
  local focusW, focusH, _ = PngReader.rgba(bundle.fonts[0].focusIndicators)
  for field = 0, focus.count - 1 do
    local rect = focus.frames[field]
    Assert.equal(rect.width, 24, "focus frame " .. field .. " must be 24 wide")
    Assert.equal(rect.height, 32, "focus frame " .. field .. " must be 32 tall")
    Assert.isTrue(
      rect.x + rect.width <= focusW and rect.y + rect.height <= focusH,
      "focus frame " .. field .. " must lie inside the focus PNG"
    )
  end
  Assert.equal(bundle.dependencies.focusIndicatorMemberId, 6)
  local member6 = assert(assert(romFs:openNarc("font")):readMember(6))
  Assert.equal(bundle.dependencies.focusIndicatorMemberSha1, Hashing.sha1hex(member6))

  -- The default band keeps the pre-change palette mapping: visible pixels
  -- resolve to the font foreground slot 1 and shadow slot 2 (the same slots
  -- the old single-band compiler used), so unstyled dialogue is unchanged.
  local atlasW, atlasH, atlasRgba = PngReader.rgba(bundle.fonts[0].atlas)
  Assert.equal(atlasH, def.atlas.height)
  local fg = def.palette[FieldFontDecoder.FG_PALETTE_INDEX + 1]
  local shadow = def.palette[FieldFontDecoder.SHADOW_PALETTE_INDEX + 1]
  local foundFg, foundShadow = false, false
  for y = 0, def.atlas.baseHeight - 1 do
    for x = 0, atlasW - 1 do
      local r, g, b, a = PngReader.pixel(atlasRgba, atlasW, x, y)
      if a > 0 then
        if r == fg.r and g == fg.g and b == fg.b then
          foundFg = true
        elseif r == shadow.r and g == shadow.g and b == shadow.b then
          foundShadow = true
        end
      end
    end
  end
  Assert.isTrue(foundFg, "the default band must draw foreground ink from slot 1")
  Assert.isTrue(foundShadow, "the default band must draw shadow ink from slot 2")
end

-- Independent check that the compiled glyph atlas places a real leading
-- glyph's ink at exactly the column the raw NARC glyph decodes to: this
-- proves the font compositor adds no horizontal shift of its own, so any
-- observed leading whitespace in a real glyph is source-decoded bearing, not
-- an extraction defect. If this test ever disagrees, the font
-- producer (not the shared dialogue layout/mapping) is the failing owner.
function T.leading_glyph_local_ink_matches_between_raw_decode_and_the_generated_atlas(romFs, _)
  local bundle = assert(FieldFontCompiler.compile(romFs))
  local font = bundle.fonts[0].font
  local code = assert(font.charmap["A"], "the font charmap must resolve 'A' for this corpus")
  local glyph = assert(font.glyphs[code])

  -- Decode straight from the source NARC member, bypassing the atlas
  -- compositor entirely: compileFont's own glyph-to-index mapping is
  -- glyphIndex = code - 1 for every in-range charcode (font.glyphIndexForCode).
  local archive = assert(romFs:openNarc(bundle.dependencies.fontNarc.alias))
  local glyphMember = assert(archive:readMember(bundle.dependencies.glyphMembers[1].memberId))
  local rawFont = assert(FieldFontDecoder.decodeMember(glyphMember, { label = "field-font-glyphs" }))
  local rawGlyph = rawFont.glyphPixels(code - 1)

  -- The compiler's own opaque rule (pixelToRgba in FieldFontCompiler): 0 is
  -- transparent, and so is 3 ("background") -- only 1 (foreground) and 2
  -- (shadow) reach the atlas as opaque pixels. Local opacity must follow that
  -- same rule or this diagnostic would disagree with the atlas for reasons
  -- that have nothing to do with a real extraction defect.
  local function localOpaqueMinX(values, width, height)
    for x = 1, width do
      for y = 1, height do
        local value = values[y][x]
        if value == 1 or value == 2 then
          return x - 1
        end
      end
    end
    return nil
  end

  local rawMinX = localOpaqueMinX(rawGlyph.values, rawGlyph.width, rawGlyph.height)
  Assert.notNil(rawMinX, "'A' must decode at least one non-transparent pixel")

  local atlasWidth, _, atlasRgba = PngReader.rgba(bundle.fonts[0].atlas)
  local atlasMinX
  for x = 0, glyph.w - 1 do
    for y = 0, glyph.h - 1 do
      local _, _, _, a = PngReader.pixel(atlasRgba, atlasWidth, glyph.x + x, glyph.y + y)
      if a > 0 then
        atlasMinX = x
        break
      end
    end
    if atlasMinX ~= nil then
      break
    end
  end

  Assert.equal(
    atlasMinX,
    rawMinX,
    "the compiled atlas must place 'A' ink at exactly the column the raw NARC glyph decodes to"
  )
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
return suite
