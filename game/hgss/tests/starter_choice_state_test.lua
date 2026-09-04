-- Production starter host: the modal surface the blocking task opens,
-- polls, and closes. It owns the pure controller, hands the three
-- pre-created candidates to presentation, and never touches graphics
-- resources outside draw/dispose, so headless compositions drive the full
-- choice without a GPU.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local STATE_MODULE = "game.hgss.src.starters.StarterChoiceState"
local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local function requireState()
  local ok, state = pcall(require, STATE_MODULE)
  Assert.isTrue(ok, "the starter state owns the modal choice surface")
  return assert(state)
end

local function openService(catalog, seed)
  local HgssMonService = assert(require(SERVICE_MODULE))
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
end

local function candidates(service)
  return {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  }
end

function T.open_status_and_close_follow_the_task_contract()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = StarterChoiceState.new({ catalog = catalog })
  Assert.isFalse(host:isActive(), "the host starts idle")

  host:open(0, candidates(service))
  Assert.isTrue(host:isActive(), "opening activates the modal surface")
  local waiting = host:status()
  Assert.equal(waiting.done, false, "the fresh choice waits for confirmation")
  Assert.equal(waiting.cursor, 0, "the choice opens on the task cursor")

  Assert.isNil(host:confirm(), "confirming a candidate opens confirmation, not publication")
  Assert.equal(host:status().done, false, "confirmation still waits for an explicit yes")
  host:focus(0)
  local result = host:confirm()
  Assert.deepEqual(result, { candidate = 0, accepted = true }, "yes publishes the highlighted candidate once")
  Assert.deepEqual(host:status(), { done = true, index = 0 }, "the completed choice reports its one-shot result")

  host:close()
  Assert.isFalse(host:isActive(), "closing releases the modal surface")
  Assert.isNil(host:status(), "a closed host reports no status")
end

function T.pointer_selection_enters_confirmation_without_publication()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = StarterChoiceState.new({ catalog = catalog })
  host:open(0, candidates(service))
  host:hover(2)
  Assert.equal(host:status().cursor, 2, "hover highlights without activating")
  host:press(1)
  Assert.isNil(host:release(2), "a drag across candidates commits nothing")
  Assert.equal(host:status().done, false, "a mismatched release stays in selection")
  host:press(1)
  Assert.isNil(host:release(1), "a matching release opens confirmation, not publication")
  Assert.isTrue(host:isActive(), "pointer selection never publishes early")
  host:close()
end

function T.resize_preserves_the_controller_without_a_layout()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = StarterChoiceState.new({ catalog = catalog })
  host:open(1, candidates(service))
  host:resize(390, 844)
  Assert.equal(host:status().cursor, 1, "recomputing layout preserves the cursor")
  Assert.isNil(host:hitTest(100000, 100000), "far points hit nothing")
  host:close()
  host:dispose()
end

return { tests = T }
