-- Item-data decoding contract for the mon catalog compiler. Fixture layout
-- mirrors pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- include/item.h ItemData: a u16 price, the hold-effect byte, and the
-- remaining effect/pocket fields the catalog never consumes. Native identity
-- to member mapping mirrors the ITEMNARC_PARAM column of src/item.c
-- sItemNarcIds: identities without their own data row share member 0.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MonSources = require("romdump.src.config.MonSources")

local T = {}

local function compiler()
  return require("romdump.src.digest.MonCatalogCompiler")
end

local function memberWithHoldEffect(holdEffect)
  return string.char(100, 0, holdEffect) .. string.rep("\0", 31)
end

function T.decodes_the_hold_effect_byte()
  local decoded = assert(compiler().decodeItemData(memberWithHoldEffect(53), {
    archive = "item_data",
    memberId = 196,
  }))
  Assert.equal(decoded.holdEffect, 53)
  local plain = assert(compiler().decodeItemData(memberWithHoldEffect(0), {
    archive = "item_data",
    memberId = 4,
  }))
  Assert.equal(plain.holdEffect, 0)
end

function T.rejects_malformed_item_members()
  local _, sizeErr = compiler().decodeItemData(string.rep("\0", 33), {
    archive = "item_data",
    memberId = 0,
  })
  Assert.isTrue(Errors.is(sizeErr))
  assert(sizeErr, "malformed item member must fail")
  Assert.equal(sizeErr.code, "MON_ITEM_DATA_BAD_SIZE")
end

function T.maps_native_identities_to_source_members()
  Assert.equal(MonSources.itemDataMember(0), 0)
  Assert.equal(MonSources.itemDataMember(112), 112)
  Assert.equal(MonSources.itemDataMember(113), 0)
  Assert.equal(MonSources.itemDataMember(134), 0)
  Assert.equal(MonSources.itemDataMember(135), 113)
  Assert.equal(MonSources.itemDataMember(427), 405)
  Assert.equal(MonSources.itemDataMember(428), 0)
  Assert.equal(MonSources.itemDataMember(429), 406)
  Assert.equal(MonSources.itemDataMember(536), 513)
  Assert.isFalse(pcall(MonSources.itemDataMember, 537))
end

function T.pins_the_friendship_and_ball_source_facts()
  Assert.equal(MonSources.HOLD_EFFECT_FRIENDSHIP_UP, 53)
  for _, nativeId in ipairs({ 1, 4, 16, 492, 498, 500 }) do
    Assert.isTrue(MonSources.ballItemIds[nativeId] == true, "item " .. nativeId .. " is a ball")
  end
  for _, nativeId in ipairs({ 0, 17, 218, 327 }) do
    Assert.isNil(MonSources.ballItemIds[nativeId], "item " .. nativeId .. " is not a ball")
  end
end

return { tests = T }
