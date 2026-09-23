-- Melon DS-derived fixtures for the DS vertex-lighting reference.
--
-- Authoritative source: melonDS-emu/melonDS, commit
-- d3cd6164deb1f217d4b262d18af3ef9b97e536c8, src/GPU3D.cpp
-- GPU3D::CalculateLighting (plus the 0x21 NORMAL and 0x32 LIGHT_VECTOR
-- command handlers that feed it). Every expected number below is computed by
-- hand from that literal integer algorithm -- never by calling DsLighting or
-- any other production code -- following melonDS's own sequencing exactly:
--
--   vtxbuff[c] = MatEmission[c] << 14                          -- start
--   per enabled light i (CurPolygonAttr bit i, the polygon light mask):
--     dot = sum_c( (LightDirection[i][c] * normaltrans[c]) >> 9 )
--       -- the bottom 9 bits are discarded PER COMPONENT, before adding;
--       -- this is NOT the same as summing raw products and shifting once.
--     if dot > 0:
--       diffdot = sign-extend(dot, 11 bits)
--       vtxbuff[c] += (MatDiffuse[c] * LightColor[i][c] * diffdot) & 0xFFFFF
--       -- specular: reuses dot, adds normaltrans.z, truncate-squares, then
--       -- multiplies by the light's precomputed SpecRecip and subtracts 1.0
--       -- (fixed-point); see specular_uses_the_reciprocal_shinelevel_sequence
--       -- below for the full derivation.
--     else shinelevel = 0
--     vtxbuff[c] += ((MatSpecular[c] * shinelevel) + (MatAmbient[c] << 9)) * LightColor[i][c]
--       -- ambient is a plain <<9 shift, added for every enabled light
--       -- regardless of the diffuse gate; it is not scaled by diffuse level.
--   VertexColor[c] = min(vtxbuff[c] >> 14, 31)                  -- only clamp
--
-- This replaces the previous DsLighting rewrite, which had the wrong
-- mathematical structure end to end: it divided the light color by 31 and
-- the material term by 512 as two separate normalized-float-style divisions
-- per light (melonDS never divides by 31 anywhere in this algorithm and only
-- shifts the accumulator once, by 14, at the very end); it summed dot
-- products in one shot and shifted once instead of truncating per
-- component; and its specular term built a conventional Blinn half-vector
-- and squared N.H, which is not melonDS's dot/SpecRecip/shinelevel
-- sequence. ds_lighting_test locked the wrong pipeline before this rewrite;
-- every fixture here is an independent, source-derived replacement.
--
-- Domain notes for the hand derivations below: NORMAL and LIGHT_VECTOR
-- command arguments both pack three signed 10-bit fields (GBATEK "1.0.9",
-- scale 512) -- LightDirection[i] (the register CalculateLighting actually
-- reads) is that same raw argument, negated and multiplied through the
-- current vector matrix, truncated back into an 11-bit signed container
-- still nominally at scale 512. Fixtures below quantize both operands to
-- that scale-512 domain by hand (round to nearest, matching how the
-- geometry engine loads a normalized vector into a fixed register) before
-- applying melonDS's literal per-component-shift dot product. This suite's
-- header also records the separate, larger finding
-- that FieldLightProfile's own vectorFx12 is authored at a different
-- (fx16/scale-4096) precision than this hardware argument, and is not
-- rotated by any vector matrix in the current pipeline at all -- a
-- reference-frame gap independent of the arithmetic bugs fixed here. The
-- production FieldLightProfile contract and its consumers own that distinction.
--
-- Each fixture calls DsLighting.vertexColorRgb5 (the module's only public
-- entry point) with plain float normal/light-direction inputs (the module's
-- existing contract: it quantizes them itself) and asserts the exact
-- RGB555 result computed above by hand. The comment on each fixture shows
-- the quantized integers and the melonDS arithmetic explicitly so the
-- expected number can be checked without running anything.

local Assert = require("tests.support.Assert")
local DsLighting = require("tests.support.DsLighting")

local T = {}

local function rgb555(r, g, b)
  return r + g * 32 + b * 1024
end

local function light(color, vec)
  return { enabled = true, colorRgb555 = rgb555(color, color, color), vectorFx12 = vec }
end

local function params(opts)
  return {
    normal = opts.normal or { 0, 0, 1 },
    diffuseRgb555 = opts.diffuse or rgb555(0, 0, 0),
    ambientRgb555 = opts.ambient or rgb555(0, 0, 0),
    specularRgb555 = opts.specular or rgb555(0, 0, 0),
    emissionRgb555 = opts.emission or rgb555(0, 0, 0),
    lights = opts.lights or {},
    lightMask = opts.lightMask or 0,
  }
end

-- 1. Emission only: vtxbuff = MatEmission << 14, no lights enabled, so the
-- final >> 14 exactly recovers MatEmission untouched. (5,10,15) trivially
-- survives both the correct pipeline and any single-light-free pipeline;
-- required by the spec regardless of whether it happens to coincide with
-- other implementations.
function T.emission_only(_)
  local c = DsLighting.vertexColorRgb5(params({ emission = rgb555(5, 10, 15), lightMask = 0 }))
  local r, g, b = DsLighting.unpackRgb555(c)
  Assert.equal(r, 5)
  Assert.equal(g, 10)
  Assert.equal(b, 15)
end

-- 2. Ambient only, midrange light color. MatDiffuse = MatSpecular = 0, so
-- the diffuse gate is irrelevant (any enabled light direction works): the
-- only surviving term is the ambient/specular line, ((0 + (MatAmbient<<9))
-- * LightColor). MatAmbient=17, LightColor=15 (about half full scale):
--   vtxbuff = (17<<9)*15 = 8704*15 = 130560
--   130560 >> 14 = floor(130560/16384) = 7 (7*16384=114688, 8*16384=131072)
-- melonDS's exact-shift ambient is not the same operation as a light-color/31
-- normalization: floor(15*17/31) = floor(255/31) = 8, one unit brighter.
function T.ambient_only_midrange_light_color(_)
  local c = DsLighting.vertexColorRgb5(params({
    ambient = rgb555(17, 17, 17),
    lights = { light(15, { 0, 0, -4096 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(7, 7, 7))
end

-- 3. Diffuse dot exercising component-wise truncation. Unit-vector normal
-- (0.6794128682,-0.7314995667,0.0575025088), quantized (scale 512, round to
-- nearest) to N=(348,-375,29). The light's authored direction
-- (-0.1692758096,0.5645169007,0.8078776944), negated per the LIGHT_VECTOR
-- command handler and quantized the same way, gives the actual
-- LightDirection register L=(87,-289,-414).
--   term_x = 87*348   = 30276;  floor(30276/512)   = 59
--   term_y = -289*-375 = 108375; floor(108375/512) = 211
--   term_z = -414*29  = -12006; floor(-12006/512)  = -24
--   dot (correct, per-component) = 59+211-24 = 246 (positive, gate fires)
-- Summing the raw products first and shifting once (the bug this fixture
-- specifically catches) gives 30276+108375-12006 = 126645,
-- floor(126645/512) = 247, one unit off.
-- vtxbuff = MatDiffuse(31)*LightColor(31)*246 = 961*246 = 236406
--   236406 >> 14 = floor(236406/16384) = 14 (14*16384=229376, 15*16384=245760)
function T.diffuse_dot_truncates_component_wise_not_after_summing(_)
  local c = DsLighting.vertexColorRgb5(params({
    normal = { 0.6794128682, -0.7314995667, 0.0575025088 },
    diffuse = rgb555(31, 31, 31),
    lights = { light(31, { -693.3537161216, 2312.2612252672, 3309.0670362624 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(14, 14, 14))
end

-- 4. A diffuse dot at a sign boundary where per-component truncation and
-- summed-then-truncated truncation land on opposite sides of the "dot > 0"
-- gate. Unit-vector normal (-0.2203804515,0.6715671726,-0.7074107642)
-- quantized (scale 512) to N=(-113,344,-362); the light's authored direction
-- (-0.8156686822,0.2652960562,0.5141036894), negated and quantized the same
-- way, gives LightDirection L=(418,-136,-263):
--   term_x = 418*-113  = -47234;  floor(-47234/512)  = -93
--   term_y = -136*344  = -46784;  floor(-46784/512)  = -92
--   term_z = -263*-362 = 95206;   floor(95206/512)   = 185
--   dot (correct, per-component) = -93-92+185 = 0 -> gate fails (dot > 0
--   is strict; zero does not fire)
-- Summing the raw products first and shifting once instead gives
-- -47234-46784+95206 = 1188, floor(1188/512) = 2, which WOULD pass the
-- gate. A nonzero MatDiffuse (17) with MatAmbient (2) and LightColor (31)
-- makes the two orderings diverge in the final channel:
--   ambient term = (2<<9)*31 = 1024*31 = 31744; >>14 = 1
--   correct (gate fails): vtxbuff = 31744 (ambient only); >>14 = 1
--   wrong-order (gate fires): vtxbuff = 31744 + 17*31*2 = 32798; >>14 = 2
function T.diffuse_dot_sign_boundary_from_component_wise_truncation(_)
  local c = DsLighting.vertexColorRgb5(params({
    normal = { -0.2203804515, 0.6715671726, -0.7074107642 },
    diffuse = rgb555(17, 17, 17),
    ambient = rgb555(2, 2, 2),
    lights = { light(31, { -0.8156686822 * 4096, 0.2652960562 * 4096, 0.5141036894 * 4096 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(1, 1, 1))
end

-- 5. Specular with a nontrivial SpecRecip. Head-on setup: normal
-- (0.6,0,0.8), and the LightDirection register aligned with the normal
-- (quantized N=L=(307,0,410), matching a light reflecting straight back at
-- the viewer). dot = floor(307*307/512)+floor(410*410/512) = 184+328 = 512
-- (the diffuse gate fires; MatDiffuse is 0 here so no diffuse term joins).
-- Specular reuses dot, adds normaltrans.z (410): 512+410 = 922 (well inside
-- the 11-bit signed range, no wraparound). Truncate-square:
--   ((922*922) >> 10) & 0x3FF = (850084 >> 10) & 0x3FF = 830 & 1023 = 830
-- SpecRecip is melonDS's reciprocal of (LightDirection.z + 1.0) in this
-- fixed domain: den = 410+512 = 922, SpecRecip = floor((1<<18)/922) =
-- floor(262144/922) = 284 (nontrivial: neither 0 nor a power of two).
--   shinelevel = ((830*284) >> 8) - 512 = floor(235720/256) - 512 = 920-512 = 408
-- MatSpecular=31, LightColor=31 (ambient/diffuse/emission all 0):
--   vtxbuff = (31*408 + 0)*31 = 31*31*408 = 961*408 = 392088
--   392088 >> 14 = floor(392088/16384) = 23 (23*16384=376832, 24*16384=393216)
-- This is not a conventional Blinn half-vector/N.H^2 specular value; a
-- half-vector implementation over the same inputs does not reproduce 23.
function T.specular_uses_the_reciprocal_shinelevel_sequence(_)
  local c = DsLighting.vertexColorRgb5(params({
    normal = { 0.6, 0, 0.8 },
    specular = rgb555(31, 31, 31),
    lights = { light(31, { -2457.6, 0, -3276.8 }) },
    lightMask = 1,
  }))
  Assert.equal(c, rgb555(23, 23, 23))
end

-- 6. Multiple enabled lights accumulate past 31 before the final clamp: two
-- identical head-on lights (MatDiffuse=22, LightColor=30, ld=512 each):
--   per light: 22*30*512 = 337920; two lights sum (unclamped) = 675840
--   675840 >> 14 = floor(675840/16384) = 41, clamped to 31
-- Neither light's own contribution (337920>>14 = 20) exceeds 31 on its own;
-- only the combined accumulator does, and only the final result saturates
-- -- melonDS never clamps per light or per term.
function T.multiple_lights_accumulate_past_31_and_saturate_only_at_the_end(_)
  local sameLight = light(30, { 0, 0, -4096 })
  local c = DsLighting.vertexColorRgb5(params({
    diffuse = rgb555(22, 22, 22),
    lights = { sameLight, sameLight },
    lightMask = 3,
  }))
  Assert.equal(c, rgb555(31, 31, 31))
end

-- 7. Light-mask exclusion: CurPolygonAttr bit i gates light i entirely (no
-- contribution of any kind, including ambient) when unset. MatDiffuse=20,
-- LightColor=9, head-on (ld=512):
--   admitted: vtxbuff = 20*9*512 = 92160; >>14 = floor(92160/16384) = 5
--   excluded: vtxbuff = 0 (emission only, here 0); final = 0
function T.light_mask_excludes_a_light_entirely(_)
  local theLight = light(9, { 0, 0, -4096 })
  local admitted =
    DsLighting.vertexColorRgb5(params({ diffuse = rgb555(20, 20, 20), lights = { theLight }, lightMask = 1 }))
  local excluded =
    DsLighting.vertexColorRgb5(params({ diffuse = rgb555(20, 20, 20), lights = { theLight }, lightMask = 0 }))
  Assert.equal(admitted, rgb555(5, 5, 5))
  Assert.equal(excluded, rgb555(0, 0, 0))
end

return { tests = T }
