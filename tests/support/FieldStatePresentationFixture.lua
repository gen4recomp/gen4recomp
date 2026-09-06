-- Complete presentation cache for real FieldState construction tests: the
-- base field-UI font/frames plus the Trainer Card front, one minimal mon
-- icon class, and the minimal field-actor index/visual/atlas FieldState
-- presentation loaders currently require.

local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local MonCache = require("libs.assets.src.MonCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local FieldStatePresentationFixture = {}

---@return CacheFs
function FieldStatePresentationFixture.cache()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:write(FieldUiFixture.TRAINER_CARD_PATH, FieldUiFixture.cardBytes())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    image = MonCache.iconImagePath(),
    entries = {
      ["TEST/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
      },
    },
    representative = { "TEST/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(255, 0, 0, 255)
  end
  cache:write(MonCache.iconImagePath(), PngWriter.encode(64, 64, table.concat(pixels)))
  cache:write(
    FieldActorCache.indexPath(),
    LuaWriter.encode({ schema = FieldActorCache.INDEX_SCHEMA, spriteIds = { 0 } })
  )
  cache:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0))
  cache:write(FieldActorCache.atlasPath(0), FieldDialogueFixture.atlasBytes())
  return cache
end

-- The terrain-effect bundle the real terrain renderer acquires during the
-- boot: one synthetic triangle mesh per effect kind, written into the same
-- presentation cache the boot reads through.
---@param cache CacheFs
---@return table<string, table<string, unknown>>
function FieldStatePresentationFixture.terrainEffects(cache)
  cache:write(
    "test/terrain-grass.mesh",
    MeshWriter.encode({
      vertices = {
        {
          x = 0,
          y = 0,
          z = 0,
          u = 0,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 1,
          y = 0,
          z = 0,
          u = 1,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 0,
          y = 0,
          z = 1,
          u = 0,
          v = 1,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
      },
      indices = { 0, 1, 2 },
    })
  )
  local function effect()
    return {
      model = {
        dynamic = {
          nodes = {
            { name = "root", translation = { 0, 0, 0 }, rotation = { 0, 0, 0 }, scale = { 1, 1, 1 } },
          },
          batches = {
            {
              id = "grass",
              nodeIndex = 0,
              materialIndex = 0,
              geometry = "test/terrain-grass.mesh",
              alphaClass = "cutout",
              cullMode = "back",
              polygonAlpha = 31,
              polygonMode = "modulation",
              polygonId = 0,
              translucentDepthWrite = false,
              depthEqual = false,
              lightMask = 15,
              fogEnabled = false,
            },
          },
        },
        materials = { { id = 0, name = "grass", wrap = { x = "clamp", y = "clamp" } } },
        animations = {},
      },
      placementOffset = { x = 0, y = 0, z = 0 },
    }
  end
  return {
    tall_grass = effect(),
    very_tall_grass = effect(),
    trainer_reveal = effect(),
  }
end

return FieldStatePresentationFixture
