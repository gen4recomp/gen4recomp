-- Binary scr_seq decoder tests: the retail entry table (relative offsets,
-- 0xFD13 sentinel), signed relative branch targets resolving to labels,
-- interleaved movement blocks discovered through ApplyMovement operands,
-- bank-qualified message operands, arg-dependent widths, and header-member
-- rejection. Uses synthetic members built by tests/support/ScriptFixture.

local Assert = require("tests.support.Assert")
local ScriptFixture = require("tests.support.ScriptFixture")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")

local T = {}

local CATALOG = {
  sounds = { [1500] = "SEQ_SE_DP_SELECT" },
  flags = { [0x6A] = "FLAG_GOT_STARTER" },
  vars = { [0x4000] = "VAR_TEMP_x4000", [0x8008] = "VAR_SPECIAL_x8008" },
  maps = { [61] = { mapCode = "MAP_NEW_BARK_ELMS_LAB_1F" } },
}

local function decode(bytes, member, opts)
  local options = { msgBank = 543, catalog = CATALOG }
  if opts ~= nil then
    for key, value in pairs(opts) do
      options[key] = value
    end
  end
  return assert(ScriptBinaryDecoder.parseMember(bytes, member, "synthetic", options))
end

local function countScripts(member)
  local n = 0
  for _ in pairs(member.scripts) do
    n = n + 1
  end
  return n
end

-- 1. The entry table scan yields the script count and labels; the sentinel
-- terminates the table; hdr members return nil.
T["entry table and sentinel"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = { { op = 2, args = {} } } },
      { offset = 0x40, instructions = { { op = 27, args = {} } } },
    },
  })
  local member = decode(bytes, 5)
  Assert.equal(countScripts(member), 2)
  Assert.equal(member.scripts[0].instructions[1].opcode, 2)
  Assert.equal(member.scripts[0].label, "scr_seq_0005_000")
  Assert.equal(member.scripts[1].instructions[1].opcode, 27)
  Assert.equal(member.scripts[1].label, "scr_seq_0005_001")
  local hdr = ScriptBinaryDecoder.parseMember("\0\0\0\0", 5, "hdr", {})
  Assert.isNil(hdr)
  local garbage = ScriptBinaryDecoder.parseMember("FD13\0\0\0", 5, "hdr", {})
  Assert.isNil(garbage)
end

-- 2. Relative branch targets resolve to `_XXXX` labels (forward and
-- backward, signed).
T["relative targets resolve to labels"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 28, args = { { value = 5, width = 1 }, { target = 0x27, width = 4 } } },
          -- A backward branch: emitted relative value is negative.
          { op = 28, args = { { value = 1, width = 1 }, { target = 0x20, width = 4 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local member = decode(bytes, 5)
  local ins = member.scripts[0].instructions
  Assert.equal(ins[1].operands[2].raw, "_0027")
  Assert.equal(ins[2].operands[2].raw, "_0020")
  -- Branch targets carry labels: the first instruction is the backward
  -- branch target, the second the forward branch target.
  Assert.equal(ins[1].label, "_0020")
  Assert.equal(ins[2].label, "_0027")
  Assert.equal(ins[3].label, nil)
end

-- 3. Movement blocks decode at ApplyMovement-referenced offsets and are
-- skipped by the script walk (no phantom instructions).
T["movement blocks decode and skip"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- ApplyMovement player -> 0x30 (relative word operand).
          { op = 94, args = { { value = 0, width = 2 }, { target = 0x30, width = 4 } } },
          { op = 95, args = {} },
          { op = 2, args = {} },
        },
      },
    },
    movements = {
      {
        offset = 0x30,
        actions = {
          { code = 12, args = { 2 } },
          { code = 75, args = { 1 } },
          { code = 254, args = { 0 } },
        },
      },
    },
  })
  local member = decode(bytes, 5)
  local script = member.scripts[0]
  Assert.equal(#script.instructions, 3)
  Assert.equal(script.instructions[1].operands[2].raw, "_0030")
  local block = member.movements[0x30]
  Assert.notNil(block)
  Assert.equal(#block.actions, 2)
  Assert.equal(block.actions[1].movementCode, 12)
  Assert.equal(block.actions[1].name, "WalkNormalNorth")
  Assert.equal(block.actions[1].count, 2)
  Assert.isTrue(block.terminated)
end

-- 4. Message operands become bank-qualified symbols; sound/flag/var/map
-- operands resolve through the pinned catalogs with mechanical fallbacks.
T["operands resolve through the catalogs"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 73, args = { { value = 1500, width = 2 } } },
          { op = 45, args = { { value = 12, width = 1 } } },
          { op = 132, args = { { value = 13, width = 1 }, { value = 14, width = 1 } } },
          { op = 30, args = { { value = 0x6A, width = 2 } } },
          { op = 41, args = { { value = 0x8008, width = 2 }, { value = 0x4000, width = 2 } } },
          {
            op = 176,
            args = {
              { value = 61, width = 2 },
              { value = 2, width = 2 },
              { value = 4, width = 2 },
              { value = 5, width = 2 },
              { value = 0, width = 1 },
            },
          },
          { op = 2, args = {} },
        },
      },
    },
  })
  local member = decode(bytes, 5)
  local ins = member.scripts[0].instructions
  Assert.equal(ins[1].operands[1].raw, "SEQ_SE_DP_SELECT")
  Assert.equal(ins[2].operands[1].raw, "msg_0543_x_00012")
  Assert.equal(ins[3].operands[1].raw, "msg_0543_x_00013")
  Assert.equal(ins[3].operands[2].raw, "msg_0543_x_00014")
  Assert.equal(ins[4].operands[1].raw, "FLAG_GOT_STARTER")
  Assert.equal(ins[5].operands[1].raw, "VAR_SPECIAL_x8008")
  Assert.equal(ins[5].operands[2].raw, "VAR_TEMP_x4000")
  Assert.equal(ins[6].operands[1].raw, "MAP_NEW_BARK_ELMS_LAB_1F")
  local unknown = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = { { op = 73, args = { { value = 9999, width = 2 } } }, { op = 2, args = {} } } },
    },
  })
  local member2 = decode(unknown, 5)
  Assert.equal(member2.scripts[0].instructions[1].operands[1].raw, "SEQ_0x270F")
end

-- 5. Arg-dependent widths: MysteryGift (489) and ScrCmd_465 sizes follow the
-- decoded base operand.
T["arg-dependent widths"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- MysteryGift 1, arg1 (6 bytes), then MysteryGift 5, arg1, arg2 (8).
          { op = 489, args = { { value = 1, width = 2 }, { value = 0x80, width = 2 } } },
          { op = 489, args = { { value = 5, width = 2 }, { value = 0x81, width = 2 }, { value = 0x82, width = 2 } } },
          -- ScrCmd_465 6 (4 bytes), then 465 3 (8 bytes).
          { op = 465, args = { { value = 6, width = 2 } } },
          { op = 465, args = { { value = 3, width = 2 }, { value = 1, width = 2 }, { value = 2, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local member = decode(bytes, 5)
  local ins = member.scripts[0].instructions
  Assert.equal(ins[1].opcode, 489)
  Assert.equal(ins[1].size, 6)
  Assert.equal(#ins[1].operands, 2)
  Assert.equal(ins[2].size, 8)
  Assert.equal(#ins[2].operands, 3)
  Assert.equal(ins[3].opcode, 465)
  Assert.equal(ins[3].size, 4)
  Assert.equal(ins[4].size, 8)
  Assert.equal(ins[4].operands[3].raw, 2)
  Assert.equal(ins[5].opcode, 2)
end

-- 6. Script walks terminate at End/Return so trailing bytes (padding or
-- movement data) never decode as phantom instructions.
T["walk terminates at script terminators"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 2, args = {} },
          { op = 73, args = { { value = 1, width = 2 } } },
        },
      },
    },
  })
  local member = decode(bytes, 5)
  Assert.equal(#member.scripts[0].instructions, 1)
  Assert.equal(member.scripts[0].instructions[1].opcode, 2)
end

-- 7. A truncated trailing instruction is recorded as a decode note instead
-- of raising.
T["truncated instructions record a note"] = function()
  -- Script at 0x20: a 4-byte PlaySE whose operand overruns the member end.
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = {
        { op = 73, args = { { value = 1, width = 2 } } },
      } },
    },
  })
  local truncated = bytes:sub(1, 0x23)
  local ir = ScriptBinaryDecoder.parseMember(truncated, 5, "synthetic", {})
  Assert.notNil(ir)
  local scripts = ir --[[@as { scripts: { decodeNote: table|nil }[] }]].scripts
  local note = scripts[0].decodeNote
  Assert.notNil(note)
  Assert.equal(note.offset, 0x20)
  Assert.equal(note.opcode, 73)
end

-- 8. The field-menu command family has fixed, source-faithful operand
-- layouts. These widths are the binary compatibility contract; semantic
-- interpretation is deliberately deferred to the menu runtime work.
T["field menu commands decode every operand"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 746, args = {} },
          { op = 747, args = {} },
          { op = 748, args = { { value = 0x4001, width = 2 } } },
          {
            op = 749,
            args = {
              { value = 17, width = 1 },
              { value = 5, width = 1 },
              { value = 2, width = 1 },
              { value = 1, width = 1 },
              { value = 0x4002, width = 2 },
            },
          },
          {
            op = 750,
            args = {
              { value = 9, width = 1 },
              { value = 8, width = 1 },
              { value = 7, width = 1 },
              { value = 0, width = 1 },
              { value = 0x4003, width = 2 },
            },
          },
          {
            op = 751,
            args = {
              { value = 0x4004, width = 2 },
              { value = 0x00FF, width = 2 },
              { value = 0x8005, width = 2 },
            },
          },
          { op = 752, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local member = decode(bytes, 5)
  local instructions = member.scripts[0].instructions
  local expected = {
    { opcode = 746, name = "ScrCmd_TouchscreenMenuHide", widths = {} },
    { opcode = 747, name = "ScrCmd_TouchscreenMenuShow", widths = {} },
    { opcode = 748, name = "ScrCmd_GetMenuChoice", widths = { 2 } },
    { opcode = 749, name = "ScrCmd_MenuInitStdGmm", widths = { 1, 1, 1, 1, 2 } },
    { opcode = 750, name = "ScrCmd_MenuInit", widths = { 1, 1, 1, 1, 2 } },
    { opcode = 751, name = "ScrCmd_MenuItemAdd", widths = { 2, 2, 2 } },
    { opcode = 752, name = "ScrCmd_MenuExec", widths = {} },
  }
  for index, contract in ipairs(expected) do
    local instruction = instructions[index]
    Assert.equal(instruction.opcode, contract.opcode)
    Assert.equal(instruction.name, contract.name)
    Assert.equal(#instruction.operands, #contract.widths)
    for operandIndex, width in ipairs(contract.widths) do
      Assert.equal(instruction.operands[operandIndex].width, width)
    end
  end
  Assert.equal(instructions[3].operands[1].raw, "VAR_0x4001")
  Assert.equal(instructions[4].operands[5].raw, "VAR_0x4002")
  Assert.equal(instructions[6].operands[3].raw, "VAR_0x8005")
end

-- 9. The signpost command family (55-60) has fixed, source-faithful operand
-- layouts. These widths are the binary compatibility contract; execution
-- timing/classification is deliberately deferred to the signpost runtime
-- work. Operand values mirror the real corpus fixtures (the Mount Moon
-- Square Trainer Tips and Route 1 directional signs).
T["signpost commands decode every operand"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- DirectionSignpost: message, type, map, unused out.
          {
            op = 55,
            args = {
              { value = 0, width = 1 },
              { value = 1, width = 1 },
              { value = 4, width = 2 },
              { value = 0x8008, width = 2 },
            },
          },
          -- SetSignpostMap: type, map.
          { op = 56, args = { { value = 2, width = 1 }, { value = 0, width = 2 } } },
          -- SetSignpostAction: the raw MAPSIGNCOMMAND value.
          { op = 57, args = { { value = 3, width = 1 } } },
          { op = 58, args = {} },
          -- TrainerTips: message, result var.
          { op = 59, args = { { value = 0, width = 1 }, { value = 0x8008, width = 2 } } },
          -- WaitSignpost: result var.
          { op = 60, args = { { value = 0x8008, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local member = decode(bytes, 5)
  local instructions = member.scripts[0].instructions
  local expected = {
    { opcode = 55, name = "ScrCmd_DirectionSignpost", widths = { 1, 1, 2, 2 } },
    { opcode = 56, name = "ScrCmd_SetSignpostMap", widths = { 1, 2 } },
    { opcode = 57, name = "ScrCmd_SetSignpostAction", widths = { 1 } },
    { opcode = 58, name = "ScrCmd_WaitSignpostAction", widths = {} },
    { opcode = 59, name = "ScrCmd_TrainerTips", widths = { 1, 2 } },
    { opcode = 60, name = "ScrCmd_WaitSignpost", widths = { 2 } },
  }
  for index, contract in ipairs(expected) do
    local instruction = instructions[index]
    Assert.equal(instruction.opcode, contract.opcode)
    Assert.equal(instruction.name, contract.name)
    Assert.equal(#instruction.operands, #contract.widths)
    for operandIndex, width in ipairs(contract.widths) do
      Assert.equal(instruction.operands[operandIndex].width, width)
    end
  end
  -- Non-catalog operands keep their raw numbers: the opcode-55 message/type/
  -- map and the opcode-56 type/map are presentation data the decoder must not
  -- rename or drop.
  Assert.equal(instructions[1].operands[1].raw, 0)
  Assert.equal(instructions[1].operands[2].raw, 1)
  Assert.equal(instructions[1].operands[3].raw, 4)
  Assert.equal(instructions[1].operands[4].raw, "VAR_SPECIAL_x8008")
  Assert.equal(instructions[2].operands[1].raw, 2)
  Assert.equal(instructions[2].operands[2].raw, 0)
  Assert.equal(instructions[3].operands[1].raw, 3)
  Assert.equal(instructions[5].operands[1].raw, 0)
  Assert.equal(instructions[5].operands[2].raw, "VAR_SPECIAL_x8008")
  Assert.equal(instructions[6].operands[1].raw, "VAR_SPECIAL_x8008")
  Assert.equal(instructions[7].opcode, 2)
end

-- RestartCurrentScript returns FALSE to the source interpreter loop, so the
-- common-child script continues into its following End: an End directly
-- abutting the restart is the script's terminal instruction, not padding in
-- a terminated region.
T["restart keeps its abutting end"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- 0x20: Call (6 bytes) -> 0x2A.
          { op = 26, args = { { target = 0x2A, width = 4 } } },
          -- 0x26: RestartCurrentScript (2) -> 0x28.
          { op = 21, args = {} },
          -- 0x28: End (2) -> 0x2A.
          { op = 2, args = {} },
          -- 0x2A: subroutine tail: Return (2).
          { op = 27, args = {} },
        },
      },
    },
  })
  local member = decode(bytes, 5)
  local opcodes = {}
  for _, ins in ipairs(member.scripts[0].instructions) do
    opcodes[#opcodes + 1] = ins.opcode
  end
  Assert.deepEqual(opcodes, { 26, 21, 2, 27 })
end

return { tests = T }
