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

-- The real dump compiles the full source-backed naming semantics through
-- actual OAM composition: window-derived text geometry, anchored controls
-- with per-OAM palette selection, the stepping cursor with home variants,
-- stepping entry slots, and distinct male/female subjects. Asserts only
-- structural facts and pixel distinctness, never copied source bytes.
function T.compiled_naming_semantics_follow_the_source_contract(romFs, _)
  local bundle, naming = compiledNaming(romFs)
  Assert.deepEqual(naming.text.name, { x = 80, y = 24, advanceX = 12 })
  local rowCount = 0
  for _ in pairs(naming.text.keyboard.cells) do
    rowCount = rowCount + 1
  end
  Assert.equal(rowCount, 5, "the keyboard text carries five source rows")
  for row = 1, 5 do
    for column = 1, 13 do
      local cell = assert(
        naming.text.keyboard.cells[row][column],
        "keyboard text row " .. row .. " column " .. column .. " is required"
      )
      Assert.equal(cell.width, 16, "keyboard text cells are the 16px source columns")
    end
  end
  local expectedAnchors = {
    upper = { x = 4, y = 68 },
    lower = { x = 36, y = 68 },
    symbols = { x = 68, y = 68 },
    back = { x = 136, y = 68 },
    ok = { x = 176, y = 68 },
    backing = { x = 22, y = 56 },
  }
  for id, anchor in pairs(expectedAnchors) do
    Assert.deepEqual(assert(naming.controls[id], "the " .. id .. " control is required").anchor, anchor)
  end
  Assert.deepEqual(naming.cursor.keyboard.origin, { x = 26, y = 91 })
  Assert.equal(naming.cursor.keyboard.stepX, 16)
  Assert.equal(naming.cursor.keyboard.stepY, 19)
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    Assert.notNil(naming.cursor.home[id], "the home cursor carries the " .. id .. " variant")
  end
  Assert.deepEqual(naming.entrySlots.origin, { x = 80, y = 39 })
  Assert.equal(naming.entrySlots.stepX, 12)
  Assert.deepEqual(naming.playerSubjects.male.anchor, { x = 24, y = 8 })
  Assert.deepEqual(naming.playerSubjects.female.anchor, { x = 24, y = 8 })

  local function opaqueBytes(record)
    local assetId = assert(record.asset, "the sprite record must reference its image by semantic asset id")
    local asset = assert(bundle.manifest.assets[assetId], "the sprite asset must be indexed: " .. assetId)
    local bytes = assert(bundle.assets[asset.image], "the sprite image must have generated pixels: " .. asset.image)
    local width, _, rgba = PngReader.rgba(bytes)
    local total = math.floor(#rgba / 4)
    for index = 0, total - 1 do
      local _, _, _, a = PngReader.pixel(rgba, width, index % width, math.floor(index / width))
      if a ~= 0 then
        return bytes
      end
    end
    Assert.isTrue(false, "the " .. assetId .. " visual carries no opaque source art")
    return bytes
  end
  local maleBytes = opaqueBytes(naming.playerSubjects.male)
  local femaleBytes = opaqueBytes(naming.playerSubjects.female)
  Assert.isTrue(maleBytes ~= femaleBytes, "the male and female subjects render distinct art")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
