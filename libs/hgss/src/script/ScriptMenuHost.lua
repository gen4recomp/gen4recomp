-- Script menu host resolves source-faithful script menu builders into
-- controller-ready requests. Builders belong to their ScriptInstance; this
-- service has no script-persistent state or love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

---@class ScriptMenuHost
---@field _provider FieldMessageProvider
---@field _resolveText fun(message: unknown): table<string, unknown>|nil
local ScriptMenuHost = {}
ScriptMenuHost.__index = ScriptMenuHost

---@param value unknown
---@param name string
local function assertInteger(value, name)
  assert(
    type(value) == "number"
      and value == value
      and value ~= math.huge
      and value ~= -math.huge
      and value == math.floor(value),
    name .. " must be a finite integer"
  )
end

---@param source unknown
---@return integer
local function messageBank(source)
  if source == "standard" then
    return MenuProtocol.STANDARD_MESSAGE_BANK
  end
  assert(type(source) == "table" and source.kind == "script", "menu message source is invalid")
  assertInteger(source.bank, "script menu message bank")
  return source.bank
end

---@param self ScriptMenuHost
---@param source unknown
---@param messageId integer
---@return table<string, unknown>
local function resolveMessage(self, source, messageId)
  local bankId = messageBank(source)
  local acquired, bankErr = self._provider:acquireBank(bankId)
  if not acquired then
    local context = { bankId = bankId, messageId = messageId, cause = bankErr and bankErr.context }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED, "menu message bank is unavailable", context)
  end
  local template, templateErr = self._provider:get(bankId, messageId)
  if not template then
    self._provider:releaseBank(bankId)
    local context = { bankId = bankId, messageId = messageId, cause = templateErr and templateErr.context }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED, "menu message is unavailable", context)
  end
  local ok, formatted = pcall(self._provider.format, self._provider, template, {})
  self._provider:releaseBank(bankId)
  if not ok then
    error(formatted)
  end
  return formatted
end

local function resolveSemanticText(self, message)
  if type(message) == "table" or (type(message) == "string" and message:match("^msg%.hgss%.%d+%.%d+$")) then
    local resolveText = self._resolveText
    if resolveText == nil then
      local context = { message = message }
      ---@cast context Errors.Context
      Errors.raise(
        ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED,
        "semantic menu message resolution is unavailable",
        context
      )
    end
    ---@cast resolveText fun(message: unknown): table<string, unknown>|nil
    local text = resolveText(message)
    if type(text) ~= "table" or type(text.text) ~= "string" then
      local context = { message = message }
      ---@cast context Errors.Context
      Errors.raise(
        ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED,
        "semantic menu message did not resolve to text",
        context
      )
    end
    return text
  end
  return { text = message }
end

---@param opts table<string, unknown> { provider, resolveText?: fun(message: unknown): table<string, unknown> }
---@return ScriptMenuHost
function ScriptMenuHost.new(opts)
  assert(type(opts) == "table" and opts.provider, "script menu host requires a message provider")
  assert(
    opts.resolveText == nil or type(opts.resolveText) == "function",
    "script menu text resolver must be a function"
  )
  return setmetatable({
    _provider = opts.provider,
    _resolveText = opts.resolveText,
  }, ScriptMenuHost)
end

-- Publishes one semantic mod menu without entering the imported-HGSS builder
-- state. A project may supply its dialogue resolver; bare strings remain
-- useful as local text in isolated tools and tests.
---@param spec table<string, unknown>
---@return unknown menuController
function ScriptMenuHost:choose(spec)
  assert(type(spec) == "table" and type(spec.items) == "table", "semantic menu specification is invalid")
  local items = {}
  for luaIndex, item in ipairs(spec.items) do
    local text = resolveSemanticText(self, item.text)
    assert(type(text) == "table", "semantic menu text resolver returned an invalid message")
    items[luaIndex] = {
      text = text,
      message = item.text,
      value = item.value,
      metadata = item.metadata,
    }
  end
  return {
    items = items,
    cancellable = spec.cancellable,
    cancelValue = spec.cancelValue,
    initialCursor = spec.initialCursor,
    placementPreference = spec.placement,
    result = spec.result,
  }
end

-- Starts one source-faithful builder. `messageSource` deliberately retains
-- the distinction between standard/global and current-script message banks.
---@param spec table<string, unknown>
---@return table<string, unknown> builder
function ScriptMenuHost:beginMenu(spec)
  assert(type(spec) == "table", "script menu specification must be a table")
  messageBank(spec.messageSource)
  assert(type(spec.sourcePlacement) == "table", "script menu source placement is required")
  assert(
    spec.sourcePlacement.system == MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT,
    "script menu placement system is invalid"
  )
  assertInteger(spec.sourcePlacement.x, "script menu source x")
  assertInteger(spec.sourcePlacement.y, "script menu source y")
  assertInteger(spec.initialCursor, "script menu initial cursor")
  assert(type(spec.cancellable) == "boolean", "script menu cancellable must be a boolean")
  assert(spec.result ~= nil, "script menu result target is required")
  local messageSource = spec.messageSource
  if type(messageSource) == "table" then
    messageSource = { kind = "script", bank = messageSource.bank }
  end
  local cancelValue = spec.cancelValue
  if cancelValue == nil and spec.cancellable then
    cancelValue = MenuProtocol.CANCEL_RESULT
  end
  return {
    messageSource = messageSource,
    sourcePlacement = {
      system = spec.sourcePlacement.system,
      x = spec.sourcePlacement.x,
      y = spec.sourcePlacement.y,
    },
    initialCursor = spec.initialCursor,
    cancellable = spec.cancellable,
    -- HGSS's list-menu cancellation result. This compatibility
    -- detail stays at the imported-script boundary; public menu APIs supply
    -- their cancellation value explicitly.
    cancelValue = cancelValue,
    result = spec.result,
    items = {},
  }
end

---@param builder table<string, unknown>|nil imported HGSS menu builder owned by a ScriptInstance
---@param item table<string, unknown> { messageId, vanillaMetadata, value }
function ScriptMenuHost:addItem(builder, item)
  if builder == nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_NOT_INITIALIZED, "script menu item added without a menu builder")
  end
  ---@cast builder table<string, unknown>
  assert(type(item) == "table", "script menu item must be a table")
  assertInteger(item.messageId, "script menu message id")
  assert(item.vanillaMetadata ~= nil, "script menu vanilla metadata is required")
  assert(item.value ~= nil, "script menu result value is required")
  builder.items[#builder.items + 1] = {
    text = { source = builder.messageSource, id = item.messageId },
    vanillaMetadata = item.vanillaMetadata,
    value = item.value,
  }
end

-- Resolves every builder entry before publication. Bank acquisitions are
-- released after each lookup; on any failure no controller request is made
-- and the builder remains available for diagnostic inspection by its caller.
---@param builder table<string, unknown>|nil imported HGSS menu builder owned by a ScriptInstance
---@return unknown menuController
function ScriptMenuHost:execute(builder)
  if builder == nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_NOT_INITIALIZED, "script menu executed without a menu builder")
  end
  ---@cast builder table<string, unknown>
  if #builder.items == 0 then
    Errors.raise(ScriptErrors.SCRIPT_MENU_EMPTY, "script menu has no items")
  end
  local items = {}
  for luaIndex, item in ipairs(builder.items) do
    items[luaIndex] = {
      text = resolveMessage(self, item.text.source, item.text.id),
      message = item.text,
      vanillaMetadata = item.vanillaMetadata,
      value = item.value,
    }
  end
  local request = {
    items = items,
    sourcePlacement = builder.sourcePlacement,
    initialCursor = builder.initialCursor,
    cancellable = builder.cancellable,
    cancelValue = builder.cancelValue,
    result = builder.result,
  }
  return request
end

return ScriptMenuHost
