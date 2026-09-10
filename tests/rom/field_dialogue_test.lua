-- ROM-conformance dialogue facts: the real cached font definition and bank
-- messages lay out and advance deterministically through the pure dialogue
-- layers (provider -> format -> layout -> controller) without any LÖVE
-- graphics. Structural facts only; no retail text is
-- asserted or printed.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DialogueLayout = require("libs.hgss.src.ui.DialogueLayout")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")

local T = {}

---@param version string
---@return FieldFontDef
local function fontDef(version)
  local def = assert(CacheFs.forVersion(version):loadLua("data/generated/field/font/font-0.lua"))
  assert(def.schema == FieldFontCache.SCHEMA, "field font cache is cold")
  return def --[[@as FieldFontDef]]
end

-- Runs one real bank message through format -> layout -> controller and
-- drives it to completion with Action. Returns the page count and the
-- completion result.
local function runMessage(version, bankId, messageId)
  local def = fontDef(version)
  local cache = CacheFs.forVersion(version)
  local provider = assert(FieldMessageProvider.new(cache))
  local bank = provider:acquireBank(bankId)
  assert(bank, "message bank cache is cold")
  local template = assert(provider:get(bankId, messageId))
  local formatted = provider:format(template, { playerName = "GOLD" }, {
    [0x0103] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
  })
  local metrics = FieldDialogueTheme.fontMetrics(def)
  local layout = function(message)
    return DialogueLayout.layout(
      message.tokens,
      metrics,
      { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
    )
  end
  local first = layout(formatted)
  local second = layout(formatted)
  Assert.deepEqual(first, second, "layout is deterministic for the same tokens")

  local controller = FieldDialogueController.new({
    layout = layout,
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
  })
  local completed = nil
  local handle = controller:open({
    id = string.format("target-%d-%d", bankId, messageId),
    message = formatted,
    allowCancel = false,
    metadata = { bankId = bankId, messageId = messageId },
  })
  handle:onComplete(function(result)
    completed = result
  end)
  local ticks = 0
  while controller:isModal() and ticks < 500 do
    controller:step({ actionPressed = true })
    ticks = ticks + 1
  end
  Assert.isTrue(ticks < 500, "target message reaches completion within 500 ticks")
  assert(completed, "completion result required")
  provider:releaseBank(bankId)
  return #first.pages, completed
end

function T.target_fixture_messages_lay_out_and_close(_, version)
  local cases = {
    { bankId = 542, messageId = 1 },
    { bankId = 543, messageId = 5 },
    { bankId = 543, messageId = 14 },
    { bankId = 543, messageId = 18 },
    { bankId = 543, messageId = 93 },
    { bankId = 543, messageId = 94 },
    { bankId = 543, messageId = 95 },
    { bankId = 543, messageId = 96 },
    { bankId = 543, messageId = 97 },
  }
  for _, spec in ipairs(cases) do
    local pages, result = runMessage(version, spec.bankId, spec.messageId)
    Assert.isTrue(
      pages >= 1,
      string.format("bank %d message %d produces at least one page", spec.bankId, spec.messageId)
    )
    Assert.equal(result.kind, "complete")
    Assert.equal(result.requestId, string.format("target-%d-%d", spec.bankId, spec.messageId))
  end
end

function T.page_break_retains_the_prior_bottom_line(_, version)
  -- Bank 542 message 18 carries a real 0x25BD page break on a two-line page;
  -- the ROM token -> layout -> controller path must scroll one line and
  -- retain the prior bottom line instead of clearing the page.
  local def = fontDef(version)
  local cache = CacheFs.forVersion(version)
  local provider = assert(FieldMessageProvider.new(cache))
  assert(provider:acquireBank(542), "message bank cache is cold")
  local template = assert(provider:get(542, 18))
  local formatted = provider:format(template, { playerName = "GOLD" }, {
    [0x0103] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
  })
  local metrics = FieldDialogueTheme.fontMetrics(def)
  local laid = DialogueLayout.layout(
    formatted.tokens,
    metrics,
    { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
  )
  Assert.equal(#laid.pages, 2, "the page-break fixture lays out to two pages")
  Assert.equal(laid.pages[1].breakKind, "page", "the fixture first boundary is a real 0x25BD page break")
  Assert.equal(#laid.pages[1].lines, 2, "the page-break fixture first page carries two lines")

  local function glyphCodes(line)
    local tokens = line.tokens or line
    local codes = {}
    for _, token in ipairs(tokens) do
      if token.kind == "glyph" then
        codes[#codes + 1] = token.code
      end
    end
    return codes
  end

  local expectedBottom = glyphCodes(laid.pages[1].lines[2])
  Assert.isTrue(#expectedBottom > 0, "the fixture bottom line carries glyphs")

  local layout = function(message)
    return DialogueLayout.layout(
      message.tokens,
      metrics,
      { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
    )
  end
  local controller = FieldDialogueController.new({
    layout = layout,
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
  })
  controller:open({
    id = "page-break-retention-542-18",
    message = formatted,
    allowCancel = false,
    metadata = { bankId = 542, messageId = 18 },
  })
  local guard = 0
  while controller:status().state == "OPENING" or controller:status().state == "REVEALING" do
    controller:step({})
    guard = guard + 1
    Assert.isTrue(guard < 500, "the page-break fixture reveals promptly")
  end
  local waiting = controller:status()
  Assert.equal(waiting.state, "WAITING_BOUNDARY")
  Assert.equal(waiting.pageIndex, 1)
  Assert.equal(waiting.continuationKind, "scroll")

  controller:step({ actionPressed = true })
  local entered = controller:status()
  Assert.equal(entered.state, "SCROLLING")
  Assert.equal(entered.pageIndex, 1, "page advances only after the scroll finishes")
  Assert.equal(
    entered.scrollRemaining,
    entered.lineHeight + entered.lineSpacing,
    "a confirmed page break scrolls exactly one line"
  )

  guard = 0
  while controller:status().state == "SCROLLING" do
    Assert.equal(controller:status().pageIndex, 1, "page advances only after the scroll finishes")
    controller:step({})
    guard = guard + 1
    Assert.isTrue(guard < 10, "one-line scroll finishes on cadence")
  end
  local settled = controller:status()
  Assert.equal(settled.state, "REVEALING")
  Assert.equal(settled.pageIndex, 2)
  Assert.equal(settled.revealedGlyphs, 0, "next page starts unrevealed")
  Assert.equal(#settled.visibleLines, 1, "retained bottom line is the new top line")
  Assert.deepEqual(glyphCodes(settled.visibleLines[1]), expectedBottom, "the prior bottom line is retained")

  guard = 0
  while controller:status().state == "REVEALING" do
    controller:step({})
    guard = guard + 1
    Assert.isTrue(guard < 500, "next page reveals promptly")
  end
  local revealed = controller:status()
  Assert.isTrue(revealed.waiting, "scrolled page reveals to its wait")
  Assert.equal(revealed.state, "WAITING_BOUNDARY", "the trailing prompt boundary waits as a boundary")
  Assert.equal(revealed.continuationKind, "clear", "the trailing prompt boundary keeps its clear kind")
  Assert.equal(#revealed.visibleLines, 2, "settled window shows two lines")
  Assert.deepEqual(glyphCodes(revealed.visibleLines[1]), expectedBottom, "settled top line is the retained line")
  controller:step({ actionPressed = true })
  Assert.equal(
    controller:status().state,
    "CLOSING",
    "one confirmation executes the trailing clear and finishes without a second wait"
  )
  controller:step({})
  Assert.equal(controller:status().state, "CLOSED", "trailing clear finishes the message")
  provider:releaseBank(542)
end

function T.target_lines_stay_inside_the_reference_text_width(_, version)
  local def = fontDef(version)
  local cache = CacheFs.forVersion(version)
  local provider = assert(FieldMessageProvider.new(cache))
  local metrics = FieldDialogueTheme.fontMetrics(def)
  local widths = {}
  assert(provider:acquireBank(543))
  for messageId = 0, 105 do
    local template = assert(provider:get(543, messageId))
    local formatted = provider:format(template, { playerName = "GOLD" }, {
      [0x0103] = function()
        return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
      end,
    })
    local layout = DialogueLayout.layout(
      formatted.tokens,
      metrics,
      { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
    )
    local warnedWidths = {}
    for _, warning in ipairs(layout.warnings) do
      if warning.kind == "overwide" then
        warnedWidths[warning.width] = true
      end
    end
    for _, page in ipairs(layout.pages) do
      for _, line in ipairs(page.lines) do
        widths[#widths + 1] = line.width
        -- Only glyph advance contributes to line width, and every over-wide
        -- line is traced as an overwide warning.
        Assert.isTrue(
          line.width <= FieldDialogueTheme.textWidth or warnedWidths[line.width] == true,
          string.format("bank 543 message %d line %d exceeds the text width untraced", messageId, line.width)
        )
      end
    end
  end
  Assert.isTrue(#widths > 100, "every bank 543 message lays out")
  provider:releaseBank(543)
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
