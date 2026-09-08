-- Headless dialogue controller tests:
-- printer reveal, Action advance/close semantics, cancel policy, auto-scroll
-- pages, exactly-once completion, error unwind, and the source cursor phase.
-- Layout and input are injected, so the whole lifecycle runs without LÖVE.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")

local T = {}

---@class FieldDialogueControllerTest.Message : FieldMessageProvider.FormattedMessage
---@field _pages table[]
---@class FieldDialogueControllerTest.Request : FieldDialogueController.Request

local function glyph(text, code)
  return { kind = "glyph", code = code, text = text, raw = { code } }
end

local function page(lines, breakKind)
  return { lines = lines, breakKind = breakKind }
end

local function line(tokens)
  return { tokens = tokens, width = 0 }
end

local CURSOR =
  { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9, placement = { x = 240, y = 168, width = 16, height = 16 } }

-- Controller whose layout returns the caller's precomputed pages verbatim.
local function controller(pages, opts)
  opts = opts or {}
  return FieldDialogueController.new({
    layout = function()
      return { pages = pages, warnings = opts.warnings or {}, lineHeight = 16, lineSpacing = 0 }
    end,
    policy = {
      interGlyphDelay = (opts.printerDelay or 2) - 1,
      glyphBudget = 1,
      abAcceleration = true,
    },
    audio = opts.audio,
    continueCursor = opts.continueCursor or CURSOR,
  })
end

local function message(pages)
  local value = {
    bankId = 543,
    messageId = 5,
    text = "",
    tokens = { glyph("A", 0x0121), glyph("B", 0x0122) },
    hadUnresolvedSubstitutions = false,
    _pages = pages,
  } --[[@as FieldDialogueControllerTest.Message]]
  return value
end

local function request(id, formattedMessage, allowCancel)
  local value = {
    id = id,
    message = formattedMessage,
    allowCancel = allowCancel == true,
  } --[[@as FieldDialogueControllerTest.Request]]
  return value
end

local function glyphCount(status)
  return status.revealedGlyphs
end

function T.printer_delays_run_at_two_substeps_per_field_tick()
  local function revealAfter(delay, fieldTicks)
    local c = controller({ page({ line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }) }, "eos") }, {
      printerDelay = delay,
    })
    c:open(request("delay-" .. delay, message()))
    c:step({})
    for _ = 1, fieldTicks do
      c:step({})
    end
    return glyphCount(c:status())
  end

  local fast = revealAfter(1, 1)
  Assert.equal(fast, 3, "opening and one field tick run two printer substeps each")
  Assert.equal(revealAfter(4, 1), 1, "mid text advances on its fourth printer update")
  Assert.equal(revealAfter(4, 2), 2, "mid text advances on the fifth printer update")
  Assert.equal(revealAfter(8, 4), 2, "slow text advances on the ninth printer update")
end

function T.action_and_cancel_speed_up_progressively_and_play_select_once()
  local played = {}
  local audio = {
    play = function(_, soundRef)
      played[#played + 1] = soundRef
    end,
  }
  local c = controller({
    page({ line({ glyph("A", 1), glyph("B", 2), glyph("C", 3), glyph("D", 4), glyph("E", 5) }) }, "clear"),
    page({ line({ glyph("F", 6) }) }, "eos"),
  }, { printerDelay = 8, audio = audio })
  c:open(request("progressive", message(), false))
  c:step({})
  c:step({ actionPressed = true, actionDown = true })
  Assert.isTrue(c:status().revealedGlyphs < 5, "a fresh A press never reveals the whole page")
  Assert.isTrue(c:status().revealedGlyphs <= 2, "one field tick has at most two printer progress units")
  c:step({ cancelPressed = true, cancelDown = true })
  Assert.isTrue(c:status().revealedGlyphs < 5, "B maps to source speed-up without instant reveal")
  for _ = 1, 20 do
    if c:status().state == "WAITING_BOUNDARY" then
      break
    end
    c:step({ actionDown = true })
  end
  Assert.equal(c:status().state, "WAITING_BOUNDARY", "clear continuation must expose a boundary wait")
  c:step({ actionDown = true })
  Assert.equal(c:status().state, "WAITING_BOUNDARY", "held input alone does not continue")
  c:step({ cancelPressed = true })
  Assert.equal(c:status().pageIndex, 2)
  Assert.equal(#played, 1)
  Assert.equal(played[1], "SEQ_SE_DP_SELECT")
end

function T.fresh_speed_up_edge_does_not_reveal_in_the_same_field_tick()
  local c = controller({ page({ line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }) }, "eos") }, {
    printerDelay = 8,
  })
  c:open(request("fresh-edge", message()))
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 1)
  c:step({ actionPressed = true, actionDown = true })
  Assert.equal(c:status().revealedGlyphs, 1, "the fresh acceleration edge consumes this field tick")
  c:step({ actionDown = true })
  Assert.equal(c:status().revealedGlyphs, 3, "the held accelerated input applies on the next field tick")
end

function T.pause_blocks_while_callback_signal_consumes_one_printer_update()
  local function make(control, argument)
    return controller({
      page({
        line({
          glyph("A", 1),
          { kind = control, control = control == "pause" and 0x0201 or 0x0202, args = { argument }, raw = {} },
          glyph("B", 2),
        }),
      }, "eos"),
    }, { printerDelay = 1 })
  end
  local pause = make("pause", 2)
  pause:open(request("pause", message()))
  pause:step({})
  pause:step({})
  Assert.equal(pause:status().revealedGlyphs, 1)
  pause:step({})
  Assert.equal(pause:status().revealedGlyphs, 2, "pause resumes after its source countdown")
  local callback = make("printer_callback", 2)
  callback:open(request("callback", message()))
  callback:step({})
  callback:step({})
  Assert.equal(callback:status().revealedGlyphs, 2, "callback signal is not a normal timed wait")
end

function T.fixed_ticks_reveal_expected_glyph_count()
  local c = controller({ page({ line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }) }, "eos") })
  c:open(request("t", message()))
  Assert.equal(c:status().state, "OPENING")
  c:step({})
  Assert.equal(c:status().state, "REVEALING")
  Assert.equal(c:status().revealedGlyphs, 1)
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 2)
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 3)
  Assert.equal(c:status().state, "WAITING_CLOSE")
  c:step({})
  Assert.equal(c:status().state, "WAITING_CLOSE")
end

function T.fastest_reveals_consecutive_source_glyphs_without_skipping()
  local tokens = { glyph("A", 1), glyph("B", 2), glyph("C", 3) }
  local c = FieldDialogueController.new({
    layout = function()
      return { pages = { page({ line(tokens) }, "eos") }, warnings = {}, lineHeight = 16, lineSpacing = 0 }
    end,
    policy = TextSpeedPolicy.forSpeed("fastest"),
    continueCursor = CURSOR,
  })
  c:open(request("fastest", message()))
  c:step({})
  local visible = c:status().visibleLines[1]
  Assert.equal(visible[1].code, 1)
  Assert.equal(visible[2].code, 2)
end

function T.default_policy_is_fastest()
  local tokens = { glyph("A", 1), glyph("B", 2), glyph("C", 3) }
  local c = FieldDialogueController.new({
    layout = function()
      return { pages = { page({ line(tokens) }, "eos") }, warnings = {}, lineHeight = 16, lineSpacing = 0 }
    end,
    continueCursor = CURSOR,
  })
  c:open(request("default-fastest", message()))
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 3)
end

-- The player-selected HGSS user-frame index travels on the open request and
-- stays on the presentation status for the whole open lifetime; closing
-- clears it. The request may omit it (hosts without player options), in
-- which case status exposes nil rather than inventing a frame.
function T.request_frame_index_is_carried_on_status_and_cleared_on_close()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local req = request("t", message())
  req.frameIndex = 3
  c:open(req)
  Assert.equal(c:status().frameIndex, 3, "open status carries the request frame index")
  c:step({})
  c:step({})
  Assert.equal(c:status().frameIndex, 3, "frame index survives the reveal lifecycle")
  c:close()
  Assert.isNil(c:status().frameIndex, "closed status clears the frame")
end

-- A request without a frame index still opens: the frame is an option-carrying
-- host's concern, not a requirement of the dialogue contract itself.
function T.request_without_a_frame_index_still_opens()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  c:open(request("t", message()))
  Assert.equal(c:status().state, "OPENING")
  Assert.isNil(c:status().frameIndex)
end

-- A malformed frame index is a programming fault at the request boundary.
function T.rejects_a_malformed_frame_index()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  for _, bad in ipairs({ -1, 0.5, "3", true }) do
    local req = request("t", message())
    req.frameIndex = bad
    Assert.throws(function()
      c:open(req)
    end, "frame index " .. tostring(bad) .. " must be rejected")
  end
end

-- The reveal cadence is injected, not a renderer constant: the runtime wires
-- the player's selected text speed into construction (ticksPerGlyph), so an
-- open request reveals at the captured cadence without ever querying options.
function T.injected_printer_delay_drives_reveal_cadence()
  local c = controller({ page({ line({ glyph("A", 1), glyph("B", 2) }) }, "eos") }, { printerDelay = 3 })
  c:open(request("t", message()))
  c:step({})
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 2, "two printer updates reveal the second glyph")
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 2, "the second glyph remains visible")
  c:step({})
  c:step({})
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 2)
end

function T.action_during_reveal_is_progressive()
  local c = controller({
    page({ line({ glyph("A", 1), glyph("B", 2), glyph("C", 3), glyph("D", 4), glyph("E", 5) }) }, "prompt"),
    page({ line({ glyph("F", 6) }) }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  c:step({ actionPressed = true, actionDown = true })
  Assert.equal(c:status().state, "REVEALING")
  Assert.isTrue(c:status().revealedGlyphs > 0)
  Assert.isTrue(c:status().revealedGlyphs < 5)
end

function T.held_action_does_not_skip_multiple_pages()
  local c = controller({
    page({ line({ glyph("A", 1) }) }, "prompt"),
    page({ line({ glyph("B", 2), glyph("C", 3), glyph("D", 4) }) }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  c:step({ actionPressed = true }) -- skip page 1 reveal
  c:step({ actionPressed = true }) -- advance to page 2
  Assert.equal(c:status().pageIndex, 2)
  -- Held Action alone must not skip the second page: only reveal ticks count.
  for _ = 1, 6 do
    c:step({ actionDown = true })
  end
  Assert.equal(c:status().pageIndex, 2)
  Assert.equal(c:status().state, "WAITING_CLOSE")
  c:step({ actionDown = true })
  Assert.equal(c:status().state, "WAITING_CLOSE")
end

function T.final_action_closes_and_completes_exactly_once()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local completed = 0
  local result
  local handle = c:open(request("t", message()))
  handle:onComplete(function(r)
    completed = completed + 1
    result = r
  end)
  c:step({})
  c:step({ actionPressed = true }) -- the edge closes the reached wait
  Assert.equal(c:status().state, "CLOSING")
  c:step({}) -- CLOSING -> CLOSED, dispatch
  Assert.equal(c:status().state, "CLOSED")
  Assert.equal(completed, 1)
  Assert.equal(result.kind, "complete")
  Assert.equal(result.bankId, 543)
  Assert.equal(result.messageId, 5)
  Assert.equal(result.requestId, "t")
  c:step({ actionPressed = true })
  Assert.equal(completed, 1, "no second completion")
end

function T.open_consumes_the_initiating_edge()
  local c = controller({
    page({ line({ glyph("A", 1), glyph("B", 2) }) }, "prompt"),
    page({ line({ glyph("C", 3) }) }, "eos"),
  })
  -- The opener consumes the edge that opened the dialogue; the first step
  -- carries only held state, so nothing is skipped or advanced.
  local _ = c:open(request("t", message()))
  c:step({ actionDown = true })
  Assert.equal(c:status().revealedGlyphs, 1)
  Assert.equal(c:status().state, "REVEALING")
  c:step({ actionDown = true })
  Assert.equal(c:status().state, "WAITING_BOUNDARY")
  c:step({ actionPressed = true })
  Assert.equal(c:status().pageIndex, 2)
end

function T.status_exposes_the_open_message_identity()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  c:open(request("semantic-message", message()))
  local status = c:status()
  Assert.equal(status.requestId, "semantic-message")
  Assert.equal(status.bankId, 543)
  Assert.equal(status.messageId, 5)
end

-- An automatic page boundary rolls the two-line window: after [A, B] the
-- printer scrolls one line without Action and reveals the next line under
-- the retained bottom line, so the settled window reads [B, C].
function T.automatic_boundary_rolls_the_two_line_window()
  for _, breakKind in ipairs({ "line", "overflow" }) do
    local played = {}
    local c = controller({
      page({ line({ glyph("A", 1) }), line({ glyph("B", 2) }) }, breakKind),
      page({ line({ glyph("C", 3) }) }, "eos"),
    }, {
      audio = {
        play = function(_, soundRef)
          played[#played + 1] = soundRef
        end,
      },
    })
    c:open(request("t-" .. breakKind, message()))
    c:step({})
    local guard = 0
    while c:status().state == "OPENING" or (c:status().state == "REVEALING" and c:status().pageIndex == 1) do
      c:step({})
      guard = guard + 1
      Assert.isTrue(guard < 20, breakKind .. ": first page reveals promptly")
    end
    local entered = c:status()
    Assert.equal(entered.state, "SCROLLING", breakKind .. ": automatic boundary scrolls without Action")
    Assert.equal(entered.pageIndex, 1, breakKind .. ": page advances only after the scroll finishes")
    Assert.equal(entered.scrollRemaining, 16, breakKind .. ": automatic scroll travels one line")
    Assert.equal(#entered.scrollLines, 2, breakKind .. ": the moving window carries both old lines")
    Assert.equal(entered.revealedGlyphs, 0, breakKind .. ": no next-page glyph reveals while scrolling")
    Assert.isFalse(entered.waiting, breakKind .. ": automatic scroll does not wait")
    local scrolled = 0
    while c:status().state == "SCROLLING" do
      Assert.equal(c:status().pageIndex, 1, breakKind .. ": page advances only after the scroll finishes")
      Assert.equal(c:status().revealedGlyphs, 0, breakKind .. ": no next-page glyph reveals while scrolling")
      c:step({})
      scrolled = scrolled + 1
      Assert.isTrue(scrolled <= 4, breakKind .. ": one-line scroll finishes on cadence")
    end
    Assert.equal(scrolled, 2, breakKind .. ": one line scrolls in two field ticks")
    local settled = c:status()
    Assert.equal(settled.state, "REVEALING", breakKind .. ": scroll completion opens the next page reveal")
    Assert.equal(settled.pageIndex, 2, breakKind .. ": scroll completion advances the page")
    Assert.equal(settled.revealedGlyphs, 0, breakKind .. ": next page starts unrevealed")
    Assert.equal(#settled.visibleLines, 1, breakKind .. ": retained bottom line is the new top line")
    Assert.equal(
      (settled.visibleLines[1].tokens or settled.visibleLines[1])[1].text,
      "B",
      breakKind .. ": prior bottom line is retained"
    )
    guard = 0
    while c:status().state == "REVEALING" do
      c:step({})
      guard = guard + 1
      Assert.isTrue(guard < 20, breakKind .. ": next line reveals promptly")
    end
    local revealed = c:status()
    Assert.equal(revealed.state, "WAITING_CLOSE", breakKind .. ": rolled page reveals to its close")
    Assert.equal(#revealed.visibleLines, 2, breakKind .. ": settled window shows two lines")
    Assert.equal(
      (revealed.visibleLines[1].tokens or revealed.visibleLines[1])[1].text,
      "B",
      breakKind .. ": settled top line is the retained line"
    )
    Assert.equal(
      (revealed.visibleLines[2].tokens or revealed.visibleLines[2])[1].text,
      "C",
      breakKind .. ": settled bottom line is the new line"
    )
    Assert.equal(#played, 0, breakKind .. ": automatic transition plays no select sound")
  end
end

-- A page break scrolls one line after confirmation: [A, B] retains B while
-- the next source tokens print into the newly exposed bottom line, so the
-- settled window reads [B, C].
function T.page_break_scrolls_and_retains_the_prior_bottom_line()
  local c = controller({
    page({ line({ glyph("A", 1) }), line({ glyph("B", 2) }) }, "page"),
    page({ line({ glyph("C", 3) }) }, "eos"),
  })
  c:open(request("page", message()))
  while c:status().state == "REVEALING" or c:status().state == "OPENING" do
    c:step({})
  end
  local waiting = c:status()
  Assert.equal(waiting.state, "WAITING_BOUNDARY")
  Assert.equal(#waiting.visibleLines, 2, "both page lines are visible at the boundary")
  Assert.equal(waiting.continuationKind, "scroll", "a page break reports a scroll continuation")

  c:step({ actionPressed = true })
  local entered = c:status()
  Assert.equal(entered.state, "SCROLLING", "a confirmed page break enters the scroll state")
  Assert.equal(entered.pageIndex, 1, "page advances only after the scroll finishes")
  Assert.equal(entered.scrollRemaining, 16, "a page scroll travels one configured line")
  Assert.equal(#entered.scrollLines, 2, "the moving window carries both old lines")
  Assert.equal(entered.revealedGlyphs, 0, "no next-page glyph reveals while scrolling")

  local scrolled = 0
  while c:status().state == "SCROLLING" do
    Assert.equal(c:status().pageIndex, 1, "page advances only after the scroll finishes")
    Assert.equal(c:status().revealedGlyphs, 0, "no next-page glyph reveals while scrolling")
    c:step({})
    scrolled = scrolled + 1
    Assert.isTrue(scrolled <= 4, "one-line scroll finishes on cadence")
  end
  Assert.equal(scrolled, 2, "one line scrolls in two field ticks")
  local settled = c:status()
  Assert.equal(settled.state, "REVEALING", "scroll completion opens the next page reveal")
  Assert.equal(settled.pageIndex, 2, "scroll completion advances the page")
  Assert.equal(settled.revealedGlyphs, 0, "next page starts unrevealed")
  Assert.equal(#settled.visibleLines, 1, "retained bottom line is the new top line")
  Assert.equal(
    (settled.visibleLines[1].tokens or settled.visibleLines[1])[1].text,
    "B",
    "prior bottom line is retained"
  )

  local guard = 0
  while c:status().state == "REVEALING" do
    c:step({})
    guard = guard + 1
    Assert.isTrue(guard < 20, "next line reveals promptly")
  end
  local revealed = c:status()
  Assert.equal(revealed.state, "WAITING_CLOSE", "scrolled page reveals to its close")
  Assert.equal(#revealed.visibleLines, 2, "settled window shows two lines")
  Assert.equal(
    (revealed.visibleLines[1].tokens or revealed.visibleLines[1])[1].text,
    "B",
    "settled top line is the retained line"
  )
  Assert.equal(
    (revealed.visibleLines[2].tokens or revealed.visibleLines[2])[1].text,
    "C",
    "settled bottom line is the new line"
  )
end

-- A final page break still executes its retail scroll: the 3-line window
-- [A, B] scrolls to [B, C], and confirming [B, C] scrolls once more before
-- finishing automatically because EOS follows, without a second confirmation.
function T.final_page_break_closes_from_its_revealed_window()
  local completed = 0
  local c = controller({
    page({ line({ glyph("A", 1) }), line({ glyph("B", 2) }) }, "line"),
    page({ line({ glyph("C", 3) }) }, "page"),
  })
  local handle = c:open(request("final-page", message()))
  handle:onComplete(function()
    completed = completed + 1
  end)
  local guard = 0
  while c:status().state == "OPENING" or c:status().state == "REVEALING" or c:status().state == "SCROLLING" do
    c:step({})
    guard = guard + 1
    Assert.isTrue(guard < 40, "both windows reveal promptly")
  end
  local waiting = c:status()
  Assert.equal(waiting.state, "WAITING_BOUNDARY", "a final page boundary waits as a boundary")
  Assert.equal(waiting.pageIndex, 2)
  Assert.equal(waiting.continuationKind, "scroll", "a final page break keeps its scroll kind")
  Assert.equal(waiting.scrollRemaining, 0, "no scroll distance is travelled before confirmation")
  Assert.equal(waiting.revealedGlyphs, 1, "the revealed window is preserved, not zeroed")
  Assert.equal(#waiting.visibleLines, 2, "the boundary wait keeps both settled lines")
  Assert.equal((waiting.visibleLines[1].tokens or waiting.visibleLines[1])[1].text, "B")
  Assert.equal((waiting.visibleLines[2].tokens or waiting.visibleLines[2])[1].text, "C")

  c:step({ actionPressed = true })
  Assert.equal(c:status().state, "SCROLLING", "one confirmation executes the final scroll effect")
  Assert.equal(c:status().pageIndex, 2, "final scroll does not advance to another page")
  guard = 0
  while c:status().state == "SCROLLING" do
    c:step({})
    guard = guard + 1
    Assert.isTrue(guard < 10, "final scroll finishes on cadence")
  end
  Assert.equal(c:status().state, "CLOSING", "EOS follows the final scroll, so no second confirmation is needed")
  c:step({})
  Assert.equal(c:status().state, "CLOSED")
  Assert.equal(completed, 1, "the message completes exactly once")
end

-- A trailing prompt break is a clear boundary on the final page: the full
-- window waits as a boundary and a single confirmation executes the clear
-- effect before finishing automatically, instead of re-showing the window.
function T.final_prompt_boundary_closes_without_repeating_its_window()
  local completed = 0
  local c = controller({
    page({ line({ glyph("A", 1) }), line({ glyph("B", 2) }) }, "prompt"),
  })
  local handle = c:open(request("final-prompt", message()))
  handle:onComplete(function()
    completed = completed + 1
  end)
  local guard = 0
  while not c:status().waiting do
    c:step({})
    guard = guard + 1
    Assert.isTrue(guard < 20, "the final window reveals promptly")
  end
  local waiting = c:status()
  Assert.equal(waiting.state, "WAITING_BOUNDARY", "a final prompt boundary waits as a boundary")
  Assert.equal(waiting.continuationKind, "clear", "a final prompt break keeps its clear kind")
  Assert.equal(#waiting.visibleLines, 2, "the boundary wait keeps the full window")
  Assert.equal((waiting.visibleLines[1].tokens or waiting.visibleLines[1])[1].text, "A")
  Assert.equal((waiting.visibleLines[2].tokens or waiting.visibleLines[2])[1].text, "B")

  c:step({ actionPressed = true })
  Assert.equal(c:status().state, "CLOSING", "one confirmation executes the clear and finishes")
  c:step({})
  Assert.equal(c:status().state, "CLOSED")
  Assert.equal(completed, 1, "the message completes exactly once")
end

-- A trailing automatic boundary on the final page likewise has nothing to
-- scroll into: the fully revealed window waits for close directly.
function T.final_automatic_boundary_closes_without_scrolling()
  local c = controller({
    page({ line({ glyph("A", 1) }), line({ glyph("B", 2) }) }, "line"),
  })
  c:open(request("final-line", message()))
  local guard = 0
  while c:status().state == "OPENING" or c:status().state == "REVEALING" do
    c:step({})
    Assert.isFalse(c:status().state == "SCROLLING", "a final automatic boundary must not scroll")
    guard = guard + 1
    Assert.isTrue(guard < 20, "the final window reveals promptly")
  end
  local waiting = c:status()
  Assert.equal(waiting.state, "WAITING_CLOSE")
  Assert.equal(waiting.scrollRemaining, 0)
  Assert.equal(#waiting.visibleLines, 2, "the close wait keeps both revealed lines")
  Assert.equal((waiting.visibleLines[1].tokens or waiting.visibleLines[1])[1].text, "A")
  Assert.equal((waiting.visibleLines[2].tokens or waiting.visibleLines[2])[1].text, "B")
end

-- A scroll continuation retains the old bottom line while the next source
-- tokens print into the newly exposed bottom line.
function T.scroll_break_retains_the_prior_bottom_line()
  local c = controller({
    page({ line({ glyph("A", 1) }), line({ glyph("B", 2) }) }, "scroll"),
    page({ line({ glyph("C", 3) }) }, "eos"),
  })
  c:open(request("scroll", message()))
  while c:status().state == "REVEALING" or c:status().state == "OPENING" do
    c:step({})
  end
  Assert.equal(c:status().state, "WAITING_BOUNDARY")
  c:step({ actionPressed = true })
  local status = c:status()
  Assert.equal(status.state, "SCROLLING", "a scroll break enters an explicit scroll state")
  Assert.equal(status.visibleLines[1].tokens[1].text, "B", "the prior bottom line becomes the new top line")
  Assert.equal(status.visibleLines[2], nil, "subsequent text starts on the bottom line")
end

-- Source scroll distance is one line and advances by four logical pixels per
-- fixed printer update, with a final partial step when needed.
function T.scroll_break_moves_exactly_one_line_in_fixed_increments()
  local c = FieldDialogueController.new({
    layout = function()
      return {
        pages = {
          {
            lines = { line({ glyph("A", 1) }), line({ glyph("B", 2) }) },
            breakKind = "scroll",
          },
          { lines = { line({ glyph("C", 3) }) }, breakKind = "eos" },
        },
        lineHeight = 17,
        lineSpacing = 2,
        warnings = {},
      }
    end,
    policy = TextSpeedPolicy.forSpeed("fast"),
    continueCursor = CURSOR,
  })
  c:open(request("scroll-distance", message()))
  while c:status().state == "REVEALING" or c:status().state == "OPENING" do
    c:step({})
  end
  c:step({ actionPressed = true })
  Assert.equal(c:status().scrollRemaining, 19)
  Assert.equal(c:status().scrollOffsetY, 0)
  local offsets = {}
  for _ = 1, 3 do
    c:step({})
    local status = c:status()
    offsets[#offsets + 1] = status.scrollOffsetY
    Assert.equal(status.revealedGlyphs, 0, "no new glyph is revealed during scrolling")
  end
  Assert.deepEqual(offsets, { 8, 16, 19 })
  Assert.equal(c:status().scrollRemaining, 0)
end

-- Prompt continuation clears both retained lines and resumes at the window
-- origin; it does not enter the one-line scroll state.
function T.prompt_break_clears_instead_of_scrolling()
  local c = controller({
    page({ line({ glyph("A", 1) }), line({ glyph("B", 2) }) }, "prompt"),
    page({ line({ glyph("C", 3) }) }, "eos"),
  })
  c:open(request("prompt", message()))
  while c:status().state == "REVEALING" or c:status().state == "OPENING" do
    c:step({})
  end
  Assert.equal(c:status().state, "WAITING_BOUNDARY")
  c:step({ actionPressed = true })
  local status = c:status()
  Assert.equal(status.state, "REVEALING")
  Assert.equal(status.scrollRemaining, 0)
  Assert.equal(status.scrollOffsetY, 0)
  Assert.equal(status.visibleLines[1], nil, "clear removes the old top line before the next glyph")
  Assert.equal(status.visibleLines[2], nil, "clear removes the old bottom line")
end

function T.zero_glyph_pages_reach_boundary_without_ticks()
  local c = controller({
    page({ line({ { kind = "style", control = 0xFF00, name = "COLOR", args = { 1 } } }) }, "prompt"),
    page({ line({ glyph("A", 1) }) }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  Assert.equal(c:status().state, "WAITING_BOUNDARY", "zero-glyph page waits immediately")
end

function T.empty_message_closes_safely_on_open()
  local c = controller({})
  local completed = 0
  local handle = c:open(request("t", message()))
  handle:onComplete(function()
    completed = completed + 1
  end)
  Assert.isTrue(c:isModal(), "modal ownership engages so the session drives close")
  c:step({})
  Assert.equal(completed, 1, "empty message completes on its first step")
  Assert.isFalse(c:isModal())
  Assert.equal(c:status().state, "CLOSED")
  c:step({})
  Assert.equal(completed, 1, "no second completion")
end

function T.malformed_message_fires_error_once_and_stays_closed()
  local c = FieldDialogueController.new({
    layout = function()
      error(Errors.new("FONT_GLYPH_MISSING", "fixture layout failure", { code = 0x9999 }))
    end,
    continueCursor = CURSOR,
  })
  local errors = 0
  local handle = c:open(request("t", message()))
  handle:onError(function(result)
    errors = errors + 1
    Assert.equal(result.kind, "error")
    Assert.notNil(result.error)
  end)
  Assert.isTrue(c:isModal(), "modal engages for one tick so the session drives the error")
  c:step({})
  Assert.equal(errors, 1)
  Assert.isFalse(c:isModal(), "the error releases modal ownership")
  c:step({})
  Assert.equal(errors, 1, "no second error dispatch")
  -- A subsequent valid open works.
  local c2 = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local done = false
  local h2 = c2:open(request("t2", message()))
  h2:onComplete(function()
    done = true
  end)
  c2:step({})
  c2:step({ actionPressed = true })
  c2:step({ actionPressed = true })
  c2:step({})
  Assert.isTrue(done, "second dialogue completes")
end

function T.cancel_ignored_unless_allow_cancel()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  c:open(request("t", message()))
  c:step({ cancelPressed = true })
  Assert.isTrue(c:isModal(), "cancel is ignored by default")

  local c2 = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local cancelled = 0
  local result
  local handle = c2:open(request("t", message(), true))
  handle:onCancel(function(r)
    cancelled = cancelled + 1
    result = r
  end)
  c2:step({ cancelPressed = true })
  Assert.equal(cancelled, 1)
  Assert.equal(result.kind, "cancel")
  Assert.isFalse(c2:isModal())
  c2:step({ cancelPressed = true })
  Assert.equal(cancelled, 1, "cancel fires exactly once")
end

function T.close_is_idempotent_and_dispose_cancels()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local completed = 0
  local handle = c:open(request("t", message()))
  handle:onComplete(function()
    completed = completed + 1
  end)
  local result = assert(c:close())
  Assert.equal(result.kind, "complete")
  Assert.equal(completed, 1)
  Assert.isNil(c:close(), "second close is a no-op")
  Assert.equal(completed, 1)

  local c2 = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local cancelled = 0
  local h2 = c2:open(request("t", message()))
  h2:onCancel(function()
    cancelled = cancelled + 1
  end)
  Assert.notNil(c2:dispose())
  Assert.equal(cancelled, 1)
  Assert.isNil(c2:dispose(), "second dispose is a no-op")
  Assert.equal(cancelled, 1)
end

function T.callback_can_queue_a_next_dialogue_but_not_step_it()
  local c = controller({
    page({ line({ glyph("A", 1) }) }, "eos"),
    page({ line({ glyph("B", 1) }) }, "eos"),
  })
  local second = false
  local handle = c:open(request("first", message()))
  handle:onComplete(function()
    local h2 = c:open(request("second", message()))
    h2:onComplete(function()
      second = true
    end)
    Assert.equal(c:status().state, "OPENING")
  end)
  c:step({ actionPressed = true }) -- to CLOSING
  c:step({ actionPressed = true }) -- close the reached wait
  c:step({}) -- dispatch: callback opens the second dialogue
  Assert.equal(c:status().state, "OPENING")
  Assert.isTrue(c:isModal(), "second dialogue owns input immediately")
  c:step({})
  c:step({ actionPressed = true })
  c:step({ actionPressed = true })
  c:step({})
  Assert.isTrue(second, "second dialogue completes on later ticks")
end

function T.cursor_phase_is_source_animated()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "prompt") })
  c:open(request("t", message()))
  for _ = 1, 10 do
    if c:status().waiting then
      break
    end
    c:step({})
  end
  -- A single-page prompt message waits as a boundary on its revealed window;
  -- the cursor contract is identical at either wait.
  Assert.equal(c:status().state, "WAITING_BOUNDARY")
  Assert.equal(c:status().cursorPhase, 0, "new wait starts at phase 0")
  local cycle = { 0, 1, 2, 1 }
  for tick = 1, 36 do
    c:step({})
    local expected = cycle[math.floor(tick / 9) % #cycle + 1]
    if tick == 8 then
      Assert.equal(c:status().cursorPhase, 0, "tick 8 stays at phase 0")
    elseif tick == 9 then
      Assert.equal(c:status().cursorPhase, 1, "tick 9 advances to phase 1")
    elseif tick == 18 then
      Assert.equal(c:status().cursorPhase, 2, "tick 18 advances to phase 2")
    elseif tick == 27 then
      Assert.equal(c:status().cursorPhase, 1, "tick 27 advances to phase 1")
    elseif tick == 36 then
      Assert.equal(c:status().cursorPhase, 0, "tick 36 cycles back to 0")
    end
    Assert.equal(c:status().cursorPhase, expected, "phase at tick " .. tick .. " must match cycle")
  end
end

-- The terminal close releases the request, handle, and page state, so
-- the presentation-facing status after completion carries no stale message
-- identity for the renderer to keep showing; the next open starts fresh.
function T.terminal_close_clears_request_handle_and_page_state()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  c:open(request("t", message()))
  local result = assert(c:close())
  Assert.equal(result.kind, "complete")
  local status = c:status()
  Assert.equal(status.state, "CLOSED")
  Assert.isNil(status.requestId)
  Assert.isNil(status.bankId)
  Assert.isNil(status.messageId)
  Assert.equal(status.pageCount, 0)
end

function T.open_while_modal_raises()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  c:open(request("t", message()))
  local err = Assert.throws(function()
    c:open(request("t2", message()))
  end)
  Assert.isTrue(Errors.is(err) and err.code == "DIALOGUE_ALREADY_OPEN", "raises DIALOGUE_ALREADY_OPEN")
  c:close()
  local h2 = c:open(request("t2", message()))
  Assert.notNil(h2)
end

function T.status_exposes_visible_lines_up_to_the_reveal()
  local c = controller({
    page({
      line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }),
      line({ glyph("D", 4), glyph("E", 5) }),
    }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  Assert.equal(#c:status().visibleLines, 1)
  Assert.equal(#c:status().visibleLines[1], 1, "first line shows the first glyph")
  c:step({})
  Assert.equal(#c:status().visibleLines[1], 2)
  c:step({})
  Assert.equal(#c:status().visibleLines[1], 3)
  c:step({})
  Assert.equal(#c:status().visibleLines, 2, "second line starts after the first fills")
  Assert.equal(#c:status().visibleLines[2], 1)
  c:step({})
  Assert.equal(#c:status().visibleLines[2], 2)
  Assert.equal(c:status().state, "WAITING_CLOSE")
end

function T.trailing_indicator_appears_only_at_its_reveal_position()
  local indicator = {
    kind = "focus_indicator",
    control = 0x0200,
    name = "YESNO",
    args = { 0 },
    raw = { 0xFFFE, 0x0200, 1, 0 },
  }
  local c = controller({ page({ line({ glyph("A", 1), glyph("B", 2), indicator }) }, "eos") })
  c:open(request("t", message()))
  c:step({}) -- opening and reveal A (printer delay 2)
  Assert.equal(#c:status().visibleLines[1], 1, "only the first glyph is visible")
  c:step({}) -- reveal B: the trailing indicator becomes visible in the same prefix
  Assert.equal(#c:status().visibleLines[1], 3)
  Assert.equal(c:status().visibleLines[1][3].kind, "focus_indicator")
  Assert.equal(c:status().state, "WAITING_CLOSE")

  -- Action accelerates printing but does not reveal the whole page instantly.
  local c2 = controller({ page({ line({ glyph("A", 1), glyph("B", 2), indicator }) }, "eos") })
  c2:open(request("t2", message()))
  c2:step({}) -- opening and reveal A
  c2:step({ actionPressed = true }) -- progressively reveal the next glyph
  Assert.equal(c2:status().revealedGlyphs, 2, "Action reveals progressively")
  Assert.equal(#c2:status().visibleLines[1], 3, "the indicator follows its reveal position")
end

function T.color_tokens_do_not_consume_the_reveal_count()
  local colorToken = {
    kind = "style",
    control = 0xFF00,
    name = "COLOR",
    args = { 1 },
    raw = { 0xFFFE, 0xFF00, 1, 1 },
  }
  local c = controller({
    page({ line({ glyph("A", 1), colorToken, glyph("B", 2) }) }, "eos"),
  })
  c:open(request("t", message()))
  c:step({}) -- opening and reveal the first glyph
  Assert.equal(c:status().revealedGlyphs, 1, "reveal counts glyphs only")
  Assert.equal(c:status().pageGlyphCount, 2, "the color control consumes no glyph slot")
  local prefix = c:status().visibleLines[1]
  Assert.equal(#prefix, 2, "the color control rides the reveal prefix")
  Assert.equal(prefix[2].control, 0xFF00)
end

return { tests = T }
