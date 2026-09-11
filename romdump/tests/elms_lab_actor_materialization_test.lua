-- ROM-conformance integration test: Professor Elm's Lab (map 61) compiled
-- field data plus his compiled actor visual, materialized through the real
-- runtime actor manager and asset provider (not a synthetic fixture). Proves
-- the fresh-state pipeline end to end: a clear hide flag on real generated
-- data produces a real, drawable object-zero actor at Elm's source position.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local FieldActorCacheWriter = require("romdump.src.digest.actor.FieldActorCacheWriter")
local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {}

local MAP_SYMBOL = "MAP_NEW_BARK_ELMS_LAB_1F"
local MAP_ID = 61
local ELM_ACTOR_ID = "map:61:object:0"

-- Stands in for love.graphics: no GPU resource is created, but every acquire
-- call still runs the provider's real load/decode path against the real
-- compiled visual/atlas bytes.
local function stubGraphics()
  return {
    newImage = function()
      local image = {}
      function image:getWidth()
        return 64
      end
      function image:getHeight()
        return 64
      end
      function image:setFilter() end
      function image:release() end
      return image
    end,
    newQuad = function(x, y, w, h)
      return { x = x, y = y, w = w, h = h }
    end,
    newMesh = function(_, vertices)
      local mesh = { vertices = vertices }
      function mesh:setVertexMap() end
      function mesh:release() end
      return mesh
    end,
  }
end

function T.a_fresh_clear_hide_flag_materializes_and_draws_the_real_elm_actor(romFs, version)
  local runtimeMap = RomRuntimeMap.compile(romFs, MAP_SYMBOL)
  ---@cast runtimeMap RuntimeFieldMap
  Assert.equal(runtimeMap.mapId, MAP_ID)

  local actorBundle = assert(FieldActorCompiler.compile(romFs))
  local cache = CacheFs.forVersion(version, FakeCache.new())
  FieldActorCacheWriter.write(cache, actorBundle)
  local assets = FieldActorAssetProvider.new(cache, { graphics = stubGraphics() })

  -- A genuinely fresh save: no flag has ever been written, so
  -- FLAG_HIDE_ELMS_LAB_ELM reads clear exactly as pret/pokeheartgold defines
  -- a fresh event-flag table.
  local eventState = FieldEventState.new()
  Assert.isFalse(
    eventState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_HIDE_ELMS_LAB_ELM),
    "a fresh save must not hide Elm"
  )

  local manager = FieldActorManager.new({
    assets = assets,
    policy = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } },
  })
  manager:enterMap(runtimeMap, eventState)

  local elm = assert(manager:getById(ELM_ACTOR_ID), "Elm must materialize as a live actor from real generated data")
  Assert.equal(elm:getFieldPosition().fieldX, 6)
  Assert.equal(elm:getFieldPosition().fieldZ, 5)
  Assert.isTrue(elm:isVisible())

  local drawn = false
  for _, record in ipairs(manager:drawRecords()) do
    if record.actorId == ELM_ACTOR_ID then
      drawn = true
      Assert.isTrue(record.visible)
    end
  end
  Assert.isTrue(drawn, "Elm must appear in the actor manager's draw records")

  manager:dispose()
end

return require("tests.rom.support.RomSuite").fromFacts(T)
