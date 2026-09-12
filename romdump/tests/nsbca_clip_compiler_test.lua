-- Cross-check tests for the compiled NSBCA clip pipeline: a decoded NSBCA
-- resource compiled by NsbcaClipCompiler and sampled by the engine's
-- CompiledNsbcaSampler must be bit-identical to Nsbca.sample over the raw
-- resource, for every fixture and every frame the fixture exercises. This is
-- the lockstep invariant between the two samplers.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local Nsbca = require("libs.nds.src.nitro.g3d.Nsbca")
local NsbcaClipCompiler = require("romdump.src.digest.model.NsbcaClipCompiler")
local CompiledNsbcaSampler = require("libs.nds.src.nitro.g3d.CompiledNsbcaSampler")

local T = {}

local function throwsCode(code, fn)
  local ok, result = pcall(fn)
  if ok then
    error("expected a structured " .. code .. " error, got a result")
  end
  local errorValue = assert(result) --[[@as { code: string }]]
  Assert.equal(errorValue.code, code)
end

-- Decode a fixture file and compile its first animation.
local function compileClip(bytes, name)
  local decoded = assert(NitroAnimation.decode(bytes))
  local anim = assert(decoded.animations[1])
  local reader = BinaryReader.new(decoded.bytes, "sec")
  return anim.resource,
    reader,
    NsbcaClipCompiler.compile(
      anim.resource,
      reader,
      #decoded.bytes,
      { id = "fixture:" .. (name or anim.name), name = anim.name }
    )
end

-- Sample both paths at every frame in 0..numFrame (whole and half frames)
-- and require identical results. The reusable sampler runs on one scratch
-- across every frame/target so stale channel data cannot leak between
-- samples either.
local function assertIdenticalSampling(bytes, name, opts)
  opts = opts or {}
  local resource, reader, clip = compileClip(bytes, name)
  Assert.equal(clip.frameCount, resource.numFrame)
  Assert.equal(clip.category, "joint")
  Assert.equal(#clip.tracks, resource.numAnm)

  local function checkSampled(sampled, expected, label)
    -- Nsbca.sample reports per-channel from-model booleans; the compiled
    -- sampler reports the NNSG3dAnmResult flag bits (scale 0x1, rot 0x2,
    -- trans 0x4, inverse scale 0x8).
    Assert.equal(math.floor(sampled.flags / 4) % 2 == 1, expected.transFromModel, label .. " transFromModel")
    Assert.equal(math.floor(sampled.flags / 2) % 2 == 1, expected.rotFromModel, label .. " rotFromModel")
    Assert.equal(sampled.flags % 2 == 1, expected.scaleFromModel, label .. " scaleFromModel")
    if expected.trans then
      for i, axis in ipairs({ "x", "y", "z" }) do
        Assert.equal(sampled.trans[i], expected.trans[axis], label .. " trans " .. axis)
      end
    end
    if expected.scale then
      for i, axis in ipairs({ "x", "y", "z" }) do
        Assert.equal(sampled.scale[i], expected.scale[axis], label .. " scale " .. axis)
        Assert.equal(sampled.scaleEx[i], expected.inverseScale[axis], label .. " scaleEx " .. axis)
      end
    end
    if expected.rot then
      for i = 1, 9 do
        Assert.equal(sampled.rot[i], expected.rot[i], label .. " rot " .. i)
      end
    end
  end

  local frames = {}
  for f = 0, resource.numFrame - 1 do
    frames[#frames + 1] = f * 4096
  end
  if opts.fractional then
    for f = 0, resource.numFrame - 1 do
      frames[#frames + 1] = f * 4096 + 2048
    end
  end
  local scratch = CompiledNsbcaSampler.newScratch()
  for _, targetIndex in ipairs(opts.targets or { 0 }) do
    for _, frameFx in ipairs(frames) do
      local expected = Nsbca.sample(reader, resource, targetIndex, frameFx)
      local actual = CompiledNsbcaSampler.sample(clip, targetIndex, frameFx)
      local label = string.format("%s target %d frame %d", name, targetIndex, frameFx / 4096)
      checkSampled(actual, expected, label)
      local reused = CompiledNsbcaSampler.sampleInto(scratch, clip, targetIndex, frameFx)
      Assert.isTrue(reused == scratch.result, label .. " reusable sampling returns the scratch result")
      checkSampled(reused, expected, label .. " reusable")
    end
  end
end

-- Frame clamping matches the decoder (both clamp into [0, numFrame<<12 - 1]).
local function assertClamping(bytes, name)
  local resource, reader, clip = compileClip(bytes, name)
  local expected = Nsbca.sample(reader, resource, 0, -4096)
  local actual = CompiledNsbcaSampler.sample(clip, 0, -4096)
  Assert.equal(actual.rot[1], expected.rot[1])
  local scratch = CompiledNsbcaSampler.newScratch()
  local reused = CompiledNsbcaSampler.sampleInto(scratch, clip, 0, -4096)
  Assert.equal(reused.rot[1], expected.rot[1])
  local expectedMax = Nsbca.sample(reader, resource, 0, resource.numFrame * 4096)
  local actualMax = CompiledNsbcaSampler.sample(clip, 0, resource.numFrame * 4096)
  Assert.equal(actualMax.rot[1], expectedMax.rot[1])
  local reusedMax = CompiledNsbcaSampler.sampleInto(scratch, clip, 0, resource.numFrame * 4096)
  Assert.equal(reusedMax.rot[1], expectedMax.rot[1])
end

-- ---- fixtures ----

local function jntDoor()
  return assertIdenticalSampling(require("tests.support.AnimationFixture").jntDoor(), "jntDoor", { fractional = true })
end
local function jntDoorWrap()
  return assertIdenticalSampling(
    require("tests.support.AnimationFixture").jntDoor(0x3),
    "jntDoorWrap",
    { fractional = true }
  )
end
local function jntFull()
  return assertIdenticalSampling(require("tests.support.AnimationFixture").jntFull(), "jntFull", { fractional = true })
end
local function jntFullHalf()
  return assertIdenticalSampling(
    require("tests.support.AnimationFixture").jntFull(0x40000000),
    "jntFullHalf",
    { fractional = true }
  )
end
local function jntFullQuarter()
  return assertIdenticalSampling(
    require("tests.support.AnimationFixture").jntFull(0x80000000),
    "jntFullQuarter",
    { fractional = true }
  )
end
local function jntConstants()
  return assertIdenticalSampling(
    require("tests.support.AnimationFixture").jntConstants(),
    "jntConstants",
    { targets = { 0, 1, 2, 3 } }
  )
end
local function jntCompressed()
  return assertIdenticalSampling(
    require("tests.support.AnimationFixture").jntCompressed(),
    "jntCompressed",
    { fractional = true, targets = { 0 } }
  )
end

T.jnt_door_pivot_rotation = jntDoor
T.jnt_door_final_frame_wrap = jntDoorWrap
T.jnt_full_rate = jntFull
T.jnt_half_rate = jntFullHalf
T.jnt_quarter_rate = jntFullQuarter
T.jnt_constants_and_model_channels = jntConstants
T.jnt_compressed_rotation = jntCompressed

function T.frame_clamping_matches_the_decoder()
  local AF = require("tests.support.AnimationFixture")
  assertClamping(AF.jntDoor(), "jntDoor")
end

-- The reusable sampler owns its result: repeated samples into one scratch
-- keep the same result and nested arrays while their contents track the
-- current frame, matching the allocating sampler exactly.
function T.reusable_sampling_keeps_stable_storage_with_current_contents()
  local AF = require("tests.support.AnimationFixture")
  local _, _, clip = compileClip(AF.jntDoor(), "jntDoor")
  local scratch = CompiledNsbcaSampler.newScratch()
  local first = CompiledNsbcaSampler.sampleInto(scratch, clip, 0, 0)
  Assert.isTrue(first == scratch.result)
  local trans, rot, scale, scaleEx = first.trans, first.rot, first.scale, first.scaleEx
  local second = CompiledNsbcaSampler.sampleInto(scratch, clip, 0, 4096)
  Assert.isTrue(second == first, "repeated sampling reuses the same result")
  Assert.isTrue(second.trans == trans, "the translation array keeps its identity")
  Assert.isTrue(second.rot == rot, "the rotation array keeps its identity")
  Assert.isTrue(second.scale == scale, "the scale array keeps its identity")
  Assert.isTrue(second.scaleEx == scaleEx, "the inverse-scale array keeps its identity")
  local expected = CompiledNsbcaSampler.sample(clip, 0, 4096)
  Assert.equal(second.flags, expected.flags)
  Assert.deepEqual(second.trans, expected.trans)
  Assert.deepEqual(second.rot, expected.rot)
  Assert.deepEqual(second.scale, expected.scale)
  Assert.deepEqual(second.scaleEx, expected.scaleEx)
end

-- The compiled clip envelope: binding tracks carry the targets' node
-- indices, and the source block is opaque provenance.
function T.compiled_clip_envelope()
  local resource, _, clip = compileClip(require("tests.support.AnimationFixture").jntDoor(), "jntDoor")
  Assert.equal(clip.id, "fixture:jntDoor")
  Assert.equal(clip.name, "door_op") -- the fixture's Nitro dictionary name
  Assert.equal(clip.kind, "trs")
  Assert.equal(clip.source.type, "nitro")
  Assert.equal(clip.compiled.targets[1].nodeIndex, resource.targets[1].nodeIndex)
  Assert.equal(clip.tracks[1].target, resource.targets[1].nodeIndex)
end

-- The final curve's key array extends to the end of the JNT0 section (the
-- key area is the record tail and no following offset bounds it): unrelated
-- bytes after the authored keys read as extra keys beyond the frame window
-- (the frame window still samples bit-identically through both paths).
function T.final_curve_key_array_extends_to_the_section_end()
  local AF = require("tests.support.AnimationFixture")
  -- Six trailing bytes after the eight authored rotation keys (three extra
  -- u16 keys referencing pivot entry 0, so the rotation table scan stays in
  -- range).
  local bytes = AF.jntDoor(nil, string.char(0x00, 0x80, 0x00, 0x80, 0x00, 0x80))
  local _, _, clip = compileClip(bytes, "jntDoorTrailing")
  local rot = clip.compiled.targets[1].channels.rot
  Assert.equal(#rot.keys, 11, "the trailing bytes read as keys past the frame window")
  assertIdenticalSampling(bytes, "jntDoorTrailing", { fractional = true })
end

-- The key-array bounds chain across the record tail: with seven curve
-- channels (jntFull) each compiled array carries exactly the authored keys,
-- because every channel's limit is the next channel's key base.
function T.key_bounds_chain_across_multiple_channels()
  local AF = require("tests.support.AnimationFixture")
  local bytes = AF.jntFull()
  local _, _, clip = compileClip(bytes, "jntFull")
  local channels = clip.compiled.targets[1].channels
  Assert.equal(#channels.trans.x.keys, 8, "fx16 trans x")
  Assert.equal(#channels.trans.y.keys, 8, "fx16 trans y")
  Assert.equal(#channels.trans.z.keys, 9, "fx16 trans z (the fixture authors nine keys)")
  Assert.equal(#channels.rot.keys, 8, "rotation")
  Assert.equal(#channels.scale.x.keys, 8, "fx32 scale pair x")
  Assert.equal(#channels.scale.y.keys, 8, "fx32 scale pair y")
  Assert.equal(#channels.scale.z.keys, 8, "fx32 scale pair z")
end

-- The corpus invariant (all real NSBCA curves have limit == numFrame --
-- verified by the ROM census over all 85 field-archive members) is enforced
-- at the compile path: a curve whose limit differs is either a different
-- title/resource or malformed data, and the compile must raise
-- NSBCA_CURVE_LIMIT_MISMATCH instead of emitting a clip whose sampler would
-- need the removed tail branches.
function T.curve_limit_below_num_frame_raises_at_compile()
  local AF = require("tests.support.AnimationFixture")
  throwsCode("NSBCA_CURVE_LIMIT_MISMATCH", function()
    compileClip(AF.jntFull(nil, 8, 8, 6), "jntLimitMismatch")
  end)
end

return { tests = T }
