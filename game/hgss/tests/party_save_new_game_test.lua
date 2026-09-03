-- New-game party state: the unpublished candidate carries the required
-- validated mons bucket so the first global save validates under the new
-- schema with an empty party and a persisted generator.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local GameSave = require("libs.hgss.src.save.GameSave")
local MonsSave = require("libs.mons.src.MonsSave")
local NewGame = require("game.hgss.src.newgame.NewGame")

local T = {}

local function candidate(catalog, seed)
  local reservations = 0
  return NewGame.createCandidate({
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
    catalog = catalog,
    monSeed = seed,
  })
end

function T.new_game_schema_requires_the_mons_bucket()
  Assert.equal(GameSave.SCHEMA, "g4-game-save-v2", "the global save schema carries the mons bucket")
end

function T.unpublished_candidate_carries_empty_validated_mons_state()
  local catalog = CatalogFixture.makeCatalog()
  local fresh = candidate(catalog, 0x12345678)
  Assert.notNil(fresh.mons, "the unpublished new game carries the required mons bucket")
  local bucket = assert(fresh.mons)
  Assert.equal(bucket.schema, "g4-mons-save-v1", "the bucket carries the mons save schema")
  Assert.equal(
    bucket.catalogFingerprint,
    catalog:fingerprint(),
    "the bucket fingerprints the catalog it was created against"
  )
  Assert.equal(bucket.rng.state, 0x12345678, "the opening generator seed persists immediately")
  Assert.isTrue(bucket.rng.state ~= 0, "a zero generator state is never persisted")
  Assert.equal(bucket.rng.calls, 0, "no generator draw precedes the first creation")
  Assert.equal(bucket.party.max, 6, "the party keeps the source maximum of six")
  Assert.equal(#bucket.party.mons, 0, "no starter exists before starter selection")
  Assert.isTrue(
    MonsSave.validate(bucket, CatalogFixture.domainContext(catalog)),
    "the unpublished bucket validates before any save"
  )
end

return { tests = T }
