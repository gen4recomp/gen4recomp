-- Generated world compatibility fields: the world manifest preserves the
-- normalized map-section identity and follow mode and strictly validates
-- them instead of inventing defaults. Producer propagation from the map
-- reference through analysis is covered ROM-backed, where real matrices
-- make the seam honest.

local Assert = require("tests.support.Assert")
local WorldManifest = require("romdump.src.digest.map.WorldManifest")

local T = {}

local function manifestEntries()
  return {
    {
      id = 61,
      symbol = "MAP_NEW_BARK_ELMS_LAB_1F",
      mapSection = "NEW_BARK_TOWN",
      mapSectionNativeId = 126,
      followMode = "HEIGHT_RESTRICT",
    },
    {
      id = 60,
      symbol = "MAP_NEW_BARK",
      mapSection = "NEW_BARK_TOWN",
      mapSectionNativeId = 126,
      followMode = "ALLOW",
    },
  }
end

function T.manifest_preserves_compat_fields_on_build()
  local manifest = WorldManifest.build(manifestEntries())
  Assert.equal(#manifest.maps, 2)
  local lab = manifest.maps[manifest.byId[61]]
  Assert.equal(lab.mapSection, "NEW_BARK_TOWN")
  Assert.equal(lab.mapSectionNativeId, 126, "the manifest must preserve the native section identity")
  Assert.equal(lab.followMode, "HEIGHT_RESTRICT", "the manifest must preserve the source follow mode")
  local town = manifest.maps[manifest.byId[60]]
  Assert.equal(town.mapSectionNativeId, 126)
  Assert.equal(town.followMode, "ALLOW")
end

function T.manifest_rejects_a_missing_native_section_identity()
  local entries = manifestEntries()
  entries[1].mapSectionNativeId = nil
  Assert.throws(function()
    WorldManifest.build(entries)
  end, "a map without its native section identity must fail the manifest")
end

function T.manifest_rejects_a_missing_follow_mode()
  local entries = manifestEntries()
  entries[2].followMode = nil
  Assert.throws(function()
    WorldManifest.build(entries)
  end, "a map without its source follow mode must fail the manifest")
end

function T.manifest_rejects_malformed_section_identities()
  for _, nativeId in ipairs({ 126.5, -1, "126" }) do
    local entries = manifestEntries()
    entries[1].mapSectionNativeId = nativeId
    Assert.throws(function()
      WorldManifest.build(entries)
    end, "native section identity " .. tostring(nativeId) .. " must fail the manifest")
  end
end

function T.manifest_rejects_an_unknown_follow_mode()
  local entries = manifestEntries()
  entries[1].followMode = "SOMETIMES"
  Assert.throws(function()
    WorldManifest.build(entries)
  end, "an unknown follow mode must fail the manifest")
end

return { tests = T }
