-- ROM conformance for the generated normal naming chrome: the real dump
-- compiles one opaque 256x192 base and three 256x112 page overlays keyed
-- upper/lower/symbols at the canonical y=80 placement, the page images keep
-- transparent source-zero holes so the base shows through, and the producer
-- fingerprint pins exactly the proven normal members. Asserts only structural
-- facts and pixel alpha behavior, never copied source bytes or text.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local FieldUiCompiler = require("romdump.src.digest.ui.FieldUiCompiler")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")

local T = {}

local function namingSelection()
  local config = require("romdump.src.config.FieldUiAssets")
  return assert(config.namingScreen, "the field-UI producer must select normal naming chrome")
end

local function compiledNaming(romFs)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local naming = assert(bundle.manifest.namingScreen, "the compiled field UI must publish normal naming chrome")
  return bundle, naming
end

local function assetBytes(bundle, entry)
  local record = assert(entry, "the naming entry is required")
  local assetId = assert(record.asset, "the naming entry must reference its image by semantic asset id")
  local asset = assert(bundle.manifest.assets[assetId], "the naming asset must be indexed: " .. assetId)
  local bytes = assert(bundle.assets[asset.image], "the naming image must have generated pixels: " .. asset.image)
  return asset, bytes
end

local function transparentCount(bytes)
  local width, _, rgba = PngReader.rgba(bytes)
  local transparent = 0
  local total = math.floor(#rgba / 4)
  for index = 0, total - 1 do
    local _, _, _, a = PngReader.pixel(rgba, width, index % width, math.floor(index / width))
    if a == 0 then
      transparent = transparent + 1
    end
  end
  return transparent, total
end

function T.compiled_naming_chrome_has_the_normal_base_and_pages(romFs, _)
  local bundle, naming = compiledNaming(romFs)
  Assert.deepEqual(naming.placement, { x = 0, y = 80, width = 256, height = 112 })
  Assert.equal(naming.base.width, 256)
  Assert.equal(naming.base.height, 192)
  for _, key in ipairs({ "upper", "lower", "symbols" }) do
    local page = assert(naming.pages[key], "the normal " .. key .. " page is required")
    Assert.equal(page.width, 256, key .. " page width")
    Assert.equal(page.height, 112, key .. " page height")
  end
  local pageCount = 0
  for _ in pairs(naming.pages) do
    pageCount = pageCount + 1
  end
  Assert.equal(pageCount, 3, "normal naming carries exactly three pages")

  local baseAsset, baseBytes = assetBytes(bundle, naming.base)
  Assert.equal(baseAsset.width, 256)
  Assert.equal(baseAsset.height, 192)
  local baseWidth, baseHeight = PngReader.rgba(baseBytes)
  Assert.equal(baseWidth, 256)
  Assert.equal(baseHeight, 192)
  local baseTransparent = transparentCount(baseBytes)
  Assert.equal(baseTransparent, 0, "the base is opaque source art")

  local seen = {}
  for _, key in ipairs({ "upper", "lower", "symbols" }) do
    local pageAsset, pageBytes = assetBytes(bundle, naming.pages[key])
    Assert.equal(pageAsset.width, 256, key .. " asset width")
    Assert.equal(pageAsset.height, 112, key .. " asset height")
    local pageWidth, pageHeight = PngReader.rgba(pageBytes)
    Assert.equal(pageWidth, 256)
    Assert.equal(pageHeight, 112)
    local transparent = transparentCount(pageBytes)
    Assert.isTrue(transparent > 0, "the " .. key .. " overlay keeps transparent source-zero holes")
    Assert.isNil(seen[pageBytes], "the " .. key .. " page renders its own artwork")
    seen[pageBytes] = key
  end
end

function T.naming_dependencies_pin_exactly_the_normal_members(romFs, _)
  local selection = namingSelection()
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local names = {}
  for _, dep in ipairs(bundle.dependencies) do
    names[dep.name] = true
  end
  local required = {
    selection.paletteMember,
    selection.charMember,
    selection.baseScreenMember,
    selection.pageScreenMembers.upper,
    selection.pageScreenMembers.lower,
    selection.pageScreenMembers.symbols,
  }
  for _, member in ipairs(required) do
    Assert.isTrue(
      names[selection.alias .. ":member:" .. member] or names[selection.alias .. ":palette:" .. member],
      "the fingerprint must pin naming member " .. member
    )
  end
  for _, excluded in ipairs({ 5, 9, 17, 18 }) do
    Assert.isNil(
      names[selection.alias .. ":member:" .. excluded],
      "member " .. excluded .. " must not be fingerprinted"
    )
    Assert.isNil(
      names[selection.alias .. ":palette:" .. excluded],
      "member " .. excluded .. " must not be fingerprinted"
    )
  end
end

function T.naming_manifest_carries_no_source_identities(romFs, _)
  local _, naming = compiledNaming(romFs)
  local forbidden = { member = true, memberId = true, narcId = true, alias = true, fileId = true }
  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for key, nested in pairs(value) do
      if type(key) == "string" and forbidden[key] then
        Assert.isTrue(false, "compiled naming leaks source detail '" .. key .. "' at " .. path)
      end
      scan(nested, path .. "." .. tostring(key))
    end
  end
  scan(naming, "namingScreen")
  Assert.isTrue(FieldUiAssetCache.validateManifest(assert(FieldUiCompiler.compile(romFs)).manifest))
end

return require("tests.rom.support.RomSuite").fromFacts(T)
