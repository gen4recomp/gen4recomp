-- Synthetic tests for the four NitroSystem 3D animation formats.
-- Fixtures mirror the verified real HGSS byte layouts (see the decoder
-- headers); sampling tests assert the exact NitroSystem arithmetic from the
-- pinned pokediamond asm.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroBuilder = require("tests.support.NitroBuilder")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local Nsbca = require("libs.nds.src.nitro.g3d.Nsbca")
local Nsbta = require("libs.nds.src.nitro.g3d.Nsbta")
local Nsbtp = require("libs.nds.src.nitro.g3d.Nsbtp")
local Nsbma = require("libs.nds.src.nitro.g3d.Nsbma")
local AnimationFixture = require("tests.support.AnimationFixture")

local T = {}

local function throwsCode(code, fn)
  local file, err = fn()
  Assert.isNil(file, "expected decode failure")
  Assert.notNil(err)
  local errorValue = assert(err) --[[@as { code: string }]]
  Assert.equal(errorValue.code, code)
end

-- Decode a fixture and return { resource, sectionReader } for the first
-- animation.
local function decodeOne(bytes)
  local decoded = assert(NitroAnimation.decode(bytes))
  local anim = assert(decoded.animations[1])
  return anim.resource, BinaryReader.new(decoded.bytes, "sec")
end

-- Sample helpers (wrap the (r, res, ...) argument order).
local function jnt(res, r, target, frame)
  return Nsbca.sample(r, res, target, frame)
end
local function srt(res, r, target, frame)
  return Nsbta.sample(r, res, target, frame)
end
local function btp(res, target, frame)
  return Nsbtp.keyAt(res, target, frame)
end
local function bma(res, r, target, frame)
  return Nsbma.sample(r, res, target, frame)
end

-- Locate a fixture's JNT record offset within the section (shared by the
-- malformed-fixture patchers).
local function jntRecordOffset(fixture)
  local r = BinaryReader.new(fixture, "patch")
  local sectionAt = r:u32le(0x10)
  local dictBase = sectionAt + 8
  local ofsEntry = r:u16le(dictBase + 6)
  local entryBase = dictBase + ofsEntry
  return sectionAt, r:u32le(entryBase + 4)
end

-- ---- NSBCA ----

function T.jnt_pivot_rotation_samples()
  local res, r = decodeOne(AnimationFixture.jntDoor())
  Assert.equal(res.numFrame, 8)
  Assert.equal(res.targets[1].nodeIndex, 0)

  -- Frame 0: pivot entry 0 (control 0x24, A=1, B=0) -> identity matrix.
  local s = jnt(res, r, 0, 0)
  Assert.isFalse(s.rotFromModel)
  Assert.isTrue(s.transFromModel, "trans comes from the model")
  Assert.isTrue(s.scaleFromModel)
  Assert.equal(s.trans, nil)
  Assert.equal(s.rot[1], 0x1000) -- A at pivotUtil cell 0
  Assert.equal(s.rot[5], 0x1000) -- pivot cell (index 4)
  Assert.equal(s.rot[9], 0x1000) -- A at cell 8 (signD clear)
  Assert.equal(s.rot[3], 0) -- B = 0
  Assert.equal(s.rot[7], 0)

  -- Frame 7: entry 7 (A = 9/16, B = 7/16): a door swinging open about Y.
  local s7 = jnt(res, r, 0, 7 * 4096)
  Assert.equal(s7.rot[1], 0x900)
  Assert.equal(s7.rot[3], 0x700)
  Assert.equal(s7.rot[7], -0x700)
  Assert.equal(s7.rot[9], 0x900)
  Assert.equal(s7.rot[5], 0x1000)
end

function T.jnt_frame_clamps_to_range()
  local res, r = decodeOne(AnimationFixture.jntDoor())
  local s = jnt(res, r, 0, 8 * 4096) -- one past the end
  Assert.equal(s.rot[1], 0x900) -- same as frame 7
  local sNeg = jnt(res, r, 0, -4096)
  Assert.equal(sNeg.rot[1], 0x1000) -- same as frame 0
end

function T.jnt_constants_and_model_channels()
  local res, r = decodeOne(AnimationFixture.jntConstants())
  Assert.equal(res.numAnm, 5)

  -- Target 0: constant translation, model rotation and scale.
  local s0 = jnt(res, r, 0, 0)
  Assert.isFalse(s0.transFromModel)
  Assert.equal(s0.trans.x, 10 * 0x1000)
  Assert.equal(s0.trans.y, 20 * 0x1000)
  Assert.equal(s0.trans.z, 30 * 0x1000)
  Assert.isTrue(s0.rotFromModel)
  Assert.isTrue(s0.scaleFromModel)

  -- Target 1: constant rotation (pivot entry 1: A=0, B=1).
  local s1 = jnt(res, r, 1, 0)
  Assert.isFalse(s1.rotFromModel)
  Assert.equal(s1.rot[3], 0x1000)
  Assert.equal(s1.rot[7], -0x1000)

  -- Target 2: constant scale pairs with inverse scales.
  local s2 = jnt(res, r, 2, 0)
  Assert.isFalse(s2.scaleFromModel)
  Assert.equal(s2.scale.x, 2 * 0x1000)
  Assert.equal(s2.inverseScale.x, math.floor(0.5 * 0x1000))
  Assert.equal(s2.scale.z, 4 * 0x1000)
  Assert.equal(s2.inverseScale.z, math.floor(0.25 * 0x1000))

  -- Target 3: whole joint from the model.
  local s3 = jnt(res, r, 3, 0)
  Assert.isTrue(s3.transFromModel and s3.rotFromModel and s3.scaleFromModel)
  Assert.equal(s3.trans, nil)

  -- Target 4: bit 7 set, bit 6 clear, bit 8 set -- the rot-mode gate is the
  -- asm's fromModel bit (0x40), not the full 0xC0 mode mask, so the channel
  -- is a constant, not from-model (pins the bit-6-only decode).
  local s4 = jnt(res, r, 4, 0)
  Assert.isFalse(s4.rotFromModel)
  Assert.equal(s4.rot[1], 0x1000) -- pivot entry 0 (A=1)
  Assert.equal(s4.rot[3], 0) -- B=0
  Assert.isTrue(s4.transFromModel)
  Assert.isTrue(s4.scaleFromModel)
end

function T.jnt_full_rate_sampling_fx16_fx32()
  local res, r = decodeOne(AnimationFixture.jntFull())
  local s = jnt(res, r, 0, 3 * 4096)
  Assert.equal(s.trans.x, 6 * 0x1000) -- fx16 key 3
  Assert.equal(s.trans.y, 7 * 0x1000)
  Assert.equal(s.scale.x, math.floor(1.75 * 0x1000)) -- fx32 pair key 3
  Assert.equal(s.inverseScale.x, math.floor((1 / 1.75) * 0x1000))
  -- Entry 1 (A=0, B=1): single-key path, cells as reconstructed.
  Assert.equal(s.rot[1], 0)
  Assert.equal(s.rot[3], 0x1000)
end

function T.jnt_half_rate_odd_frame_averages()
  local res, r = decodeOne(AnimationFixture.jntFull(0x40000000))
  local s = jnt(res, r, 0, 1 * 4096)
  -- fx16 trans: (key[0] + key[1]) >> 1 = (0 + 2) >> 1.
  Assert.equal(s.trans.x, 1 * 0x1000)
  -- fx32 scale: (a >> 1) + (b >> 1) = 1/2 + 1.25/2.
  Assert.equal(s.scale.x, math.floor(1 * 0x1000 / 2) + math.floor(1.25 * 0x1000 / 2))
  -- Rotation: merge keys[0] + keys[1], then the rows are normalized.
  -- Row 0 = (0x1000, 0, 0x1000) -> normalized.
  local length = math.sqrt(0x1000 * 0x1000 + 0x1000 * 0x1000)
  Assert.equal(s.rot[1], math.floor(0x1000 * 0x1000 / length))
  Assert.equal(s.rot[4], 0) -- row 1 = (0, 0x2000, 0) -> (0, 0x1000, 0)
  Assert.equal(s.rot[5], 0x1000)
  Assert.equal(s.rot[6], 0)
end

function T.jnt_quarter_rate_weighted_averages()
  local res, r = decodeOne(AnimationFixture.jntFull(0x80000000))
  -- Raw fx16 keys: key[i] = fx16(2i) = 0x2000 * i.
  -- Frame 1 (f%4==1): (3*key[0] + key[1]) >> 2 = (0x2000) >> 2.
  local s1 = jnt(res, r, 0, 1 * 4096)
  Assert.equal(s1.trans.x, 0x800)
  -- Frame 2 (f%4==2): (key[0] + key[1]) >> 1 = 0x2000 >> 1.
  local s2 = jnt(res, r, 0, 2 * 4096)
  Assert.equal(s2.trans.x, 0x1000)
  -- Frame 3 (f%4==3): (3*key[1] + key[0]) >> 2 = (0x6000) >> 2.
  local s3 = jnt(res, r, 0, 3 * 4096)
  Assert.equal(s3.trans.x, 0x1800)
end

function T.jnt_fractional_frame_interpolation()
  -- anmFlags bit 0 enables fractional interpolation.
  local res, r = decodeOne(AnimationFixture.jntDoor(0x1))
  local s = jnt(res, r, 0, 0.5 * 4096)
  -- Halfway between entry 0 (A=1, B=0) and entry 1 (A=15/16, B=1/16):
  -- the interpolated row 0 is (0xF80, 0, 0x80), then normalized.
  local length = math.sqrt(0xF80 * 0xF80 + 0x80 * 0x80)
  Assert.equal(s.rot[1], math.floor(0x1000 * 0xF80 / length))
  Assert.equal(s.rot[3], math.floor(0x1000 * 0x80 / length))
  Assert.equal(s.rot[5], 0x1000) -- pivot row normalizes to itself
  -- Even frames take the exact key.
  local s1 = jnt(res, r, 0, 1 * 4096)
  Assert.equal(s1.rot[1], 0xF00)
end

function T.jnt_final_frame_wrap()
  -- anmFlags bit 1 wraps the final frame toward key[0].
  local res, r = decodeOne(AnimationFixture.jntDoor(0x3))
  local s = jnt(res, r, 0, 7.5 * 4096)
  -- key[7] A=9/16 toward key[0] A=1 with frac 0x800: interpolated row 0
  -- is (0xC80, 0, 0x380), then normalized.
  local length = math.sqrt(0xC80 * 0xC80 + 0x380 * 0x380)
  Assert.equal(s.rot[1], math.floor(0x1000 * 0xC80 / length))
  Assert.equal(s.rot[3], math.floor(0x1000 * 0x380 / length))
end

function T.jnt_compressed_rotation()
  local res, r = decodeOne(AnimationFixture.jntCompressed())
  -- Key 0 -> compressed entry {0x2000, 0x2000, 0, 0x1003, 0x1005}.
  -- getRotDataByIdx_ packs all five low-3-bit remainders as
  -- (e3&7)|((e2&7)<<3)|((e1&7)<<6)|((e0&7)<<9)|((e4&7)<<12), then keeps
  -- only the low 13 bits sign-extended (the trailing lsl #19 / asr #19):
  -- a 13-bit signed rotation element, never packed << 19.
  local s = jnt(res, r, 0, 0)
  Assert.equal(s.rot[1], 0x400) -- 0x2000 >> 3
  Assert.equal(s.rot[2], 0x400)
  Assert.equal(s.rot[3], 0)
  Assert.equal(s.rot[4], 0x200) -- 0x1003 >> 3
  Assert.equal(s.rot[5], 0x200) -- 0x1005 >> 3
  local packed = 3 + 0 * 8 + 0 * 64 + 0 * 512 + 5 * 4096 -- 0x5003
  Assert.equal(packed % 8192, 4099)
  Assert.equal(s.rot[6], 4099 - 8192) -- bit 12 set: sign-extended to -4093
  -- Row 2 = cross product of rows 0 x 1 (32-bit wrap, asr 12):
  -- (0x400 * -4093 - 0) >> 12 = -1024, (0 - 0x400 * -4093) >> 12 = 1023.
  Assert.equal(s.rot[7], -1024)
  Assert.equal(s.rot[8], 1023)
  Assert.equal(s.rot[9], 0) -- rows share the (x,y) plane
end

function T.jnt_invalid_pivot_index_raises()
  local fixture = AnimationFixture.jntDoor()
  local sectionAt, record = jntRecordOffset(fixture)
  local r = BinaryReader.new(fixture, "patch")
  local controlAt = sectionAt + record + r:u32le(sectionAt + record + 0x0C)
  local patched = fixture:sub(1, controlAt) .. NitroBuilder.u16(0x1F) .. fixture:sub(controlAt + 3)
  local res, reader = decodeOne(patched)
  local ok, err = pcall(Nsbca.sample, reader, res, 0, 0)
  Assert.isFalse(ok)
  Assert.equal(err.code, "NSBCA_ROT_PIVOT_INDEX_INVALID")
end

function T.jnt_malformed_target_offset_raises()
  local fixture = AnimationFixture.jntDoor()
  local sectionAt, record = jntRecordOffset(fixture)
  local tableAt = sectionAt + record + 0x14
  local patched = fixture:sub(1, tableAt) .. NitroBuilder.u16(0xFFFF) .. fixture:sub(tableAt + 3)
  throwsCode("READ_OUT_OF_BOUNDS", function()
    return NitroAnimation.decode(patched)
  end)
end

function T.animation_malformed_dictionary_raises()
  local fixture = AnimationFixture.jntDoor()
  -- The dict starts at section + 8; inflate its entry count so the entry
  -- reads run past the section.
  local sectionAt = BinaryReader.new(fixture, "patch"):u32le(0x10)
  local countAt = sectionAt + 8 + 1
  local patched = fixture:sub(1, countAt) .. string.char(0xFF) .. fixture:sub(countAt + 2)
  throwsCode("READ_OUT_OF_BOUNDS", function()
    return NitroAnimation.decode(patched)
  end)
end

function T.animation_unknown_file_magic_raises()
  throwsCode("ANM_UNKNOWN_FILE_MAGIC", function()
    return NitroAnimation.decode("XXXX" .. string.rep("\0", 12))
  end)
end

-- ---- NSBTA ----

function T.srt_constant_and_sampled_channels()
  local res, r = decodeOne(AnimationFixture.srtWater())
  Assert.equal(res.numTargets, 1)
  Assert.equal(res.targets[1].name, "en_sp1_3")
  local s = srt(res, r, 0, 0)
  -- The channel order follows GetTexSRTAnm_: the scale pair first, then
  -- the translation pair (the record reads transS at +0x18, not +0x00).
  Assert.equal(s.scaleS, 0x1000)
  Assert.equal(s.scaleT, 0x1000)
  Assert.equal(s.transS, 0)
  Assert.equal(s.transT, 1 * 0x1000)
  -- Identity scales make the pair "one"; the sampled translation-T curve
  -- scrolls the material.
  Assert.isTrue(s.scaleOne)
  Assert.isFalse(s.transOne)
  Assert.isTrue(s.rotOne) -- identity rotation constant
  -- fx16 sampled transT at frame 3.
  local s3 = srt(res, r, 0, 3 * 4096)
  Assert.equal(s3.transT, 4 * 0x1000)
  Assert.equal(s3.transS, 0)
end

function T.srt_constant_rotation()
  local res, r = decodeOne(AnimationFixture.srtConstRot())
  local s = srt(res, r, 0, 0)
  Assert.isFalse(s.rotOne)
  Assert.equal(s.rot.sin, math.floor(0.5 * 0x1000))
  Assert.equal(s.rot.cos, math.floor(0.8660 * 0x1000))
  -- The authored identity translation is zero; identity scales are 0x1000.
  Assert.isTrue(s.scaleOne)
  Assert.equal(s.scaleS, 0x1000)
  Assert.equal(s.scaleT, 0x1000)
  Assert.equal(s.transS, 0)
  Assert.equal(s.transT, 0)
  Assert.isTrue(s.transOne)
end

function T.srt_rotation_pairs()
  local res, r = decodeOne(AnimationFixture.srtSpin())
  local s0 = srt(res, r, 0, 0)
  Assert.equal(s0.rot.sin, math.floor(0.5 * 0x1000))
  Assert.equal(s0.rot.cos, math.floor(0.8660 * 0x1000))
  Assert.equal(s0.transS, 0)
  local s3 = srt(res, r, 0, 3 * 4096)
  Assert.equal(s3.transS, 3 * 0x1000)
  Assert.equal(s3.rot.sin, math.floor(0.7071 * 0x1000))
  -- The fixture packs -0.7071 as fx16, which floors to -2897.
  Assert.equal(s3.rot.cos, -2897)
end

-- ---- NSBTP ----

function T.btp_key_selection()
  local res, _ = decodeOne(AnimationFixture.patPcMb())
  Assert.equal(res.numTargets, 1)
  Assert.equal(res.targets[1].name, "pc_mb")
  Assert.equal(#res.textureNames, 4)
  Assert.equal(res.textureNames[1], "pc_mb.1")
  Assert.equal(res.paletteNames[4], "pc_mb.4_pl")

  local k0 = btp(res, 0, 3)
  Assert.equal(k0.frame, 0)
  Assert.equal(k0.texIdx, 0)
  local k1 = btp(res, 0, 4)
  Assert.equal(k1.frame, 4)
  Assert.equal(k1.texIdx, 1)
  local kLast = btp(res, 0, 67)
  Assert.equal(kLast.frame, 64)
  Assert.equal(kLast.texIdx, 0)
  -- A frame past the last key clamps to it.
  local kOver = btp(res, 0, 1000)
  Assert.equal(kOver.frame, 64)
end

-- ---- NSBMA ----

function T.bma_colors_and_alpha()
  local res, r = decodeOne(AnimationFixture.matFade())
  Assert.equal(res.targets[1].name, "yuka2_lm3")
  local s = bma(res, r, 0, 0)
  Assert.equal(s.diffuse, 0x203C)
  Assert.equal(s.ambient, 0x203C)
  Assert.equal(s.specular, 0x203C)
  Assert.equal(s.emission, 0x203C)
  Assert.equal(s.alpha, 31)
  local s10 = bma(res, r, 0, 10 * 4096)
  Assert.equal(s10.alpha, 26) -- 31 - 10/2
  local s59 = bma(res, r, 0, 59 * 4096)
  Assert.equal(s59.alpha, math.max(0, math.floor(31 - 59 / 2)))
end

return { tests = T }
