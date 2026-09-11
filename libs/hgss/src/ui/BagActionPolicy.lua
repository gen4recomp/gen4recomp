-- Pure inventory-local action menu projection for the field bag. The menu
-- is a pure function of semantic facts -- the selected item key, its source
-- toss/registerability metadata, the pocket ordering, the pocket occupancy,
-- and the two-slot registration state. It never inspects renderer assets or
-- script opcodes, and it never names actions outside the inventory-local
-- set: toss, manual reorder, register/unregister, and cancel. Out-of-scope
-- item uses stay absent rather than disabled. A full registration omits
-- register: the audited source set offers no replacement selection and the
-- compiled overlays carry no replacement geometry. Pure module: no love,
-- no I/O.

---@class BagActionPolicyFacts
---@field itemKey string? the selected semantic item, nil when nothing is selected
---@field preventToss boolean the source item toss metadata
---@field registerable boolean whether the catalog marks the item field-registerable
---@field registered boolean whether the item currently holds a registration slot
---@field pocketOrdering string the catalog pocket ordering ("manual" or "native_id")
---@field pocketCount integer occupied slots in the selected pocket
---@field registeredCount integer currently occupied registration slots (0..2)

---@class BagActionPolicy
local BagActionPolicy = {}

---@param facts BagActionPolicyFacts
---@return { id: string, enabled: boolean }[]
function BagActionPolicy.actionsFor(facts)
  assert(type(facts) == "table", "the action policy needs its semantic facts")
  assert(
    facts.pocketOrdering == "manual" or facts.pocketOrdering == "native_id",
    "the action policy needs the catalog pocket ordering"
  )
  assert(
    type(facts.pocketCount) == "number" and facts.pocketCount % 1 == 0 and facts.pocketCount >= 0,
    "the action policy needs the pocket occupancy"
  )
  assert(
    type(facts.registeredCount) == "number"
      and facts.registeredCount % 1 == 0
      and facts.registeredCount >= 0
      and facts.registeredCount <= 2,
    "the action policy needs the registration occupancy"
  )
  local actions = {}
  if facts.itemKey ~= nil then
    assert(type(facts.itemKey) == "string" and facts.itemKey ~= "", "a selected action needs its item key")
    assert(type(facts.preventToss) == "boolean", "the action policy needs the source toss metadata")
    assert(type(facts.registerable) == "boolean", "the action policy needs registerability")
    assert(type(facts.registered) == "boolean", "the action policy needs the registration state")
    if not facts.preventToss then
      actions[#actions + 1] = { id = "toss", enabled = true }
    end
    if facts.pocketOrdering == "manual" and facts.pocketCount >= 2 then
      actions[#actions + 1] = { id = "move", enabled = true }
    end
    if facts.registerable then
      if facts.registered then
        actions[#actions + 1] = { id = "unregister", enabled = true }
      elseif facts.registeredCount < 2 then
        actions[#actions + 1] = { id = "register", enabled = true }
      end
    end
  end
  actions[#actions + 1] = { id = "cancel", enabled = true }
  return actions
end

-- Binds the pure projection to one live inventory service: the returned
-- closure reads the catalog definitions, the pocket occupancy, and the
-- registration list for the view's current selection. Composition owns this
-- binding; the controller only calls the closure with its refreshed view.
---@param service HgssBagService
---@return fun(view: table<string, unknown>): { id: string, enabled: boolean }[]
function BagActionPolicy.forService(service)
  assert(type(service) == "table", "the action policy binding needs the live bag service")
  assert(type(service.catalog) == "function", "the action policy binding needs the item catalog")
  assert(type(service.registeredItems) == "function", "the action policy binding needs registration reads")
  local function resolveForView(view)
    assert(type(view) == "table", "the action policy binding needs the refreshed browse view")
    assert(type(view.pocket) == "string", "the browse view names its pocket")
    local catalog = service:catalog()
    local pocketOrdering = catalog:pocket(view.pocket).ordering
    local registeredList = service:registeredItems()
    local registeredSet = {}
    for _, key in ipairs(registeredList) do
      registeredSet[key] = true
    end
    local selected = view.selected
    local facts = {
      itemKey = nil,
      preventToss = false,
      registerable = false,
      registered = false,
      pocketOrdering = pocketOrdering,
      pocketCount = type(view.slots) == "table" and #view.slots or 0,
      registeredCount = #registeredList,
    }
    if selected ~= nil then
      local itemKey = assert(selected.item, "selected slots carry their item key")
      local definition = catalog:item(itemKey)
      facts.itemKey = itemKey
      facts.preventToss = definition.preventToss == true
      facts.registerable = catalog:isRegisterable(itemKey)
      facts.registered = registeredSet[itemKey] == true
    end
    return BagActionPolicy.actionsFor(facts)
  end
  return resolveForView
end

return BagActionPolicy
