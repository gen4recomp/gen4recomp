-- Tests for RenderQueue: classification, pass-order preservation for
-- opaque/cutout/mixedOpaque/wireframe, translucent back-to-front sorting,
-- MIXED item splitting into opaque and blended passes, and deterministic
-- tie-breaking by traversal position across ordered parts. Queue construction
-- validates its input contract and never mutates the caller's draw records.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function item(id, mode, center, transform)
  return {
    id = id,
    alphaClass = mode,
    center = center or { 0, 0, 0 },
    transform = transform or Matrix4.identity(),
  }
end

local function ids(queue, key)
  local out = {}
  local entries = queue[key]
  if key == "blended" then
    -- blended contains {item, fragmentPass, viewZ, position} records
    for _, record in ipairs(entries) do
      out[#out + 1] = record.item.id
    end
  else
    for _, it in ipairs(entries) do
      out[#out + 1] = it.id
    end
  end
  return out
end

local function fragmentPassesIn(queue, key)
  local out = {}
  if key == "blended" then
    for _, record in ipairs(queue[key]) do
      out[#out + 1] = record.fragmentPass
    end
  end
  return out
end

local function scratch()
  return RenderQueue.newScratch()
end

local function build(parts, viewMatrix)
  return RenderQueue.buildInto(parts, viewMatrix, scratch())
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(
    Errors.is(err) and err.code == code,
    "expected " .. code .. ", got " .. tostring(Errors.is(err) and err.code or err)
  )
  return err
end

function T.classifies_by_alpha_class()
  local items = {
    item("a", "opaque"),
    item("b", "cutout"),
    item("c", "translucent"),
    item("d", "wireframe"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { "a" })
  Assert.deepEqual(ids(q, "cutout"), { "b" })
  Assert.deepEqual(ids(q, "blended"), { "c" })
  Assert.deepEqual(ids(q, "wireframe"), { "d" })
end

function T.classifies_mixed_items()
  local items = {
    item("mixed1", "mixed"),
    item("mixed2", "mixed"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "mixedOpaque"), { "mixed1", "mixed2" })
  -- Mixed items also appear in blended with fragmentPass
  Assert.deepEqual(ids(q, "blended"), { "mixed1", "mixed2" })
  Assert.deepEqual(
    fragmentPassesIn(q, "blended"),
    { "mixed", "mixed" },
    "mixed items in blended have fragmentPass='mixed'"
  )
end

function T.build_into_reuses_caller_owned_scratch_arrays()
  local storage = scratch()
  local opaque = storage.opaque
  local cutout = storage.cutout
  local mixedOpaque = storage.mixedOpaque
  local wireframe = storage.wireframe
  local blended = storage.blended

  local queue = RenderQueue.buildInto({
    { item("map", "opaque"), item("glass", "translucent") },
    { item("building", "cutout") },
    { item("actor", "wireframe") },
  }, Matrix4.identity(), storage)

  Assert.isTrue(queue == storage)
  Assert.isTrue(queue.opaque == opaque)
  Assert.isTrue(queue.cutout == cutout)
  Assert.isTrue(queue.mixedOpaque == mixedOpaque)
  Assert.isTrue(queue.wireframe == wireframe)
  Assert.isTrue(queue.blended == blended)
  Assert.deepEqual(ids(queue, "opaque"), { "map" })
  Assert.deepEqual(ids(queue, "cutout"), { "building" })
  Assert.deepEqual(ids(queue, "blended"), { "glass" })
  Assert.deepEqual(ids(queue, "wireframe"), { "actor" })
end

function T.build_into_preserves_order_across_parts()
  local queue = RenderQueue.buildInto({
    { item("map-a", "opaque"), item("map-b", "cutout") },
    { item("building", "opaque") },
    { item("neighbor", "cutout") },
    { item("actor", "opaque") },
  }, Matrix4.identity(), scratch())

  Assert.deepEqual(ids(queue, "opaque"), { "map-a", "building", "actor" })
  Assert.deepEqual(ids(queue, "cutout"), { "map-b", "neighbor" })
end

function T.build_into_clears_stale_tail_entries()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("opaque-a", "opaque"),
      item("opaque-b", "opaque"),
      item("cutout", "cutout"),
      item("far", "translucent", { 0, 0, -2 }),
      item("near", "translucent", { 0, 0, -1 }),
      item("wire", "wireframe"),
    },
  }, Matrix4.identity(), storage)

  RenderQueue.buildInto({ { item("only", "opaque") } }, Matrix4.identity(), storage)

  Assert.deepEqual(ids(storage, "opaque"), { "only" })
  Assert.equal(#storage.cutout, 0)
  Assert.equal(#storage.mixedOpaque, 0)
  Assert.equal(#storage.wireframe, 0)
  Assert.equal(#storage.blended, 0)
end

function T.build_into_translucent_ties_preserve_cross_part_order()
  local queue = RenderQueue.buildInto({
    { item("map", "translucent", { 0, 0, -5 }) },
    { item("building", "translucent", { 0, 0, -5 }) },
    { item("neighbor", "translucent", { 0, 0, -5 }) },
    { item("actor", "translucent", { 0, 0, -5 }) },
  }, Matrix4.identity(), scratch())

  Assert.deepEqual(ids(queue, "blended"), { "map", "building", "neighbor", "actor" })
end

function T.mixed_and_translucent_sort_jointly_by_view_z()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local queue = RenderQueue.buildInto({
    {
      item("trans-far", "translucent", { 0, 0, -10 }),
      item("mixed-mid", "mixed", { 0, 0, -5 }),
      item("trans-near", "translucent", { 0, 0, -1 }),
    },
  }, view, scratch())

  Assert.deepEqual(ids(queue, "blended"), { "trans-far", "mixed-mid", "trans-near" })
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "translucent", "mixed", "translucent" })
end

function T.mixed_and_translucent_equal_depth_tie_by_position()
  local queue = RenderQueue.buildInto({
    { item("trans1", "translucent", { 0, 0, -5 }) },
    { item("mixed1", "mixed", { 0, 0, -5 }) },
    { item("trans2", "translucent", { 0, 0, -5 }) },
    { item("mixed2", "mixed", { 0, 0, -5 }) },
  }, Matrix4.identity(), scratch())

  Assert.deepEqual(
    ids(queue, "blended"),
    { "trans1", "mixed1", "trans2", "mixed2" },
    "equal-depth items maintain submission order"
  )
end

function T.mixed_item_in_opaque_and_blended_passes()
  local storage = scratch()
  local queue = RenderQueue.buildInto({
    {
      item("opaque", "opaque"),
      item("mixed", "mixed"),
      item("translucent", "translucent"),
    },
  }, Matrix4.identity(), storage)

  -- Mixed appears in mixedOpaque for the opaque subpass
  Assert.deepEqual(ids(queue, "mixedOpaque"), { "mixed" })
  -- Mixed also appears in blended for the translucent subpass
  Assert.deepEqual(ids(queue, "blended"), { "mixed", "translucent" })
  -- Verify fragmentPass markers
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "mixed", "translucent" })
end

function T.rejects_material_only_alpha_class()
  local matItem = {
    id = "mat",
    alphaClass = nil,
    material = { alphaClass = "cutout" },
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  local err = throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({ { matItem } }, Matrix4.identity())
  end)
  Assert.isNil(err.context.alphaClass)
end

function T.rejects_unknown_alpha_class()
  local err = throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({ { item("ghostly", "ghostly") } }, Matrix4.identity())
  end)
  Assert.equal(err.context.alphaClass, "ghostly")
end

function T.rejects_missing_alpha_class()
  local bare = {
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({ { bare } }, Matrix4.identity())
  end)
end

function T.preserves_submission_order_for_opaque()
  local items = { item("a", "opaque"), item("b", "opaque"), item("c", "opaque") }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { "a", "b", "c" })
end

function T.preserves_submission_order_for_cutout_and_wireframe()
  local items = { item("a", "cutout"), item("b", "wireframe"), item("c", "cutout") }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "cutout"), { "a", "c" })
  Assert.deepEqual(ids(q, "wireframe"), { "b" })
end

function T.sorts_translucent_back_to_front()
  -- Camera at (0,0,5) looking at origin; view matrix maps world +Z to -Z.
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local items = {
    item("nearest", "translucent", { 0, 0, 0 }),
    item("farthest", "translucent", { 0, 0, -10 }),
    item("middle", "translucent", { 0, 0, -5 }),
  }
  local q = build({ items }, view)
  Assert.deepEqual(ids(q, "blended"), { "farthest", "middle", "nearest" })
end

-- Equal-depth blended draws tie-break by traversal position across the
-- ordered parts: the earlier part (map geometry) draws before the later part
-- (actors) deterministically.
function T.equal_depth_ties_break_by_part_position()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local parts = {
    { item("first", "translucent", { 0, 0, -5 }) },
    { item("second", "translucent", { 0, 0, -5 }) },
    { item("third", "translucent", { 0, 0, -5 }) },
  }
  local q = build(parts, view)
  Assert.deepEqual(ids(q, "blended"), { "first", "second", "third" })
end

function T.transforms_center_by_item_transform()
  -- Two items at the same model-space center but translated differently.
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local near = item("near", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, 0))
  local far = item("far", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, -10))
  local q = build({ { near, far } }, view)
  Assert.deepEqual(ids(q, "blended"), { "far", "near" })
end

function T.transforms_nonzero_model_center_once_before_sorting()
  local translated = item("translated", "translucent", { 0, 0, 1 }, Matrix4.translate(0, 0, 32))
  local origin = item("origin", "translucent", { 0, 0, 49 }, Matrix4.identity())
  local q = build({ { translated, origin } }, Matrix4.identity())
  Assert.deepEqual(ids(q, "blended"), { "translated", "origin" })
end

-- Sorting must not attach fields (e.g. a cached `_viewZ`) to the persistent
-- draw records, and repeated construction must not change any input item.
-- Blended entries are scratch records, but original items remain untouched.
function T.build_does_not_mutate_input_items()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local items = {
    item("a", "opaque", { 0, 0, 0 }),
    item("b", "translucent", { 0, 0, -10 }),
    item("c", "translucent", { 0, 0, -5 }),
    item("d", "cutout"),
    item("e", "wireframe"),
  }
  local before = {}
  for i, it in ipairs(items) do
    before[i] = {}
    for k, v in pairs(it) do
      before[i][k] = v
    end
  end
  local first = build({ items }, view)
  local second = build({ items }, view)
  for i, it in ipairs(items) do
    Assert.isNil(rawget(it, "_viewZ"), "no sort field is attached to item " .. i)
    Assert.deepEqual(it, before[i], "item " .. i .. " mutated by queue construction")
  end
  Assert.deepEqual(ids(first, "blended"), ids(second, "blended"))
end

-- The returned queue holds the original item tables in opaque/cutout/mixedOpaque/wireframe.
-- Blended entries are scratch records that point to original items via .item field.
function T.queue_entries_are_the_original_items()
  local items = {
    item("a", "opaque"),
    item("b", "translucent"),
    item("c", "cutout"),
    item("d", "wireframe"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.isTrue(q.opaque[1] == items[1], "opaque pass returns the original item")
  Assert.isTrue(q.blended[1].item == items[2], "blended pass record points to original item")
  Assert.isTrue(q.cutout[1] == items[3], "cutout pass returns the original item")
  Assert.isTrue(q.wireframe[1] == items[4], "wireframe pass returns the original item")
end

-- A rotated+translated item: the model-space center is transformed exactly
-- once by the item transform, so the sort reflects the true world position
-- (the dynamic-instance contract -- never a world-space center that the
-- queue would transform a second time).
function T.transforms_rotated_translated_centers_once()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local rotate = Matrix4.rotateY(math.pi / 2)
  local move = Matrix4.translate(0, 0, -10)
  local transform = Matrix4.multiply(move, rotate)
  -- A model-local center at +X maps, under the 90-degree Y rotation, to -Z:
  -- the world center is (0, 0, -10). An item at the origin stays nearer.
  local rotated = item(1, "translucent", { 5, 0, 0 }, transform)
  local origin = item(2, "translucent", { 0, 0, 0 }, Matrix4.identity())
  local q = build({ { origin, rotated } }, view)
  Assert.deepEqual(ids(q, "blended"), { 1, 2 }, "far (rotated) first, near origin last")
end

function T.sorts_billboards_from_their_view_space_center_and_scaled_model_center()
  local billboard = item("billboard", "translucent", { 0, 0, 1 })
  billboard.billboardCenter = { 0, 0, -32 }
  billboard.billboardScale = { 1, 1, 2 }
  local ordinary = item("ordinary", "translucent", { 0, 0, -29.5 })

  local q = build({ { billboard, ordinary } }, Matrix4.identity())

  Assert.deepEqual(
    ids(q, "blended"),
    { "billboard", "ordinary" },
    "billboard depth includes its view-space center and scaled model center"
  )
end

-- Blended entries are renderer-owned scratch records with {item, fragmentPass, viewZ, position}.
-- They must be reused across frames so repeated queue construction does not
-- allocate new entry tables.
function T.blended_entries_are_reused_scratch_records()
  local storage = scratch()
  local q1 = RenderQueue.buildInto({
    { item("trans1", "translucent"), item("trans2", "translucent") },
  }, Matrix4.identity(), storage)

  local firstEntry1 = q1.blended[1]
  local firstEntry2 = q1.blended[2]

  local q2 = RenderQueue.buildInto({
    { item("trans1", "translucent"), item("trans2", "translucent") },
  }, Matrix4.identity(), storage)

  -- Same storage object is reused
  Assert.isTrue(q2 == storage)
  -- Scratch entry tables are reused (same object identities)
  Assert.isTrue(q2.blended[1] == firstEntry1, "blended entry 1 table is reused")
  Assert.isTrue(q2.blended[2] == firstEntry2, "blended entry 2 table is reused")
end

-- After a smaller frame, stale blended entries must be truncated.
function T.blended_tail_truncation_after_smaller_frame()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("t1", "translucent"),
      item("t2", "translucent"),
      item("t3", "translucent"),
    },
  }, Matrix4.identity(), storage)

  Assert.equal(#storage.blended, 3)

  RenderQueue.buildInto({
    { item("t1", "translucent") },
  }, Matrix4.identity(), storage)

  Assert.equal(#storage.blended, 1, "stale blended tail is removed")
end

-- Blended records must have fragmentPass field set to the correct pass type.
function T.blended_records_have_fragment_pass_field()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("trans", "translucent"),
      item("mixed", "mixed"),
    },
  }, Matrix4.identity(), storage)

  Assert.equal(storage.blended[1].fragmentPass, "translucent")
  Assert.equal(storage.blended[2].fragmentPass, "mixed")
end

-- MIXED items must not be in the translucent-only array, and must appear separately.
function T.mixed_does_not_confuse_with_translucent_only()
  local storage = scratch()
  local items = {
    item("trans-a", "translucent"),
    item("mixed-a", "mixed"),
    item("trans-b", "translucent"),
    item("mixed-b", "mixed"),
  }
  RenderQueue.buildInto({ items }, Matrix4.identity(), storage)

  -- mixedOpaque contains only mixed items
  Assert.deepEqual(ids(storage, "mixedOpaque"), { "mixed-a", "mixed-b" })
  -- blended contains all items (mixed + translucent)
  Assert.deepEqual(ids(storage, "blended"), { "trans-a", "mixed-a", "trans-b", "mixed-b" })
  -- Verify the fragmentPass values
  Assert.deepEqual(fragmentPassesIn(storage, "blended"), { "translucent", "mixed", "translucent", "mixed" })
end

-- Blended ordering through the queue-owned scratch constructor: every alpha
-- class across multiple parts lands in its pass, blended sorts far-to-near
-- with source-position tie breaks, and mixed items reference the same
-- original record in both passes without mutating caller items.
function T.preserves_exact_pass_membership_and_blended_order_through_owned_scratch()
  local storage = RenderQueue.newScratch()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local wall = item("wall", "opaque")
  local fence = item("fence", "cutout")
  local far = item("far", "translucent", { 0, 0, -10 })
  local mixedMid = item("mixed-mid", "mixed", { 0, 0, -5 })
  local tieLate = item("tie-late", "translucent", { 0, 0, -5 })
  local near = item("near", "translucent", { 0, 0, -1 })
  local wire = item("wire", "wireframe")
  local queue = RenderQueue.buildInto({
    { wall, fence, far, mixedMid },
    { tieLate, near },
    { wire },
  }, view, storage)

  Assert.isTrue(queue == storage)
  Assert.deepEqual(ids(queue, "opaque"), { "wall" })
  Assert.deepEqual(ids(queue, "cutout"), { "fence" })
  Assert.deepEqual(ids(queue, "mixedOpaque"), { "mixed-mid" })
  Assert.deepEqual(ids(queue, "wireframe"), { "wire" })
  Assert.deepEqual(ids(queue, "blended"), { "far", "mixed-mid", "tie-late", "near" })
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "translucent", "mixed", "translucent", "translucent" })
  Assert.isTrue(
    queue.mixedOpaque[1] == mixedMid and queue.blended[2].item == mixedMid,
    "the mixed item reaches both passes by identity"
  )
  Assert.isTrue(queue.blended[1].item == far, "the first entry is the farthest draw")
  Assert.isTrue(queue.blended[#queue.blended].item == near, "the last entry is the nearest draw")
  for _, original in ipairs({ wall, fence, far, mixedMid, tieLate, near, wire }) do
    Assert.isNil(rawget(original, "viewZ"), "no sort key is written back onto caller items")
    Assert.isNil(rawget(original, "position"), "no source position is written back onto caller items")
  end
end

-- Warmed rebuilds at a stable blended cardinality reuse every piece of sort
-- storage owned by the scratch: one comparator, one key buffer, the same
-- unsorted wrapper objects, the same order table, and the same visible
-- blended array. The field renderer must build its lifetime scratch through
-- the same queue-owned constructor so production always carries valid sort
-- storage.
function T.warmed_rebuilds_reuse_sort_storage_and_leave_inputs_untouched()
  local storage = RenderQueue.newScratch()
  Assert.isTrue(type(storage._sortCompare) == "function", "the scratch owns one comparator")
  Assert.notNil(storage._sortKeys, "the scratch owns reusable key storage")
  Assert.notNil(storage._sortOrder, "the scratch owns a reusable order table")

  local view = Matrix4.identity()
  local first = item("first", "translucent", { 0, 0, -3 })
  local second = item("mixed-second", "mixed", { 0, 0, -2 })
  local third = item("third", "translucent", { 0, 0, -1 })
  local parts = { { first, second, third } }
  local before = {}
  for index, original in ipairs(parts[1]) do
    before[index] = {}
    for key, value in pairs(original) do
      before[index][key] = value
    end
  end

  RenderQueue.buildInto(parts, view, storage)
  local comparator = storage._sortCompare
  local keys = storage._sortKeys
  local order = storage._sortOrder
  local blendedArray = storage.blended
  local wrappers = {}
  for index, wrapper in ipairs(storage.blended) do
    wrappers[index] = wrapper
  end
  Assert.equal(#wrappers, 3)

  RenderQueue.buildInto(parts, view, storage)

  Assert.isTrue(storage._sortCompare == comparator, "the comparator is reused, not recreated per build")
  Assert.isTrue(storage._sortKeys == keys, "the key buffer is reused across warmed builds")
  Assert.isTrue(storage._sortOrder == order, "the order table is reused across warmed builds")
  Assert.isTrue(storage.blended == blendedArray, "the visible blended array is reused across warmed builds")
  Assert.equal(#storage.blended, 3)
  for index, wrapper in ipairs(storage.blended) do
    Assert.isTrue(wrapper == wrappers[index], "unsorted wrapper " .. index .. " is reused across warmed builds")
  end
  Assert.deepEqual(ids(storage, "blended"), { "first", "mixed-second", "third" })
  for index, original in ipairs(parts[1]) do
    Assert.deepEqual(original, before[index], "caller item " .. index .. " is untouched by warmed rebuilds")
  end

  local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
  local renderer = FieldRenderer.new({
    gxRenderer = { stats = {}, draw = function() end, release = function() end },
  })
  Assert.isTrue(
    type(renderer._queueScratch._sortCompare) == "function"
      and renderer._queueScratch._sortKeys ~= nil
      and renderer._queueScratch._sortOrder ~= nil,
    "the field renderer lifetime scratch carries the queue-owned sort storage"
  )
  local rendererQueue = RenderQueue.buildInto(parts, view, renderer._queueScratch)
  Assert.deepEqual(ids(rendererQueue, "blended"), { "first", "mixed-second", "third" })
end

-- Sort capacity grows once when blended cardinality exceeds it, then holds
-- steady at or below the warmed maximum; shrinking clears stale references.
-- The warmed timing sample below is measurement only: it reports the current
-- cost so the later comparison can judge the non-regression gate without
-- committing a machine-specific threshold to the suite.
function T.sort_capacity_grows_once_then_holds_with_reported_warmed_cost()
  local storage = RenderQueue.newScratch()
  local view = Matrix4.identity()

  local function partsWith(count)
    local part = {}
    for index = 1, count do
      part[index] = item("glass-" .. index, "translucent", { 0, 0, -index })
    end
    return { part }
  end

  RenderQueue.buildInto(partsWith(1), view, storage)
  local initialBuffer = storage._sortKeys
  Assert.notNil(initialBuffer, "the scratch owns key storage from the first build")
  Assert.equal(#storage.blended, 1)

  local grownAt = nil
  local grownBuffer = nil
  local count = 2
  while count <= 4096 do
    RenderQueue.buildInto(partsWith(count), view, storage)
    if storage._sortKeys ~= initialBuffer then
      grownAt = count
      grownBuffer = storage._sortKeys
      break
    end
    count = count * 2
  end
  Assert.notNil(grownBuffer, "key storage grows once cardinality exceeds its initial capacity")
  Assert.isTrue(grownBuffer ~= initialBuffer)

  RenderQueue.buildInto(partsWith(grownAt), view, storage)
  RenderQueue.buildInto(partsWith(grownAt), view, storage)
  Assert.isTrue(storage._sortKeys == grownBuffer, "no further buffer replacement at the warmed maximum")
  Assert.equal(#storage.blended, grownAt)
  Assert.isTrue(storage.blended[1].item.id == "glass-" .. grownAt, "the first entry is still the farthest draw")
  Assert.isTrue(storage.blended[#storage.blended].item.id == "glass-1", "the last entry is still the nearest draw")

  RenderQueue.buildInto(partsWith(1), view, storage)
  Assert.equal(#storage.blended, 1, "shrinking clears the visible blended tail")
  Assert.isNil(storage.blended[2], "no stale blended reference survives shrinking")

  RenderQueue.buildInto(partsWith(grownAt), view, storage)
  Assert.isTrue(storage._sortKeys == grownBuffer, "capacity is retained after a smaller frame")
  Assert.equal(#storage.blended, grownAt)

  local benchParts = partsWith(64)
  for _ = 1, 200 do
    RenderQueue.buildInto(benchParts, view, storage)
  end
  local samples = {}
  for sample = 1, 7 do
    local started = os.clock()
    for _ = 1, 1000 do
      RenderQueue.buildInto(benchParts, view, storage)
    end
    samples[sample] = os.clock() - started
  end
  table.sort(samples)
  local median = samples[4]
  Assert.isTrue(median > 0, "the warmed benchmark completes and reports positive CPU time")
  io.stderr:write(
    string.format(
      "[render-queue] warmed buildInto x1000 (64 blended): median %.6fs min %.6fs max %.6fs\n",
      median,
      samples[1],
      samples[#samples]
    )
  )
end

-- Key storage tracks the first and last blended entries exactly, and the
-- reusable order array sheds stale indexes when a later frame shrinks.
function T.blended_key_storage_tracks_boundary_entries_and_order_tail_clears()
  local storage = RenderQueue.newScratch()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local far = item("far", "translucent", { 0, 0, -10 })
  local near = item("near", "translucent", { 0, 0, -1 })
  RenderQueue.buildInto({ { far, near } }, view, storage)

  Assert.equal(storage._sortKeys[0].entryIndex, 1, "the first key slot describes the first entry")
  Assert.equal(storage._sortKeys[1].entryIndex, 2, "the last key slot describes the last entry")
  Assert.equal(storage._sortKeys[0].position, 1)
  Assert.equal(storage._sortKeys[1].position, 2)
  Assert.isTrue(storage._sortKeys[0].viewZ < storage._sortKeys[1].viewZ, "the first key holds the farther depth")
  Assert.deepEqual(ids(storage, "blended"), { "far", "near" })
  Assert.equal(#storage._sortOrder, 2)

  local third = item("third", "translucent", { 0, 0, -5 })
  RenderQueue.buildInto({ { far, near, third } }, view, storage)
  Assert.equal(#storage._sortOrder, 3)

  RenderQueue.buildInto({ { near } }, view, storage)
  Assert.equal(#storage.blended, 1, "shrinking clears the visible blended tail")
  Assert.isNil(storage.blended[2], "no stale blended reference survives shrinking")
  Assert.equal(#storage._sortOrder, 1, "shrinking clears stale order indexes")
  Assert.isNil(storage._sortOrder[2], "no stale order index survives shrinking")
  Assert.deepEqual(ids(storage, "blended"), { "near" })
end

return { tests = T }
