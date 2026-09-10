-- MaterialCompiler: textured materials get a content hash + finalized asset,
-- untextured materials get none, identical texture references deduplicate, and a
-- name the bound pack does not define yields an untextured material plus a
-- reported unresolved binding -- what the DS draws, since no HGSS material stores
-- a texture format or address of its own for a failed bind to fall back on.

local Assert = require("tests.support.Assert")
local BinaryView = require("libs.codec.src.BinaryView")
local Errors = require("libs.errors.src.Errors")
local MaterialCompiler = require("romdump.src.digest.model.MaterialCompiler")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local TexFixture = require("tests.support.Tex0Fixture")

local T = {}

-- One 8x8 palette16 texture "t" (all texels index 1) + palette "p".
local function buildPack()
  return TexFixture.pack({ textures = { "t" }, palettes = { "p" } })
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

function T.textured_untextured_and_dedup()
  local out = MaterialCompiler.compile({
    { index = 0, name = "m0", textureName = "t", paletteName = "p" },
    { index = 1, name = "m1" }, -- untextured
    { index = 2, name = "m2", textureName = "t", paletteName = "p" }, -- same texture -> dedup
  }, buildPack())

  Assert.equal(#out.materials, 3)
  Assert.equal(#out.materials[1].texture, 40) -- 40 hex chars
  Assert.isNil(out.materials[2].texture)
  Assert.equal(out.materials[1].texture, out.materials[3].texture)
  Assert.equal(countKeys(out.textures), 1) -- deduplicated

  local asset = out.textures[out.materials[1].texture]
  Assert.equal(asset.width, 8)
  Assert.equal(asset.data:getSize(), 57 + 2 + (8 * (1 + 8 * 4)) + 5 + 4)
  Assert.isTrue(asset.alphaUsage.hasOpaque)
  Assert.isFalse(asset.alphaUsage.hasZero)
  Assert.isFalse(asset.alphaUsage.hasPartial)
  Assert.equal(out.materials[1].textureFormat, 3)
  Assert.isNil(out.materials[1].alphaMode)
  Assert.isNil(out.materials[1].cullMode)
end

function T.resolved_materials_report_nothing_unresolved()
  local out = MaterialCompiler.compile({ { index = 0, name = "m", textureName = "t", paletteName = "p" } }, buildPack())
  Assert.deepEqual(out.unresolved, {})
end

function T.missing_texture_compiles_untextured_and_is_reported()
  local out = MaterialCompiler.compile(
    { { index = 0, name = "m", textureName = "nope", paletteName = "p" } },
    buildPack(),
    { context = { textureArchive = "map_textures", textureMemberId = 42 } }
  )

  Assert.isNil(out.materials[1].texture)
  Assert.equal(#out.unresolved, 1)
  Assert.equal(out.unresolved[1].material, "m")
  Assert.equal(out.unresolved[1].kind, "texture")
  Assert.equal(out.unresolved[1].name, "nope")
  Assert.equal(out.unresolved[1].source, "map_textures member 42")
end

function T.missing_palette_compiles_untextured_and_is_reported()
  -- Paletted format with no palette name: the texture exists but cannot be
  -- decoded, so the DS has nothing bound either.
  local out = MaterialCompiler.compile({ { index = 0, name = "m", textureName = "t" } }, buildPack())

  Assert.isNil(out.materials[1].texture)
  Assert.equal(#out.unresolved, 1)
  Assert.equal(out.unresolved[1].kind, "palette")
end

function T.an_unresolved_material_keeps_its_wrap_and_flip()
  -- Wrap/flip come from the material's own register, which a failed bind leaves
  -- untouched; only the texture reference is lost.
  local out = MaterialCompiler.compile(
    { { index = 0, name = "m", textureName = "nope", repeatX = true, flipY = true } },
    buildPack()
  )
  Assert.equal(out.materials[1].wrap.x, "repeat")
  Assert.isTrue(out.materials[1].flip.y)
end

function T.decode_texture_is_the_single_content_addressed_store()
  -- The shared decode/store step: identical texel/palette bytes produce one
  -- key and one asset, different texel bytes a different key, and the stored
  -- asset carries final PNG data and alpha usage. The terrain texture-swap
  -- compile and the base material resolve both call here, so equal bytes must
  -- deduplicate across callers.
  local pack = buildPack()
  local tex = pack.textureByName["t"]
  local pal = pack.paletteByName["p"]
  local opts = Nsbtx.decoderOpts(pack, tex, pal)
  local textures = {}

  local a = MaterialCompiler.decodeTexture(tex, opts, textures, "t")
  local b = MaterialCompiler.decodeTexture(tex, opts, textures, "t")
  Assert.equal(a, b)
  Assert.equal(countKeys(textures), 1)

  local otherOpts = {}
  for k, v in pairs(opts) do
    otherOpts[k] = v
  end
  otherOpts.texel = string.rep("\0", 32)
  local c = MaterialCompiler.decodeTexture(tex, otherOpts, textures, "t")
  Assert.isTrue(a ~= c)
  Assert.equal(countKeys(textures), 2)

  local asset = textures[a]
  Assert.equal(asset.width, 8)
  Assert.equal(asset.data:getSize(), 57 + 2 + (8 * (1 + 8 * 4)) + 5 + 4)
  Assert.isTrue(asset.alphaUsage.hasOpaque)
  Assert.isFalse(asset.alphaUsage.hasZero)
end

function T.texture_identity_accepts_binary_view_inputs_without_changing_the_key()
  local pack = buildPack()
  local texture = pack.textureByName["t"]
  local palette = pack.paletteByName["p"]
  local stringOpts = Nsbtx.decoderOpts(pack, texture, palette)
  local viewOpts = {}
  for key, value in pairs(stringOpts) do
    viewOpts[key] = value
  end
  local texel = stringOpts.texel --[[@as string]]
  local paletteBytes = stringOpts.palette --[[@as string]]
  viewOpts.texel = BinaryView.fromString(texel, "texel")
  viewOpts.palette = BinaryView.fromString(paletteBytes, "palette")

  local stringTextures, viewTextures = {}, {}
  local stringKey = MaterialCompiler.decodeTexture(texture, stringOpts, stringTextures, "t")
  local viewKey = MaterialCompiler.decodeTexture(texture, viewOpts, viewTextures, "t")
  Assert.equal(viewKey, stringKey)
end

function T.texture_dimensions_are_rejected_before_rgba_allocation()
  local ok, result = pcall(function()
    MaterialCompiler.decodeTexture(
      { formatRaw = 7, width = -1, height = 1, color0Transparent = false },
      { format = 7, width = -1, height = 1, texel = "", palette = "" },
      {},
      "invalid"
    )
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(result), "invalid dimensions remain structured")
  ---@cast result Errors.Error
  Assert.equal(result.code, "PNG_BAD_DIMENSIONS")
end

return { tests = T }
