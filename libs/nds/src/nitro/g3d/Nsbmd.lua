-- NSBMD / MDL0 decoder for static map and building models. Produces a
-- normalized, serializable inventory: per-model info counts, node/material/
-- shape names, texture/palette associations, the SBC draw-instance stream, and
-- per-shape geometry decoded through GxDisplayList (finite bounds + opcode
-- counts). Animation sections (NSBCA/NSBTA/...) are out of scope.
--
-- Layout (from pokeheartgold res_struct.h plus offsets verified against the
-- real HGSS Elm map model), all model-internal offsets relative to the model:
--   NNSG3dResMdl:  +0x00 size, +0x04 ofsSbc, +0x08 ofsMat, +0x0C ofsShp,
--                  +0x10 ofsEvpMtx, +0x14 info(0x2C), +0x40 node dict
--   Material blk:  +0x00 u16 ofsTexToMat, +0x02 u16 ofsPlttToMat, +0x04 dict
--   texToMat/plttToMat dict entry (4 bytes): u16 ofsList, u8 count, u8 bound;
--                  ofsList points at a u8[count] of material indices
--   Shape data:    +0x08 u32 ofsDL, +0x0C u32 sizeDL  (relative to shape data)
--   EvpMtx array:  NNSG3dResEvpMtx[numNode], MtxFx43 invM then MtxFx33 invN
--   SBC:           packed byte stream, MAT(0x04)/SHP(0x05) form draw calls
-- Pure domain module.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local FixedPoint = require("libs.math.src.FixedPoint")
local NitroFile = require("libs.nds.src.nitro.g3d.NitroFile")
local NitroDict = require("libs.nds.src.nitro.g3d.NitroDict")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local Material = require("libs.nds.src.gx.Material")
local NsbmdMaterialSrt = require("libs.nds.src.nitro.g3d.NsbmdMaterialSrt")

local Nsbmd = {}

-- SBC opcode -> { name, args(cmd, r, pos), options }. The low 5 bits of a
-- command byte are the opcode (NNS_G3D_SBCCMD_MASK) and the high 3 bits are an
-- option field (NNS_G3D_SBCFLG_MASK 0xE0), so option values run 0..7. `args` is
-- the number of operand bytes after the opcode, matching how each
-- NNSi_G3dFuncSbc_* in NitroSystem g3d/src/sbc.c advances rs->c; it reads the
-- stream for NODEMIX, whose length depends on an operand. `options` is the set
-- of option values that function acts on -- any other value would be decoded
-- with a length or meaning the SDK never defines, so it is rejected rather than
-- silently mis-executed. RET terminates the stream.
local function fixedArgs(n)
  return { kind = "fixed", count = n }
end

-- Option bit0 (0x20) appends a store-slot operand and bit1 (0x40) a restore-slot
-- operand, store first: sbc.c reads the restore index at rs->c + 2 for
-- SBCFLG_010 but at rs->c + 3 for SBCFLG_011 (BB; +4 / +5 for NODEDESC).
local function storeRestoreArgs(base)
  return { kind = "store-restore", base = base }
end

local function readNodeMixArgs(_, r, pos)
  r:assertRange(pos, 3, "sbc-nodemix-count")
  return 2 + r:u8(pos + 2) * 3
end

local function readArgumentCount(spec, cmd, r, pos)
  if type(spec) == "function" then
    return spec(cmd, r, pos)
  end
  if spec.kind == "fixed" then
    return spec.count
  end
  local count = spec.base
  if math.floor(cmd / 0x20) % 2 == 1 then
    count = count + 1
  end
  if math.floor(cmd / 0x40) % 2 == 1 then
    count = count + 1
  end
  return count
end

local OPT_NONE = { [0] = true }
local OPT_STORE_RESTORE = { [0] = true, [1] = true, [2] = true, [3] = true }

local SBC = {
  [0x00] = { name = "NOP", args = fixedArgs(0), options = OPT_NONE },
  [0x01] = { name = "RET", args = fixedArgs(0), options = OPT_NONE, terminates = true },
  [0x02] = { name = "NODE", args = fixedArgs(2), options = OPT_NONE },
  [0x03] = { name = "MTX", args = fixedArgs(1), options = OPT_NONE },
  -- MAT's option selects which material state the command overrides
  -- (NNSi_G3dFuncSbc_MAT_InternalDefault tests SBCFLG_001 and SBCFLG_010).
  [0x04] = { name = "MAT", args = fixedArgs(1), options = { [0] = true, [1] = true, [2] = true } },
  [0x05] = { name = "SHP", args = fixedArgs(1), options = OPT_NONE },
  [0x06] = { name = "NODEDESC", args = storeRestoreArgs(3), options = OPT_STORE_RESTORE },
  [0x07] = { name = "BB", args = storeRestoreArgs(1), options = OPT_STORE_RESTORE },
  [0x08] = { name = "BBY", args = storeRestoreArgs(1), options = OPT_STORE_RESTORE },
  -- NODEMIX: destination stack slot, term count, then that many
  -- (stack slot, node index, ratio) triples -- `rs->c += 3 + *(rs->c + 2) * 3`.
  [0x09] = {
    name = "NODEMIX",
    options = OPT_NONE,
    args = readNodeMixArgs,
  },
  -- CALLDL: u32 display-list offset relative to the command, then a u32 size.
  [0x0A] = { name = "CALLDL", args = fixedArgs(8), options = OPT_NONE },
  [0x0B] = { name = "POSSCALE", args = fixedArgs(0), options = { [0] = true, [1] = true } },
  [0x0C] = { name = "ENVMAP", args = fixedArgs(2), options = OPT_NONE },
  [0x0D] = { name = "PRJMAP", args = fixedArgs(2), options = OPT_NONE },
}

-- NNSG3dResNodeData SRT flags (res_struct.h). The high bits of `flag` encode
-- which transform components are present and, for pivot rotations, which cell
-- receives the fixed +/-1 and where the A/B pair is written.
local SRTFLAG_TRANS_ZERO = 0x0001
local SRTFLAG_ROT_ZERO = 0x0002
local SRTFLAG_SCALE_ONE = 0x0004
local SRTFLAG_PIVOT_EXIST = 0x0008
local SRTFLAG_PIVOT_MINUS = 0x0100
local SRTFLAG_SIGN_REVC = 0x0200
local SRTFLAG_SIGN_REVD = 0x0400

local pivotUtil_ = {
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

-- Decode one NNSG3dResNodeData record. `nodeInfoBase` is the model-relative
-- offset of the NNSG3dResNodeInfo (dict at modelBase + 0x40); the dict entry's
-- payload is an offset from that base to the variable-length node data.
--
-- The record's length depends on the model's scaling rule: NODEDESC hands the
-- post-rotation pointer to the rule's GetJointScale, and the non-standard rules
-- read three further fx32 there as the joint's inverse scale
-- (NNSi_G3dGetJointScaleMaya reads p+3..p+5). Only the raw SRT components are
-- returned -- composing them is the scaling rule's job, not the parser's.
---@param r BinaryReader
---@param nodeInfoBase integer
---@param e table<string, unknown>
---@param scalingRule integer
---@param context Errors.Context
---@return table<string, unknown>
local function decodeNodeData(r, nodeInfoBase, e, scalingRule, context)
  local offset = BinaryReader.new(e.data, "node-ref"):u32le(0)
  if offset == 0 then
    Errors.raise(
      "NSBMD_NODE_DATA_OFFSET_ZERO",
      string.format("node %d (%s) has a zero data offset", e.index, e.name),
      { nodeIndex = e.index, nodeName = e.name, source = context }
    )
  end

  local base = nodeInfoBase + offset
  r:assertRange(base, 4, "node-data-header")

  local flags = r:u16le(base)
  local _00 = FixedPoint.fx16(r:u16le(base + 2))
  local pos = base + 4

  local function bitSet(v, bit)
    return math.floor(v / bit) % 2 == 1
  end

  local translation
  if bitSet(flags, SRTFLAG_TRANS_ZERO) then
    translation = { x = 0, y = 0, z = 0 }
  else
    r:assertRange(pos, 12, "node-translation")
    translation = {
      x = FixedPoint.fx32(r:u32le(pos)),
      y = FixedPoint.fx32(r:u32le(pos + 4)),
      z = FixedPoint.fx32(r:u32le(pos + 8)),
    }
    pos = pos + 12
  end

  local rotation
  if bitSet(flags, SRTFLAG_ROT_ZERO) then
    rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
  elseif bitSet(flags, SRTFLAG_PIVOT_EXIST) then
    r:assertRange(pos, 4, "node-pivot")
    local A = FixedPoint.fx16(r:u16le(pos))
    local B = FixedPoint.fx16(r:u16le(pos + 2))
    local idxPivot = math.floor(flags / 16) % 16
    if idxPivot > 8 then
      Errors.raise(
        "NSBMD_NODE_PIVOT_INDEX_INVALID",
        string.format("node %d (%s) has pivot index %d", e.index, e.name, idxPivot),
        { nodeIndex = e.index, nodeName = e.name, idxPivot = idxPivot, source = context }
      )
    end
    local rot = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    rot[idxPivot + 1] = bitSet(flags, SRTFLAG_PIVOT_MINUS) and -1 or 1
    local u = pivotUtil_[idxPivot + 1]
    rot[u[1] + 1] = A
    rot[u[2] + 1] = B
    rot[u[3] + 1] = bitSet(flags, SRTFLAG_SIGN_REVC) and -B or B
    rot[u[4] + 1] = bitSet(flags, SRTFLAG_SIGN_REVD) and -A or A
    rotation = rot
    pos = pos + 4
  else
    r:assertRange(pos, 16, "node-rotation")
    rotation = { _00 }
    for i = 1, 8 do
      rotation[#rotation + 1] = FixedPoint.fx16(r:u16le(pos + (i - 1) * 2))
    end
    pos = pos + 16
  end

  local scaleOne = bitSet(flags, SRTFLAG_SCALE_ONE)
  local scale, inverseScale
  if scaleOne then
    scale = { x = 1, y = 1, z = 1 }
  else
    r:assertRange(pos, 12, "node-scale")
    scale = {
      x = FixedPoint.fx32(r:u32le(pos)),
      y = FixedPoint.fx32(r:u32le(pos + 4)),
      z = FixedPoint.fx32(r:u32le(pos + 8)),
    }
    pos = pos + 12
    if scalingRule ~= 0 then
      r:assertRange(pos, 12, "node-inverse-scale")
      inverseScale = {
        x = FixedPoint.fx32(r:u32le(pos)),
        y = FixedPoint.fx32(r:u32le(pos + 4)),
        z = FixedPoint.fx32(r:u32le(pos + 8)),
      }
    end
  end

  -- Bits 11-15 of the flag word hold the intended matrix-stack slot.
  local matrixStackIndex = math.floor(flags / 2048) % 32

  return {
    index = e.index,
    name = e.name,
    flagsRaw = flags,
    matrixStackIndex = matrixStackIndex,
    translation = translation,
    rotation = rotation,
    scale = scale,
    inverseScale = inverseScale,
    transZero = bitSet(flags, SRTFLAG_TRANS_ZERO),
    rotZero = bitSet(flags, SRTFLAG_ROT_ZERO),
    scaleOne = scaleOne,
  }
end

local function applyNodeCommand(entry, args, state)
  entry.nodeIndex = args[1]
  entry.visible = args[2] % 2 == 1
  state.currentNode = args[1]
end

local function applyMaterialCommand(entry, args, state)
  entry.materialIndex = args[1]
  state.currentMaterial = args[1]
  state.matSincePrevShp = true
end

local function applyShapeCommand(entry, args, state)
  entry.shapeIndex = args[1]
  state.draws[#state.draws + 1] = {
    nodeIndex = state.currentNode,
    materialIndex = state.currentMaterial,
    shapeIndex = args[1],
    offset = entry.offset,
    materialReapplied = state.matSincePrevShp,
  }
  state.matSincePrevShp = false
end

local function applyNodeDescription(entry, args, state)
  local fixed = entry.opcode == 0x06 and 3 or 1
  entry.nodeIndex = args[1]
  if entry.opcode == 0x06 then
    entry.parentIndex = args[2]
    entry.flags = args[3]
  end
  if entry.option == 1 or entry.option == 3 then
    entry.storeSlot = args[fixed + 1]
  end
  if entry.option == 2 then
    entry.restoreSlot = args[fixed + 1]
  elseif entry.option == 3 then
    entry.restoreSlot = args[fixed + 2]
  end
  state.currentNode = args[1]
end

local function applyNodeMix(entry, args)
  entry.storeSlot = args[1]
  entry.terms = {}
  for i = 0, args[2] - 1 do
    entry.terms[#entry.terms + 1] = {
      matrixSlot = args[3 + i * 3],
      nodeIndex = args[4 + i * 3],
      ratio = args[5 + i * 3],
    }
  end
end

local function applyCallDisplayList(entry, args)
  entry.displayListOffset = args[1] + args[2] * 0x100 + args[3] * 0x10000 + args[4] * 0x1000000
  entry.displayListSize = args[5] + args[6] * 0x100 + args[7] * 0x10000 + args[8] * 0x1000000
end

local function applyPositionScale(entry)
  entry.inverse = entry.option == 1
end

local SBC_HANDLERS = {
  [0x02] = applyNodeCommand,
  [0x04] = applyMaterialCommand,
  [0x05] = applyShapeCommand,
  [0x06] = applyNodeDescription,
  [0x07] = applyNodeDescription,
  [0x08] = applyNodeDescription,
  [0x09] = applyNodeMix,
  [0x0A] = applyCallDisplayList,
  [0x0B] = applyPositionScale,
}

-- Decode the SBC stream in [start, limit). Returns commands, opcode counts, and
-- the ordered MAT/SHP draw instances bound to the active node.
local function decodeSbc(r, start, limit, context)
  local commands, counts, draws = {}, {}, {}
  local pos = start
  local state = {
    currentNode = 0,
    currentMaterial = 0,
    draws = draws,
    -- The stream start counts as an implicit material apply.
    matSincePrevShp = true,
  }
  while pos < limit do
    local cmd = r:u8(pos)
    local op = cmd % 0x20 -- low 5 bits; high bits are option flags
    local option = math.floor(cmd / 0x20)
    local def = SBC[op]
    if not def then
      error(
        Errors.new(
          "SBC_UNKNOWN_OPCODE",
          string.format("unknown SBC opcode 0x%02X at offset 0x%X", cmd, pos),
          { opcode = cmd, offset = pos, source = context }
        )
      )
    end
    if not def.options[option] then
      error(
        Errors.new(
          "SBC_INVALID_OPTION_BITS",
          string.format(
            "%s at offset 0x%X has option bits 0x%02X, which the command does not define",
            def.name,
            pos,
            option * 0x20
          ),
          { opcode = op, command = cmd, optionBits = option * 0x20, offset = pos, source = context }
        )
      )
    end

    local nargs = readArgumentCount(def.args, cmd, r, pos)
    r:assertRange(pos, 1 + nargs, "sbc-cmd")

    local args = {}
    for i = 1, nargs do
      args[i] = r:u8(pos + i)
    end

    local entry = {
      opcode = op,
      command = cmd,
      option = option,
      optionBits = option * 0x20,
      offset = pos,
      name = def.name,
      args = args,
    }

    if op == 0x03 then
      entry.matrixSlot = args[1]
    end

    local handler = SBC_HANDLERS[op]
    if handler then
      handler(entry, args, state)
    end

    commands[#commands + 1] = entry
    counts[op] = (counts[op] or 0) + 1
    pos = pos + 1 + nargs
    if def.terminates then
      break
    end
  end
  return { commands = commands, opcodeCounts = counts, draws = draws }
end

local function decodeInfo(r, base)
  return {
    sbcType = r:u8(base + 0x00),
    scalingRule = r:u8(base + 0x01),
    texMtxMode = r:u8(base + 0x02),
    numNode = r:u8(base + 0x03),
    numMat = r:u8(base + 0x04),
    numShp = r:u8(base + 0x05),
    firstUnusedMtxStackID = r:u8(base + 0x06),
    posScale = FixedPoint.fx32(r:u32le(base + 0x08)),
    invPosScale = FixedPoint.fx32(r:u32le(base + 0x0C)),
    numVertex = r:u16le(base + 0x10),
    numPolygon = r:u16le(base + 0x12),
    numTriangle = r:u16le(base + 0x14),
    numQuad = r:u16le(base + 0x16),
    box = {
      x = FixedPoint.fx16(r:u16le(base + 0x18)),
      y = FixedPoint.fx16(r:u16le(base + 0x1A)),
      z = FixedPoint.fx16(r:u16le(base + 0x1C)),
      w = FixedPoint.fx16(r:u16le(base + 0x1E)),
      h = FixedPoint.fx16(r:u16le(base + 0x20)),
      d = FixedPoint.fx16(r:u16le(base + 0x22)),
    },
    boxPosScale = FixedPoint.fx32(r:u32le(base + 0x24)),
    boxInvPosScale = FixedPoint.fx32(r:u32le(base + 0x28)),
  }
end

local function bit(v, i)
  return math.floor(v / 2 ^ i) % 2 == 1
end

local MATERIAL_PREFIX = 0x2C

-- Parse the fixed NNSG3dResMatData prefix (NitroSDK res_struct.h) at
-- matBase+blockOfs. Exposes the exact file words -- the raw registers, ownership
-- flags, and packed lighting colors -- so Material can resolve effective state
-- later; the parser makes no field-global assumption. The transitional
-- repeat/flip booleans read the raw texImageParam wrap bits directly (every
-- target material fully masks that register, so raw equals effective); wrap
-- sourcing later moves onto the producer's material policy and drops them.
---@param r BinaryReader
---@param matBase integer
---@param blockOfs integer
---@param context Errors.Context
---@return table<string, unknown>
local function decodeMaterialData(r, matBase, blockOfs, context)
  local base = matBase + blockOfs
  if base + MATERIAL_PREFIX > r:length() then
    Errors.raise(
      "NSBMD_MATERIAL_OUT_OF_RANGE",
      string.format("material block at 0x%X + 0x%X exceeds %d-byte section", base, MATERIAL_PREFIX, r:length()),
      { offset = base, source = context }
    )
  end
  local itemTag = r:u16le(base + 0x00)
  local size = r:u16le(base + 0x02)
  if size < MATERIAL_PREFIX then
    Errors.raise(
      "NSBMD_BAD_MATERIAL_SIZE",
      string.format("material size 0x%X is smaller than the 0x%X fixed prefix", size, MATERIAL_PREFIX),
      { size = size, source = context }
    )
  end
  if base + size > r:length() then
    Errors.raise(
      "NSBMD_MATERIAL_OUT_OF_RANGE",
      string.format("material record at 0x%X size 0x%X exceeds %d-byte section", base, size, r:length()),
      { offset = base, size = size, source = context }
    )
  end
  if itemTag ~= 0 then
    Errors.raise(
      "NSBMD_UNSUPPORTED_MATERIAL_TAG",
      string.format("material itemTag 0x%X is not the standard tag 0", itemTag),
      { itemTag = itemTag, source = context }
    )
  end

  local diffAmbRaw = r:u32le(base + 0x04)
  local specEmiRaw = r:u32le(base + 0x08)
  local texImageParamRaw = r:u32le(base + 0x14)
  local texImageParamMask = r:u32le(base + 0x18)
  local flagsRaw = r:u16le(base + 0x1E)
  local diffAmb = Material.unpackDiffAmb(diffAmbRaw)
  local specEmi = Material.unpackSpecEmi(specEmiRaw)

  return {
    itemTag = itemTag,
    size = size,
    diffAmbRaw = diffAmbRaw,
    specEmiRaw = specEmiRaw,
    polyAttrRaw = r:u32le(base + 0x0C),
    polyAttrMask = r:u32le(base + 0x10),
    texImageParamRaw = texImageParamRaw,
    texImageParamMask = texImageParamMask,
    texPlttBase = r:u16le(base + 0x1C),
    flagsRaw = flagsRaw,
    origWidth = r:u16le(base + 0x20),
    origHeight = r:u16le(base + 0x22),
    magW = FixedPoint.fx32(r:u32le(base + 0x24)),
    magH = FixedPoint.fx32(r:u32le(base + 0x28)),

    diffuseRgb555 = diffAmb.diffuseRgb555,
    ambientRgb555 = diffAmb.ambientRgb555,
    specularRgb555 = specEmi.specularRgb555,
    emissionRgb555 = specEmi.emissionRgb555,
    setVertexColor = diffAmb.setVertexColor,
    useShininessTable = specEmi.useShininessTable,
    owns = Material.ownership(flagsRaw),

    extraBytes = size > MATERIAL_PREFIX and r:bytes(base + MATERIAL_PREFIX, size - MATERIAL_PREFIX) or "",

    -- The static texture-SRT extension: decoded from the flags and
    -- the extra bytes; nil when the material carries no texture transform.
    textureSrt = size > MATERIAL_PREFIX
        and NsbmdMaterialSrt.decode(flagsRaw, r:bytes(base + MATERIAL_PREFIX, size - MATERIAL_PREFIX))
      or nil,

    -- Transitional: raw wrap/flip bits (bits 16-19 of texImageParam), consumed by
    -- MaterialCompiler until wrap sourcing routes through the producer policy.
    repeatX = bit(texImageParamRaw, 16),
    repeatY = bit(texImageParamRaw, 17),
    flipX = bit(texImageParamRaw, 18),
    flipY = bit(texImageParamRaw, 19),
  }
end

-- Read a name->materialIndices mapping dict (texToMat / plttToMat).
local function decodeMatBindings(r, sec, matBase, dictOffset, context)
  local dict = assert(NitroDict.decode(sec, matBase + dictOffset, context))
  local list = {}
  for _, e in ipairs(dict.entries) do
    local br = BinaryReader.new(e.data, "matbind")
    local ofsList = br:u16le(0)
    local count = br:u8(2)
    local materials = {}
    for i = 0, count - 1 do
      materials[#materials + 1] = r:u8(matBase + ofsList + i)
    end
    list[#list + 1] = { name = e.name, materials = materials }
  end
  return list
end

-- NNSG3dResEvpMtx: the inverse bind pose of one joint, read by NODEMIX to bring a
-- vertex out of that joint's space before blending. `MtxFx43 invM` (12 fx32) then
-- `MtxFx33 invN` (9 fx32), 84 bytes per entry, indexed by joint. Both are stored
-- as DS rows, which are the columns of this project's column-major matrices --
-- the same mapping GxDisplayList uses for MTX_LOAD_4x3.
local EVP_MTX_SIZE = (12 + 9) * 4

local function decodeEvpMatrices(r, base, count)
  local out = {}
  for joint = 0, count - 1 do
    local at = base + joint * EVP_MTX_SIZE
    local function fx(i)
      return FixedPoint.fx32(r:u32le(at + i * 4))
    end
    out[joint] = {
      invM = {
        fx(0),
        fx(1),
        fx(2),
        0,
        fx(3),
        fx(4),
        fx(5),
        0,
        fx(6),
        fx(7),
        fx(8),
        0,
        fx(9),
        fx(10),
        fx(11),
        1,
      },
      invN = {
        fx(12),
        fx(13),
        fx(14),
        0,
        fx(15),
        fx(16),
        fx(17),
        0,
        fx(18),
        fx(19),
        fx(20),
        0,
        0,
        0,
        0,
        1,
      },
    }
  end
  return out
end

local function decodeModel(sec, modelBase, name, index, context)
  local r = BinaryReader.new(sec, "mdl0")
  local ofsSbc = r:u32le(modelBase + 0x04)
  local ofsMat = r:u32le(modelBase + 0x08)
  local ofsShp = r:u32le(modelBase + 0x0C)
  local ofsEvpMtx = r:u32le(modelBase + 0x10)
  local info = decodeInfo(r, modelBase + 0x14)

  -- Nodes.
  local nodeInfoBase = modelBase + 0x40
  local nodeDict = assert(NitroDict.decode(sec, nodeInfoBase, context))
  local nodes = {}
  for _, e in ipairs(nodeDict.entries) do
    nodes[#nodes + 1] = decodeNodeData(r, nodeInfoBase, e, info.scalingRule, { model = name, node = e.name })
  end

  -- Materials + texture/palette associations.
  local matBase = modelBase + ofsMat
  local ofsTexToMat = r:u16le(matBase)
  local ofsPlttToMat = r:u16le(matBase + 2)
  local matDict = assert(NitroDict.decode(sec, matBase + 4, context))
  local materials = {}
  for _, e in ipairs(matDict.entries) do
    -- The material dict payload is a u16 offset (from matBase) to the material's
    -- NNSG3dResMatData block.
    local m =
      decodeMaterialData(r, matBase, BinaryReader.new(e.data, "matref"):u16le(0), { model = name, material = e.name })
    m.index = e.index
    m.name = e.name
    materials[e.index] = m
  end
  local textureAssociations = decodeMatBindings(r, sec, matBase, ofsTexToMat, context)
  local paletteAssociations = decodeMatBindings(r, sec, matBase, ofsPlttToMat, context)
  for _, assoc in ipairs(textureAssociations) do
    for _, mi in ipairs(assoc.materials) do
      if materials[mi] then
        materials[mi].textureName = assoc.name
      end
    end
  end
  for _, assoc in ipairs(paletteAssociations) do
    for _, mi in ipairs(assoc.materials) do
      if materials[mi] then
        materials[mi].paletteName = assoc.name
      end
    end
  end
  local materialList = {}
  for i = 0, info.numMat - 1 do
    materialList[#materialList + 1] = materials[i]
  end

  -- Shapes + geometry.
  local shpBase = modelBase + ofsShp
  local shpDict = assert(NitroDict.decode(sec, shpBase, context))
  local shapes = {}
  local modelBounds
  for _, e in ipairs(shpDict.entries) do
    local shpDataOffset = shpBase + BinaryReader.new(e.data, "shp"):u32le(0)
    local ofsDL = r:u32le(shpDataOffset + 0x08)
    local sizeDL = r:u32le(shpDataOffset + 0x0C)
    local dlOffset = shpDataOffset + ofsDL
    local dlBytes = r:bytes(dlOffset, sizeDL)
    local geometry, gerr = GxDisplayList.decode(dlBytes, { context = { model = name, shape = e.name } })
    if not geometry then
      error(gerr)
    end
    shapes[#shapes + 1] = {
      index = e.index,
      name = e.name,
      dlOffset = dlOffset,
      dlSize = sizeDL,
      -- Raw display-list bytes, retained so the model compiler can replay the
      -- shape with the material/GX state active at its SBC draw. `geometry` is the
      -- neutral (stateless) decode kept for inspection.
      displayListBytes = dlBytes,
      displayListOffset = dlOffset,
      displayListSize = sizeDL,
      vertexCount = geometry.slice.vertexCount,
      triangleCount = geometry.slice.indexCount / 3,
      bounds = geometry.bounds,
      opcodeCounts = geometry.opcodeCounts,
      geometry = geometry,
    }
    local b = geometry.bounds
    if b then
      if not modelBounds then
        modelBounds = { min = { b.min[1], b.min[2], b.min[3] }, max = { b.max[1], b.max[2], b.max[3] } }
      else
        for k = 1, 3 do
          modelBounds.min[k] = math.min(modelBounds.min[k], b.min[k])
          modelBounds.max[k] = math.max(modelBounds.max[k], b.max[k])
        end
      end
    end
  end

  local sbc = decodeSbc(r, modelBase + ofsSbc, modelBase + ofsMat, context)

  -- A model without skinning still stores an ofsEvpMtx, pointing just past its
  -- data, so the block is read only when the SBC actually issues NODEMIX.
  local evpMatrices = (ofsEvpMtx ~= 0 and sbc.opcodeCounts[0x09])
      and decodeEvpMatrices(r, modelBase + ofsEvpMtx, info.numNode)
    or nil

  return {
    index = index,
    name = name,
    info = info,
    nodes = nodes,
    evpMatrices = evpMatrices,
    materials = materialList,
    shapes = shapes,
    textureAssociations = textureAssociations,
    paletteAssociations = paletteAssociations,
    sbc = sbc,
    bounds = modelBounds,
  }
end

local function _decode(bytes, context)
  local file, err = NitroFile.decode(bytes, "BMD0", context)
  if not file then
    error(err)
  end
  local mdlSection = NitroFile.section(file, "MDL0")
  if not mdlSection then
    error(Errors.new("NSBMD_NO_MDL0", "BMD0 file has no MDL0 section", { source = context }))
  end

  local sec = mdlSection.bytes
  local modelDict = assert(NitroDict.decode(sec, 8, context))
  local models = {}
  for _, e in ipairs(modelDict.entries) do
    local modelBase = BinaryReader.new(e.data, "mdlset"):u32le(0)
    models[#models + 1] = decodeModel(sec, modelBase, e.name, e.index, context)
  end

  local embeddedTextures
  local texSection = NitroFile.section(file, "TEX0")
  if texSection then
    embeddedTextures = assert(Nsbtx.decodeTex0(texSection.bytes, context))
  end

  local unknownSections = {}
  for _, s in ipairs(file.sections) do
    if s.magic ~= "MDL0" and s.magic ~= "TEX0" then
      unknownSections[#unknownSections + 1] = { magic = s.magic, offset = s.offset, size = s.size }
    end
  end

  return {
    models = models,
    embeddedTextures = embeddedTextures,
    unknownSections = unknownSections,
    source = context,
  }
end

function Nsbmd.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Nsbmd
