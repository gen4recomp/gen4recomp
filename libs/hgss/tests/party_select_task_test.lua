-- PartySelectTask: the blocking opcode-349 selection task. It drives the
-- shared pure select controller from scheduler input edges, completes with
-- the zero-based slot or the source cancellation value, mutates no party
-- state, and serializes only the named eligibility policy, cancel
-- permission, and cursor. Source sentinel translation lives here alone:
-- the controller only ever emits the semantic selected/cancelled records.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartySelectTask = require("libs.hgss.src.script.tasks.PartySelectTask")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xAAAAAAAA):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function give(service, species)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

local function request(overrides)
  local base = {
    mode = "select",
    initialSlot = 0,
    eligibility = { policy = "occupied" },
    allowCancel = true,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return { request = base }
end

local function context(service, input)
  return { services = { mons = service }, input = input or {}, tick = 7, instance = { locals = {} } }
end

function T.confirm_completes_with_the_zero_based_slot()
  local service = openService()
  give(service, "CHIKORITA")
  give(service, "TOTODILE")
  local revision = service:partyRevision()
  local state = PartySelectTask.create(request(), context(service))
  local outcome = PartySelectTask.poll(state, context(service, { pressedDirection = "south" }))
  Assert.isFalse(outcome.complete, "navigation alone never completes")
  local parked = context(service, { pressedAction = true })
  outcome = PartySelectTask.poll(state, parked)
  Assert.isTrue(outcome.complete, "confirm completes the selection")
  Assert.equal(parked.instance.locals.__party_selection, 1, "the task parks the zero-based slot on the instance")
  Assert.equal(service:partyRevision(), revision, "selection mutates no party state")
end

function T.cancel_completes_with_the_source_cancellation_value()
  local service = openService()
  give(service, "CHIKORITA")
  local state = PartySelectTask.create(request(), context(service))
  local parked = context(service, { pressedCancel = true })
  local outcome = PartySelectTask.poll(state, parked)
  Assert.isTrue(outcome.complete)
  Assert.equal(parked.instance.locals.__party_selection, 255, "cancel translates to the source result-command value")
  Assert.equal(service:partyCount(), 1, "cancel removes nothing")
end

function T.forbidden_cancel_stays_pending()
  local service = openService()
  give(service, "CHIKORITA")
  local state = PartySelectTask.create(request({ allowCancel = false }), context(service))
  local outcome = PartySelectTask.poll(state, context(service, { pressedCancel = true }))
  Assert.isFalse(outcome.complete, "a forbidden cancel completes nothing")
  Assert.isNil(PartySelectTask.validate(state), "the pending state stays serializable")
end

function T.resting_on_cancel_persists_the_last_slot()
  local service = openService()
  give(service, "CHIKORITA")
  local state = PartySelectTask.create(request(), context(service))
  for _ = 1, 5 do
    PartySelectTask.poll(state, context(service, { pressedDirection = "south" }))
  end
  Assert.equal(state.selectedSlot, 0, "the cancel affordance never enters the saved cursor")
  Assert.isNil(PartySelectTask.validate(state))
  local outcome = PartySelectTask.poll(state, context(service, { pressedCancel = true }))
  Assert.isTrue(outcome.complete, "a later poll still runs from the persisted cursor")
end

function T.state_serializes_the_policy_cursor_and_permission()
  local service = openService()
  give(service, "CHIKORITA")
  give(service, "TOTODILE")
  local state = PartySelectTask.create(request(), context(service))
  Assert.isNil(PartySelectTask.validate(state), "fresh task state validates")
  PartySelectTask.poll(state, context(service, { pressedDirection = "south" }))
  Assert.equal(state.selectedSlot, 1, "polls persist the cursor for save/restore")
  Assert.equal(state.policy, "occupied", "eligibility serializes as a named policy")
  Assert.isNil(PartySelectTask.validate(state), "moved task state still validates")
  Assert.isTrue(PartySelectTask.validate({ policy = "occupied", allowCancel = true }) ~= nil, "a cursor is required")
  Assert.isTrue(
    PartySelectTask.validate({ policy = "trade_only", allowCancel = true, selectedSlot = 0 }) ~= nil,
    "unknown policies fail validation"
  )
end

function T.unknown_policies_fail_before_opening()
  local service = openService()
  give(service, "CHIKORITA")
  Assert.throws(function()
    PartySelectTask.create(request({ eligibility = { policy = "trade_only" } }), context(service))
  end, "an unknown eligibility policy fails explicitly")
end

function T.missing_service_faults_loudly()
  local ok, err = pcall(function()
    PartySelectTask.create(request(), { services = {}, input = {}, tick = 1 })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal((err --[[@as Errors.Error]]).code, ScriptErrors.SCRIPT_SERVICE_MISSING)
end

return { tests = T }
