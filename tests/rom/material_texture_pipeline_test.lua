-- ROM-backed material compilation keeps content-addressed texture identities,
-- alpha classification, and final PNG bytes while handing cache writers a
-- completed LÖVE Data value.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local PngWriter = require("libs.assets.src.PngWriter")
local AreaData = require("romdump.src.digest.map.AreaData")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local LandData = require("romdump.src.digest.map.LandData")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function readMember(romFs, archive, memberId)
  return assert(romFs:openNarc(archive):readMember(memberId))
end

local function sourceMaterial(romFs)
  local resolved = assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
  local area = assert(AreaData.decode(readMember(romFs, "area_data", resolved.areaDataMemberId)))
  local land = assert(LandData.decode(readMember(romFs, "land_data", resolved.landDataMemberId)))
  local model = assert(Nsbmd.decode(land.mapModelBytes)).models[1]
  local pack = assert(Nsbtx.decode(readMember(romFs, "map_textures", area.mapTexturePackId)))

  for index, material in ipairs(model.materials) do
    local texture = material.textureName and pack.textureByName[material.textureName] or nil
    local palette = material.paletteName and pack.paletteByName[material.paletteName] or nil
    if texture and palette and texture.formatRaw >= 1 and texture.formatRaw <= 6 then
      return index, material, texture, palette, pack
    end
  end
  error("New Bark Town has no indexed map material", 0)
end

local function textureKey(path)
  local prefix = "assets/generated/maps/textures/"
  local suffix = ".png"
  Assert.isTrue(path:sub(1, #prefix) == prefix, "map material uses the generated texture root")
  Assert.isTrue(path:sub(-#suffix) == suffix, "map material uses PNG texture output")
  return path:sub(#prefix + 1, -#suffix - 1)
end

function T.map_material_bundle_carries_final_png_data(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local materialIndex, _, texture, palette, pack = sourceMaterial(romFs)
  local sceneMaterial = assert(bundle.scene.materials[materialIndex])
  local key = textureKey(assert(sceneMaterial.texture))
  Assert.equal(#key, 40, "texture identity remains a SHA-1 content key")
  Assert.equal(sceneMaterial.texture, MapAssetCache.texturePath(key), "scene points at the content-addressed PNG")

  local asset = assert(bundle.textures[key], "the compiled map bundle carries the referenced texture")
  Assert.isNil(asset.pixels, "the cache bundle no longer retains decoded RGBA pixels")
  Assert.notNil(asset.data, "the cache bundle carries final PNG Data")
  Assert.isTrue(type(asset.data.getFFIPointer) == "function", "the final texture is LÖVE Data")

  local reference = TextureDecoder.decode(Nsbtx.decoderOpts(pack, texture, palette))
  local expectedPng = PngWriter.encode(reference.width, reference.height, reference.pixels)
  local actualPng = ffi.string(asset.data:getFFIPointer(), asset.data:getSize())
  Assert.equal(actualPng, expectedPng, "the staged PNG bytes remain deterministic")
  Assert.deepEqual(asset.alphaUsage, reference.alphaUsage, "material alpha classification remains unchanged")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "producer", "material", "texture" }
return suite
