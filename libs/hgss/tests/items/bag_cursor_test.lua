-- Runtime-only field Bag cursor: current pocket plus per-pocket grid
-- position and scroll offset. The cursor never enters the persisted save;
-- reloading a runtime restarts it at its default while reopening the Bag in
-- one runtime keeps it.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {}

function T.cursor_starts_at_the_default_pocket_with_zero_offsets()
  local cursor = BagCursor.new()
  Assert.equal(cursor:currentPocket(), "items")
  for _, pocket in ipairs(BagSave.POCKET_ORDER) do
    Assert.equal(cursor:position(pocket), 0, "pocket " .. pocket .. " starts at position zero")
    Assert.equal(cursor:scroll(pocket), 0, "pocket " .. pocket .. " starts with no scroll")
  end
end

function T.cursor_remembers_per_pocket_offsets_across_pocket_switches()
  local cursor = BagCursor.new()
  cursor:setPosition("balls", 3)
  cursor:setScroll("balls", 1)
  cursor:setPocket("balls")
  Assert.equal(cursor:currentPocket(), "balls")
  cursor:setPocket("medicine")
  cursor:setPosition("medicine", 2)
  cursor:setPocket("balls")
  Assert.equal(cursor:position("balls"), 3, "returning to a pocket restores its cursor")
  Assert.equal(cursor:scroll("balls"), 1, "returning to a pocket restores its scroll")
  Assert.equal(cursor:position("medicine"), 2)
end

function T.cursor_rejects_unknown_pockets_and_negative_offsets()
  local cursor = BagCursor.new()
  Assert.throws(function()
    cursor:setPocket("BOGUS_POCKET")
  end)
  Assert.throws(function()
    cursor:setPosition("balls", -1)
  end)
  Assert.throws(function()
    cursor:setScroll("balls", -1)
  end)
  Assert.throws(function()
    cursor:position("BOGUS_POCKET")
  end)
  Assert.equal(cursor:currentPocket(), "items", "a rejected switch leaves the pocket untouched")
end

return { tests = T }
