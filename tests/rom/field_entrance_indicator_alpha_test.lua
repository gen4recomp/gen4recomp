-- ROM-backed provenance for the canonical warp-entrance effect. This records
-- the source texture alpha mechanism and proves it survives the producer
-- boundary without inferring transparency from RGB values.

local Assert = require("tests.support.Assert")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local RomSuite = require("tests.rom.support.RomSuite")

local function hasZeroAlpha(pixels)
  for offset = 4, #pixels, 4 do
    if string.byte(pixels, offset) == 0 then
      return true
    end
  end
  return false
end

local function testMember85Alpha(romFs)
  local narc = assert(romFs:openNarc("field_static_models"))
  local bytes = assert(narc:readMember(85))
  local decoded = assert(Nsbmd.decode(bytes, { alias = "field_static_models", memberId = 85 }))
  local sourceMaterials = {}
  for _, material in ipairs(decoded.models[1].materials) do
    if material.textureName then
      local texture = decoded.embeddedTextures.textureByName[material.textureName]
      if texture then
        sourceMaterials[#sourceMaterials + 1] = { material = material, texture = texture }
      end
    end
  end
  Assert.isTrue(#sourceMaterials > 0, "member 85 must bind at least one source texture")

  local transparentSource = false
  for _, entry in ipairs(sourceMaterials) do
    if entry.texture.color0Transparent then
      transparentSource = true
    end
  end
  Assert.isTrue(transparentSource, "member 85 must expose its source color-zero alpha flag")

  local bundle = assert(FieldEntranceIndicatorCompiler.compile(romFs))
  for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
    local effect = bundle.effects[kind] ---@as { model: ModelDefinition.Descriptor }
    local model = effect.model --[[@as ModelDefinition.Descriptor]]
    local definition = ModelDefinition.fromNitroDescriptor(model, { key = "field-effect:" .. kind })
    local clip = assert(definition.animations[1])
    local targets = {}
    for _, track in ipairs(clip.tracks) do
      targets[#targets + 1] = tostring(track.target)
    end
    local materials = {}
    for _, material in ipairs(definition.materials) do
      materials[#materials + 1] = tostring(material.name)
    end
    Assert.notNil(
      next(definition:binding(clip).map),
      kind
        .. " animation ("
        .. clip.category
        .. ") targets ["
        .. table.concat(targets, ",")
        .. "] but model materials are ["
        .. table.concat(materials, ",")
        .. "]"
    )
  end
  local transparentOutput = false
  local compiledByName = {}
  for _, material in ipairs(bundle.model.materials) do
    if material.name then
      compiledByName[material.name] = material
    end
  end
  for _, texture in pairs(bundle.textures) do
    Assert.notNil(texture.alphaUsage, "compiled effect texture must classify decoded alpha")
    if texture.alphaUsage.hasZero then
      transparentOutput = true
      Assert.isTrue(hasZeroAlpha(texture.data:getString()), "compiled zero-alpha usage must have alpha-zero pixels")
    end
  end
  Assert.isTrue(transparentOutput, "member 85 transparent coverage must survive compilation")

  for _, entry in ipairs(sourceMaterials) do
    if entry.texture.color0Transparent then
      local material = compiledByName[entry.material.name]
      Assert.notNil(material, "source material must survive normalized compilation: " .. entry.material.name)
      local textureKey = assert(material.texture:match("/([^/]+)%.png$"))
      local compiledTexture = assert(bundle.textures[textureKey])
      Assert.isTrue(
        compiledTexture.alphaUsage.hasZero,
        "source color-zero transparency must survive for material " .. entry.material.name
      )
      Assert.isTrue(
        hasZeroAlpha(compiledTexture.data:getString()),
        "source color-zero transparency must produce alpha-zero pixels for material " .. entry.material.name
      )
    end
  end

  local classified = false
  for _, batch in ipairs(bundle.model.batches) do
    Assert.isTrue(
      batch.alphaClass == AlphaClassifier.OPAQUE
        or batch.alphaClass == AlphaClassifier.CUTOUT
        or batch.alphaClass == AlphaClassifier.MIXED
        or batch.alphaClass == AlphaClassifier.TRANSLUCENT,
      "compiled effect batch must use a generic final-alpha class"
    )
    classified = true
  end
  Assert.isTrue(classified, "member 85 must compile at least one drawable batch")
end

return RomSuite.fromFacts({
  ["member 85 preserves source alpha through compilation"] = testMember85Alpha,
})
