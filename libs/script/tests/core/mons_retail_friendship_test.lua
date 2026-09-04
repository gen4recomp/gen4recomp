-- Retail friendship mutation through the script runtime: the source bonus
-- order for ScrCmd_MonAddFriendship (383). A zero modifier bypasses every
-- bonus; otherwise the luxury-ball and current-map-section increments apply
-- first, the held-item friendship multiplier scales the running total with
-- integer division, and the final value saturates at 255. The map comparison
-- reads the native map-section identity the service was constructed with,
-- and the held-item fact comes from the generated catalog record.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local NATIVE_SECTION = 126

local function buildCatalog()
  local root = CatalogFixture.buildAssetRoot()
  root.items["LUXURY_BALL"] = { nativeId = 11, isBall = true, friendshipBoost = false }
  root.items["ITEM_11"] = nil
  root.items["SOOTHE_BELL"] = { nativeId = 218, isBall = false, friendshipBoost = true }
  root.items["ITEM_218"] = nil
  return root
end

local function openService()
  local root = buildCatalog()
  local catalog = MonCatalog.new(root)
  local items = {}
  local balls = {}
  for key, definition in pairs(root.items) do
    items[key] = definition.nativeId
    if definition.isBall then
      balls[key] = definition.nativeId
    end
  end
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xBBBBBBBB):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = items,
    balls = balls,
    mapSection = NATIVE_SECTION,
    date = CatalogFixture.metDate(),
  })
  local factory = require("libs.mons.src.gen4.MonFactory").new({
    catalog = catalog,
    rng = Lcrng.new(0xCCCCCCCC),
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = items,
    balls = balls,
    game = "heartgold",
    language = "english",
  })
  local function addMon(ball, eggLocation, heldItem)
    local record = factory:createNormal({
      species = "CHIKORITA",
      level = 5,
      form = 0,
      profile = CatalogFixture.profile(),
      ball = "POKE_BALL",
      location = 7,
      terrain = 4,
      date = CatalogFixture.metDate(),
    })
    record.origin.ball = ball
    record.egg.location = eggLocation
    record.heldItem = heldItem
    record.friendship = 70
    Assert.isTrue(service:addMon(record), "setup mon must enter the party")
  end
  addMon("POKE_BALL", 0, "NONE")
  addMon("LUXURY_BALL", 0, "NONE")
  addMon("POKE_BALL", NATIVE_SECTION, "NONE")
  addMon("POKE_BALL", 0, "SOOTHE_BELL")
  addMon("LUXURY_BALL", NATIVE_SECTION, "SOOTHE_BELL")
  return service
end

local function runWith(service)
  local world = {
    vars = {},
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  return {
    instance = { scriptId = "test.retail.friendship", locals = {}, textArgs = {} },
    services = { mons = service, world = world },
    semantics = RuntimeValues,
  }
end

local function addFriendship(service, amount, slot)
  local run = runWith(service)
  local ok, outcome = pcall(function()
    return Runtime.executeNode({ op = "mon_add_friendship", amount = amount, slot = slot }, run)
  end)
  Assert.isTrue(ok, "a source-valid modifier must never fault")
  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE)
end

function T.zero_modifier_skips_every_bonus()
  local service = openService()
  local run = runWith(service)
  Assert.equal(Runtime.executeNode({ op = "mon_add_friendship", amount = 0, slot = 4 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(service:monFriendship(4), 70, "zero adds nothing even with every bonus armed")
end

function T.ball_and_location_bonuses_add_before_the_percent_step()
  local service = openService()
  addFriendship(service, 5, 0)
  Assert.equal(service:monFriendship(0), 75, "an ordinary modifier adds plainly")
  addFriendship(service, 5, 1)
  Assert.equal(service:monFriendship(1), 76, "the luxury ball contributes one extra point")
  addFriendship(service, 5, 2)
  Assert.equal(service:monFriendship(2), 76, "a matching native map section contributes one extra point")
end

function T.held_item_percent_applies_after_increments_with_integer_division()
  local service = openService()
  addFriendship(service, 5, 3)
  Assert.equal(service:monFriendship(3), 77, "five scaled by 150 percent truncates to seven")
  addFriendship(service, 5, 4)
  Assert.equal(service:monFriendship(4), 80, "increments precede the percent step: seven scales to ten")
end

function T.large_modifiers_saturate_instead_of_failing()
  local service = openService()
  addFriendship(service, 300, 0)
  Assert.equal(service:monFriendship(0), 255, "a modifier above 255 saturates the final value")
  addFriendship(service, 200, 1)
  Assert.equal(service:monFriendship(1), 255, "a boosted total still saturates at the top")
end

return { tests = T }
