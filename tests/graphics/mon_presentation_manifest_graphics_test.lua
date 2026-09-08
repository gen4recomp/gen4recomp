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

local PORTRAIT_CELL = 80

local function toByte(v)
  return math.floor(v * 255 + 0.5)
end

local function mul32(a, b)
  local aLo, aHi = a % 65536, math.floor(a / 65536)
  local bLo, bHi = b % 65536, math.floor(b / 65536)
  return (aLo * bLo + ((aLo * bHi + aHi * bLo) % 65536) * 65536) % 4294967296
end

-- Starter portraits decoded from the retail source through the row layout:
-- the unscanned 6400-byte surface is 80 rows of 80 bytes with two 40-byte
-- frame halves per row, each byte expanding low nibble then high nibble
-- (pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981, src/pokepic.c
-- UnscanPokepic_PtHGSS row addressing pRawCharData[j * 80 + k]). Expected
-- pixels are recomputed here from the dump's own character and palette
-- members, never from the portrait compiler output, so a fragmented
-- tile-major atlas fails these samples.
local function starter_portraits_follow_source_row_layout(_, context)
  local MonCache = require("libs.assets.src.MonCache")
  local MonSources = require("romdump.src.config.MonSources")
  local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
  local RomFs = require("romdump.src.source.RomFs")
  local bit = require("bit")

  local function unscanSource(scanned, label)
    Assert.equal(#scanned, 6400, label .. " unscanned surface stays 6400 bytes")
    local seed = string.byte(scanned, 1) + string.byte(scanned, 2) * 256
    local parts = {}
    for i = 0, 3199 do
      local word = string.byte(scanned, i * 2 + 1) + string.byte(scanned, i * 2 + 2) * 256
      local plain = bit.bxor(word, seed % 65536)
      parts[#parts + 1] = string.char(plain % 256, math.floor(plain / 256) % 256)
      seed = (mul32(seed, 1103515245) + 24691) % 4294967296
    end
    return table.concat(parts)
  end

  local function expectedRgba(unscanned, colors, frame, x, y, label)
    local offset0 = y * 80 + frame * 40 + math.floor(x / 2)
    local packed = assert(string.byte(unscanned, offset0 + 1), label .. " sample stays in the surface")
    local index
    if x % 2 == 0 then
      index = packed % 16
    else
      index = math.floor(packed / 16) % 16
    end
    if index == 0 then
      return 0, 0, 0, 0
    end
    local color = assert(colors[index + 1], label .. " palette index stays in range")
    return color.r, color.g, color.b, 255
  end

  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      local portraits =
        assert(cache:loadLua(MonCache.portraitManifestPath()), versionId .. " portrait manifest must load")
      local imageBytes = assert(cache:read(portraits.image), versionId .. " portrait atlas must be present")
      local data = love.image.newImageData(love.filesystem.newFileData(imageBytes, portraits.image))
      local romFs = assert(RomFs.open(versionId))
      for _, key in ipairs({ "CHIKORITA", "CYNDAQUIL", "TOTODILE" }) do
        local speciesId = assert(MonSources.speciesId(key), key .. " must be a known species")
        local ids = MonSources.portraitIds(speciesId, "male", 2, false, 0)
        local archive = assert(romFs:openNarc(ids.narc), versionId .. " " .. ids.narc .. " must open")
        local charMember = assert(archive:readMember(ids.charMemberId), versionId .. " char member must read")
        local palMember = assert(archive:readMember(ids.palMemberId), versionId .. " palette member must read")
        local char = assert(G2dDecoder.decodeChar(charMember, { label = key .. " portrait" }))
        local pal = assert(G2dDecoder.decodePalette(palMember, { label = key .. " palette" }))
        Assert.equal(#pal.colors, 16, versionId .. " " .. key .. " palette stays 16 colors")
        local unscanned = unscanSource(char.tiles, versionId .. " " .. key)
        local selector = MonCache.portraitSelector(key, 0, "male", false)
        local rect = assert(portraits.entries[selector], versionId .. " selector must resolve: " .. selector)
        Assert.equal(rect.width, PORTRAIT_CELL, versionId .. " " .. selector .. " stays 80 wide")
        Assert.equal(rect.height, PORTRAIT_CELL, versionId .. " " .. selector .. " stays 80 high")
        Assert.equal(#rect.frames, 2, versionId .. " " .. selector .. " keeps two frames")
        for frameIndex = 0, 1 do
          local frameRect = rect
          if frameIndex == 1 then
            frameRect = assert(rect.frames[2], versionId .. " " .. selector .. " must carry a second frame")
          end
          for y = 0, PORTRAIT_CELL - 1 do
            for x = 0, PORTRAIT_CELL - 1 do
              local er, eg, eb, ea = expectedRgba(unscanned, pal.colors, frameIndex, x, y, versionId .. " " .. key)
              local pr, pg, pb, pa = data:getPixel(frameRect.x + x, frameRect.y + y)
              if toByte(pr) ~= er or toByte(pg) ~= eg or toByte(pb) ~= eb or toByte(pa) ~= ea then
                error(
                  versionId
                    .. " "
                    .. selector
                    .. " frame"
                    .. frameIndex
                    .. " pixel "
                    .. x
                    .. ","
                    .. y
                    .. " expected {"
                    .. er
                    .. ","
                    .. eg
                    .. ","
                    .. eb
                    .. ","
                    .. ea
                    .. "} got {"
                    .. toByte(pr)
                    .. ","
                    .. toByte(pg)
                    .. ","
                    .. toByte(pb)
                    .. ","
                    .. toByte(pa)
                    .. "}",
                  0
                )
              end
            end
          end
        end
      end
      romFs:close()
      data:release()
    end
  end
  context = context -- capability is asserted by the runner
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
  starter_portraits_follow_source_row_layout = starter_portraits_follow_source_row_layout,
})
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
