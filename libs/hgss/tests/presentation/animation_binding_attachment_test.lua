-- ModelAnimationState + precomputed ModelDefinition bindings: the collapsed
-- animation object graph. Clip bindings are precomputed
-- ONCE at definition assembly (ModelDefinition:binding(clip)) -- a material
-- clip's binding carries the material-index -> track-index mapping the
-- MaterialEvaluator consumes -- and the state attaches clips WITHOUT a
-- caller-supplied binding: attach(clip, opts) builds the attachment from the
-- definition's precomputed binding and returns the LIVE attachment as the
-- handle. One attachment per clip kind: a second same-kind clip raises
-- ANIM_STATE_SAME_KIND_IN_USE. The attachment is a plain table
-- (clip/binding/player); detach takes that handle and removes exactly one
-- attachment; attachments(category) snapshots only the active attachments.
-- There are no tokens: play/stop cycles leave no monotonically growing range
-- behind.

local Assert = require("tests.support.Assert")
local AnimationClip = require("libs.assets.src.model.AnimationClip")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")
local ModelAnimationState = require("libs.hgss.src.presentation.ModelAnimationState")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

local function jointClip()
  return AnimationClip.new({
    id = "clip:jnt",
    name = "joint",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    -- Minimal compiled stub: validation requires the payload; the samplers
    -- touch it only when the clip actually plays through them.
    compiled = {},
    tracks = {
      {
        target = 3,
        channels = {
          translation = { interpolation = "step", keys = { { frame = 0, value = { x = 1, y = 0, z = 0 } } } },
        },
      },
      {
        target = 5,
        channels = {
          rotation = {
            interpolation = "linear",
            keys = { { frame = 0, value = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } } },
          },
        },
      },
    },
  })
end

local function materialClip()
  return AnimationClip.new({
    id = "clip:mat",
    name = "material",
    category = "material",
    kind = "color",
    frameCount = 4,
    compiled = {},
    tracks = {
      {
        target = "door",
        channels = { diffuse = { interpolation = "step", keys = { { frame = 0, value = 0x203C } } } },
      },
    },
  })
end

-- A two-track material clip whose track ORDER differs from the material
-- order: track 0 targets "sign" (material 1), track 1 targets "door"
-- (material 0). The precomputed binding must map material indices to the
-- correct track indices, not assume declaration order.
local function crossedMaterialClip()
  return AnimationClip.new({
    id = "clip:cross",
    name = "crossed",
    category = "material",
    kind = "color",
    frameCount = 4,
    compiled = {},
    tracks = {
      {
        target = "sign",
        channels = { diffuse = { interpolation = "step", keys = { { frame = 0, value = 0x0000 } } } },
      },
      {
        target = "door",
        channels = { diffuse = { interpolation = "step", keys = { { frame = 0, value = 0x203C } } } },
      },
    },
  })
end

-- A material clip whose target name exists on no material: it binds zero
-- model elements and must fail loudly when played, never silently no-op.
local function ghostClip()
  return AnimationClip.new({
    id = "clip:ghost",
    name = "ghost",
    category = "material",
    kind = "color",
    frameCount = 4,
    compiled = {},
    tracks = {
      {
        target = "absent",
        channels = { diffuse = { interpolation = "step", keys = { { frame = 0, value = 0x0000 } } } },
      },
    },
  })
end

local function node(i)
  return {
    index = i,
    name = "node" .. i,
    parentIndex = i > 0 and i - 1 or nil,
    translation = { x = 0, y = 0, z = 0 },
    rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    scale = { x = 1, y = 1, z = 1 },
  }
end

---@class AnimationBindingAttachmentTest.Clip
---@field frameCount integer
---@class AnimationBindingAttachmentTest.Definition : ModelDefinition
---@field animation fun(self: AnimationBindingAttachmentTest.Definition, name: string): AnimationBindingAttachmentTest.Clip
local function definition()
  return ModelDefinition.new({
    key = "model:1",
    nodes = { node(0), node(1), node(2), node(3), node(4), node(5) },
    meshes = {
      { id = "m0", nodeIndex = 0, materialIndex = 0, geometry = "fixtures/m0.g4mesh" },
      { id = "m1", nodeIndex = 0, materialIndex = 1, geometry = "fixtures/m1.g4mesh" },
    },
    materials = {
      {
        id = 0,
        name = "door",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
      {
        id = 1,
        name = "sign",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
    },
    animations = { jointClip(), materialClip(), crossedMaterialClip(), ghostClip() },
  }) --[[@as AnimationBindingAttachmentTest.Definition]]
end

-- ---- precomputed bindings ----

function T.binding_is_precomputed_in_the_definition()
  local def = definition()
  local joint = def:animation("joint")
  local material = def:animation("material")
  local jointBinding = def:binding(joint)
  Assert.notNil(jointBinding)
  Assert.deepEqual(jointBinding.map, { [3] = 3, [5] = 5 })
  Assert.equal(jointBinding.map[3], 3, "joint targets map to themselves")
  local materialBinding = def:binding(material)
  Assert.notNil(materialBinding)
  Assert.deepEqual(materialBinding.map, { door = 0 })
  -- One binding record per clip, resolved once at assembly: repeated reads
  -- return the SAME record.
  Assert.isTrue(def:binding(joint) == jointBinding, "the binding is a precomputed definition record")
  Assert.isTrue(def:binding(material) == materialBinding, "the binding is a precomputed definition record")
end

-- The MaterialEvaluator's per-evaluation track lookup must consume a
-- precomputed material-index -> track-index mapping: a clip
-- whose track order differs from the material order binds material 0 to
-- track 1 and material 1 to track 0.
function T.binding_track_by_material_maps_material_indices_to_tracks()
  local def = definition()
  local clip = def:animation("crossed")
  local binding = def:binding(clip)
  Assert.notNil(binding)
  Assert.deepEqual(binding.map, { door = 0, sign = 1 })
  Assert.deepEqual(binding.trackByMaterial, { [0] = 1, [1] = 0 })
end

-- ---- ModelAnimationState ----

-- The collapsed attach surface: the binding comes from the definition, so
-- attach takes the clip and the optional player, never a caller binding. It
-- returns the LIVE attachment as the handle.
function T.state_attach_builds_the_attachment_from_the_definitions_binding()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local clip = def:animation("joint")
  local handle = state:attach(clip)
  Assert.equal(handle.clip, clip)
  Assert.equal(handle.binding, def:binding(clip), "the attachment carries the precomputed binding")
  Assert.notNil(handle.player)
  Assert.equal(handle.player.frameCount, 8)
end

function T.state_detach_removes_the_exact_attachment()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local joint = state:attach(def:animation("joint"))
  local material = state:attach(def:animation("material"))
  state:detach(joint)
  Assert.equal(#state:attachments("joint"), 0)
  Assert.equal(#state:attachments("material"), 1)
  Assert.isTrue(state:attachments("material")[1] == material, "detaching one handle leaves the other attachment")
  state:detach(material)
  Assert.equal(#state:attachments("material"), 0)
end

-- The O(active) enumeration contract: play/stop cycles must
-- leave no stale range to scan -- attachments(category) returns exactly the
-- active attachments, nothing more.
function T.state_attachments_return_only_the_active_attachments()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local clip = def:animation("joint")
  for _ = 1, 100 do
    local handle = state:attach(clip)
    state:detach(handle)
  end
  Assert.equal(#state:attachments("joint"), 0, "100 play/stop cycles leave no stale attachments")
  local survivor = state:attach(clip)
  Assert.equal(#state:attachments("joint"), 1)
  Assert.isTrue(state:attachments("joint")[1] == survivor)
end

-- Detaching the same handle twice is a no-op: the second detach removes
-- nothing and never disturbs the other attachments (a double stop is a
-- programming mistake the state must tolerate silently).
function T.state_double_detach_is_a_noop()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local joint = state:attach(def:animation("joint"))
  local material = state:attach(def:animation("material"))
  state:detach(joint)
  state:detach(joint)
  Assert.equal(#state:attachments("joint"), 0)
  Assert.equal(#state:attachments("material"), 1)
  Assert.isTrue(state:attachments("material")[1] == material, "the second detach leaves the other attachment")
end

-- Different-kind clips coexist: joint (trs) and material (color) clips
-- attach side by side in attach order, and every player advances.
function T.state_attachments_are_in_attach_order()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local joint = state:attach(def:animation("joint"))
  local material = state:attach(def:animation("material"))
  local jointAttachments = state:attachments("joint")
  Assert.isTrue(jointAttachments[1] == joint)
  local materialAttachments = state:attachments("material")
  Assert.isTrue(materialAttachments[1] == material)
end

function T.state_updates_all_players()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local joint = state:attach(def:animation("joint"))
  local material = state:attach(def:animation("material"))
  state:updateFixed()
  Assert.equal(joint.player.frameFx, 0x1000)
  Assert.equal(material.player.frameFx, 0x1000)
end

function T.state_supports_multiple_simultaneous_clips()
  local def = definition()
  local state = ModelAnimationState.new(def)
  state:attach(def:animation("joint"))
  state:attach(def:animation("material"))
  Assert.equal(#state:attachments("joint"), 1)
  Assert.equal(#state:attachments("material"), 1)
end

-- ---- validation stays ----

-- A clip that binds no model element is a data failure: the attachment
-- cannot be built and playback fails loudly (the precomputed binding is
-- zero-mapped).
function T.zero_binding_clip_cannot_be_attached()
  local def = definition()
  local state = ModelAnimationState.new(def)
  throwsCode("ANIM_STATE_ZERO_BINDING", function()
    return state:attach(def:animation("ghost"))
  end)
end

-- One attachment per clip kind: the state rejects a conflicting same-kind
-- attachment instead of arbitrating between them; the joint group's only
-- kind is trs, so it is single-attachment for the same reason.
function T.state_rejects_a_second_same_kind_attachment()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local clip = def:animation("joint")
  state:attach(clip)
  throwsCode("ANIM_STATE_SAME_KIND_IN_USE", function()
    return state:attach(clip)
  end)
end

-- A clip carrying a category outside the joint/material vocabulary is
-- rejected at attach like any other bad record.
function T.state_attach_rejects_an_unknown_category()
  local def = definition()
  local state = ModelAnimationState.new(def)
  throwsCode("ANIM_STATE_BAD_CATEGORY", function()
    return state:attach({
      id = "clip:unknown",
      name = "unknown",
      category = "bogus",
      kind = "trs",
      frameCount = 4,
      tracks = { { target = 0 } },
    })
  end)
end

-- The attach opts may supply a player, exactly like the instance surface.
function T.attach_accepts_a_custom_player()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local clip = def:animation("joint")
  local player = AnimationPlayer.new(clip)
  local handle = state:attach(clip, { player = player })
  Assert.equal(handle.player, player)
end

-- ---- caller-owned attachment fills ----

-- attachmentsInto fills the caller's list in attach order and returns the
-- same table, matching the snapshot contents without allocating.
function T.state_attachments_into_fills_the_caller_list_in_order()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local joint = state:attach(def:animation("joint"))
  local material = state:attach(def:animation("material"))
  local jointOut = {}
  local returned = state:attachmentsInto("joint", jointOut)
  Assert.isTrue(returned == jointOut, "the fill returns the caller-owned list")
  Assert.equal(#jointOut, 1)
  Assert.isTrue(jointOut[1] == joint)
  local materialOut = {}
  state:attachmentsInto("material", materialOut)
  Assert.equal(#materialOut, 1)
  Assert.isTrue(materialOut[1] == material)
end

-- A fill after detach clears the stale tail: no previous attachment
-- survives in the reused list.
function T.state_attachments_into_clears_the_stale_tail()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local joint = state:attach(def:animation("joint"))
  local out = {}
  state:attachmentsInto("joint", out)
  Assert.equal(#out, 1)
  state:detach(joint)
  local returned = state:attachmentsInto("joint", out)
  Assert.isTrue(returned == out)
  Assert.equal(#out, 0, "detaching empties the next fill")
  Assert.isNil(out[1])
end

-- The filled list is caller-owned: mutating it never disturbs the
-- authoritative group, and the next fill overwrites the damage.
function T.state_attachments_into_never_exposes_internal_storage()
  local def = definition()
  local state = ModelAnimationState.new(def)
  local joint = state:attach(def:animation("joint"))
  local out = {}
  state:attachmentsInto("joint", out)
  out[1] = nil
  out[2] = joint
  state:attachmentsInto("joint", out)
  Assert.equal(#out, 1, "the fill overwrites caller damage")
  Assert.isTrue(out[1] == joint)
  Assert.equal(#state:attachments("joint"), 1, "caller damage never reaches the group")
end

-- An unknown category fails instead of filling an unrelated group.
function T.state_attachments_into_rejects_an_unknown_category()
  local def = definition()
  local state = ModelAnimationState.new(def)
  Assert.throws(function()
    state:attachmentsInto("bogus", {})
  end)
end

return { tests = T }
