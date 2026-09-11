-- Producer-side item source inventory contract: the item compilers resolve
-- every selection they need through ItemSources, and the semantic keys cover
-- the source native identities. Pure data and pure functions; no I/O and no
-- runtime imports.

local Assert = require("tests.support.Assert")

local T = {}

local function sources()
  return require("romdump.src.config.ItemSources")
end

function T.semantic_keys_cover_the_native_identities()
  local ItemSources = sources()
  Assert.equal(ItemSources.itemKeys[0], "NONE")
  Assert.equal(ItemSources.itemKeys[4], "POKE_BALL")
  Assert.equal(ItemSources.itemKeys[17], "POTION")
  Assert.equal(ItemSources.itemKeys[83], "THUNDERSTONE")
  Assert.equal(ItemSources.itemKeys[218], "SOOTHE_BELL")
  Assert.equal(ItemSources.itemKeys[328], "TM01")
  Assert.equal(ItemSources.itemKeys[420], "HM01")
  Assert.equal(ItemSources.itemKeys[536], "ENIGMA_STONE")
  -- Every native identity in the source range carries a semantic key: no
  -- gaps, no blank keys. The range bound is the audited maximum identity.
  for nativeId = 0, 536 do
    local key = ItemSources.itemKeys[nativeId]
    Assert.isTrue(type(key) == "string" and key ~= "", "native item " .. nativeId .. " must carry a semantic key")
  end
end

function T.machine_moves_cover_every_tm_and_hm()
  local ItemSources = sources()
  Assert.equal(ItemSources.machineMoves[0].move, "FOCUS_PUNCH")
  Assert.equal(ItemSources.machineMoves[0].nativeId, 264)
  Assert.equal(ItemSources.machineMoves[99].move, "ROCK_CLIMB")
  -- Every machine index carries a named move joined to a native item
  -- identity; no index is skipped or blank.
  for index = 0, 99 do
    local entry = ItemSources.machineMoves[index]
    Assert.notNil(entry, "machine index " .. index .. " must carry its move entry")
    Assert.isTrue(type(entry.move) == "string" and entry.move ~= "", "machine index " .. index .. " must name its move")
    Assert.isTrue(
      type(entry.nativeId) == "number" and entry.nativeId % 1 == 0 and entry.nativeId >= 0,
      "machine index " .. index .. " must join a native item identity"
    )
  end
end

function T.icon_selection_covers_every_identity_without_arithmetic()
  local ItemSources = sources()
  local graphics = ItemSources.iconGraphics
  for nativeId = 0, 536 do
    local selection = graphics[nativeId]
    Assert.notNil(selection, "item " .. nativeId .. " must carry icon graphics")
    Assert.isTrue(
      type(selection.ncgr) == "number" and selection.ncgr % 1 == 0 and selection.ncgr >= 0,
      "item " .. nativeId .. " ncgr must be a member identity"
    )
    Assert.isTrue(
      type(selection.nclr) == "number" and selection.nclr % 1 == 0 and selection.nclr >= 0,
      "item " .. nativeId .. " nclr must be a member identity"
    )
  end
  -- Representative shared rows stay shared: remapped graphics reuse members.
  Assert.equal(graphics[9].nclr, graphics[10].nclr)
end

return { tests = T }
