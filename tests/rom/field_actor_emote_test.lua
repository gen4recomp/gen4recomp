-- ROM-backed provenance for the compiled movement-emote billboard: proves
-- the exclamation model compiles from field_static_models member 118 into a
-- nonempty, source-dimensioned texture surface rather than an invented or
-- degenerate one. Mirrors field_entrance_indicator_alpha_test's shape for
-- the sibling field-effect model.

local Assert = require("tests.support.Assert")
local FieldActorEmoteCompiler = require("romdump.src.digest.actor.FieldActorEmoteCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local function testExclamationModelSurface(romFs)
  local bundle = assert(FieldActorEmoteCompiler.compile(romFs))

  Assert.equal(bundle.model.schema, "g4-field-emote-v1")
  Assert.deepEqual(bundle.model.anchorOffset, { x = 0, y = 2, z = 0.0625 })
  Assert.equal(bundle.model.model.key, "field-emote:exclamation")
  Assert.isTrue(#bundle.model.model.batches > 0, "the compiled exclamation model must have at least one drawable batch")
  Assert.isTrue(#bundle.model.model.materials > 0, "the compiled exclamation model must have at least one material")

  local textureCount = 0
  for _, texture in pairs(bundle.textures) do
    local image = love.image.newImageData(assert(texture.data))
    textureCount = textureCount + 1
    Assert.isTrue(texture.width > 0, "the compiled exclamation texture must have a nonzero width")
    Assert.isTrue(texture.height > 0, "the compiled exclamation texture must have a nonzero height")
    Assert.equal(image:getWidth(), texture.width, "PNG width matches the compiled texture dimensions")
    Assert.equal(image:getHeight(), texture.height, "PNG height matches the compiled texture dimensions")

    local nonTransparentFound = false
    for y = 0, texture.height - 1 do
      for x = 0, texture.width - 1 do
        local _, _, _, alpha = image:getPixel(x, y)
        if alpha ~= 0 then
          nonTransparentFound = true
          break
        end
      end
      if nonTransparentFound then
        break
      end
    end
    image:release()
    Assert.isTrue(nonTransparentFound, "the compiled exclamation texture must not be fully transparent/blank")
  end
  Assert.isTrue(textureCount > 0, "member 118 must bind at least one source texture")
end

return RomSuite.fromFacts({
  ["member 118 compiles a nonempty source-dimensioned exclamation surface"] = testExclamationModelSurface,
})
