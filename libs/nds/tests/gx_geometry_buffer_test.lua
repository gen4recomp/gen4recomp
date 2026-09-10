-- Tests the retained contiguous storage and offset-based slice contract.

local Assert = require("tests.support.Assert")
local GeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")

local T = {}

function T.uses_the_locked_native_layouts()
  Assert.equal(GeometryBuffer.vertexNumericSize, 64)
  Assert.equal(GeometryBuffer.vertexAttribSize, 8)
end

function T.grows_by_power_of_two_and_copies_active_prefixes()
  local arena = GeometryBuffer.new()
  local first = arena:beginSlice()
  arena:reserve(2, 3)
  arena.numeric[0].x = 12.5
  arena.attrib[1].colorSource = 2
  arena.indices[0], arena.indices[1], arena.indices[2] = 0, 1, 0
  arena.vertexCount = 2
  arena.indexCount = 3
  arena:finishSlice(first)
  local oldNumeric, oldAttrib, oldIndices = arena.numeric, arena.attrib, arena.indices

  arena:reserve(arena.vertexCapacity, arena.indexCapacity)

  Assert.isTrue(arena.numeric ~= oldNumeric, "vertex growth replaces the cdata array")
  Assert.isTrue(arena.attrib ~= oldAttrib, "attribute growth replaces the cdata array")
  Assert.isTrue(arena.indices ~= oldIndices, "index growth replaces the cdata array")
  Assert.equal(arena.numeric[0].x, 12.5)
  Assert.equal(arena.attrib[1].colorSource, 2)
  Assert.equal(arena.indices[0], 0)
  Assert.equal(arena.indices[1], 1)
  Assert.equal(arena.indices[2], 0)
  Assert.equal(first.vertexOffset, 0)
  Assert.equal(first.indexOffset, 0)
  Assert.equal(first.vertexCount, 2)
  Assert.equal(first.indexCount, 3)
end

function T.reset_retains_high_water_capacity()
  local arena = GeometryBuffer.new()
  arena:reserve(1000, 3000)
  local vertexCapacity, indexCapacity = arena.vertexCapacity, arena.indexCapacity
  arena.vertexCount, arena.indexCount = 1000, 3000
  arena:reset()
  Assert.equal(arena.vertexCount, 0)
  Assert.equal(arena.indexCount, 0)
  Assert.equal(arena.vertexCapacity, vertexCapacity)
  Assert.equal(arena.indexCapacity, indexCapacity)
end

function T.slices_keep_batch_local_indices_after_arena_growth()
  local arena = GeometryBuffer.new()
  local first = arena:beginSlice()
  arena:reserve(3, 3)
  arena.vertexCount, arena.indexCount = 3, 3
  arena.indices[0], arena.indices[1], arena.indices[2] = 0, 1, 2
  arena:finishSlice(first)
  local second = arena:beginSlice()
  arena:reserve(400, 1200)
  arena.vertexCount, arena.indexCount = 403, 1203
  arena:finishSlice(second)
  Assert.equal(first.vertexOffset, 0)
  Assert.equal(first.indexOffset, 0)
  Assert.equal(arena.indices[first.indexOffset + 2], 2)
  Assert.equal(second.vertexOffset, 3)
  Assert.equal(second.indexOffset, 3)
  Assert.equal(arena.indices[second.indexOffset], 0)
end

return { tests = T }
