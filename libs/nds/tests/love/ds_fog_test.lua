-- MelonDS-derived fixtures for the DS per-pixel fog density/blend reference
-- (tests/support/DsFog.lua).
--
-- Authoritative source: melonDS-emu/melonDS, commit
-- d3cd6164deb1f217d4b262d18af3ef9b97e536c8, src/GPU3D_Soft.cpp,
-- SoftRenderer3D::CalculateFogDensity and the post-density RGB/alpha blend in
-- SoftRenderer3D::RenderPixel. Every expected number below is computed by
-- hand from that literal integer algorithm -- never by calling DsFog or any
-- other code.
--
-- The algorithm (see DsFog.lua's header for the full derivation):
--
--   renderFogOffset = fogOffsetRaw * 0x200
--   if z < renderFogOffset: densityId, densityFrac = 0, 0
--   else:
--     shifted = floor((z - renderFogOffset) / 4) * 2^fogShift
--     densityId = floor(shifted / 0x20000)
--     if densityId >= 32: densityId, densityFrac = 32, 0
--     else: densityFrac = shifted - densityId * 0x20000
--   density = floor((expanded[densityId] * (0x20000 - densityFrac)
--                     + expanded[densityId + 1] * densityFrac) / 0x20000)
--   if density >= 127: density = 128
--
-- where expanded[k] duplicates table[0] at k=0 and table[31] at k=33.
--
-- A 1-indexed 32-entry ramp table, table32[k] = 4*(k-1) for k=1..32 (the
-- values 0, 4, 8, ..., 124), matching HgssFieldFog.rampTable()'s shape --
-- reproduced here inline rather than required, since the renderer must not
-- import romdump.
local function rampTable()
  local t = {}
  for k = 1, 32 do
    t[k] = 4 * (k - 1)
  end
  return t
end

-- A 1-indexed 32-entry table of all 255, matching HgssFieldFog.flashTable()'s
-- shape (Flash/Flash-2's fog fills every entry with the maximum byte value).
local function allMaxTable()
  local t = {}
  for k = 1, 32 do
    t[k] = 255
  end
  return t
end

local Assert = require("tests.support.Assert")
local DsFog = require("tests.support.DsFog")

local T = {}

-- Case 1: a depth strictly below the offset always yields densityId 0 with
-- no fraction, so density is exactly the ramp's first entry (0).
-- fogOffsetRaw=10 -> renderFogOffset = 10*0x200 = 5120; z=1000 < 5120.
function T.depth_below_offset_yields_the_first_table_entry(_)
  local density = DsFog.density(1000, 10, 0, rampTable())
  Assert.equal(density, 0, "z below renderFogOffset must read the ramp's first entry (0)")
end

-- Case 2: a depth exactly equal to the offset takes the "z >= offset" branch
-- (the comparison is strict "<"), producing z=0, densityId=0, frac=0 -- the
-- same boundary result as case 1, proving the boundary is inclusive on the
-- "at offset" side without a fencepost error.
-- fogOffsetRaw=10 -> renderFogOffset=5120; z=5120 exactly.
function T.depth_exactly_at_offset_yields_the_first_table_entry(_)
  local density = DsFog.density(5120, 10, 0, rampTable())
  Assert.equal(density, 0, "z exactly at renderFogOffset must still read the ramp's first entry (0)")
end

-- Case 3: halfway through the [densityId=5, densityId=6] interval. With
-- fogOffsetRaw=0, fogShift=0: shifted = floor(z/4). Choosing z=2883584 gives
-- shifted=720896 = 5*0x20000 + 0x10000 (0x10000 is exactly half of 0x20000),
-- i.e. densityId=5, densityFrac=0x10000 (exact midpoint). The ramp's
-- entries 5 and 6 (0-indexed 4 and 5) are source[4]=16 and source[5]=20;
-- their exact midpoint is 18.
function T.halfway_through_an_interpolation_interval_produces_the_midpoint(_)
  local density = DsFog.density(2883584, 0, 0, rampTable())
  Assert.equal(density, 18, "the exact midpoint between ramp entries 16 and 20 is 18")
end

-- Case 4: exactly at a density-table boundary (densityFrac=0, not merely
-- close to it), proving the index/fraction split lands on entry 3 (value 8)
-- rather than off-by-one onto entry 2 (4) or entry 4 (12).
-- z=1572864 -> shifted=393216=3*0x20000 exactly -> densityId=3, frac=0.
function T.exactly_at_a_density_table_boundary_selects_the_correct_entry(_)
  local density = DsFog.density(1572864, 0, 0, rampTable())
  Assert.equal(density, 8, "densityId=3 with zero fraction must read the ramp's third entry (8) exactly")
end

-- Case 5: far beyond the final interval clamps densityId to 32 (not merely
-- large) with densityFrac forced to 0, reading the table's last entry (124)
-- exactly, not a garbage extrapolation past it.
-- z=20971520 -> shifted=5242880=40*0x20000 (>= 32*0x20000) -> clamp 32/0.
function T.beyond_the_final_interval_clamps_to_the_last_table_entry(_)
  local density = DsFog.density(20971520, 0, 0, rampTable())
  Assert.equal(density, 124, "densityId clamped to 32 must read the ramp's last entry (124), not overflow past it")
end

-- Case 6: a raw interpolated density of exactly 127 saturates to 128 (the
-- documented >=127 rule, not a >127 off-by-one). A custom table with its
-- first entry set to 127, sampled at densityId=0 with zero fraction, reads
-- 127 as the raw interpolated value before saturation.
function T.raw_density_127_saturates_to_128(_)
  local table32 = rampTable()
  table32[1] = 127
  -- fogOffsetRaw=100 -> renderFogOffset=51200; z=0 is below it, densityId=0.
  local density = DsFog.density(0, 100, 0, table32)
  Assert.equal(density, 128, "a raw density of 127 must saturate to 128, not stay 127")
end

-- Case 7: a source table byte of 255 must never drive the interpolation
-- arithmetic negative or nonsensical, even when it is the heavily
-- downweighted term. densityId=1 (lo=table32[1]=255, hi=table32[2]=0) with
-- densityFrac=0x1FFFF (the maximum representable fraction, weighting hi
-- almost entirely): density = floor((255*1 + 0*0x1FFFF) / 0x20000) = 0. A
-- broken implementation that mis-signs or overflows the 255 byte could
-- easily produce a negative or huge result instead of this small,
-- unambiguously correct 0.
-- z=1048572 -> shifted=262143=1*0x20000+0x1FFFF -> densityId=1, frac=0x1FFFF.
function T.a_source_byte_of_255_cannot_drive_the_interpolation_negative(_)
  local table32 = rampTable()
  table32[1] = 255
  table32[2] = 0
  local density = DsFog.density(1048572, 0, 0, table32)
  Assert.equal(density, 0, "a heavily downweighted 255 byte must not perturb the result away from 0")
end

-- Case 8: the Flash preset's all-255 table clamps to density 128 at any
-- depth, with no intermediate negative/garbage value -- both interpolation
-- endpoints are 255 regardless of densityId/densityFrac, so the raw
-- interpolated value is always 255, always saturating to 128.
function T.flash_preset_table_clamps_to_128_without_going_negative(_)
  local density = DsFog.density(0, 0, 0, allMaxTable())
  Assert.equal(density, 128, "an all-255 density table must saturate to 128 at any depth")
end

-- Case 9: fog color channel 4 (RGB555) expands to six-bit 9 -- the same
-- 0->0, n->2n+1 rule locked for the geometry-pass combiner by the graphics
-- smoke suite's EXPAND5TO6_LOCKED_CASES, reused here
-- rather than reintroducing a `/31` fog color normalization.
function T.fog_color_channel_4_expands_to_six_bit_9(_)
  Assert.equal(DsFog.expand5to6(4), 9, "RGB555 channel 4 must expand to six-bit 9 (2*4+1)")
end

-- Case 10: at full fog (density=128, the value every saturating preset
-- above produces), a steady preset's fog alpha (31) leaves an opaque
-- fragment's alpha unchanged, while the Flash preset's fog alpha (0) drives
-- it to fully transparent -- both from the identical opaque source alpha
-- (31), proving the alpha-5 blend equation (not merely the RGB-6 one) reads
-- the preset's own alpha value.
function T.alpha_31_and_alpha_0_fog_presets_both_blend_correctly_at_full_fog(_)
  local steady = DsFog.blend(31, 31, 128)
  local flash = DsFog.blend(31, 0, 128)
  Assert.equal(steady, 31, "a steady preset's fog alpha 31 must leave opaque alpha (31) unchanged at full fog")
  Assert.equal(flash, 0, "the Flash preset's fog alpha 0 must zero opaque alpha (31) at full fog")
end

return { tests = T }
