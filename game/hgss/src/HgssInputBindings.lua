-- Game-local physical button alias authority for HGSS A/confirm, B/cancel,
-- and X/menu semantics. Field gameplay, the Oak-hosted naming screen, and
-- the Main Menu share this module so their keyboard aliases cannot drift
-- apart again. Gamepad buttons keep their existing host mapping (south is
-- action, east is cancel) and are not part of these keyboard lookups.

local FieldPresentation = require("data.manifests.field_presentation")

---@class HgssInputBindings
local HgssInputBindings = {}

---@param list table<string, unknown>?
---@param what string
---@return table<string, boolean>
local function buildSet(list, what)
  assert(type(list) == "table", "field presentation input " .. what .. " aliases are required")
  local set = {}
  for _, key in ipairs(list) do
    assert(type(key) == "string" and key ~= "", "field presentation input " .. what .. " aliases must be keys")
    set[key] = true
  end
  return set
end

-- The bindings are read from the manifest on every lookup so the authority
-- always reflects the current presentation: tests and development harnesses
-- may rebind the manifest, and a require-time snapshot would silently keep
-- serving the stale aliases. The lists stay tiny, so rebuilding per lookup
-- costs nothing measurable on the input path.
---@param what string
---@return table<string, boolean>
local function currentKeys(what)
  local input = assert(
    type(FieldPresentation) == "table" and FieldPresentation.input,
    "field presentation input bindings are required"
  )
  assert(type(input) == "table", "field presentation input bindings are required")
  return buildSet(assert(input[what], "field presentation input " .. what .. " aliases are required"), what)
end

---@param key string
---@return boolean
function HgssInputBindings.isActionKey(key)
  return currentKeys("action")[key] == true
end

---@param key string
---@return boolean
function HgssInputBindings.isCancelKey(key)
  return currentKeys("cancel")[key] == true
end

---@param key string
---@return boolean
function HgssInputBindings.isMenuKey(key)
  return currentKeys("menu")[key] == true
end

---@return table<string, boolean> a fresh copy; callers may not mutate the authority
function HgssInputBindings.actionKeys()
  local copy = {}
  for key in pairs(currentKeys("action")) do
    copy[key] = true
  end
  return copy
end

---@return table<string, boolean> a fresh copy; callers may not mutate the authority
function HgssInputBindings.cancelKeys()
  local copy = {}
  for key in pairs(currentKeys("cancel")) do
    copy[key] = true
  end
  return copy
end

---@return table<string, boolean> a fresh copy; callers may not mutate the authority
function HgssInputBindings.menuKeys()
  local copy = {}
  for key in pairs(currentKeys("menu")) do
    copy[key] = true
  end
  return copy
end

return HgssInputBindings
