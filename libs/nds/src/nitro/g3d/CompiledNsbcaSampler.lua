-- CompiledNsbcaSampler: the runtime sampler for compiled NSBCA clips.
--
-- A compiled clip (NsbcaClipCompiler, digest side) carries every channel,
-- curve key, and rotation-table entry as plain numbers; this module
-- reproduces Nsbca.sample's NitroSystem arithmetic over that data. The math
-- is the exact transcription of pokediamond arm9/asm/NNS_G3D_nsbca.s
-- (pinned commit 038cccaed, 2025-12-24) that Nsbca.lua already validates
-- against the real ROM; the two samplers must stay in lockstep and the
-- cross-check test requires bit-identical results for the same resource.
--
-- Sampling one target returns the NNSG3dAnmResult shape JointAnimBlend
-- consumes -- fx32 words plus the from-model flag bits:
--
--   { flags, scale = {x,y,z}, scaleEx = {x,y,z},
--     rot = {9 cells}, trans = {x,y,z} }
--
-- and NitroJointState.srtFromBlend turns that into the SRT record the pose
-- evaluator composes. The frame is clamped into [0, numFrame << 12 - 1],
-- exactly like NNSi_G3dAnmCalcNsBca. Every curve carries limit == numFrame
-- (asserted at compile), so the sampling paths never see a frame past the
-- last key. Pure domain module.

local JointAnimBlend = require("libs.nds.src.nitro.g3d.JointAnimBlend")

local CompiledNsbcaSampler = {}

-- One fixed-point unit: fx32 values are 1.M.12 (4096 per unit), and the
-- sampler works on raw words throughout.
local FX_UNIT = 4096

local HALF, QUARTER = 2, 4
local FROM_MODEL = JointAnimBlend.FROM_MODEL

local AXES = { "x", "y", "z" }

local function bitSet(value, bit)
  return math.floor(value / bit) % 2 == 1
end

-- The low 32 bits of a signed product, as the ARM `mul` leaves it.
local function mul32(a, b)
  local p = (a * b) % 4294967296
  if p >= 2147483648 then
    p = p - 4294967296
  end
  return p
end

local function asr(value, bits)
  return math.floor(value / 2 ^ bits)
end

local function wrap32(v)
  local p = v % 4294967296
  if p >= 2147483648 then
    p = p - 4294967296
  end
  return p
end

-- Cross product for the third row (cells 6-8 = row 0 x row 1), as the asm
-- computes it: 32-bit wraps, arithmetic shift by 12.
local function computeCross(cells)
  cells[7] = asr(wrap32(mul32(cells[2], cells[6]) - mul32(cells[3], cells[5])), 12)
  cells[8] = asr(wrap32(mul32(cells[3], cells[4]) - mul32(cells[1], cells[6])), 12)
  cells[9] = asr(wrap32(mul32(cells[1], cells[5]) - mul32(cells[2], cells[4])), 12)
end

-- Double-precision row normalization (VEC_Normalize stand-in; the SDK's
-- exact implementation is unavailable, within the bind-pose tolerance).
local function normalizeRow(cells, offset)
  local x, y, z = cells[offset + 1], cells[offset + 2], cells[offset + 3]
  local length = math.sqrt(x * x + y * y + z * z)
  if length == 0 then
    return
  end
  cells[offset + 1] = math.floor(x * FX_UNIT / length)
  cells[offset + 2] = math.floor(y * FX_UNIT / length)
  cells[offset + 3] = math.floor(z * FX_UNIT / length)
end

-- ---- rotation reconstruction (NitroRotation over compiled tables) ----

local PIVOT_UTIL = {
  { 4, 5, 7, 8 },
  { 3, 5, 6, 8 },
  { 3, 4, 6, 7 },
  { 1, 2, 7, 8 },
  { 0, 2, 6, 8 },
  { 0, 1, 6, 7 },
  { 1, 2, 4, 5 },
  { 0, 2, 3, 5 },
  { 0, 1, 3, 4 },
}

-- Reconstruct the nine cells of one rotation key (u16 value) into `out`.
-- Returns true for compressed entries, false for pivot entries.
local function reconstructInto(clip, key, out)
  for i = 1, 9 do
    out[i] = 0
  end
  local index = key % 32768
  if key >= 0x8000 then
    -- The rotation tables are compiled to the highest key the clip's keys
    -- reference, and the artifact gate (ModelAsset.validate) requires every
    -- key inside its table and every pivot within 0..8, so an out-of-range
    -- read here is a program invariant, not data.
    local entry = clip.compiled.rotData[index + 1]
    if entry == nil then
      error(
        "rotation key " .. tostring(key) .. " indexes pivot entry " .. tostring(index) .. ", beyond the compiled table"
      )
    end
    local pivot = entry.control % 16
    if pivot > 8 then
      error("pivot index " .. tostring(pivot) .. " exceeds the 0..8 pivotUtil table")
    end
    out[pivot + 1] = bitSet(entry.control, 0x10) and -FX_UNIT or FX_UNIT
    local u = PIVOT_UTIL[pivot + 1]
    out[u[1] + 1] = entry.a
    out[u[2] + 1] = entry.b
    out[u[3] + 1] = bitSet(entry.control, 0x20) and -entry.b or entry.b
    out[u[4] + 1] = bitSet(entry.control, 0x40) and -entry.a or entry.a
    return false
  end
  local e = clip.compiled.pivotData[index + 1]
  if e == nil then
    error(
      "rotation key "
        .. tostring(key)
        .. " indexes compressed entry "
        .. tostring(index)
        .. ", beyond the compiled table"
    )
  end
  for i = 1, 5 do
    out[i] = asr(e[i], 3)
  end
  -- All five low-3-bit remainders feed cell 5, narrowed to the low 13
  -- bits sign-extended (the asm's trailing lsl #19 / asr #19 in
  -- getRotDataByIdx_): a 13-bit signed rotation element. This must stay
  -- in lockstep with NitroRotation.reconstruct over the raw bytes.
  local packed = (e[4] % 8) + (e[3] % 8) * 8 + (e[2] % 8) * 64 + (e[1] % 8) * 512 + (e[5] % 8) * 4096
  local low13 = packed % 8192
  out[6] = low13 >= 4096 and low13 - 8192 or low13
  return true
end

local function reconstructFinalInto(clip, key, out)
  local compressed = reconstructInto(clip, key, out)
  if compressed then
    computeCross(out)
  end
  return out
end

-- Merge path for the integer sampler's odd frames: out = weight * a + b
-- across both reconstructions, then normalize (pivot) or cross (compressed).
local function mergeKeysInto(clip, keyA, keyB, weight, out, workA, workB)
  local compressedA = reconstructInto(clip, keyA, workA)
  local compressedB = reconstructInto(clip, keyB, workB)
  for i = 1, 9 do
    out[i] = workA[i] * weight + workB[i]
  end
  if compressedA or compressedB then
    computeCross(out)
  else
    normalizeRow(out, 0)
    normalizeRow(out, 3)
    normalizeRow(out, 6)
  end
  return out
end

-- Interpolating path: lerp out cells 0-5 with the given step and fractional
-- part (32-bit muls, no final shift -- the asm omits it), then normalize
-- rows (pivot) or cross-product (compressed).
local function lerpKeysInto(clip, keyA, keyB, frac, step, out, workA, workB)
  local compressedA = reconstructInto(clip, keyA, workA)
  local compressedB = reconstructInto(clip, keyB, workB)
  for i = 1, 6 do
    out[i] = workA[i] * step + asr(mul32(workB[i] - workA[i], frac), 12)
  end
  if compressedA or compressedB then
    computeCross(out)
  else
    for i = 7, 9 do
      out[i] = workA[i] * step + asr(mul32(workB[i] - workA[i], frac), 12)
    end
    normalizeRow(out, 0)
    normalizeRow(out, 3)
    normalizeRow(out, 6)
  end
  return out
end

-- ---- curve sampling (NitroCurve over compiled keys) ----

-- Ex-path interpolation: (a*step + mul32(b - a, frac) >> 12) >> log2(step).
local function lerpEx(a, b, step, frac)
  local delta = mul32(b - a, frac)
  return asr(a * step + asr(delta, 12), step == HALF and 1 or step == QUARTER and 2 or 0)
end

local function interpolateWrappedScalar(v1, v2, frac)
  return v1 + asr(mul32(v2 - v1, frac), 12)
end

local function averageFx32(a, b)
  return asr(a, 1) + asr(b, 1)
end

local function averageFx16(a, b)
  return asr(a + b, 1)
end

local function weightedQuarter(a, b)
  return asr(3 * a + b, 2)
end

-- Compiled keys hold scalars as numbers and scale pairs as tables
-- { scale, inverse }; read them without building value records.
local function keyScalar(keys, keyIndex)
  local key = keys[keyIndex + 1]
  if type(key) == "table" then
    return key[1]
  end
  return key
end

local function keyPair(keys, keyIndex)
  local key = keys[keyIndex + 1]
  if type(key) == "table" then
    return key[1], key[2]
  end
  return key, nil
end

-- Sample one scalar curve channel at `frameFx` (already clamped).
local function sampleScalar(channel, frameFx, numFrame, interpolate, wrapFinal)
  local frame = math.floor(frameFx / FX_UNIT)
  local frac = frameFx % FX_UNIT
  local step = channel.rate
  local index = math.floor(frame / channel.rate)
  local keys = channel.keys

  -- Final frame with the wrap flag: interpolate key[last] toward key[0].
  if wrapFinal and frame == numFrame - 1 and frac ~= 0 then
    return interpolateWrappedScalar(keyScalar(keys, index), keyScalar(keys, 0), frac)
  end

  if interpolate and frac ~= 0 then
    local fracWide = frameFx % (FX_UNIT * step)
    return lerpEx(keyScalar(keys, index), keyScalar(keys, index + 1), step, fracWide)
  end

  if step == HALF then
    if frame % 2 == 1 then
      local a, b = keyScalar(keys, index), keyScalar(keys, index + 1)
      if channel.storage == "fx32" then
        return averageFx32(a, b)
      end
      return averageFx16(a, b)
    end
    return keyScalar(keys, index)
  elseif step == QUARTER then
    if frame % 4 ~= 0 then
      if frame % 4 == 2 then
        return averageFx16(keyScalar(keys, index), keyScalar(keys, index + 1))
      end
      local a, b = index, index + 1
      if frame % 4 == 3 then
        a, b = b, a
      end
      return weightedQuarter(keyScalar(keys, a), keyScalar(keys, b))
    end
    return keyScalar(keys, index)
  end
  return keyScalar(keys, frame)
end

-- Sample one scale-pair curve channel at `frameFx` (already clamped).
-- Returns scale, inverseScale; the inverse is nil when the sampled keys
-- carry no second value, matching the allocating sampler's pair contract.
local function samplePair(channel, frameFx, numFrame, interpolate, wrapFinal)
  local frame = math.floor(frameFx / FX_UNIT)
  local frac = frameFx % FX_UNIT
  local step = channel.rate
  local index = math.floor(frame / channel.rate)
  local keys = channel.keys

  -- Final frame with the wrap flag: interpolate key[last] toward key[0].
  if wrapFinal and frame == numFrame - 1 and frac ~= 0 then
    local a1, a2 = keyPair(keys, index)
    local b1, b2 = keyPair(keys, 0)
    local v = interpolateWrappedScalar(a1, b1, frac)
    if a2 ~= nil then
      return v, interpolateWrappedScalar(a2, b2, frac)
    end
    return v, nil
  end

  if interpolate and frac ~= 0 then
    local fracWide = frameFx % (FX_UNIT * step)
    local a1, a2 = keyPair(keys, index)
    local b1, b2 = keyPair(keys, index + 1)
    local v = lerpEx(a1, b1, step, fracWide)
    if a2 ~= nil then
      return v, lerpEx(a2, b2, step, fracWide)
    end
    return v, nil
  end

  if step == HALF then
    if frame % 2 == 1 then
      local a1, a2 = keyPair(keys, index)
      local b1, b2 = keyPair(keys, index + 1)
      local second
      if channel.storage == "fx32" then
        second = a2 ~= nil and averageFx32(a2, b2) or nil
        return averageFx32(a1, b1), second
      end
      second = a2 ~= nil and averageFx16(a2, b2) or nil
      return averageFx16(a1, b1), second
    end
    return keyPair(keys, index)
  elseif step == QUARTER then
    if frame % 4 ~= 0 then
      if frame % 4 == 2 then
        local a1, a2 = keyPair(keys, index)
        local b1, b2 = keyPair(keys, index + 1)
        local second = a2 ~= nil and averageFx16(a2, b2) or nil
        return averageFx16(a1, b1), second
      end
      local a, b = index, index + 1
      if frame % 4 == 3 then
        a, b = b, a
      end
      -- The allocating path interpolates from the first key's pair
      -- presence: mirror that gate so scalar/pair behavior matches.
      local a1, a2 = keyPair(keys, a)
      local b1, b2 = keyPair(keys, b)
      local second = a2 ~= nil and weightedQuarter(a2, b2) or nil
      return weightedQuarter(a1, b1), second
    end
    return keyPair(keys, index)
  end
  return keyPair(keys, frame)
end

-- ---- rotation channel sampling (Nsbca.sampleRot over compiled data) ----

local function rotationKey(channel, keyIndex)
  -- The artifact gate requires every rotation curve to carry all referenced
  -- keys, so a missing key here is a program invariant, not data.
  local key = channel.keys[keyIndex + 1]
  if key == nil then
    error("rotation curve references key " .. tostring(keyIndex) .. " beyond its compiled array")
  end
  return key
end

local function sampleRotInto(clip, channel, frameFx, numFrame, out, workA, workB)
  local frame = math.floor(frameFx / FX_UNIT)
  local frac = frameFx % FX_UNIT
  local anmFlags = clip.compiled.anmFlags
  local interpolate = anmFlags % 2 == 1
  local wrapFinal = math.floor(anmFlags / 2) % 2 == 1

  -- Ex path: fractional part present and interpolation enabled.
  if interpolate and frac ~= 0 then
    if frame == numFrame - 1 then
      local index = frame
      if channel.rate == HALF then
        index = frame % 2 + math.floor(frame / 2)
      elseif channel.rate == QUARTER then
        index = frame % 4 + math.floor(frame / 4)
      end
      if wrapFinal then
        return lerpKeysInto(clip, rotationKey(channel, index), rotationKey(channel, 0), frac, 1, out, workA, workB)
      end
      return reconstructFinalInto(clip, rotationKey(channel, index), out)
    end

    local index = math.floor(frame / channel.rate)
    local step = channel.rate
    local fracWide = frameFx % (FX_UNIT * channel.rate)
    return lerpKeysInto(
      clip,
      rotationKey(channel, index),
      rotationKey(channel, index + 1),
      fracWide,
      step,
      out,
      workA,
      workB
    )
  end

  -- Integer path.
  local rate = channel.rate
  local index = math.floor(frame / rate)
  if rate == HALF then
    if frame % 2 == 1 then
      return mergeKeysInto(clip, rotationKey(channel, index), rotationKey(channel, index + 1), 1, out, workA, workB)
    end
    return reconstructFinalInto(clip, rotationKey(channel, index), out)
  elseif rate == QUARTER then
    if frame % 4 ~= 0 then
      if frame % 4 == 2 then
        return mergeKeysInto(clip, rotationKey(channel, index), rotationKey(channel, index + 1), 1, out, workA, workB)
      end
      local a, b
      if frame % 4 == 1 then
        a, b = index, index + 1
      else
        a, b = index + 1, index
      end
      return mergeKeysInto(clip, rotationKey(channel, a), rotationKey(channel, b), 3, out, workA, workB)
    end
    return reconstructFinalInto(clip, rotationKey(channel, index), out)
  end
  return reconstructFinalInto(clip, rotationKey(channel, frame), out)
end

-- ---- target sampling ----

---@class NsbcaSamplerScratch
---@field result JointAnimResult -- the reusable sampled result
---@field workA number[] -- 9-cell rotation reconstruction workspace
---@field workB number[] -- 9-cell rotation reconstruction workspace

-- Owner-held reusable sampling storage: one persistent result with stable
-- nested arrays plus two 9-cell rotation work arrays.
---@return NsbcaSamplerScratch
function CompiledNsbcaSampler.newScratch()
  return {
    result = {
      flags = 0,
      scale = { 0, 0, 0 },
      scaleEx = { 0, 0, 0 },
      rot = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
      trans = { 0, 0, 0 },
    },
    workA = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    workB = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
  }
end

-- Sample one target of a compiled clip at `frameFx` (fixed-point) into
-- scratch-owned storage. Returns `scratch.result`; repeated calls preserve
-- the result and nested-array identities while overwriting every value and
-- flag. From-model channels write zero placeholders, matching the
-- allocating sampler, so no previous sample data leaks semantically.
---@param scratch NsbcaSamplerScratch
---@param clip table<string, unknown>
---@param targetIndex integer
---@param frameFx number
---@return JointAnimResult
function CompiledNsbcaSampler.sampleInto(scratch, clip, targetIndex, frameFx)
  assert(
    type(scratch) == "table" and type(scratch.result) == "table",
    "CompiledNsbcaSampler.sampleInto requires sampler scratch"
  )
  assert(type(clip) == "table" and clip.compiled ~= nil, "CompiledNsbcaSampler requires a compiled NSBCA clip")
  local target = clip.compiled.targets[targetIndex + 1]
  if target == nil then
    error("compiled clip " .. tostring(clip.id) .. " has no target " .. tostring(targetIndex))
  end

  -- NNSi_G3dAnmCalcNsBca clamps the frame into [0, numFrame << 12 - 1].
  local maxFx = clip.frameCount * FX_UNIT - 1
  if frameFx > maxFx then
    frameFx = maxFx
  end
  if frameFx < 0 then
    frameFx = 0
  end

  local result = scratch.result
  local channels = target.channels
  local interpolate = clip.compiled.anmFlags % 2 == 1
  local wrapFinal = math.floor(clip.compiled.anmFlags / 2) % 2 == 1

  local flags = 0
  local transFromModel = false
  for i = 1, 3 do
    local c = channels.trans[AXES[i]]
    if c.source == "model" then
      transFromModel = true
      result.trans[i] = 0
    elseif c.source == "constant" then
      result.trans[i] = c.value
    else
      result.trans[i] = sampleScalar(c, frameFx, clip.frameCount, interpolate, wrapFinal)
    end
  end
  if transFromModel then
    flags = flags + FROM_MODEL.trans
  end

  local rotFromModel = false
  local rc = channels.rot
  if rc.source == "model" then
    rotFromModel = true
    for i = 1, 9 do
      result.rot[i] = 0
    end
  elseif rc.source == "constant" then
    reconstructFinalInto(clip, rc.value, result.rot)
  else
    sampleRotInto(clip, rc, frameFx, clip.frameCount, result.rot, scratch.workA, scratch.workB)
  end
  if rotFromModel then
    flags = flags + FROM_MODEL.rot
  end

  local scaleFromModel = false
  for i = 1, 3 do
    local s = channels.scale[AXES[i]]
    if s.source == "model" then
      scaleFromModel = true
      result.scale[i] = 0
      result.scaleEx[i] = 0
    elseif s.source == "constant" then
      result.scale[i] = s.value
      result.scaleEx[i] = s.inverse or 0
    else
      local v, vex = samplePair(s, frameFx, clip.frameCount, interpolate, wrapFinal)
      result.scale[i] = v
      result.scaleEx[i] = vex or 0
    end
  end
  -- The NSBCA scale channel is one 2-bit scale-mode field covering scale and
  -- inverse scale together, so both vectors travel under the single scale
  -- flag bit (there is no independent inverse-scale presence bit).
  if scaleFromModel then
    flags = flags + FROM_MODEL.scale
  end

  result.flags = flags
  return result
end

-- Sample one target of a compiled clip at `frameFx` (fixed-point). Returns
-- the NNSG3dAnmResult shape: fx32 words plus the from-model flag bits.
function CompiledNsbcaSampler.sample(clip, targetIndex, frameFx)
  return CompiledNsbcaSampler.sampleInto(CompiledNsbcaSampler.newScratch(), clip, targetIndex, frameFx)
end

return CompiledNsbcaSampler
