-- The party-screen view projection: one fresh immutable six-slot model per
-- build. Occupied slots carry the nickname-or-species display name, the
-- service-derived level and max HP, the personality-derived gender, live
-- current HP and its fraction, the source status key, and the catalog (or
-- egg) icon key. Empty slots carry position and occupancy only. Every
-- derived value comes from its domain owner (Mon, Personality, the
-- HgssMonService derivation seam, the mon catalog); this module copies no
-- stat, level, gender, or icon formula. Pure module: no love, no I/O.

local Mon = require("libs.mons.src.Mon")
local MonCache = require("libs.assets.src.MonCache")
local Personality = require("libs.mons.src.gen4.Personality")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")

---@class PartyScreenModel
local PartyScreenModel = {}

PartyScreenModel.SLOT_COUNT = 6

---@param service HgssMonService the live mon service (partyCount/partyRevision/partyMon/partyMonDerived/catalog)
---@param mon table<string, unknown> an owned party mon copy
---@return string
local function iconKeyFor(service, mon)
  if mon.isEgg then
    return MonCache.iconSelector(mon.species, mon.form, true)
  end
  return service:catalog():iconSelection(mon)
end

---@param service HgssMonService
---@param slot0 integer
---@param isEligible fun(slot: integer): boolean
---@return table<string, unknown>
local function projectSlot(service, slot0, isEligible)
  local record = { slot = slot0, occupied = false, eligible = false }
  if slot0 >= service:partyCount() then
    return record
  end
  local mon = service:partyMon(slot0)
  local derived = service:partyMonDerived(slot0)
  local catalog = service:catalog()
  local species = catalog:species(mon.species)
  assert(type(derived.maxHp) == "number" and derived.maxHp > 0, "party max HP derives positive")
  assert(mon.condition.currentHp <= derived.maxHp, "current HP cannot exceed derived max HP")
  record.occupied = true
  record.eligible = isEligible(slot0) == true
  record.iconKey = iconKeyFor(service, mon)
  record.displayName = Mon.displayName(mon, catalog)
  record.level = derived.level
  record.gender = Personality.gender(species.genderRatio, mon.personality)
  record.status = PartyScreenTheme.statusKey(mon.condition.status, mon.condition.currentHp)
  record.currentHp = mon.condition.currentHp
  record.maxHp = derived.maxHp
  record.hpFraction = mon.condition.currentHp / derived.maxHp
  return record
end

---@param service HgssMonService the live mon service
---@param opts { isEligible?: fun(slot: integer): boolean }?
---@return { revision: integer, slots: table[] }
function PartyScreenModel.build(service, opts)
  assert(type(service) == "table", "the party view needs the live mon service")
  assert(type(service.partyCount) == "function", "the party view needs the party count")
  assert(type(service.partyRevision) == "function", "the party view needs the party revision")
  assert(type(service.partyMon) == "function", "the party view needs party reads")
  assert(type(service.partyMonDerived) == "function", "the party view needs derived level and max HP")
  assert(type(service.catalog) == "function", "the party view needs the mon catalog")
  opts = opts or {}
  assert(type(opts) == "table", "the party view options must be a record")
  local isEligible = opts.isEligible
  if isEligible == nil then
    local function allEligible(_)
      return true
    end
    isEligible = allEligible
  end
  assert(type(isEligible) == "function", "slot eligibility must be a predicate")
  local slots = {}
  for slot0 = 0, PartyScreenModel.SLOT_COUNT - 1 do
    slots[slot0 + 1] = projectSlot(service, slot0, isEligible)
  end
  return { revision = service:partyRevision(), slots = slots }
end

return PartyScreenModel
