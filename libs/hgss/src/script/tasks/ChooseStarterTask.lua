-- Blocking starter-choice task: pre-creates the three provider-ordered
-- candidates through the mon service, drives the source fade order around
-- the modal choice, publishes the exact confirmed instance once, and
-- resumes the field script. Generation is one atomic creation step, so a
-- saved task always carries its candidates and never redraws the
-- generator; publication is idempotent, so a restored task never inserts
-- twice. The task sets no story flags: the resumed script owns them.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local MonsErrors = require("libs.mons.src.errors")
local ScriptErrors = require("libs.script.src.errors")

local ChooseStarterTask = {}

ChooseStarterTask.type = "choose_starter"
ChooseStarterTask.version = 1

local PHASE_FADE_OUT = "fade_out"
local PHASE_CHOOSE = "choose"
local PHASE_PUBLISH = "publish"
local PHASE_FADE_IN = "fade_in"
local PHASE_DONE = "done"

local PHASES = {
  [PHASE_FADE_OUT] = true,
  [PHASE_CHOOSE] = true,
  [PHASE_PUBLISH] = true,
  [PHASE_FADE_IN] = true,
  [PHASE_DONE] = true,
}

local FADE_SPEC = { color = "black", duration = 6, speed = 1 }

---@param ctx table<string, unknown>
---@return HgssMonService mons service
local function monsService(ctx)
  local services = ctx.services or {}
  local mons = services.mons
  assert(mons ~= nil, "choose_starter requires the mon service")
  return mons
end

---@param ctx table<string, unknown>
---@return table<string, unknown> provider
local function starterProvider(ctx)
  local services = ctx.services or {}
  local provider = services.starterProvider
  if provider == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "choose_starter requires the starter provider",
      { scriptId = ctx.instance and ctx.instance.scriptId }
    )
  end
  ---@cast provider table<string, unknown>
  if type(provider.resolve) ~= "function" then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the starter provider must resolve its species roster",
      { scriptId = ctx.instance and ctx.instance.scriptId }
    )
  end
  return provider
end

---@param ctx table<string, unknown>
---@return table<string, unknown> choice host
local function choiceHost(ctx)
  local services = ctx.services or {}
  local host = services.starterChoice
  if host == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "choose_starter requires the starter choice host",
      { scriptId = ctx.instance and ctx.instance.scriptId }
    )
  end
  ---@cast host table<string, unknown>
  if type(host.open) ~= "function" or type(host.close) ~= "function" or type(host.status) ~= "function" then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the starter choice host must open, close, and report status",
      { scriptId = ctx.instance and ctx.instance.scriptId }
    )
  end
  return host
end

-- One fade leg of the source order. A test composition without a screen
-- service skips fading; the production screen controller starts each leg
-- once and the task waits for its completion.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@param leg "out"|"in"
---@return boolean ready
local function fadeReady(state, ctx, leg)
  local services = ctx.services or {}
  local screen = services.screen
  if screen == nil then
    return true
  end
  if type(screen.startFade) ~= "function" or type(screen.fadeDone) ~= "function" then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the screen service must start fades and report fade progress",
      { scriptId = ctx.instance and ctx.instance.scriptId }
    )
  end
  local startedKey = leg == "out" and "fadeOutStarted" or "fadeInStarted"
  if not state[startedKey] then
    screen:startFade({
      direction = leg,
      color = FADE_SPEC.color,
      duration = FADE_SPEC.duration,
      speed = FADE_SPEC.speed,
    })
    state[startedKey] = true
    return false
  end
  return screen:fadeDone()
end

---@param host table<string, unknown>
---@param event table<string, unknown>
local function applyPointerEvent(host, event)
  local hit = nil
  if type(host.hitTest) == "function" and type(event.x) == "number" and type(event.y) == "number" then
    hit = host:hitTest(event.x, event.y)
  end
  if event.type == "pointer_move" then
    if hit ~= nil and hit.kind == "candidate" then
      host:hover(hit.index)
    elseif hit ~= nil and hit.kind == "confirm" then
      host:hover(hit.index)
    else
      host:hover(nil)
    end
  elseif event.type == "pointer_down" then
    if hit ~= nil then
      host:press(hit.index)
    else
      host:press(nil)
    end
  elseif event.type == "pointer_up" then
    if event.dragged then
      host:release(nil)
    elseif hit ~= nil then
      host:release(hit.index)
    else
      host:release(nil)
    end
  end
end

-- Maps one tick of normalized UI events onto the choice host. The host owns
-- the cursor and confirmation state; the task only carries the candidate
-- cursor for reopening after a restore.
---@param state table<string, unknown>
---@param host table<string, unknown>
---@param ctx table<string, unknown>
local function applyEvents(state, host, ctx)
  local input = ctx.input or {}
  local events = input.uiEvents or {}
  assert(type(events) == "table", "starter choice UI events must be a table")
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "starter choice UI event is invalid")
    local eventType = event.type
    if eventType == "navigate" then
      local direction = event.direction
      if direction == "left" or direction == "right" then
        local status = host:status()
        if status ~= nil and status.mode == "confirming" then
          -- The confirmation answers left (no) and right (yes).
          host:focus(direction == "left" and 1 or 0)
        else
          if direction == "left" then
            state.cursor = (state.cursor - 1) % 3
          else
            state.cursor = (state.cursor + 1) % 3
          end
          host:focus(state.cursor)
        end
      elseif direction ~= "up" and direction ~= "down" then
        assert(false, "unknown starter choice navigation " .. tostring(direction))
      end
    elseif eventType == "confirm" then
      host:confirm()
    elseif eventType == "cancel" then
      host:cancel()
    elseif eventType == "pointer_move" or eventType == "pointer_down" or eventType == "pointer_up" then
      applyPointerEvent(host, event)
    elseif eventType ~= "pointer_scroll" then
      assert(false, "unknown starter choice UI event " .. eventType)
    end
  end
end

---@param spec table<string, unknown> { node: unknown }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function ChooseStarterTask.create(spec, ctx)
  assert(type(spec) == "table" and type(spec.node) == "table", "choose_starter requires its graph node")
  assert(spec.node.op == "choose_starter", "choose_starter requires the starter operation")
  local mons = monsService(ctx)
  local provider = starterProvider(ctx)
  choiceHost(ctx)
  local catalog = mons:catalog()
  assert(catalog ~= nil, "choose_starter requires the mon catalog")

  -- Resolve once for this task instance. Exactly three keys, each a native
  -- form-zero species, validated before any generator draw.
  local roster = provider:resolve()
  if type(roster) ~= "table" or #roster ~= 3 then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "the starter provider must resolve exactly three species",
      { scriptId = ctx.instance and ctx.instance.scriptId }
    )
  end
  ---@cast roster string[]
  for _, key in ipairs(roster) do
    catalog:species(key)
    catalog:form(key, 0)
  end

  -- One atomic generation step in provider order: complete canonical
  -- records stored before the UI opens. Never regenerated afterwards.
  local candidates = {}
  for index, key in ipairs(roster) do
    candidates[index] = mons:buildStarter(key)
  end

  return {
    phase = PHASE_FADE_OUT,
    candidates = candidates,
    cursor = 0,
    opened = false,
    closed = false,
    published = false,
    selectedIndex = nil,
    fadeOutStarted = false,
    fadeInStarted = false,
    result = nil,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function ChooseStarterTask.poll(state, ctx)
  if state.phase == PHASE_DONE then
    return { complete = true, state = state, result = state.result }
  end
  local mons = monsService(ctx)
  local host = choiceHost(ctx)

  if state.phase == PHASE_FADE_OUT then
    if not fadeReady(state, ctx, "out") then
      return { complete = false, state = state }
    end
    state.phase = PHASE_CHOOSE
  end

  if state.phase == PHASE_CHOOSE then
    if host:status() == nil and not state.closed then
      host:open(state.cursor, state.candidates)
      state.opened = true
    end
    applyEvents(state, host, ctx)
    local status = host:status()
    if status == nil then
      return { complete = false, state = state }
    end
    if status.done ~= true then
      if type(status.cursor) == "number" then
        state.cursor = status.cursor
      end
      return { complete = false, state = state }
    end
    local index = status.index
    if type(index) ~= "number" or index % 1 ~= 0 or index < 0 or index > 2 then
      Errors.raise(
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        "the starter choice result names a candidate 0..2",
        { scriptId = ctx.instance and ctx.instance.scriptId }
      )
    end
    ---@cast index integer
    state.selectedIndex = index
    state.phase = PHASE_PUBLISH
  end

  if state.phase == PHASE_PUBLISH then
    local index = assert(state.selectedIndex, "starter publication requires the confirmed candidate")
    local candidate = assert(state.candidates[index + 1], "starter publication requires the pre-created candidate")
    if not mons:addMon(candidate) then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "starter publication requires a free party slot", { slot = index })
    end
    state.published = true
    if host:status() ~= nil then
      host:close()
    end
    state.closed = true
    state.phase = PHASE_FADE_IN
  end

  if state.phase == PHASE_FADE_IN then
    if not fadeReady(state, ctx, "in") then
      return { complete = false, state = state }
    end
    state.phase = PHASE_DONE
    state.result = { index = assert(state.selectedIndex, "completed starter choice names its candidate") }
    return { complete = true, state = state, result = state.result }
  end

  error("unknown starter task phase " .. tostring(state.phase), 0)
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function ChooseStarterTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx ~= nil and state.opened and not state.closed then
    local services = ctx.services or {}
    local host = services.starterChoice
    if type(host) == "table" and type(host.status) == "function" and type(host.close) == "function" then
      if host:status() ~= nil then
        host:close()
      end
      state.closed = true
    end
  end
end

---@param value unknown
---@return boolean
local function isCursor(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 2
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function ChooseStarterTask.validate(state)
  if type(state) ~= "table" or PHASES[state.phase] ~= true then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter task state must hold a known phase", {})
  end
  local candidates = state.candidates
  if type(candidates) ~= "table" or #candidates ~= 3 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter task state must hold three candidates", {})
  end
  for _, candidate in ipairs(candidates) do
    if type(candidate) ~= "table" or type(candidate.species) ~= "string" then
      return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter candidates must be semantic records", {})
    end
    if type(candidate.form) ~= "number" or type(candidate.personality) ~= "number" then
      return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter candidates must be complete records", {})
    end
  end
  if not isCursor(state.cursor) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter cursor must name a candidate 0..2", {})
  end
  if state.selectedIndex ~= nil and not isCursor(state.selectedIndex) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter selection must name a candidate 0..2", {})
  end
  for _, field in ipairs({ "opened", "closed", "published", "fadeOutStarted", "fadeInStarted" }) do
    if type(state[field]) ~= "boolean" then
      return Errors.new(
        ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
        "starter task flag " .. field .. " must be a boolean",
        {}
      )
    end
  end
  if state.result ~= nil then
    if type(state.result) ~= "table" or not isCursor(state.result.index) then
      return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter result must name a candidate 0..2", {})
    end
  end
  if
    (state.phase == PHASE_PUBLISH or state.phase == PHASE_FADE_IN or state.phase == PHASE_DONE)
    and state.selectedIndex == nil
  then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter publication requires the selection", {})
  end
  if state.phase == PHASE_DONE and (not state.published or not state.closed or state.result == nil) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "completed starter state must hold its result", {})
  end
  if state.phase == PHASE_CHOOSE and state.published then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "starter choice must precede publication", {})
  end
  return nil
end

return ChooseStarterTask
