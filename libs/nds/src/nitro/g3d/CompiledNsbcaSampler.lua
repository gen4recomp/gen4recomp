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

-- Reconstruct the nine cells of one rotation key (u16 value).
local function reconstruct(clip, key, _)
  local cells = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  local index = key % 32768
  if key >= 0x8000 then
    -- The rotation tables are compiled to the highest key the clip's keys
    -- reference, and the artifact gate (ModelAsset.validate) requires every
    -- key inside its table and every pivot within 0..8, so an out-of-range
    -- read here is a program invariant, not data.
    local entry = assert(
      clip.compiled.rotData[index + 1],
      "rotation key " .. tostring(key) .. " indexes pivot entry " .. tostring(index) .. ", beyond the compiled table"
    )
    local pivot = entry.control % 16
    assert(pivot <= 8, "pivot index " .. tostring(pivot) .. " exceeds the 0..8 pivotUtil table")
    cells[pivot + 1] = bitSet(entry.control, 0x10) and -FX_UNIT or FX_UNIT
    local u = PIVOT_UTIL[pivot + 1]
    cells[u[1] + 1] = entry.a
    cells[u[2] + 1] = entry.b
    cells[u[3] + 1] = bitSet(entry.control, 0x20) and -entry.b or entry.b
    cells[u[4] + 1] = bitSet(entry.control, 0x40) and -entry.a or entry.a
    return cells, false
  end
  local e = assert(
    clip.compiled.pivotData[index + 1],
    "rotation key " .. tostring(key) .. " indexes compressed entry " .. tostring(index) .. ", beyond the compiled table"
  )
  for i = 1, 5 do
    cells[i] = asr(e[i], 3)
  end
  -- All five low-3-bit remainders feed cell 5, narrowed to the low 13
  -- bits sign-extended (the asm's trailing lsl #19 / asr #19 in
  -- getRotDataByIdx_): a 13-bit signed rotation element. This must stay
  -- in lockstep with NitroRotation.reconstruct over the raw bytes.
  local packed = (e[4] % 8) + (e[3] % 8) * 8 + (e[2] % 8) * 64 + (e[1] % 8) * 512 + (e[5] % 8) * 4096
  local low13 = packed % 8192
  cells[6] = low13 >= 4096 and low13 - 8192 or low13
  return cells, true
end

local function reconstructFinal(clip, key, targetIndex)
  local cells, compressed = reconstruct(clip, key, targetIndex)
  if compressed then
    computeCross(cells)
  end
  return cells
end

-- Merge path for the integer sampler's odd frames: cells = weight * a + b
-- across both reconstructions, then normalize (pivot) or cross (compressed).
local function mergeKeys(clip, keyA, keyB, weight, targetIndex)
  local ra, compressed = reconstruct(clip, keyA, targetIndex)
  local rb, rbCompressed = reconstruct(clip, keyB, targetIndex)
  local cells = {}
  for i = 1, 9 do
    cells[i] = ra[i] * weight + rb[i]
  end
  if compressed or rbCompressed then
    computeCross(cells)
  else
    normalizeRow(cells, 0)
    normalizeRow(cells, 3)
    normalizeRow(cells, 6)
  end
  return cells
end

-- Interpolating path: lerp cells 0-5 with the given step and fractional
-- part (32-bit muls, no final shift -- the asm omits it), then normalize
-- rows (pivot) or cross-product (compressed).
local function lerpKeys(clip, keyA, keyB, frac, step, targetIndex)
  local ra, compressed = reconstruct(clip, keyA, targetIndex)
  local rb, rbCompressed = reconstruct(clip, keyB, targetIndex)
  local cells = {}
  for i = 1, 6 do
    cells[i] = ra[i] * step + asr(mul32(rb[i] - ra[i], frac), 12)
  end
  if compressed or rbCompressed then
    computeCross(cells)
  else
    for i = 7, 9 do
      cells[i] = ra[i] * step + asr(mul32(rb[i] - ra[i], frac), 12)
    end
    normalizeRow(cells, 0)
    normalizeRow(cells, 3)
    normalizeRow(cells, 6)
  end
  return cells
end

-- ---- curve sampling (NitroCurve over compiled keys) ----

-- Ex-path interpolation: (a*step + mul32(b - a, frac) >> 12) >> log2(step).
local function lerpEx(a, b, step, frac)
  local delta = mul32(b - a, frac)
  return asr(a * step + asr(delta, 12), step == HALF and 1 or step == QUARTER and 2 or 0)
end

-- Sample one scalar-or-pair curve channel at `frameFx` (already clamped).
-- Returns { a, b } where b is nil for scalars and the inverse scale for
-- scale pairs.
local function curveValue(keys, keyIndex)
  -- Compiled keys hold scalars as numbers and scale pairs as tables; the
  -- arithmetic below expects NitroCurve's { value[, value2] } shape.
  local key = keys[keyIndex + 1]
  if type(key) == "table" then
    return key
  end
  return { key }
end

local function curveBetween(keys, i, j, interpolate, context)
  local a = curveValue(keys, i)
  local b = curveValue(keys, j)
  local out = { interpolate(a[1], b[1], context) }
  if a[2] ~= nil then
    out[2] = interpolate(a[2], b[2], context)
  end
  return out
end

local function interpolateWrapped(v1, v2, context)
  return v1 + asr(mul32(v2 - v1, context.frac), 12)
end

local function interpolateFractional(a, b, context)
  return lerpEx(a, b, context.step, context.fracWide)
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

local function sampleCurveValues(channel, frameFx, numFrame, interpolate, wrapFinal)
  local frame = math.floor(frameFx / FX_UNIT)
  local frac = frameFx % FX_UNIT
  local step = channel.rate
  local index = math.floor(frame / channel.rate)
  local keys = channel.keys
  local context = { frac = frac, step = step, fracWide = 0 }

  -- Final frame with the wrap flag: interpolate key[last] toward key[0].
  if wrapFinal and frame == numFrame - 1 and frac ~= 0 then
    return curveBetween(keys, index, 0, interpolateWrapped, context)
  end

  if interpolate and frac ~= 0 then
    context.fracWide = frameFx % (FX_UNIT * step)
    return curveBetween(keys, index, index + 1, interpolateFractional, context)
  end

  if step == HALF then
    if frame % 2 == 1 then
      if channel.storage == "fx32" then
        return curveBetween(keys, index, index + 1, averageFx32)
      end
      return curveBetween(keys, index, index + 1, averageFx16)
    end
    return curveValue(keys, index)
  elseif step == QUARTER then
    if frame % 4 ~= 0 then
      if frame % 4 == 2 then
        return curveBetween(keys, index, index + 1, averageFx16)
      end
      local a, b = index, index + 1
      if frame % 4 == 3 then
        a, b = b, a
      end
      return curveBetween(keys, a, b, weightedQuarter)
    end
    return curveValue(keys, index)
  end
  return curveValue(keys, frame)
end

local function sampleCurve(channel, frameFx, numFrame, interpolate, wrapFinal)
  return sampleCurveValues(channel, frameFx, numFrame, interpolate, wrapFinal)[1]
end

-- ---- rotation channel sampling (Nsbca.sampleRot over compiled data) ----

local function rotationKey(channel, keyIndex)
  -- The artifact gate requires every rotation curve to carry all referenced
  -- keys, so a missing key here is a program invariant, not data.
  return assert(
    channel.keys[keyIndex + 1],
    "rotation curve references key " .. tostring(keyIndex) .. " beyond its compiled array"
  )
end

local function sampleRot(clip, channel, frameFx, numFrame, targetIndex)
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
        return lerpKeys(clip, rotationKey(channel, index), rotationKey(channel, 0), frac, 1, targetIndex)
      end
      return reconstructFinal(clip, rotationKey(channel, index), targetIndex)
    end

    local index = math.floor(frame / channel.rate)
    local step = channel.rate
    local fracWide = frameFx % (FX_UNIT * channel.rate)
    return lerpKeys(clip, rotationKey(channel, index), rotationKey(channel, index + 1), fracWide, step, targetIndex)
  end

  -- Integer path.
  local rate = channel.rate
  local index = math.floor(frame / rate)
  if rate == HALF then
    if frame % 2 == 1 then
      return mergeKeys(clip, rotationKey(channel, index), rotationKey(channel, index + 1), 1, targetIndex)
    end
    return reconstructFinal(clip, rotationKey(channel, index), targetIndex)
  elseif rate == QUARTER then
    if frame % 4 ~= 0 then
      if frame % 4 == 2 then
        return mergeKeys(clip, rotationKey(channel, index), rotationKey(channel, index + 1), 1, targetIndex)
      end
      local a, b
      if frame % 4 == 1 then
        a, b = index, index + 1
      else
        a, b = index + 1, index
      end
      return mergeKeys(clip, rotationKey(channel, a), rotationKey(channel, b), 3, targetIndex)
    end
    return reconstructFinal(clip, rotationKey(channel, index), targetIndex)
  end
  return reconstructFinal(clip, rotationKey(channel, frame), targetIndex)
end

-- ---- target sampling ----

-- Sample one target of a compiled clip at `frameFx` (fixed-point). Returns
-- the NNSG3dAnmResult shape: fx32 words plus the from-model flag bits.
function CompiledNsbcaSampler.sample(clip, targetIndex, frameFx)
  assert(type(clip) == "table" and clip.compiled ~= nil, "CompiledNsbcaSampler requires a compiled NSBCA clip")
  local target = assert(
    clip.compiled.targets[targetIndex + 1],
    "compiled clip " .. clip.id .. " has no target " .. tostring(targetIndex)
  )
  local res = clip.compiled

  -- NNSi_G3dAnmCalcNsBca clamps the frame into [0, numFrame << 12 - 1].
  local maxFx = clip.frameCount * FX_UNIT - 1
  if frameFx > maxFx then
    frameFx = maxFx
  end
  if frameFx < 0 then
    frameFx = 0
  end

  local channels = target.channels
  local interpolate = res.anmFlags % 2 == 1
  local wrapFinal = math.floor(res.anmFlags / 2) % 2 == 1

  local flags = 0
  local trans = { 0, 0, 0 }
  local transFromModel = false
  for i, axis in ipairs({ "x", "y", "z" }) do
    local c = channels.trans[axis]
    if c.source == "model" then
      transFromModel = true
    elseif c.source == "constant" then
      trans[i] = c.value
    else
      trans[i] = sampleCurve(c, frameFx, clip.frameCount, interpolate, wrapFinal)
    end
  end
  if transFromModel then
    flags = flags + FROM_MODEL.trans
  end

  local rot = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  local rotFromModel = false
  local c = channels.rot
  if c.source == "model" then
    rotFromModel = true
  elseif c.source == "constant" then
    rot = reconstructFinal(clip, c.value, targetIndex)
  else
    rot = sampleRot(clip, c, frameFx, clip.frameCount, targetIndex)
  end
  if rotFromModel then
    flags = flags + FROM_MODEL.rot
  end

  local scale = { 0, 0, 0 }
  local scaleEx = { 0, 0, 0 }
  local scaleFromModel = false
  for i, axis in ipairs({ "x", "y", "z" }) do
    local s = channels.scale[axis]
    if s.source == "model" then
      scaleFromModel = true
    elseif s.source == "constant" then
      scale[i] = s.value
      scaleEx[i] = s.inverse or 0
    else
      local pair = sampleCurveValues(s, frameFx, clip.frameCount, interpolate, wrapFinal)
      scale[i] = pair[1]
      scaleEx[i] = pair[2] or 0
    end
  end
  -- The NSBCA scale channel is one 2-bit scale-mode field covering scale and
  -- inverse scale together, so both vectors travel under the single scale
  -- flag bit (there is no independent inverse-scale presence bit).
  if scaleFromModel then
    flags = flags + FROM_MODEL.scale
  end

  return {
    flags = flags,
    scale = scale,
    scaleEx = scaleEx,
    rot = rot,
    trans = trans,
  }
end

return CompiledNsbcaSampler
