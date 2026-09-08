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

-- Digest over row-major RGBA bytes of one portrait cell. The constants below
-- are the independently derived retail values, not output of the producer.
local function pixelDigest(data, x, y, size)
  local bit = require("bit")
  local hash = 2166136261
  local function feed(byte)
    local mixed = bit.bxor(hash, byte)
    if mixed < 0 then
      mixed = mixed + 4294967296
    end
    hash = mul32(mixed, 16777619)
  end
  for row = 0, size - 1 do
    for col = 0, size - 1 do
      local r, g, b, a = data:getPixel(x + col, y + row)
      feed(toByte(r))
      feed(toByte(g))
      feed(toByte(b))
      feed(toByte(a))
    end
  end
  return hash
end

local function assertSpot(data, x, y, r, g, b, a, what)
  local pr, pg, pb, pa = data:getPixel(x, y)
  Assert.deepEqual({ toByte(pr), toByte(pg), toByte(pb), toByte(pa) }, { r, g, b, a }, what)
end

-- Retail starter portraits carry exact decoded pixels: per-starter crop
-- digests plus fixed opaque and transparent spots for the normal male
-- default-form selection. Scanned payload noise cannot satisfy these.
local STARTER_PORTRAIT_EVIDENCE = {
  {
    key = "CHIKORITA",
    digest = 0x3BCB1C15,
    transparent = 5515,
    spots = {
      { 0, 0, 0, 0, 0, 0 },
      { 16, 8, 132, 230, 49, 255 },
      { 64, 27, 107, 181, 41, 255 },
      { 24, 40, 214, 247, 123, 255 },
    },
  },
  {
    key = "CYNDAQUIL",
    digest = 0xAC182097,
    transparent = 5409,
    spots = {
      { 0, 0, 0, 0, 0, 0 },
      { 58, 16, 222, 0, 0, 255 },
      { 46, 35, 99, 173, 189, 255 },
      { 7, 43, 255, 247, 165, 255 },
    },
  },
  {
    key = "TOTODILE",
    digest = 0x23026B9F,
    transparent = 5665,
    spots = {
      { 0, 0, 0, 0, 0, 0 },
      { 24, 24, 41, 90, 132, 255 },
      { 78, 33, 16, 16, 16, 255 },
      { 27, 41, 239, 230, 74, 255 },
    },
  },
}

local function starter_portraits_match_source_derived_pixels(_, context)
  local MonCache = require("libs.assets.src.MonCache")
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      local portraits =
        assert(cache:loadLua(MonCache.portraitManifestPath()), versionId .. " portrait manifest must load")
      local imageBytes = assert(cache:read(portraits.image), versionId .. " portrait atlas must be present")
      local data = love.image.newImageData(love.filesystem.newFileData(imageBytes, portraits.image))
      for _, evidence in ipairs(STARTER_PORTRAIT_EVIDENCE) do
        local selector = MonCache.portraitSelector(evidence.key, 0, "male", false)
        local rect = assert(portraits.entries[selector], versionId .. " selector must resolve: " .. selector)
        Assert.equal(rect.width, PORTRAIT_CELL, versionId .. " " .. selector .. " stays 80 wide")
        Assert.equal(rect.height, PORTRAIT_CELL, versionId .. " " .. selector .. " stays 80 high")
        Assert.equal(#rect.frames, 2, versionId .. " " .. selector .. " keeps two frames")
        for _, frame in ipairs(rect.frames) do
          Assert.equal(frame.width, PORTRAIT_CELL, versionId .. " " .. selector .. " frame stays 80 wide")
          Assert.equal(frame.height, PORTRAIT_CELL, versionId .. " " .. selector .. " frame stays 80 high")
          Assert.isTrue(
            frame.x + frame.width <= data:getWidth(),
            versionId .. " " .. selector .. " frame stays in the atlas"
          )
          Assert.isTrue(
            frame.y + frame.height <= data:getHeight(),
            versionId .. " " .. selector .. " frame stays in the atlas"
          )
        end
        for _, spot in ipairs(evidence.spots) do
          assertSpot(
            data,
            rect.x + spot[1],
            rect.y + spot[2],
            spot[3],
            spot[4],
            spot[5],
            spot[6],
            versionId .. " " .. selector .. " pixel " .. spot[1] .. "," .. spot[2]
          )
        end
        Assert.equal(
          pixelDigest(data, rect.x, rect.y, PORTRAIT_CELL),
          evidence.digest,
          versionId .. " " .. selector .. " crop must match the decoded retail pixels"
        )
        local opaque = opaquePixelCount(data, rect.x, rect.y, rect.width, rect.height)
        Assert.equal(
          PORTRAIT_CELL * PORTRAIT_CELL - opaque,
          evidence.transparent,
          versionId .. " " .. selector .. " keeps its transparent regions"
        )
      end
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
  starter_portraits_match_source_derived_pixels = starter_portraits_match_source_derived_pixels,
})
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
