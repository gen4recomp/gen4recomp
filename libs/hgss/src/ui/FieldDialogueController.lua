-- Fixed-tick modal dialogue controller. Owns the
-- typewriter reveal state machine, Action reveal/advance/close semantics,
-- cancel policy, and the exactly-once completion handle. Layout and input are
-- injected, so headless tests drive the full lifecycle without LÖVE; the
-- controller never touches presentation. Pages come from the injected layout
-- function; continuation state retains the visible window instead of replacing
-- it wholesale.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")

---@class FieldDialogueController
---@field _layout fun(message: FieldMessageProvider.FormattedMessage): DialogueLayout.Result
---@field _policy table<string, unknown>
---@field _audio table<string, unknown>?
---@field _state "CLOSED"|"OPENING"|"REVEALING"|"WAITING_BOUNDARY"|"WAITING_CLOSE"|"SCROLLING"|"CLOSING"
---@field _request FieldDialogueController.Request?
---@field _handle FieldDialogueController.Handle?
---@field _pages DialogueLayout.Page[]?
---@field _pageGlyphs integer[]?
---@field _warnings DialogueLayout.Warning[]?
---@field _pageIndex integer
---@field _revealed integer
---@field _terminal { kind: string, result: FieldDialogueController.Result }?
---@field _pendingClose { kind: string, error: unknown }?
---@field _lineHeight integer
---@field _lineSpacing integer
---@field _textOriginX integer
---@field _textOriginY integer
---@field _contentWidth integer
---@field _syntheticBreaks integer
---@field _retainedLines MessageToken[][]
---@field _scrollLines FieldDialogueController.VisibleLine[]?
---@field _scrollRemaining integer
---@field _scrollOffsetY integer
---@field _cursorCycle integer[]
---@field _cursorTicksPerPhase integer
---@field _cursorCycleIndex integer
---@field _cursorTicksIntoPhase integer
local FieldDialogueController = {}
FieldDialogueController.__index = FieldDialogueController

-- Pages whose breakKind asks the reader for Action ("prompt", "page") wait;
-- "line" and "overflow" auto-scroll into the next page the way the DS scrolls
-- a full box. "eos" waits for the final close. A final prompt/page boundary
-- still waits as a boundary: one confirmation executes its retail
-- clear/scroll effect, then the message finishes automatically because EOS
-- follows, without a second confirmation.

---@param page DialogueLayout.Page
---@return boolean
local function waitsForAction(page)
  return page.breakKind == "prompt"
    or page.breakKind == "page"
    or page.breakKind == "clear"
    or page.breakKind == "scroll"
    or page.breakKind == "eos"
end

---@param page DialogueLayout.Page
---@return "clear"|"scroll"|nil
local function continuationKind(page)
  if page.breakKind == "prompt" or page.breakKind == "clear" then
    return "clear"
  elseif page.breakKind == "page" or page.breakKind == "scroll" then
    return "scroll"
  else
    return nil
  end
end

---@param page DialogueLayout.Page
---@return integer
local function glyphCount(page)
  local count = 0
  for _, line in ipairs(page.lines) do
    for _, token in ipairs(line.tokens) do
      if token.kind == "glyph" then
        count = count + 1
      end
    end
  end
  return count
end

-- Flattens the page's tokens up to the Nth revealed glyph. Non-glyph
-- presentation controls before the cut remain visible so their source-position
-- effects activate at the correct reveal point; lines beyond the cut are
-- omitted.

---@param page DialogueLayout.Page
---@param revealed integer
---@return MessageToken[][]
local function visibleLines(page, revealed)
  local out = {}
  local seen = 0
  for _, line in ipairs(page.lines) do
    local tokens = {}
    for _, token in ipairs(line.tokens) do
      if token.kind == "glyph" then
        if seen >= revealed then
          break
        end
        seen = seen + 1
      end
      tokens[#tokens + 1] = token
    end
    if #tokens > 0 then
      out[#out + 1] = tokens
    end
  end
  return out
end

---@param line MessageToken[]|FieldDialogueController.VisibleLine
---@return MessageToken[]
local function lineTokens(line)
  return line.tokens or line
end

-- opts.layout(formattedMessage) -> DialogueLayout.Result
-- opts.printerDelay is measured in source printer ticks.

---@class FieldDialogueControllerOptions
---@field layout fun(message: FieldMessageProvider.FormattedMessage): DialogueLayout.Result
---@field policy { interGlyphDelay: integer, glyphBudget: integer, abAcceleration: boolean }?
---@field printerDelay integer?
---@field audio table<string, unknown>? { play: function(self: table<string, unknown>, soundRef: string) }
---@field continueCursor { cycle: integer[], framePrinterTicks: integer }?

---@param opts FieldDialogueControllerOptions
---@return FieldDialogueController
function FieldDialogueController.new(opts)
  assert(
    type(opts) == "table" and type(opts.layout) == "function",
    "FieldDialogueController requires a layout function"
  )
  local policy = opts.policy
    or (opts.printerDelay and { interGlyphDelay = opts.printerDelay, glyphBudget = 1, abAcceleration = true })
    or TextSpeedPolicy.forSpeed("fastest")
  local cursorSource = opts.continueCursor
  assert(cursorSource, "FieldDialogueController requires continueCursor from the validated field-UI manifest")
  local cursorCycle = assert(cursorSource.cycle, "continueCursor must carry the source cycle")
  local cursorTicks = assert(cursorSource.framePrinterTicks, "continueCursor must carry framePrinterTicks")
  assert(type(cursorCycle) == "table" and #cursorCycle == 4, "continuation cursor cycle must be the source cycle")
  assert(
    type(cursorTicks) == "number" and cursorTicks >= 1 and cursorTicks % 1 == 0,
    "continuation cursor timing must be a positive integer"
  )
  return setmetatable({
    _layout = opts.layout,
    _policy = policy,
    _audio = opts.audio,
    _state = "CLOSED",
    _request = nil,
    _handle = nil,
    _pages = nil,
    _pageGlyphs = nil,
    _warnings = nil,
    _pageIndex = 0,
    _revealed = 0,
    _terminal = nil,
    _pendingClose = nil,
    _lineHeight = 16,
    _lineSpacing = 0,
    _textOriginX = 0,
    _textOriginY = 0,
    _contentWidth = 216,
    _syntheticBreaks = 0,
    _retainedLines = {},
    _scrollLines = nil,
    _scrollRemaining = 0,
    _scrollOffsetY = 0,
    _pageTokens = nil,
    _tokenIndex = 1,
    _delayCounter = 0,
    _pauseRemaining = 0,
    _hasPrintBeenSpedUp = false,
    _cursorCycle = cursorCycle,
    _cursorTicksPerPhase = cursorTicks,
    _cursorCycleIndex = 1,
    _cursorTicksIntoPhase = 0,
  }, FieldDialogueController)
end

---@return boolean
function FieldDialogueController:isModal()
  return self._state ~= "CLOSED"
end

-- True when the open request is owned by the field-script runtime (the
-- script dialogue host opens requests with `metadata.scriptOwned`). The
-- session's modal gate skips script-owned boxes: the script scheduler steps
-- them from its engine-owned async phase instead.
---@return boolean
function FieldDialogueController:isScriptOwned()
  if self._state == "CLOSED" or self._request == nil then
    return false
  end
  local metadata = self._request.metadata
  return metadata ~= nil and metadata.scriptOwned == true
end

---@return FieldDialogueController.Status
function FieldDialogueController:status()
  local page = self._pages and self._pages[self._pageIndex]
  local waiting = self._state == "WAITING_BOUNDARY" or self._state == "WAITING_CLOSE"
  local resolvedContinuation = nil
  if waiting and page then
    resolvedContinuation = continuationKind(page)
  end
  local lines
  local scrollLines
  if self._state == "SCROLLING" then
    scrollLines = self._scrollLines
    lines = { assert(self._scrollLines)[#self._scrollLines] }
  else
    lines = {}
    for _, retained in ipairs(self._retainedLines) do
      lines[#lines + 1] = retained
    end
    for _, visible in ipairs(page and visibleLines(page, self._revealed) or {}) do
      lines[#lines + 1] = visible
    end
  end
  return {
    state = self._state,
    modal = self:isModal(),
    requestId = self._request and self._request.id or nil,
    bankId = self._request and self._request.message and self._request.message.bankId or nil,
    messageId = self._request and self._request.message and self._request.message.messageId or nil,
    frameIndex = self._request and self._request.frameIndex or nil,
    pageIndex = self._pageIndex,
    pageCount = self._pages and #self._pages or 0,
    revealedGlyphs = self._revealed,
    pageGlyphCount = page and self._pageGlyphs[self._pageIndex] or 0,
    waiting = waiting,
    continuationKind = resolvedContinuation,
    cursorPhase = waiting and self._cursorCycle[self._cursorCycleIndex] or nil,
    warnings = self._warnings or {},
    visibleLines = lines,
    scrollLines = scrollLines,
    lineHeight = self._lineHeight,
    lineSpacing = self._lineSpacing,
    textOriginX = self._textOriginX,
    textOriginY = self._textOriginY,
    contentWidth = self._contentWidth,
    syntheticBreaks = self._syntheticBreaks,
    scrollOffsetY = self._scrollOffsetY,
    scrollRemaining = self._scrollRemaining,
    allowCancel = self._request and self._request.allowCancel == true or false,
  }
end

-- Builds the terminal result: request identity plus any extra fields
-- (e.g. the layout error for the error path).

---@param kind string
---@param extra table<string, unknown>?
---@return FieldDialogueController.Result
function FieldDialogueController:_result(kind, extra)
  local request = assert(self._request)
  local result = {
    kind = kind,
    requestId = request.id,
    bankId = request.message.bankId,
    messageId = request.message.messageId,
    metadata = request.metadata,
  }
  if extra then
    for key, value in pairs(extra) do
      result[key] = value
    end
  end
  return result
end

-- Queues a terminal and returns the result. The callback fires from
-- _dispatch, which runs only after the state machine finished mutating.

---@param kind string
---@param extra table<string, unknown>?
---@return FieldDialogueController.Result
function FieldDialogueController:_complete(kind, extra)
  assert(not self._terminal, "dialogue already reached a terminal state")
  self._terminal = { kind = kind, result = self:_result(kind, extra) }
  return self._terminal.result
end

-- Fires the terminal callback exactly once, after every internal table is
-- fully settled, and returns the result. The request, handle, and page state
-- are released before the callback runs, so a callback that reopens a
-- dialogue (the reentrant-open contract) starts from a clean CLOSED
-- controller instead of inheriting the finished request; the terminal result
-- already carries the identity copies it needs.

---@return FieldDialogueController.Result?
function FieldDialogueController:_dispatch()
  local terminal = self._terminal
  if not terminal then
    return nil
  end
  self._terminal = nil
  local callback = terminal.kind == "complete" and self._handle._onComplete
    or terminal.kind == "cancel" and self._handle._onCancel
    or self._handle._onError
  self._request = nil
  self._handle = nil
  self._pages = nil
  self._pageGlyphs = nil
  self._warnings = nil
  self._retainedLines = {}
  self._scrollLines = nil
  self._scrollRemaining = 0
  self._scrollOffsetY = 0
  self._pageTokens = nil
  self._tokenIndex = 1
  self._delayCounter = 0
  self._pauseRemaining = 0
  self._hasPrintBeenSpedUp = false
  self._cursorCycleIndex = 1
  self._cursorTicksIntoPhase = 0
  local ok, err = pcall(function()
    if callback then
      callback(terminal.result)
    end
  end)
  if not ok then
    error(err)
  end
  return terminal.result
end

-- Opens a DialogueRequest (see Request for the shape). Returns the completion
-- handle. A malformed message (layout failure) still returns a handle whose
-- error callback fires exactly once; modal ownership engages for one tick so
-- the session's modal gate drives that dispatch, then releases.

---@param request FieldDialogueController.Request
---@return FieldDialogueController.Handle
function FieldDialogueController:open(request)
  assert(type(request) == "table" and type(request.id) == "string", "dialogue request requires an id")
  assert(
    type(request.message) == "table" and type(request.message.tokens) == "table",
    "dialogue request requires a formatted message with a token stream"
  )
  if self._state ~= "CLOSED" then
    Errors.raise(
      FieldErrors.DIALOGUE_ALREADY_OPEN,
      "a dialogue is already open; open() while modal is not allowed",
      { requestId = self._request and self._request.id }
    )
  end
  local handle = {}
  ---@cast handle FieldDialogueController.Handle
  ---@param callbackHandle FieldDialogueController.Handle
  ---@param fn fun(result: FieldDialogueController.Result)
  ---@return FieldDialogueController.Handle
  local function onComplete(callbackHandle, fn)
    callbackHandle._onComplete = fn
    return callbackHandle
  end
  ---@param callbackHandle FieldDialogueController.Handle
  ---@param fn fun(result: FieldDialogueController.Result)
  ---@return FieldDialogueController.Handle
  local function onCancel(callbackHandle, fn)
    callbackHandle._onCancel = fn
    return callbackHandle
  end
  ---@param callbackHandle FieldDialogueController.Handle
  ---@param fn fun(result: FieldDialogueController.Result)
  ---@return FieldDialogueController.Handle
  local function onError(callbackHandle, fn)
    callbackHandle._onError = fn
    return callbackHandle
  end
  handle.onComplete = onComplete
  handle.onCancel = onCancel
  handle.onError = onError
  -- The player-selected HGSS user-frame index is presentation data captured
  -- at open time: an already-open message keeps the frame it opened with.
  -- The request may omit it; status then exposes nil rather than inventing a
  -- frame.
  local frameIndex = request.frameIndex
  assert(
    frameIndex == nil or (type(frameIndex) == "number" and frameIndex >= 0 and frameIndex % 1 == 0),
    "dialogue request frameIndex must be a non-negative integer"
  )
  local ok, layout = pcall(self._layout, request.message)
  self._request = request
  self._handle = handle
  self._pageIndex = 1
  self._revealed = 0
  self._terminal = nil
  self._pendingClose = nil
  self._retainedLines = {}
  self._scrollLines = nil
  self._scrollRemaining = 0
  self._scrollOffsetY = 0
  if not ok then
    self._pages = {}
    self._pageGlyphs = {}
    self._warnings = {}
    self._state = "OPENING"
    self._pendingClose = { kind = "error", error = layout }
    return handle
  end
  local pageGlyphs = {}
  for index, page in ipairs(layout.pages) do
    pageGlyphs[index] = glyphCount(page)
  end
  self._pages = layout.pages
  self._pageGlyphs = pageGlyphs
  self._warnings = layout.warnings
  self._lineHeight = assert(layout.lineHeight or 16)
  self._lineSpacing = assert(layout.lineSpacing or 0)
  self._textOriginX = assert(layout.textOriginX or 0)
  self._textOriginY = assert(layout.textOriginY or 0)
  self._contentWidth = assert(layout.contentWidth or 216)
  self._syntheticBreaks = assert(layout.syntheticBreaks or 0)
  self._pageTokens = {}
  for pageIndex, page in ipairs(layout.pages) do
    local tokens = {}
    for _, line in ipairs(page.lines) do
      for _, token in ipairs(line.tokens) do
        tokens[#tokens + 1] = token
      end
    end
    self._pageTokens[pageIndex] = tokens
  end
  self._tokenIndex = 1
  self._delayCounter = 0
  self._pauseRemaining = 0
  self._hasPrintBeenSpedUp = false
  self._cursorCycleIndex = 1
  self._cursorTicksIntoPhase = 0
  self._state = "OPENING"
  if #self._pages == 0 then
    -- An empty or control-only message closes safely on its first step: the
    -- session's modal gate still drives the completion, and handle callbacks
    -- registered after open() fire normally.
    self._pendingClose = { kind = "complete" }
  end
  return handle
end

-- Advances to the next page, or to the final wait when the last page ends.
-- Returns true when a page switch happened.

---@return boolean
function FieldDialogueController:_advancePage()
  if self._pageIndex >= #self._pages then
    self._state = "WAITING_CLOSE"
    return false
  end
  self._pageIndex = self._pageIndex + 1
  self._revealed = 0
  self._tokenIndex = 1
  self._delayCounter = 0
  self._pauseRemaining = 0
  self._state = "REVEALING"
  return true
end

---@return nil
function FieldDialogueController:_beginScroll()
  local statusLines = self:status().visibleLines
  assert(#statusLines > 0, "scroll break requires visible dialogue lines")
  self._scrollLines = {}
  for _, tokens in ipairs(statusLines) do
    self._scrollLines[#self._scrollLines + 1] = { tokens = lineTokens(tokens), width = 0 }
  end
  self._retainedLines = { statusLines[#statusLines] }
  self._revealed = 0
  self._scrollOffsetY = 0
  self._scrollRemaining = self._lineHeight + self._lineSpacing
  assert(self._scrollRemaining > 0, "dialogue scroll distance must be positive")
  self._state = "SCROLLING"
end

---@return nil
function FieldDialogueController:_finishScroll()
  self._scrollLines = nil
  self._scrollRemaining = 0
  if self._pageIndex >= #self._pages then
    self._state = "CLOSING"
    return
  end
  self:_advancePage()
end

---@return nil
function FieldDialogueController:_enterWait()
  local page = self._pages[self._pageIndex]
  -- Prompt/page (and their clear/scroll continuation aliases) always wait
  -- as a boundary, even on the final page: confirming a final 0x25BC/0x25BD
  -- still executes the retail clear/scroll effect and then finishes
  -- automatically because EOS follows, without a second confirmation.
  -- EOS and trailing automatic boundaries wait for close directly.
  local state = continuationKind(page) ~= nil and "WAITING_BOUNDARY" or "WAITING_CLOSE"
  self._state = state
  self._cursorCycleIndex = 1
  self._cursorTicksIntoPhase = 0
end

-- Called when the current page has fully revealed: prompt/page/eos pages
-- wait for Action; line/overflow pages scroll one line into the next page.

---@return nil
function FieldDialogueController:_atPageEnd()
  local page = self._pages[self._pageIndex]
  if waitsForAction(page) then
    self:_enterWait()
    return
  end
  -- Automatic boundary (breakKind "line" or "overflow"): roll the two-line
  -- window through the existing scroll state. Zero-glyph automatic pages
  -- carry no line to retain, so step through them until a wait or a real
  -- reveal, bounded by the page count.
  if self._pageGlyphs[self._pageIndex] > 0 and #self:status().visibleLines > 0 then
    if self._pageIndex >= #self._pages then
      self:_enterWait()
    else
      self:_beginScroll()
    end
    return
  end
  while not waitsForAction(page) do
    if not self:_advancePage() then
      return
    end
    page = self._pages[self._pageIndex]
    if self._pageGlyphs[self._pageIndex] > 0 then
      return
    end
  end
  self:_enterWait()
end

---@param sourceNew boolean
---@param sourceHeld boolean
---@return boolean
function FieldDialogueController:_printerSubstep(sourceNew, sourceHeld)
  self._scrollOffsetY = 0
  local total = self._pageGlyphs[self._pageIndex]
  if self._policy.abAcceleration and self._delayCounter > 0 then
    if sourceNew then
      self._hasPrintBeenSpedUp = true
      self._delayCounter = 0
      return true
    elseif self._hasPrintBeenSpedUp and sourceHeld then
      self._delayCounter = 0
    end
  end
  if self._pauseRemaining > 0 then
    self._pauseRemaining = self._pauseRemaining - 1
    return false
  end
  local tokens = self._pageTokens[self._pageIndex]
  local visible = 0
  while self._tokenIndex <= #tokens do
    local token = tokens[self._tokenIndex]
    if token.kind == "glyph" then
      if self._delayCounter > 0 then
        self._delayCounter = self._delayCounter - 1
        return false
      end
      self._tokenIndex = self._tokenIndex + 1
      self._revealed = math.min(total, self._revealed + 1)
      self._delayCounter = self._policy.interGlyphDelay
      if self._revealed >= total then
        self:_atPageEnd()
      end
      visible = visible + 1
      if visible >= self._policy.glyphBudget or self._state ~= "REVEALING" then
        return false
      end
      -- Fastest may continue through non-rendering controls for its second glyph.
    end
    if token.kind ~= "glyph" then
      self._tokenIndex = self._tokenIndex + 1
    end
    if token.kind == "pause" then
      self._pauseRemaining = assert(token.args and token.args[1], "pause control requires an argument")
      return false
    elseif token.kind == "printer_callback" then
      return false
    end
  end
  self:_atPageEnd()
  return false
end

-- One fixed simulation tick. snapshot = { actionPressed, cancelPressed }
-- (the FieldInput snapshot edges this controller reads). Returns the
-- terminal result when this tick finished the dialogue, else nil.

---@param snapshot FieldDialogueController.Input?
---@return FieldDialogueController.Result?
function FieldDialogueController:step(snapshot)
  if self._state == "CLOSED" then
    return nil
  end
  snapshot = snapshot or {}
  local sourceNew = snapshot.actionPressed == true or (not self._request.allowCancel and snapshot.cancelPressed == true)
  local sourceHeld = snapshot.actionDown == true or (not self._request.allowCancel and snapshot.cancelDown == true)

  if self._request.allowCancel and snapshot.cancelPressed and self._state ~= "CLOSING" then
    self._state = "CLOSED"
    self:_complete("cancel")
    return self:_dispatch()
  end

  if self._state == "OPENING" then
    if self._pendingClose then
      local pending = assert(self._pendingClose)
      self._pendingClose = nil
      self._state = "CLOSED"
      if pending.kind == "error" then
        self:_complete("error", { error = pending.error })
      else
        self:_complete("complete")
      end
      return self:_dispatch()
    end
    self._state = "REVEALING"
  end

  if self._state == "REVEALING" then
    for substep = 1, 2 do
      if self._state ~= "REVEALING" then
        break
      end
      local accelerated = self:_printerSubstep(substep == 1 and sourceNew or false, sourceHeld)
      if accelerated then
        break
      end
    end
  elseif self._state == "WAITING_BOUNDARY" or self._state == "WAITING_CLOSE" then
    if sourceNew then
      if self._audio then
        assert(type(self._audio.play) == "function", "dialogue audio host must provide play")
        self._audio:play("SEQ_SE_DP_SELECT")
      end
      if self._state == "WAITING_BOUNDARY" then
        local page = assert(self._pages[self._pageIndex])
        if continuationKind(page) == "scroll" then
          self:_beginScroll()
        elseif self._pageIndex >= #self._pages then
          self._retainedLines = {}
          self._state = "CLOSING"
        else
          self._retainedLines = {}
          self:_advancePage()
        end
      else
        self._state = "CLOSING"
      end
    else
      self._cursorTicksIntoPhase = self._cursorTicksIntoPhase + 1
      if self._cursorTicksIntoPhase >= self._cursorTicksPerPhase then
        self._cursorTicksIntoPhase = 0
        self._cursorCycleIndex = self._cursorCycleIndex % #self._cursorCycle + 1
      end
    end
  elseif self._state == "SCROLLING" then
    for _ = 1, 2 do
      local delta = math.min(4, self._scrollRemaining)
      self._scrollOffsetY = self._scrollOffsetY + delta
      self._scrollRemaining = self._scrollRemaining - delta
      if self._scrollRemaining == 0 then
        self:_finishScroll()
        break
      end
    end
  elseif self._state == "CLOSING" then
    self._state = "CLOSED"
    self:_complete("complete")
    return self:_dispatch()
  end

  return nil
end

-- Closes an open dialogue with a completion result. Idempotent: a second
-- close on a closed controller returns nil and fires nothing.

---@return FieldDialogueController.Result?
function FieldDialogueController:close()
  if self._state == "CLOSED" then
    return nil
  end
  if self._state ~= "CLOSING" then
    self._state = "CLOSING"
  end
  self._state = "CLOSED"
  self:_complete("complete")
  return self:_dispatch()
end

-- State disposal: cancels an open dialogue exactly once and never re-enters
-- modal ownership. Used on map teardown and quit paths.

---@return FieldDialogueController.Result?
function FieldDialogueController:dispose()
  if self._state == "CLOSED" then
    return nil
  end
  self._state = "CLOSED"
  self:_complete("cancel")
  return self:_dispatch()
end

-- A DialogueRequest is the immutable open() argument.
-- The message is a formatted, pre-layout message; the pre-script adapter
-- builds it from the message provider. `frameIndex` is the player-selected
-- HGSS user-frame index, captured at open time (optional: a host without
-- player options opens without one).

---@class FieldDialogueController.Request
---@field id string
---@field message FieldMessageProvider.FormattedMessage
---@field allowCancel boolean
---@field metadata table<string, unknown>?
---@field frameIndex integer?

-- The completion handle: exactly one of onComplete/onCancel/onError fires,
-- once, after the dialogue settles. Register handlers right after open().

---@class FieldDialogueController.Handle
---@field _onComplete fun(result: FieldDialogueController.Result)?
---@field _onCancel fun(result: FieldDialogueController.Result)?
---@field _onError fun(result: FieldDialogueController.Result)?
---@field onComplete fun(self: FieldDialogueController.Handle, fn: fun(result: FieldDialogueController.Result)): FieldDialogueController.Handle
---@field onCancel fun(self: FieldDialogueController.Handle, fn: fun(result: FieldDialogueController.Result)): FieldDialogueController.Handle
---@field onError fun(self: FieldDialogueController.Handle, fn: fun(result: FieldDialogueController.Result)): FieldDialogueController.Handle

-- The terminal result delivered to callbacks and returned by step/close/
-- dispose when they finish the dialogue.

---@class FieldDialogueController.Result
---@field kind "complete"|"cancel"|"error"
---@field requestId string
---@field bankId integer?
---@field messageId integer?
---@field metadata table<string, unknown>?
---@field error unknown?

-- Fixed-tick input snapshot consumed by step(); produced by FieldInput.

---@class FieldDialogueController.Input
---@field actionPressed boolean?
---@field actionDown boolean?
---@field cancelPressed boolean?
---@field cancelDown boolean?

-- Snapshot of the controller's reveal position for the renderer and HUD.

---@class FieldDialogueController.Status
---@field state "CLOSED"|"OPENING"|"REVEALING"|"WAITING_BOUNDARY"|"WAITING_CLOSE"|"SCROLLING"|"CLOSING"
---@field modal boolean
---@field requestId string?
---@field bankId integer?
---@field messageId integer?
---@field frameIndex integer?
---@field pageIndex integer
---@field pageCount integer
---@field revealedGlyphs integer
---@field pageGlyphCount integer
---@field waiting boolean
---@field continuationKind "clear"|"scroll"?
---@field cursorPhase integer?
---@field warnings DialogueLayout.Warning[]
---@field visibleLines (MessageToken[]|FieldDialogueController.VisibleLine)[]
---@field scrollLines FieldDialogueController.VisibleLine[]?
---@field lineHeight integer
---@field lineSpacing integer
---@field scrollOffsetY integer
---@field scrollRemaining integer
---@field allowCancel boolean

---@class FieldDialogueController.VisibleLine
---@field tokens MessageToken[]
---@field width integer

return FieldDialogueController
