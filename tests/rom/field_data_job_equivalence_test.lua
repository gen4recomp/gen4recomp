-- Per-map field-data jobs reproduce the established single-map
-- normalization: one reusable source session compiles the same normalized
-- event, movement, script, music, and coordinate values as the direct
-- one-shot compiler for representative maps, including the New Bark warp
-- pair in both directions.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")

local T = {}

-- A small runtime-derived representative set: New Bark and Elm's Lab plus one
-- map per unseen day-music, header-type, and message-bank class, so music
-- overrides, soundplate carriers, script-init maps, and warp maps are
-- covered without hardcoding corpus members.
local function representatives()
  local selected, seenMusic, seenType, seenMessage = { 60, 61 }, {}, {}, {}
  for _, mapId in ipairs(selected) do
    local record = MapCatalog.require(mapId)
    seenMusic[record.dayMusic] = true
    seenType[record.mapType] = true
    seenMessage[record.messageMemberId] = true
  end
  for record in MapCatalog.all() do
    if #selected >= 8 then
      break
    end
    if not seenMusic[record.dayMusic] or not seenType[record.mapType] or not seenMessage[record.messageMemberId] then
      selected[#selected + 1] = record.id
      seenMusic[record.dayMusic] = true
      seenType[record.mapType] = true
      seenMessage[record.messageMemberId] = true
    end
  end
  return selected
end

local function hasWarpTo(field, destinationMapId, x, z)
  for _, warp in ipairs(field.events.warps) do
    if warp.destinationMapId == destinationMapId and warp.x == x and warp.z == z then
      return true
    end
  end
  return false
end

function T.single_map_field_map_data_matches_direct_normalization(romFs)
  Assert.equal(type(FieldMapDataCompiler.newSession), "function", "per-map production reuses one source session")
  local session = assert(FieldMapDataCompiler.newSession(romFs))
  local compiled = {}
  for _, mapId in ipairs(representatives()) do
    local single, singleErr = session:compile(mapId)
    local direct, directErr = FieldMapDataCompiler.compile(romFs, mapId)
    if direct == nil then
      Assert.isNil(single, "a map the direct compiler rejects is rejected by the session: " .. mapId)
      Assert.equal(singleErr.code, assert(directErr).code, "matching failure identity: " .. mapId)
    else
      single = assert(single, singleErr)
      Assert.equal(
        LuaWriter.encode(single.field),
        LuaWriter.encode(direct.field),
        "one-map field values match: " .. mapId
      )
      Assert.equal(
        LuaWriter.encode(single.dependencies),
        LuaWriter.encode(direct.dependencies),
        "one-map source identity matches: " .. mapId
      )
      compiled[mapId] = single
    end
  end
  local newBark = assert(compiled[60], "New Bark compiles in the session")
  local elmsLab = assert(compiled[61], "Elm's Lab compiles in the session")
  Assert.isTrue(hasWarpTo(newBark.field, 61, 684, 393), "New Bark keeps its direct lab warp destination")
  Assert.isTrue(hasWarpTo(elmsLab.field, 60, 4, 14), "the lab keeps its direct town warp destination")
  Assert.equal(type(newBark.field.music.day), "string")
  Assert.equal(type(newBark.field.messageBankId), "number")
  Assert.equal(type(newBark.field.scriptBankId), "number")
  session:close()
  session:close()
end

return require("tests.rom.support.RomSuite").fromFacts(T)
