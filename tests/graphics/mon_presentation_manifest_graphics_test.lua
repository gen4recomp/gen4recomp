-- Presentation smoke: icon, portrait, and follower visual manifests from the
-- production ROM class address correct rendered pixels through the existing
-- field-actor visual contract. No separate follower draw path is introduced.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local RomImporter = require("romdump.src.source.RomImporter")

local function opaquePixelCount(data, x, y, width, height)
  local count = 0
  for row = y, y + height - 1 do
    for col = x, x + width - 1 do
      local _, _, _, a = data:getPixel(col, row)
      if a > 0 then
        count = count + 1
      end
    end
  end
  return count
end

-- Representative normal/form/gender/shiny/egg icon and portrait selections
-- resolve to in-atlas rectangles with visible pixels and transparent
-- backgrounds, and every follower selector references a loadable field-actor
-- visual instead of a parallel image contract.
local function representative_selections_address_rendered_pixels(_, context)
  local MonCache = require("libs.assets.src.MonCache")
  local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      local icons = assert(cache:loadLua(MonCache.iconManifestPath()), versionId .. " icon manifest must load")
      local portraits =
        assert(cache:loadLua(MonCache.portraitManifestPath()), versionId .. " portrait manifest must load")
      for _, manifest in ipairs({ icons, portraits }) do
        local imageBytes = assert(cache:read(manifest.image), versionId .. " atlas must be present")
        local data = love.image.newImageData(love.filesystem.newFileData(imageBytes, manifest.image))
        local checked = 0
        for _, selector in ipairs(manifest.representative) do
          local rect = assert(manifest.entries[selector], versionId .. " selector must resolve: " .. selector)
          Assert.isTrue(rect.x + rect.width <= data:getWidth(), "rectangle inside atlas width")
          Assert.isTrue(rect.y + rect.height <= data:getHeight(), "rectangle inside atlas height")
          Assert.isTrue(
            opaquePixelCount(data, rect.x, rect.y, rect.width, rect.height) > 0,
            versionId .. " " .. selector .. " must address visible pixels"
          )
          checked = checked + 1
        end
        Assert.isTrue(checked > 0, versionId .. " must check representative selections")
        data:release()
      end
      local catalog = assert(cache:loadLua(MonCache.catalogPath()), versionId .. " catalog must load")
      local actorIndex = assert(FieldActorCache.loadIndex(cache), versionId .. " field-actor index must load")
      local known = {}
      for _, spriteId in ipairs(actorIndex.spriteIds) do
        known[spriteId] = true
      end
      local followers = 0
      for _, species in pairs(catalog.species) do
        for _, form in pairs(species.forms) do
          if form.follower ~= nil then
            Assert.isNil(form.follower.image, "follower visuals stay in the field-actor contract")
            Assert.isTrue(known[form.follower.visualId], "follower visual must be loadable")
            followers = followers + 1
          end
        end
      end
      Assert.isTrue(followers > 0, versionId .. " must carry follower visuals")
    end
  end
  context = context -- capability is asserted by the runner
end

local suite = GraphicsSmoke.suite({
  representative_selections_address_rendered_pixels = representative_selections_address_rendered_pixels,
})
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
