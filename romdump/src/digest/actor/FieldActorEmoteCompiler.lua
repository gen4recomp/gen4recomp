-- Compiles the HGSS movement-emote billboard: field_static_models member
-- 118 ("sisen_ef" -- the exclamation-mark badge drawn above an actor
-- performing EmoteExclamationMark, per MapObjectMovementCmd075_Step0 ->
-- sub_02062F48 -> ov01_02200540 with the field-effect vtable at
-- ov01_022092DC). The model is self-contained: its BMD0 embeds its own
-- TEX0, so no separate texture member is required. Nitro decoding ends
-- here; the runtime receives only normalized model data and content-
-- addressed mesh/texture references.

local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local Hashing = require("romdump.src.digest.Hashing")

local Compiler = {}
local MEMBER_ID = 118
local SOURCE_Y_OFFSET = 0x20000
local SOURCE_Z_OFFSET = 0x1000
local SOURCE_FIXED_POINT_UNITS = 0x1000
local SOURCE_POSITION_UNITS_PER_FIELD_UNIT = 16

local function member(narc, memberId)
  if memberId < 0 or memberId >= narc:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "field_static_models member " .. memberId .. " is unavailable", {
      archive = "field_static_models",
      memberId = memberId,
      count = narc:memberCount(),
    })
  end
  return assert(narc:readMember(memberId))
end

function Compiler.compile(romFs, hashLua)
  assert(romFs and romFs.openNarc, "field-emote compiler requires RomFs")
  hashLua = hashLua or Hashing.hashLua
  local narc = assert(romFs:openNarc("field_static_models"))
  local bytes = member(narc, MEMBER_ID)
  local decoded =
    assert(Nsbmd.decode(bytes, { alias = "field_static_models", memberId = MEMBER_ID, section = "emote-exclamation" }))
  local model = decoded.models[1]
  if not model or not decoded.embeddedTextures then
    Errors.raise(
      "FIELD_EFFECT_SOURCE_INVALID",
      "field-emote member " .. MEMBER_ID .. " has no decodable model textures",
      {
        archive = "field_static_models",
        memberId = MEMBER_ID,
      }
    )
  end
  local embeddedTextures = assert(decoded.embeddedTextures)
  local meshes, textures = {}, {}
  local compiled = ModelAssetCompiler.compileModel(model, embeddedTextures, meshes, textures, {
    role = "field-emote",
    modelArchive = "field_static_models",
    modelMemberId = MEMBER_ID,
    modelName = model.name,
    textureArchive = "field_static_models",
    textureMemberId = MEMBER_ID,
    finalizeMeshes = true,
  })
  if #compiled.unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-emote member " .. MEMBER_ID .. " has unresolved materials", {
      archive = "field_static_models",
      memberId = MEMBER_ID,
      unresolved = compiled.unresolved,
    })
  end
  local modelDescriptor = {
    schema = ModelAsset.SCHEMA,
    key = "field-emote:exclamation",
    kind = "static",
    batches = compiled.batches,
    materials = compiled.materials,
  }
  for _, batch in ipairs(modelDescriptor.batches) do
    local sha1 = assert(batch.geometry:match("/([^/]+)%.g4mesh$"), "compiled field-emote geometry path is malformed")
    batch.geometry = FieldEmoteAssetCache.geometryPath(sha1)
  end
  for _, material in ipairs(modelDescriptor.materials) do
    if material.texture then
      local sha1 = assert(material.texture:match("/([^/]+)%.png$"), "compiled field-emote texture path is malformed")
      material.texture = FieldEmoteAssetCache.texturePath(sha1)
    end
  end
  local descriptor = {
    schema = FieldEmoteAssetCache.SCHEMA,
    anchorOffset = {
      x = 0,
      y = SOURCE_Y_OFFSET / (SOURCE_FIXED_POINT_UNITS * SOURCE_POSITION_UNITS_PER_FIELD_UNIT),
      z = SOURCE_Z_OFFSET / (SOURCE_FIXED_POINT_UNITS * SOURCE_POSITION_UNITS_PER_FIELD_UNIT),
    },
    model = modelDescriptor,
  }
  local ok, valid, err = pcall(FieldEmoteAssetCache.validateDescriptor, descriptor)
  if not ok then
    error(valid, 0)
  end
  if not valid then
    error(err, 0)
  end
  local depHash = hashLua({ memberSha1 = Hashing.sha1hex(bytes), model = descriptor })
  return {
    model = descriptor,
    meshes = meshes,
    textures = textures,
    marker = FieldEmoteAssetCache.marker(romFs:metadata().sha1, depHash),
  }
end

return Compiler
