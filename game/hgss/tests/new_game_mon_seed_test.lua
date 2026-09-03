-- New-game mon seed coverage: the unpublished candidate carries the
-- required empty bucket with the exact fingerprint, an explicit seed wins
-- deterministically, the derived seed is stable for its inputs and never
-- zero, and candidates without a catalog keep the legacy shape.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MonsSave = require("libs.mons.src.MonsSave")
local NewGame = require("game.hgss.src.newgame.NewGame")

local T = {}

local function candidate(options)
  local reservations = 0
  ---@type table<string, any>
  local base = {
    saveService = {
      reserve = function()
        reservations = reservations + 1
        return "save-00000027"
      end,
    },
    versionId = "heartgold",
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
  }
  for key, value in pairs(options or {}) do
    base[key] = value
  end
  return NewGame.createCandidate(base)
end

function T.explicit_seed_persists_verbatim()
  local catalog = CatalogFixture.makeCatalog()
  local fresh = candidate({ catalog = catalog, monSeed = 0x12345678 })
  Assert.equal(fresh.mons.rng.state, 0x12345678)
  Assert.equal(fresh.mons.rng.calls, 0)
  Assert.equal(fresh.mons.catalogFingerprint, catalog:fingerprint())
  Assert.isTrue(MonsSave.validate(fresh.mons, CatalogFixture.domainContext(catalog)))
end

function T.zero_seed_maps_to_one()
  local catalog = CatalogFixture.makeCatalog()
  local fresh = candidate({ catalog = catalog, monSeed = 0 })
  Assert.equal(fresh.mons.rng.state, 1, "a zero generator state is never persisted")
end

function T.derived_seed_is_stable_nonzero_and_identity_scoped()
  local catalog = CatalogFixture.makeCatalog()
  local first = candidate({ catalog = catalog, nowSeconds = 1720000000 })
  local second = candidate({ catalog = catalog, nowSeconds = 1720000000 })
  Assert.equal(first.mons.rng.state, second.mons.rng.state, "the same inputs derive the same seed")
  Assert.isTrue(first.mons.rng.state ~= 0, "the derived seed is never zero")
  local other = NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000028"
      end,
    },
    versionId = "heartgold",
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
    catalog = catalog,
    nowSeconds = 1720000000,
  })
  Assert.isTrue(other.mons.rng.state ~= first.mons.rng.state, "the save identity scopes the derived seed")
end

function T.candidates_without_a_catalog_keep_the_legacy_shape()
  local fresh = candidate()
  Assert.isNil(fresh.mons, "no catalog means no mons bucket")
end

return { tests = T }
