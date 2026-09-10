-- Starter task input and fade sequencing: normalized UI events drive the
-- retail choice host without rerolling candidates, and the source fade legs
-- run around the modal whenever a screen service is composed. Inspecting
-- never publishes; the zoom path settles into confirmation before the final
-- lock; cancelling the task releases the host exactly once.

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

-- Fuller fake host: the retail controller behind the production host's
-- open/close/status/move/focus/confirm/cancel/update shape. The runtime
-- advances the host once per fixed tick; tests settle it explicitly between
-- polls, mirroring production.
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
  function host:update()
    if self.controller ~= nil then
      -- The fake owns no playback clocks, so it settles transitions with an
      -- all-complete observation, mirroring a presentation whose every gate
      -- has opened. Production hosts supply the real per-tick observation.
      self.controller:update({
        rotationComplete = true,
        cameraComplete = true,
        ballArcComplete = true,
        smallWobbleReady = true,
        infoFadeComplete = true,
        machineFadeComplete = true,
      })
    end
  end
  function host:status()
    if self.controller == nil then
      return nil
    end
    local snapshot = self.controller:snapshot()
    if snapshot.done then
      return { done = true, index = assert(snapshot.result, "a completed choice names its candidate").index }
    end
    return { done = false, cursor = snapshot.selection }
  end
  function host:focus(index)
    self.controller:focus(index)
  end
  function host:move(direction)
    self.controller:move(direction)
  end
  function host:confirm()
    return self.controller:confirm()
  end
  function host:cancel()
    return self.controller:cancel()
  end
  function host:tap(index)
    return self.controller:tap(index)
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

local function settle(host, bound)
  for _ = 1, bound or 64 do
    host:update()
    local status = host:status()
    if status ~= nil and status.done then
      return
    end
    local snapshot = host.controller:snapshot()
    if snapshot.transition == "idle" then
      return
    end
  end
end

function T.navigation_rotates_one_step_and_settles_without_rerolling()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  local state = generate(task, service, host, nil)
  local calls = service:capture().rng.calls

  local ctx = ctxFor(service, host, { { type = "navigate", direction = "right" } }, nil)
  local outcome = task.poll(state, ctx)
  Assert.isFalse(outcome.complete, "navigation never completes the task")
  Assert.equal(host:status().cursor, 0, "rotation waits for its transition instead of jumping")
  Assert.equal(service:capture().rng.calls, calls, "navigation draws nothing")

  settle(host)
  Assert.equal(host:status().cursor, 1, "a settled right step advances one ball")

  local back = ctxFor(service, host, { { type = "navigate", direction = "left" } }, nil)
  task.poll(state, back)
  settle(host)
  Assert.equal(host:status().cursor, 0, "a settled left step returns one ball")
end

function T.confirmation_walks_inspect_zoom_lock_through_events()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  local state = generate(task, service, host, nil)

  local opening = ctxFor(service, host, { { type = "confirm" } }, nil)
  local opened = task.poll(state, opening)
  Assert.isFalse(opened.complete, "the first confirm inspects instead of publishing")
  Assert.equal(host.controller:snapshot().selectionState, "inspect", "the host enters inspection")

  local declining = ctxFor(service, host, { { type = "cancel" } }, nil)
  local declined = task.poll(state, declining)
  Assert.isFalse(declined.complete, "cancel never completes the story application")
  Assert.equal(service:partyCount(), 0, "cancel publishes nothing")

  local zooming = ctxFor(service, host, { { type = "confirm" } }, nil)
  task.poll(state, zooming)
  local locking = ctxFor(service, host, { { type = "confirm" } }, nil)
  local locked = task.poll(state, locking)
  Assert.isFalse(locked.complete, "the lock reports only after its exit transition settles")
  settle(host)
  Assert.equal(host.controller:snapshot().selectionState, "confirm", "the zoom path settles into confirmation")

  local backingOut = ctxFor(service, host, { { type = "cancel" } }, nil)
  local backedOut = task.poll(state, backingOut)
  Assert.isFalse(backedOut.complete, "backing out of confirmation publishes nothing")
  settle(host)
  Assert.equal(host.controller:snapshot().selectionState, "inspect", "cancel returns to inspection")

  local rezoning = ctxFor(service, host, { { type = "confirm" } }, nil)
  task.poll(state, rezoning)
  settle(host)
  local final = ctxFor(service, host, { { type = "confirm" } }, nil)
  local outcome = task.poll(state, final)
  Assert.isFalse(outcome.complete, "the final activation starts the lock, not the report")
  settle(host)
  local published = task.poll(state, ctxFor(service, host, {}, nil))
  Assert.isTrue(published.complete, "the settled lock completes the task")
  Assert.equal(service:partyCount(), 1, "exactly the highlighted mon enters the party")
  Assert.equal(service:partyMon(0).species, "CHIKORITA", "the party holds the cursor-highlighted choice")
  Assert.equal(host.closed, 1, "the modal closes exactly once on publication")
end

function T.pointer_taps_rotate_toward_the_tapped_ball()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  function host:hitTest(x, _)
    if x == 10 then
      return { kind = "ball", index = 1 }
    end
    return nil
  end
  local state = generate(task, service, host, nil)

  local tap = ctxFor(service, host, {
    { type = "pointer_down", x = 10, y = 4 },
    { type = "pointer_up", x = 10, y = 4 },
  }, nil)
  local outcome = task.poll(state, tap)
  Assert.isFalse(outcome.complete, "tapping another ball never publishes")
  settle(host)
  Assert.equal(host:status().cursor, 1, "the settled tap selects the tapped ball")

  local away = ctxFor(service, host, {
    { type = "pointer_down", x = 900, y = 900 },
    { type = "pointer_up", x = 900, y = 900 },
  }, nil)
  task.poll(state, away)
  settle(host)
  Assert.equal(host:status().cursor, 1, "tapping outside keeps the ball")
end

function T.pointer_down_on_another_ball_rotates_without_release()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  function host:hitTest(x, _)
    if x == 10 then
      return { kind = "ball", index = 1 }
    end
    return nil
  end
  local state = generate(task, service, host, nil)

  local tap = ctxFor(service, host, {
    { type = "pointer_down", x = 10, y = 4 },
  }, nil)
  local outcome = task.poll(state, tap)
  Assert.isFalse(outcome.complete, "tapping another ball never publishes")
  local started = host.controller:snapshot()
  Assert.equal(started.transition, "rotate", "the press edge starts rotation without waiting for release")
  Assert.equal(started.direction, "right", "the press edge rotates toward the tapped ball")
  Assert.equal(started.selection, 0, "semantic selection waits for rotation settlement")

  local lift = ctxFor(service, host, {
    { type = "pointer_up", x = 10, y = 4 },
  }, nil)
  task.poll(state, lift)
  local afterLift = host.controller:snapshot()
  Assert.equal(afterLift.transition, "rotate", "release after the press edge starts no second transition")

  settle(host)
  Assert.equal(host:status().cursor, 1, "the settled press-edge tap selects the tapped ball")
end

function T.pointer_move_and_release_without_press_change_nothing()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  function host:hitTest(x, _)
    if x == 10 then
      return { kind = "ball", index = 1 }
    elseif x == 11 then
      return { kind = "ball", index = 2 }
    end
    return nil
  end
  local state = generate(task, service, host, nil)
  local before = host.controller:snapshot()

  local moves = ctxFor(service, host, {
    { type = "pointer_move", x = 10, y = 4 },
    { type = "pointer_move", x = 11, y = 4 },
  }, nil)
  task.poll(state, moves)
  local afterMove = host.controller:snapshot()
  Assert.equal(afterMove.selection, before.selection, "pointer movement never reselects")
  Assert.equal(afterMove.selectionState, before.selectionState, "pointer movement never advances the choice flow")
  Assert.equal(afterMove.transition, "idle", "pointer movement starts no transition")

  local lift = ctxFor(service, host, {
    { type = "pointer_up", x = 11, y = 4 },
  }, nil)
  task.poll(state, lift)
  local afterLift = host.controller:snapshot()
  Assert.equal(afterLift.selection, before.selection, "release without a press edge changes nothing")
  Assert.equal(afterLift.selectionState, before.selectionState, "release without a press edge advances nothing")
  Assert.equal(afterLift.transition, "idle", "release without a press edge starts no transition")
  Assert.equal(host:status().cursor, 0, "the cursor stays on the opening ball")
end

function T.pointer_down_on_current_ball_advances_choice_without_release()
  local task = requireTask()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local host = controllerHost()
  function host:hitTest(x, _)
    if x == 11 then
      return { kind = "ball", index = host.controller:snapshot().selection }
    end
    return nil
  end
  local state = generate(task, service, host, nil)

  local firstTap = ctxFor(service, host, {
    { type = "pointer_down", x = 11, y = 4 },
  }, nil)
  task.poll(state, firstTap)
  Assert.equal(
    host.controller:snapshot().selectionState,
    "inspect",
    "the press edge on the current ball inspects without waiting for release"
  )
  local firstLift = ctxFor(service, host, {
    { type = "pointer_up", x = 11, y = 4 },
  }, nil)
  task.poll(state, firstLift)
  Assert.equal(host.controller:snapshot().selectionState, "inspect", "release after inspection changes nothing")

  local secondTap = ctxFor(service, host, {
    { type = "pointer_down", x = 11, y = 4 },
  }, nil)
  task.poll(state, secondTap)
  Assert.equal(
    host.controller:snapshot().transition,
    "zoomIn",
    "the press edge on the inspected ball starts confirmation without release"
  )
  settle(host)
  Assert.equal(host.controller:snapshot().selectionState, "confirm", "the zoom path settles into confirmation")

  local confirmTap = ctxFor(service, host, {
    { type = "pointer_down", x = 11, y = 4 },
  }, nil)
  local locking = task.poll(state, confirmTap)
  Assert.isFalse(locking.complete, "the final press edge starts the lock, not the report")
  Assert.equal(host.controller:snapshot().transition, "lockExit", "confirmation press locks on the press edge")
  settle(host)
  local published = task.poll(state, ctxFor(service, host, {}, nil))
  Assert.isTrue(published.complete, "the settled lock completes the task")
  Assert.equal(service:partyCount(), 1, "exactly the highlighted mon enters the party")
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
  Assert.equal(host.controller:snapshot().selectionState, "inspect", "the first activation inspects")
  host:confirm()
  settle(host)
  Assert.equal(host.controller:snapshot().selectionState, "confirm", "the zoom path settles into confirmation")
  host:confirm()
  settle(host)
  Assert.isTrue(host:status().done, "the settled lock reports the confirmed candidate")
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
