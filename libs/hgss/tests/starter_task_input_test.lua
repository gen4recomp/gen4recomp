-- Starter task input and fade sequencing: normalized UI events drive the
-- choice host without rerolling candidates, and the source fade legs run
-- around the modal whenever a screen service is composed. Cancelling the
-- task releases the host exactly once.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local TASK_MODULE = "libs.hgss.src.script.tasks.ChooseStarterTask"
local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local TRIO = { "CHIKORITA", "TOTODILE", "EEVEE" }

local function requireTask()
  local ok, task = pcall(require, TASK_MODULE)
  Assert.isTrue(ok, "the starter task owns candidate generation and selected publication")
  return assert(task)
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

local function providerFor(species)
  return {
    resolve = function()
      return { species[1], species[2], species[3] }
    end,
  }
end

-- Fuller fake host: a controller-backed choice surface with the production
-- host's open/close/status/focus/confirm/cancel shape.
local function controllerHost()
  local StarterChoiceController = assert(require("libs.hgss.src.ui.StarterChoiceController"))
  local host = { opened = 0, closed = 0, controller = nil }
  function host:open(cursor, candidates)
    self.opened = self.opened + 1
    Assert.isTrue(cursor >= 0 and cursor <= 2, "the task opens on a candidate cursor")
    Assert.equal(#candidates, 3, "the task hands all three candidates to the host")
    self.controller = StarterChoiceController.new({
      candidates = { candidates[1].species, candidates[2].species, candidates[3].species },
      initialCursor = cursor,
    })
  end
  function host:close()
    self.closed = self.closed + 1
    self.controller = nil
  end
  function host:status()
    if self.controller == nil then
      return nil
    end
    local controllerStatus = self.controller:status()
    if controllerStatus.state == "complete" then
      return { done = true, index = assert(self.doneIndex, "a completed choice names its candidate") }
    end
    return { done = false, cursor = controllerStatus.candidateIndex, mode = controllerStatus.mode }
  end
  function host:focus(index)
    self.controller:focus(index)
  end
  function host:confirm()
    local result = self.controller:confirm()
    if result ~= nil then
      self.doneIndex = result.candidate
    end
    return result
  end
  function host:cancel()
    return self.controller:cancel()
  end
  function host:hover(index)
    self.controller:hover(index)
  end
  function host:press(index)
    self.controller:press(index)
  end
  function host:release(index)
    local result = self.controller:release(index)
    if result ~= nil then
      self.doneIndex = result.candidate
    end
    return result
  end
  return host
end

local function screenFake()
  local screen = { started = {}, done = false }
  function screen:startFade(spec)
    self.started[#self.started + 1] = spec.direction
  end
  function screen:fadeDone()
    return self.done
  end
  return screen
end

local function ctxFor(service, host, events, screen)
  local services = { mons = service, starterProvider = providerFor(TRIO), starterChoice = host }
  if screen ~= nil then
    services.screen = screen
  end
  return {
    services = services,
    input = { uiEvents = events or {} },
    instance = { scriptId = "starter-input-fixture" },
  }
end

local function generate(task, service, host, screen)
  local ctx = ctxFor(service, host, {}, screen)
  local state = task.create({ node = { op = "choose_starter" } }, ctx)
  for _ = 1, 6 do
    local outcome = task.poll(state, ctx)
    if host.opened >= 1 and not outcome.complete then
      break
    end
  end
  Assert.equal(host.opened, 1, "the choice UI opens exactly once after generation")
  return state
end

function T.navigation_moves_the_cursor_without_rerolling()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  local state = generate(task, service, host, nil)
  local calls = service:capture().rng.calls

  local ctx = ctxFor(service, host, { { type = "navigate", direction = "right" } }, nil)
  local outcome = task.poll(state, ctx)
  Assert.isFalse(outcome.complete, "navigation never completes the task")
  Assert.equal(state.cursor, 1, "right moves the candidate cursor")
  Assert.equal(host.controller:status().candidateIndex, 1, "the host highlights the moved cursor")
  Assert.equal(service:capture().rng.calls, calls, "navigation draws nothing")

  local back = ctxFor(service, host, { { type = "navigate", direction = "left" } }, nil)
  task.poll(state, back)
  Assert.equal(state.cursor, 0, "left wraps the candidate cursor back")
end

function T.confirmation_requires_an_explicit_yes_through_events()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  local state = generate(task, service, host, nil)

  local opening = ctxFor(service, host, { { type = "confirm" } }, nil)
  local opened = task.poll(state, opening)
  Assert.isFalse(opened.complete, "the first confirm opens confirmation, not publication")
  Assert.equal(host.controller:status().mode, "confirming", "the host enters confirmation")

  local declining = ctxFor(service, host, { { type = "cancel" } }, nil)
  local declined = task.poll(state, declining)
  Assert.isFalse(declined.complete, "cancel never completes the story application")
  Assert.equal(host.controller:status().mode, "selecting", "cancel returns to selection")
  Assert.equal(service:partyCount(), 0, "cancel publishes nothing")

  local confirming = ctxFor(service, host, { { type = "confirm" } }, nil)
  task.poll(state, confirming)
  local accepting = ctxFor(service, host, { { type = "confirm" } }, nil)
  local outcome = task.poll(state, accepting)
  Assert.isTrue(outcome.complete, "an explicit yes completes the task")
  Assert.equal(service:partyCount(), 1, "exactly the highlighted mon enters the party")
  Assert.equal(service:partyMon(0).species, "CHIKORITA", "the party holds the cursor-highlighted choice")
  Assert.equal(host.closed, 1, "the modal closes exactly once on publication")
end

function T.fade_legs_run_around_the_modal_when_a_screen_is_composed()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  local screen = screenFake()
  local ctx = ctxFor(service, host, {}, screen)
  local state = task.create({ node = { op = "choose_starter" } }, ctx)

  local fading = task.poll(state, ctx)
  Assert.isFalse(fading.complete, "the task waits for the fade-out leg")
  Assert.deepEqual(screen.started, { "out" }, "the source order fades out before the choice")
  Assert.equal(host.opened, 0, "the modal stays hidden until the screen is dark")

  screen.done = true
  local opened = task.poll(state, ctx)
  Assert.isFalse(opened.complete, "the choice waits for confirmation")
  Assert.equal(host.opened, 1, "the modal opens once the fade completes")

  screen.done = false
  host:focus(2)
  host:confirm()
  host:focus(0)
  host:confirm()
  local published = task.poll(state, ctx)
  Assert.isFalse(published.complete, "the task waits for the fade-in leg after publication")
  Assert.deepEqual(screen.started, { "out", "in" }, "the field fades back in after insertion")
  Assert.equal(service:partyCount(), 1, "publication precedes the fade-in")

  screen.done = true
  local outcome = task.poll(state, ctx)
  Assert.isTrue(outcome.complete, "the task completes once the field is restored")
  Assert.equal(outcome.result.index, 2, "the result names the confirmed candidate")
end

function T.cancel_releases_an_open_host_exactly_once()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  local state = generate(task, service, host, nil)
  local ctx = ctxFor(service, host, {}, nil)
  task.cancel(state, "test teardown", ctx)
  Assert.equal(host.closed, 1, "cancelling an open choice closes the host")
  Assert.equal(service:partyCount(), 0, "cancelling publishes nothing")
  task.cancel(state, "test teardown", ctx)
  Assert.equal(host.closed, 1, "a second cancel never double-closes")
end

function T.invalid_task_state_fails_validation()
  local task = requireTask()
  Assert.isNil(
    task.validate({
      phase = "choose",
      candidates = {
        { species = "CHIKORITA", form = 0, personality = 1 },
        { species = "TOTODILE", form = 0, personality = 2 },
        { species = "EEVEE", form = 0, personality = 3 },
      },
      cursor = 0,
      opened = true,
      closed = false,
      published = false,
      selectedIndex = nil,
      fadeOutStarted = false,
      fadeInStarted = false,
      result = nil,
    }),
    "a well-formed choose phase validates"
  )
  Assert.isTrue(Errors.is(task.validate({ phase = "choose" })), "a phaseless husk never validates")
end

return { tests = T }
