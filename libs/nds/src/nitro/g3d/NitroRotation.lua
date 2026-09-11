-- NSBCA rotation reconstruction: turns one rotation key value into the nine
-- matrix cells NitroSystem uses.
--
-- Authority: pokediamond arm9/asm/NNS_G3D_nsbca.s (pinned commit 038cccaed,
-- 2025-12-24) -- getRotDataByIdx_ (0x020BC500). A rotation key is a u16 with
-- bit 15 selecting the form:
--
--   bit 15 set  -- pivot form: value & 0x7FFF indexes a table of 3 x u16
--                  entries at the record's ofsRotData. Entry element 0 is a
--                  control word packing the pivot cell index (bits 0-3), the
--                  pivot sign (bit 4: 0x1000 vs -0x1000) and the C/D
--                  negation bits (bits 5-6); elements 1-2 are the A/B fx16
--                  values. The nine cells are placed via the pivotUtil table
--                  (the same table Nsbmd.lua's node decode uses) and the
--                  caller normalizes the three rows.
--
--   bit 15 clear -- compressed form: value & 0x7FFF indexes a table of
--                  5 x u16 entries at the record's ofsPivotData. Cells 0-4
--                  are the entry values shifted right 3 (arithmetic); cell 5
--                  packs all five low-3-bit remainders as
--                  (e3&7)|((e2&7)<<3)|((e1&7)<<6)|((e0&7)<<9)|((e4&7)<<12),
--                  narrowed to the low 13 bits sign-extended (the asm's
--                  trailing lsl #19 / asr #19), so the cell is a 13-bit
--                  signed rotation element, never packed << 19. The caller
--                  computes cells 6-8 as the cross product of rows 0 x 1 and
--                  skips normalization (the encoder pre-normalizes the rows).
--
-- `reconstruct` handles one key; interpolating between two keys is the
-- caller's job (the curve machinery in Nsbca.lua). Pure domain module.

local Errors = require("libs.errors.src.Errors")

local NitroRotation = {}

local function s16(value)
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

-- For pivot index p, cells u0..u3 receive A, B, -B, -A.
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

local function bitSet(value, bit)
  return math.floor(value / bit) % 2 == 1
end

-- Reconstruct the nine rotation cells from one key value.
--   r          BinaryReader over the section bytes
--   rotBase    absolute offset of the 3 x u16 pivot-entry table
--   compBase   absolute offset of the 5 x u16 compressed-entry table
--   value      the u16 key value
-- Returns { cells = { 9 fx32 }, compressed = bool }.
function NitroRotation.reconstruct(r, rotBase, compBase, value, context)
  local cells = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  local index = value % 32768
  if bitSet(value, 0x8000) then
    local at = rotBase + index * 6
    r:assertRange(at, 6, "anm-rot-pivot")
    local control = r:u16le(at)
    local a = s16(r:u16le(at + 2))
    local b = s16(r:u16le(at + 4))
    local pivot = control % 16
    if pivot > 8 then
      Errors.raise(
        "NSBCA_ROT_PIVOT_INDEX_INVALID",
        string.format("pivot index %d exceeds the 0..8 pivotUtil table", pivot),
        { pivot = pivot, value = value, source = context }
      )
    end
    cells[pivot + 1] = bitSet(control, 0x10) and -0x1000 or 0x1000
    local u = PIVOT_UTIL[pivot + 1]
    cells[u[1] + 1] = a
    cells[u[2] + 1] = b
    cells[u[3] + 1] = bitSet(control, 0x20) and -b or b
    cells[u[4] + 1] = bitSet(control, 0x40) and -a or a
    return { cells = cells, compressed = false }
  end

  local at = compBase + index * 10
  r:assertRange(at, 10, "anm-rot-compressed")
  local e = {}
  for i = 0, 4 do
    e[i + 1] = s16(r:u16le(at + i * 2))
  end
  for i = 1, 5 do
    cells[i] = math.floor(e[i] / 8)
  end
  -- All five remainders feed cell 5, and the asm keeps only the low 13
  -- bits sign-extended (lsl #19 then asr #19): a 13-bit signed element.
  -- Lua % on the s16 entries reproduces the asm's `and #7` on the
  -- sign-extended words (both yield value mod 8 in the floor sense).
  local packed = (e[4] % 8) + (e[3] % 8) * 8 + (e[2] % 8) * 64 + (e[1] % 8) * 512 + (e[5] % 8) * 4096
  local low13 = packed % 8192
  cells[6] = low13 >= 4096 and low13 - 8192 or low13
  return { cells = cells, compressed = true }
end

return NitroRotation
