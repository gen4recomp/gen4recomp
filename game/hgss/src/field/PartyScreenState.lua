-- The concrete party-screen application: the per-launch controller the
-- field application host steps while the party screen owns the tick. It
-- binds the shared pure view-mode controller to the live mon service
-- (view projection reads, swaps), resolves layout from the live viewport
-- every tick so resizes never lose semantic state, and returns the single
-- close result the host expects. Reordering is already in the service on
-- return, so the following-mon controller observes it immediately and
-- persistence follows the existing save boundaries.

local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")

---@class PartyScreenState
---@field _measureViewport fun(): number, number
---@field _lastWidth number?
---@field _lastHeight number?
---@field _controller PartyScreenController
local PartyScreenState = {}
PartyScreenState.__index = PartyScreenState

---@class PartyScreenState.Options
---@field service HgssMonService the live mon service
---@field measureViewport fun(): number, number the live viewport dimensions

---@param opts PartyScreenState.Options
---@return PartyScreenState
function PartyScreenState.new(opts)
  assert(type(opts) == "table", "the party screen requires options")
  local service = assert(opts.service, "the party screen requires the live mon service")
  assert(type(opts.measureViewport) == "function", "the party screen requires the viewport dimensions")
  assert(
    type(service.partyCount) == "function" and service:partyCount() > 0,
    "the party screen requires a non-empty party"
  )
  local self = setmetatable({
    _measureViewport = opts.measureViewport,
    _lastWidth = nil,
    _lastHeight = nil,
  }, PartyScreenState)
  local function refreshModel()
    return PartyScreenModel.build(service)
  end
  local function swapPartyMons(a, b)
    service:swapPartyMons(a, b)
  end
  local function resolveLayout()
    return self:_layout()
  end
  self._controller = PartyScreenController.new({
    mode = "view",
    model = {
      refresh = refreshModel,
    },
    swap = swapPartyMons,
    resolveLayout = resolveLayout,
  })
  return self
end

---@return PartyScreenLayoutResolved
function PartyScreenState:_layout()
  local width, height = self._measureViewport()
  return PartyScreenLayout.resolve({
    width = width,
    height = height,
    cancellable = self._controller:cancellable(),
  })
end

-- One fixed tick with the tick's UI events in viewport coordinates, the
-- same coordinate space the layout resolves in. A press held across a
-- viewport change must not activate a different post-change target, so a
-- dimension change cancels the pointer capture first.
---@param uiInput table[]
function PartyScreenState:updateFixed(uiInput)
  local width, height = self._measureViewport()
  if self._lastWidth ~= nil and (width ~= self._lastWidth or height ~= self._lastHeight) then
    self._controller:cancelPointerCapture()
  end
  self._lastWidth, self._lastHeight = width, height
  self._controller:updateFixed(uiInput)
end

-- The presentation snapshot: the controller status plus the current
-- resolved layout for hit testing and rendering. Fresh tables per call.
---@return table<string, unknown>
function PartyScreenState:status()
  local status = self._controller:status()
  if not status.open then
    return status
  end
  status.layout = self:_layout()
  return status
end

-- The host result contract: view mode only ever closes back to the menu.
---@return { kind: "close" }?
function PartyScreenState:takeResult()
  local result = self._controller:takeResult()
  if result == nil then
    return nil
  end
  assert(result.kind == "closed", "the party application only returns close")
  return { kind = "close" }
end

-- Idempotent release of the logical lifetime: a pending result is
-- discarded and no close is reported after disposal.
function PartyScreenState:dispose()
  self._controller:dispose()
end

return PartyScreenState
