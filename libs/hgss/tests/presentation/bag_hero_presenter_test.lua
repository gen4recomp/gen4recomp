-- Pocket-indexed hero animation state for the field bag: which pose and
-- pattern clips the upper pane presents per pocket, advanced on the fixed
-- presentation cadence. Covers pocket selection, clip resolution for all
-- eight pockets, deterministic frame advance, and rejection of unknown
-- pockets. Pure state; mesh acquisition stays with the draw stage.

local Assert = require("tests.support.Assert")
local BagHeroPresenter = require("libs.hgss.src.presentation.BagHeroPresenter")

local T = {}

local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local function manifest()
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] =
      { pocket = pocket, pose = "pocket." .. pocket .. ".pose", pattern = "pocket." .. pocket .. ".pattern" }
  end
  local function framingRecord(angleXDegrees, angleYDegrees, distance, modelY)
    return {
      angleXDegrees = angleXDegrees,
      angleYDegrees = angleYDegrees,
      distance = distance,
      modelY = modelY,
    }
  end
  local function pocketRecords(base)
    local records = {}
    for index, pocket in ipairs(POCKETS) do
      records[pocket] = framingRecord(base + index, base + 2 * index, 100 + 10 * index, 5 + index)
    end
    return records
  end
  return {
    hero = {
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
      presentation = {
        framing = {
          transitionTicks = 7,
          baseline = { male = framingRecord(0, 0, 100, 5), female = framingRecord(1, 1, 110, 6) },
          byGender = { male = pocketRecords(10), female = pocketRecords(20) },
        },
      },
    },
  }
end

function T.defaults_to_the_first_pocket_state()
  local presenter = BagHeroPresenter.new({ manifest = manifest(), gender = "male" })
  local status = presenter:status()
  Assert.equal(status.pocket, "items")
  Assert.equal(status.pose, "pocket.items.pose")
  Assert.equal(status.pattern, "pocket.items.pattern")
  Assert.equal(status.frame, 0)
end

function T.every_pocket_resolves_its_clips_and_restarts_the_frame()
  local presenter = BagHeroPresenter.new({ manifest = manifest(), gender = "male" })
  presenter:updateFixed()
  presenter:updateFixed()
  for _, pocket in ipairs(POCKETS) do
    presenter:selectPocket(pocket)
    local status = presenter:status()
    Assert.equal(status.pocket, pocket)
    Assert.equal(status.pose, "pocket." .. pocket .. ".pose")
    Assert.equal(status.pattern, "pocket." .. pocket .. ".pattern")
    Assert.equal(status.frame, 0, "a pocket switch restarts its animation")
  end
end

function T.frames_advance_on_the_fixed_cadence_only()
  local presenter = BagHeroPresenter.new({ manifest = manifest(), gender = "male" })
  presenter:selectPocket("balls")
  for _ = 1, 5 do
    presenter:updateFixed()
  end
  Assert.equal(presenter:status().frame, 5, "five fixed ticks advance five frames")
  Assert.equal(presenter:status().pocket, "balls", "advancing never changes the selected state")
end

function T.unknown_pockets_are_programming_errors()
  local presenter = BagHeroPresenter.new({ manifest = manifest(), gender = "male" })
  Assert.throws(function()
    presenter:selectPocket("BOGUS_POCKET")
  end)
  Assert.equal(presenter:status().pocket, "items", "a rejected switch leaves the pocket untouched")
end

local function framingRecord(angleXDegrees, angleYDegrees, distance, modelY)
  return {
    angleXDegrees = angleXDegrees,
    angleYDegrees = angleYDegrees,
    distance = distance,
    modelY = modelY,
  }
end

-- Synthetic pocket-aware framing with easily distinguished values: the male
-- table wraps the yaw from baseline 350 to items 10 over the short +20 arc,
-- and steps items yaw 10 to balls yaw 190 across the exact -180 direction.
local function framingManifest()
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] =
      { pocket = pocket, pose = "pocket." .. pocket .. ".pose", pattern = "pocket." .. pocket .. ".pattern" }
  end
  local male = {
    items = framingRecord(20, 10, 200, 15),
    medicine = framingRecord(100, 250, 400, 35),
    balls = framingRecord(60, 190, 300, 25),
    tmhm = framingRecord(120, 300, 500, 45),
    berries = framingRecord(140, 30, 600, 55),
    mail = framingRecord(160, 90, 700, 65),
    battle_items = framingRecord(180, 150, 800, 75),
    key_items = framingRecord(200, 210, 900, 85),
  }
  local female = {
    items = framingRecord(50, 60, 250, 18),
    medicine = framingRecord(110, 260, 410, 38),
    balls = framingRecord(70, 200, 310, 28),
    tmhm = framingRecord(130, 310, 510, 48),
    berries = framingRecord(150, 40, 610, 58),
    mail = framingRecord(170, 100, 710, 68),
    battle_items = framingRecord(190, 160, 810, 78),
    key_items = framingRecord(210, 220, 910, 88),
  }
  return {
    hero = {
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
      presentation = {
        framing = {
          transitionTicks = 7,
          baseline = { male = framingRecord(10, 350, 100, 5), female = framingRecord(30, 40, 150, 8) },
          byGender = { male = male, female = female },
        },
      },
    },
  }
end

---@param presenter BagHeroPresenter
---@param what string
---@return { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }
local function framingOf(presenter, what)
  local status = presenter:status()
  return assert(status.framing, what .. " carries its interpolated framing")
end

-- Angles compare by arc so the normalized degree domain stays an
-- implementation detail; distances and heights compare exactly.
---@param actual { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }
---@param expected { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }
---@param what string
local function assertFraming(actual, expected, what)
  local function arc(actualDegrees, expectedDegrees, label)
    local delta = ((actualDegrees - expectedDegrees + 180) % 360) - 180
    Assert.isTrue(
      math.abs(delta) <= 1e-9,
      what
        .. " "
        .. label
        .. " follows the shortest arc, got "
        .. tostring(actualDegrees)
        .. " want "
        .. tostring(expectedDegrees)
    )
  end
  arc(actual.angleXDegrees, expected.angleXDegrees, "pitch")
  arc(actual.angleYDegrees, expected.angleYDegrees, "yaw")
  Assert.near(actual.distance, expected.distance, 1e-9, what .. " interpolates its distance linearly")
  Assert.near(actual.modelY, expected.modelY, 1e-9, what .. " interpolates its model height linearly")
end

-- The framing transition state machine: construction opens at the baseline
-- and settles the default pocket over seven fixed ticks, a mid-transition
-- request waits behind exactly one pending slot that a later request
-- replaces, and reselecting the settled pocket restarts the pose frame
-- without a redundant framing transition.
function T.queued_transitions_interpolate_shortest_arc_without_interruption()
  local fixture = framingManifest()
  local male = assert(fixture.hero.presentation.framing.byGender.male, "the fixture carries the male pocket framing")
  local baseline = assert(fixture.hero.presentation.framing.baseline.male, "the fixture carries the male baseline")
  local presenter = BagHeroPresenter.new({ manifest = fixture, gender = "male" })
  assertFraming(framingOf(presenter, "construction"), baseline, "construction opens at the neutral baseline")
  Assert.equal(presenter:status().pocket, "items", "construction still defaults to the first pocket")
  for _ = 1, 3 do
    presenter:updateFixed()
  end
  assertFraming(
    framingOf(presenter, "the opening transition"),
    framingRecord(10 + 10 * 3 / 7, 350 + 20 * 3 / 7, 100 + 100 * 3 / 7, 5 + 10 * 3 / 7),
    "the opening midpoint wraps the yaw over the short arc"
  )
  for _ = 1, 4 do
    presenter:updateFixed()
  end
  assertFraming(framingOf(presenter, "the settled pocket"), male.items, "seven ticks settle the requested pocket")
  local female = BagHeroPresenter.new({ manifest = fixture, gender = "female" })
  local femaleBaseline =
    assert(fixture.hero.presentation.framing.baseline.female, "the fixture carries the female baseline")
  local femalePockets =
    assert(fixture.hero.presentation.framing.byGender.female, "the fixture carries the female pocket framing")
  assertFraming(framingOf(female, "the female construction"), femaleBaseline, "construction selects the gender table")
  for _ = 1, 7 do
    female:updateFixed()
  end
  assertFraming(
    framingOf(female, "the settled female pocket"),
    assert(femalePockets.items, "the fixture carries the female items framing"),
    "the female table settles its own pocket record"
  )
  presenter:selectPocket("balls")
  Assert.equal(presenter:status().frame, 0, "a pocket switch still restarts the pose animation")
  for _ = 1, 3 do
    presenter:updateFixed()
  end
  assertFraming(
    framingOf(presenter, "the interrupted transition"),
    framingRecord(20 + 40 * 3 / 7, 10 - 180 * 3 / 7, 200 + 100 * 3 / 7, 15 + 10 * 3 / 7),
    "the midpoint takes the deterministic exact-180 direction"
  )
  presenter:selectPocket("medicine")
  presenter:selectPocket("berries")
  for _ = 1, 2 do
    presenter:updateFixed()
  end
  local ongoing = framingOf(presenter, "the queued transition")
  Assert.near(
    ongoing.distance,
    200 + 100 * 5 / 7,
    1e-9,
    "a queued request never interrupts the in-flight interpolation"
  )
  for _ = 1, 2 do
    presenter:updateFixed()
  end
  assertFraming(
    framingOf(presenter, "the completed transition"),
    male.balls,
    "the in-flight transition completes without a jump to the queued pocket"
  )
  presenter:updateFixed()
  local resumed = framingOf(presenter, "the resumed transition")
  Assert.near(
    resumed.distance,
    300 + (male.berries.distance - 300) / 7,
    1e-9,
    "the queued pocket begins from the completed pocket"
  )
  for _ = 1, 6 do
    presenter:updateFixed()
  end
  assertFraming(
    framingOf(presenter, "the replaced pending pocket"),
    male.berries,
    "only the latest pending request runs after the in-flight transition"
  )
  presenter:selectPocket("berries")
  Assert.equal(presenter:status().frame, 0, "reselecting the settled pocket still restarts the pose animation")
  for _ = 1, 3 do
    presenter:updateFixed()
  end
  assertFraming(
    framingOf(presenter, "the reselected pocket"),
    male.berries,
    "reselecting the settled pocket creates no redundant framing transition"
  )
  Assert.throws(function()
    local opts = { manifest = fixture, gender = "male" }
    opts.gender = nil
    ---@diagnostic disable-next-line: param-type-mismatch -- the missing gender is the invalid input under test
    BagHeroPresenter.new(opts)
  end, "construction without a gender fails")
  Assert.throws(function()
    local opts = { manifest = fixture, gender = "male" }
    opts.gender = "other"
    ---@diagnostic disable-next-line: param-type-mismatch -- the unknown gender is the invalid input under test
    BagHeroPresenter.new(opts)
  end, "construction with an unknown gender fails")
end

-- Each status carries a fresh framing record: mutating a published
-- snapshot never moves the presenter-owned interpolation.
function T.published_framing_is_a_fresh_record_per_call()
  local presenter = BagHeroPresenter.new({ manifest = framingManifest(), gender = "male" })
  local first = framingOf(presenter, "the opening status")
  first.distance = -9999
  first.angleYDegrees = -9999
  local second = framingOf(presenter, "the next status")
  Assert.near(second.distance, 100, 1e-9, "the published distance stays presenter-owned")
  assertFraming(second, framingRecord(10, 350, 100, 5), "the published framing stays presenter-owned")
end

return { tests = T }
