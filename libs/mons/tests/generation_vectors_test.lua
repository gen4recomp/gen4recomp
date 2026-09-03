-- Randomness and creation-order contract: the Generation-IV linear
-- congruential generator reproduces reference draws exactly, and normal
-- creation consumes personality and individual-value draws in source order
-- while deriving ability, gender, experience, moveset, and party health
-- from those draws.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

function T.exact_generator_matches_reference_draws()
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local vectors = {
    { seed = 0x00000000, draws = { 0, 59774, 21105, 12720 }, state = 0x31B0DDE4 },
    { seed = 0x00000001, draws = { 16838, 44065, 53998, 8119 }, state = 0x1FB75CF5 },
    { seed = 0xFFFFFFFF, draws = { 48698, 9947, 53747, 17322 }, state = 0x43AA5ED3 },
    { seed = 0x80000000, draws = { 32768, 27006, 53873, 45488 }, state = 0xB1B0DDE4 },
    { seed = 0x12345678, draws = { 2929, 34026, 55690, 62688 }, state = 0xF4E023DC },
  }
  for _, vector in ipairs(vectors) do
    local rng = Lcrng.new(vector.seed)
    for index, expected in ipairs(vector.draws) do
      Assert.equal(rng:nextU16(), expected, "draw " .. index .. " from seed " .. vector.seed)
    end
    local captured = rng:capture()
    Assert.equal(captured.state, vector.state)
    Assert.equal(captured.calls, 4)
  end

  -- Two draws combine low first, high second.
  local ordered = Lcrng.new(0x12345678)
  Assert.equal(ordered:nextU32FromTwoDraws(), 2229930865)
  Assert.equal(ordered:capture().calls, 2)

  -- Restoring a captured record continues the identical sequence.
  local first = Lcrng.new(0x12345678)
  first:nextU16()
  first:nextU16()
  local resumed = Lcrng.restore(first:capture())
  Assert.equal(resumed:nextU16(), 55690)
  Assert.equal(resumed:nextU16(), 62688)
  Assert.equal(resumed:capture().calls, 4)

  -- Malformed generator records fail instead of producing a weak stream.
  Assert.isTrue(Lcrng.validate({ state = 0, calls = 0 }))
  Assert.throws(function()
    Lcrng.new(0x100000000)
  end)
  Assert.throws(function()
    Lcrng.new(-1)
  end)
  Assert.throws(function()
    Lcrng.validate({ state = 0x100000000, calls = 0 })
  end)
  Assert.throws(function()
    Lcrng.validate({ state = 0, calls = -1 })
  end)
  Assert.throws(function()
    Lcrng.validate({ state = 0 })
  end)
end

function T.normal_creation_follows_source_draw_order()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  local args = CatalogFixture.factoryArgs(0x12345678, catalog)
  local factory = MonFactory.new(args)
  local mon = factory:createNormal(CatalogFixture.normalRequest())

  Assert.equal(mon.schema, "g4-mon-v1")
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.form, 0)
  Assert.equal(mon.personality, 2229930865)
  Assert.deepEqual(mon.ivs, {
    hp = 10,
    attack = 12,
    defense = 22,
    speed = 0,
    specialAttack = 7,
    specialDefense = 29,
  })
  Assert.equal(mon.experience, 419)
  Assert.equal(mon.friendship, 70)
  Assert.equal(mon.ability, "OVERGROW")
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(mon.markings, 0)
  Assert.deepEqual(mon.evs, { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 })
  Assert.deepEqual(mon.contest, { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 })
  Assert.deepEqual(mon.moves, {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 35, ppUps = 0 },
  })
  Assert.equal(mon.isEgg, false)
  Assert.isNil(mon.nickname)
  Assert.deepEqual(mon.ribbons, { ds1 = 0, gba = 0, ds2 = 0 })
  Assert.equal(mon.fatefulEncounter, false)
  Assert.equal(mon.shinyLeaves, 0)
  Assert.deepEqual(mon.egg, { location = 0 })
  Assert.deepEqual(mon.met, {
    location = 7,
    date = { year = 2009, month = 9, day = 13 },
    level = 9,
    terrain = 4,
  })
  Assert.deepEqual(mon.origin, {
    trainerId = 2271560481,
    trainerName = "RED",
    trainerGender = 0,
    game = "heartgold",
    ball = "POKE_BALL",
    language = "english",
  })
  Assert.equal(mon.pokerus, 0)
  Assert.equal(mon.mood, 0)
  Assert.equal(mon.condition.status, 0)
  Assert.equal(mon.condition.currentHp, 28)
  Assert.notNil(mon.mail)
  Assert.notNil(mon.capsule)

  local Mon = require("libs.mons.src.Mon")
  Assert.deepEqual(Mon.validate(mon, context), mon)

  local rng = args.rng
  Assert.equal(rng:capture().calls, 4)
  Assert.equal(rng:capture().state, 0xF4E023DC)

  -- Level never consumes draws: the same seed at level fifteen replays the
  -- identical personality and individual values, shifts the full moveset
  -- down to its last four distinct entries, and skips the repeated opener.
  local higher = CatalogFixture.makeFactory(0x12345678, catalog)
  local grown = higher:createNormal(CatalogFixture.normalRequest({ level = 15 }))
  Assert.equal(grown.personality, mon.personality)
  Assert.deepEqual(grown.ivs, mon.ivs)
  Assert.equal(grown.experience, 2035)
  Assert.deepEqual(grown.moves, {
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 35, ppUps = 0 },
    { move = "SYNTHESIS", pp = 5, ppUps = 0 },
    { move = "REFLECT", pp = 20, ppUps = 0 },
  })
  Assert.equal(grown.condition.currentHp, 40)
  Assert.equal(grown.met.level, 15)
end

return { tests = T }
