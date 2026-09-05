-- Script translation pipeline tests: decode a synthetic member, lower,
-- structure, verify, and emit the DSL resource, with
-- deterministic emission and coverage accounting. No ROM and no decomp
-- checkout required.

local Assert = require("tests.support.Assert")
local ScriptFixture = require("tests.support.ScriptFixture")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local LuaEmitter = require("romdump.src.digest.script.LuaEmitter")
local Verifier = require("romdump.src.digest.script.Verifier")
local Coverage = require("romdump.src.digest.script.Coverage")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local S = require("gen4.script")

local T = {}

-- Script-cache invalidation is owned by the producer fingerprint: any edit
-- under romdump/src (including semantic-lowering changes) changes the
-- fingerprint and forces a full derived rebuild (producer_fingerprint_test +
-- cache_builder_test's forced-rebuild case). The old per-compiler
-- COMPILER_VERSION pin is gone with the constant.

local CATALOG = {
  sounds = { [1500] = "SEQ_SE_DP_SELECT" },
  flags = { [0x6A] = "FLAG_GOT_STARTER" },
  vars = { [0x8008] = "VAR_SPECIAL_x8008" },
  maps = {},
}

local function loweredActorSteps(operands)
  local instructions = {}
  for index, operand in ipairs(operands) do
    instructions[index] = {
      opcode = 94,
      operands = { operand, "@0010" },
      offset = index * 4,
    }
  end
  local lowered = SemanticLowering.lowerScript(
    { instructions = instructions },
    { member = 1, scripts = {}, movements = { [0x10] = { actions = {} } } },
    { stdCatalog = SourceCatalog.catalog() }
  )
  return lowered.items
end

-- The lab-sign shape (member 843 script 9): PlaySE; LockAll; NPCMsg 97;
-- WaitButton; CloseMsg; ReleaseAll; End.
local function labSignMember()
  return ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 73, args = { { value = 1500, width = 2 } } },
          { op = 96, args = {} },
          { op = 45, args = { { value = 97, width = 1 } } },
          { op = 50, args = {} },
          { op = 53, args = {} },
          { op = 97, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
end

local function translate(bytes, member, scriptIndex)
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, member, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[scriptIndex], ir, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, scriptIndex)
  local function scrub(items)
    for _, item in ipairs(items) do
      if item.op == "if" then
        scrub(item.yes)
        scrub(item.no)
      end
      item.movementComplete = nil
      item.movementUnsupported = nil
      item.yieldsNextTick = nil
      item.sourceNotes = nil
    end
  end
  scrub(steps)
  local report = Verifier.verifyScript(steps, ir.scripts[scriptIndex], ir, lowered.omissions)
  return ir, steps, report
end

-- 1. The lab-sign sequence lowers to the canonical fold shape.
T["lab sign fold shape"] = function()
  local _, steps, report = translate(labSignMember(), 843, 0)
  local ops = {}
  for _, step in ipairs(steps) do
    ops[#ops + 1] = step.op
  end
  Assert.deepEqual(ops, { "play_sound", "lock_all", "say", "release_all", "yield_tick", "stop" })
  Assert.equal(steps[1].sound, "SEQ_SE_DP_SELECT")
  Assert.equal(steps[3].message, "msg.hgss.0543.00097")
  Assert.isTrue(report.complete)
end

T["opcode 609 lowers to the follower gate"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = { { op = 609, args = {} }, { op = 2, args = {} } } },
    },
  })
  local _, steps, report = translate(bytes, 845, 0)
  Assert.equal(steps[1].op, "yield_tick")
  Assert.isTrue(report.complete)
end

T["generated movement operands preserve local and player identities"] = function()
  local items = loweredActorSteps({ 0, 1, "obj_player", 255 })
  Assert.deepEqual(items[1].actor, { ref = "actor", mapIndex = 0 })
  Assert.deepEqual(items[2].actor, { ref = "actor", mapIndex = 1 })
  Assert.deepEqual(items[3].actor, { ref = "actor", special = "player" })
  Assert.deepEqual(items[4].actor, { ref = "actor", special = "player" })
end

T["set object movement type lowers the semantic source type"] = function()
  local ir = {
    instructions = {
      {
        opcode = 340,
        operands = { { raw = 7 }, { raw = 3 } },
        offset = 0x20,
      },
    },
    scripts = {},
    movements = {},
  }
  ir.scripts[0] = { label = 0x20, instructions = ir.instructions }
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local step = lowered.items[1]
  Assert.equal(step.op, "set_object_movement_type")
  Assert.deepEqual(step.actor, { ref = "actor", mapIndex = 7 })
  Assert.equal(step.movementType, "wander_around")
  Assert.isFalse(step.movementType == "3")
end

T["set object movement type rejects an invalid source selector"] = function()
  local ir = {
    instructions = {
      {
        opcode = 340,
        operands = { { raw = 7 }, { raw = 57 } },
        offset = 0x24,
      },
    },
    scripts = {},
    movements = {},
  }
  ir.scripts[0] = { label = 0x24, instructions = ir.instructions }
  local err = Assert.throws(function()
    SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  end)
  Assert.equal(err.code, "SCRIPT_UNKNOWN_OBJECT_MOVEMENT")
  Assert.equal(err.context.sourceOffset, 0x24)
  Assert.equal(err.context.opcode, 340)
  Assert.equal(err.context.movement, 57)
end

-- 2. Emission is deterministic and byte-stable, and the resource validates.
T["emitter determinism and validation"] = function()
  local _, steps, report = translate(labSignMember(), 843, 0)
  local resource = {
    api = 1,
    id = "vanilla.hgss.scr_seq.0843.script_009",
    metadata = { coverage = { complete = report.complete, unsupportedCount = report.unsupportedCount } },
    steps = steps,
  }
  local meta = {
    member = 843,
    scriptIndex = 9,
    sourcePath = "romfs/scr_seq.narc",
    romSha1 = "rom-sha",
    repository = "g4recomp",
    game = "heartgold",
    sourceHash = "member-sha",
    coverage = resource.metadata.coverage,
  }
  Assert.equal(LuaEmitter.emit(resource, meta), LuaEmitter.emit(resource, meta))
  local text = LuaEmitter.emit(resource, meta)
  Assert.equal(text:sub(-1), "\n")
  Assert.isTrue(text:find("Generated by hgss-script-translator", 1, true) ~= nil)
  Assert.isTrue(text:find("msg.hgss.0543.00097", 1, true) ~= nil)
  Assert.isTrue(text:find('game = "heartgold"', 1, true) ~= nil)
  local ok, validateErr = S.validate(resource)
  Assert.isTrue(ok, tostring(validateErr))
end

-- 3. An unsupported instruction (e.g. SetTrainerFlag) makes the script
-- partial with an explicit unsupported node.
T["unsupported instructions stay explicit"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 36, args = { { value = 1, width = 2 }, { value = 2, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.equal(#lowered.unsupported, 1)
  Assert.equal(lowered.unsupported[1].command, 36)
  Assert.equal(lowered.unsupported[1].originalName, "ScrCmd_SetTrainerFlag")
  local report = Verifier.verifyScript(Structurer.structure(lowered, 0), ir.scripts[0], ir, lowered.omissions)
  Assert.isFalse(report.complete)
  Assert.equal(report.unsupportedCount, 1)
end

-- 4. The coverage record aggregates occurrence counts with the pinned names.
T["coverage record counts opcodes"] = function()
  local ir =
    assert(ScriptBinaryDecoder.parseMember(labSignMember(), 843, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, ir.scripts[0], ir, lowered.omissions)
  local record = Coverage.record(ir, {
    [0] = { script = ir.scripts[0], resource = { id = "x" }, report = report },
  }, { repository = "g4recomp", romSha1 = "rom-sha" })
  Assert.equal(record.totals.scripts, 1)
  Assert.equal(record.totals.reachableInstructions, 7)
  Assert.equal(record.opcodes[73].name, "ScrCmd_PlaySE")
  Assert.equal(record.opcodes[73].occurrences, 1)
  Assert.equal(record.opcodes[45].name, "ScrCmd_NPCMsg")
  Assert.equal(record.scripts[1].status, "complete")
  Assert.isTrue(Coverage.markdown(record):find("ScrCmd_PlaySE", 1, true) ~= nil)
end

-- 5. The std catalog resolves CallStd operands to common.<name> ids.
T["call std resolves common ids"] = function()
  local catalog = SourceCatalog.catalog()
  local name = SourceCatalog.commonPublicId(catalog, 0x30A)
  Assert.isTrue(name == "common.std_" .. tostring(0x30A) or name:match("^common%.") ~= nil)
  Assert.equal(catalog.locate(2000).member, 3)
  Assert.equal(catalog.locate(2000).scriptIndex, 0)
end

-- 6. A conditional call is never peeled into a branch region: the emitted
-- program keeps the structured if wrapping the call.
T["call_if stays a structured call"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- 0x20: compare (6 bytes) -> 0x26
          { op = 17, args = { { value = 1, width = 2 }, { value = 2, width = 2 } } },
          -- 0x26: CallIf (7 bytes) -> 0x2D, target 0x33 (the subroutine entry)
          { op = 29, args = { { value = 1, width = 1 }, { target = 0x33, width = 4 } } },
          -- 0x2D: SetFlag (4 bytes) -> 0x31
          { op = 30, args = { { value = 3, width = 2 } } },
          -- 0x31: End (2 bytes) -> 0x33
          { op = 2, args = {} },
          -- 0x33: subroutine entry (branch target label), SetFlag (4) -> 0x37
          { op = 30, args = { { value = 4, width = 2 } } },
          -- 0x37: Return (2 bytes) -> 0x39
          { op = 27, args = {} },
        },
      },
    },
  })
  local _, steps = translate(bytes, 5, 0)
  local function walk(list, depth, out)
    for _, step in ipairs(list) do
      if step.op == "if" then
        walk(step.yes, depth + 1, out)
        walk(step.no, depth + 1, out)
      else
        out[#out + 1] = { op = step.op, target = step.target, depth = depth }
      end
    end
  end
  local flat = {}
  walk(steps, 0, flat)
  local callSeen = false
  for _, entry in ipairs(flat) do
    if entry.op == "call" then
      callSeen = true
      Assert.equal(entry.depth, 1, "the conditional call sits inside one if")
    end
  end
  Assert.isTrue(callSeen, "the conditional call survives as a call")
end

-- 7. A label on the second instruction of a candidate fold keeps the
-- instructions separate: jumping into the fold's interior must not execute
-- the folded head.
T["fold respects interior labels"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- 0x20: Goto (6 bytes) -> 0x26, target 0x2C (labels the GoToIf)
          { op = 22, args = { { target = 0x2C, width = 4 } } },
          -- 0x26: compare (6 bytes) -> 0x2C
          { op = 17, args = { { value = 1, width = 2 }, { value = 2, width = 2 } } },
          -- 0x2C: GoToIf (7 bytes) -> 0x33, target 0x44 (labeled entry)
          { op = 28, args = { { value = 1, width = 1 }, { target = 0x3A, width = 4 } } },
          -- 0x33: NPCMsg (3 bytes) -> 0x36
          { op = 45, args = { { value = 97, width = 1 } } },
          -- 0x36: WaitButton (2) -> 0x38
          { op = 50, args = {} },
          -- 0x38: CloseMsg (2) -> 0x3A
          { op = 53, args = {} },
          -- 0x3A: End (2) -> 0x3C
          { op = 2, args = {} },
          -- 0x3C: Goto (6) -> 0x42, target 0x42
          { op = 22, args = { { target = 0x42, width = 4 } } },
          -- 0x42: End (2) -> 0x44
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, steps = translate(bytes, 5, 0)
  -- The compare and the GoToIf stay separate instructions; the label owns
  -- the branch alone.
  local ops = {}
  local function walk(list)
    for _, step in ipairs(list) do
      if step.op == "if" then
        walk(step.yes)
        walk(step.no)
      else
        ops[#ops + 1] = step.op
      end
    end
  end
  walk(steps)
  Assert.isTrue(ops[2] == "compare" or ops[3] == "compare", "the compare survives as its own instruction")
  local controlSeen = false
  for _, op in ipairs(ops) do
    if op == "goto_if" or op == "goto_compared" then
      controlSeen = true
    end
  end
  Assert.isTrue(controlSeen, "the labeled branch survives as its own control node")
end

-- 8. MovePersonFacing (opcode 339) emits position then facing: the facing
-- side effect is a canonical operation, never diagnostic data.
T["move person facing emits position and facing"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          {
            op = 339,
            args = {
              { value = 2, width = 2 },
              { value = 684, width = 2 },
              { value = 393, width = 2 },
              { value = 0, width = 2 },
              { value = 0, width = 2 },
            },
          },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, steps = translate(bytes, 5, 0)
  Assert.equal(steps[1].op, "set_object_position")
  Assert.equal(steps[2].op, "set_object_facing")
  Assert.equal(steps[2].direction, "north")
  Assert.isNil(steps[1].sourceFacing, "no diagnostic facing field survives")

  -- ScrCmd_MovePersonFacing (src/scrcmd_c.c) reads its operands in the order
  -- objectId, x, y, z, direction -- the ground-plane Z field is the fourth
  -- operand and the height is the third, even though the assembly macro
  -- names its own third parameter "z" and fourth "y". The lowering must
  -- follow the engine's read order, not the macro's cosmetic parameter
  -- names, or a stationary NPC gets placed one axis off from every other
  -- source of ground coordinates.
  Assert.equal(steps[1].fieldX, 684, "field X is the second operand")
  Assert.equal(steps[1].fieldZ, 0, "field Z is the fourth operand, not the third")
  Assert.equal(steps[1].worldY, 393, "world Y (height) is the third operand, not the fourth")
end

-- 9. The verifier runs on the final structured program: a scrub that strips
-- a step's provenance leaves the source instruction uncovered and fails.
T["verifier catches post-lowering damage"] = function()
  local bytes = labSignMember()
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 843, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  steps[3].provenance = nil -- the say's coverage vanishes
  local report = Verifier.verifyScript(steps, ir.scripts[0], ir, lowered.omissions)
  Assert.isFalse(report.ok, "the verifier sees the final program")
end

-- 10. Every emitted step retains its source provenance: the emitted text of
-- a translated script covers every reachable instruction offset.
T["emitted steps keep provenance"] = function()
  local _, steps, report = translate(labSignMember(), 843, 0)
  Assert.isTrue(report.ok)
  for i, step in ipairs(steps) do
    if step.op ~= "label" and step.op ~= "yield_tick" then
      Assert.notNil(step.provenance, "step " .. i .. " (" .. step.op .. ") keeps provenance")
      Assert.isTrue(#step.provenance.offsets > 0)
    end
  end
end

-- 11. The touchscreen visibility and list-menu builder commands lower to
-- their own semantic operations. GetMenuChoice is an independent asynchronous
-- contextual-provider request.
T["field menu commands lower with exact semantics"] = function()
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
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.equal(lowered.items[1].op, "set_auxiliary_ui_visible")
  Assert.isFalse(lowered.items[1].visible)
  Assert.equal(lowered.items[2].op, "set_auxiliary_ui_visible")
  Assert.isTrue(lowered.items[2].visible)
  Assert.equal(lowered.items[3].op, "context_choice")
  Assert.deepEqual(lowered.items[3].result, { value = "var", id = "VAR_0x4001" })
  Assert.equal(#lowered.unsupported, 0)
  Assert.deepEqual(lowered.items[4], {
    op = "menu_begin",
    messageSource = "standard",
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 17, y = 5 },
    initialCursor = 2,
    cancellable = true,
    result = { value = "var", id = "VAR_0x4002" },
    provenance = { offsets = { 40 }, opcodes = { 749 } },
  })
  Assert.deepEqual(lowered.items[5], {
    op = "menu_begin",
    messageSource = { kind = "script", bank = 543 },
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 9, y = 8 },
    initialCursor = 7,
    cancellable = false,
    result = { value = "var", id = "VAR_0x4003" },
    provenance = { offsets = { 48 }, opcodes = { 750 } },
  })
  Assert.deepEqual(lowered.items[6], {
    op = "menu_add",
    messageId = { value = "var", id = "VAR_0x4004" },
    vanillaMetadata = 0x00FF,
    value = { value = "var", id = "VAR_0x8005" },
    provenance = { offsets = { 56 }, opcodes = { 751 } },
  })
  Assert.deepEqual(lowered.items[7], {
    op = "menu_exec",
    provenance = { offsets = { 64 }, opcodes = { 752 } },
  })
end

-- The corpus verifier must recognize every supported field-menu lowering as
-- an intentional semantic operation rather than treating it as an uncovered
-- source instruction.
T["field menu operations verify as supported"] = function()
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
            args = { { value = 0x4004, width = 2 }, { value = 0x00FF, width = 2 }, { value = 0x8005, width = 2 } },
          },
          { op = 752, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, _, report = translate(bytes, 5, 0)

  Assert.isTrue(
    report.ok,
    report.problems[1] and report.problems[1].message or "field-menu operations are verifier-supported"
  )
  Assert.equal(report.unsupportedCount, 0)
end

-- 12. Opcodes 55-61 carry their execution classifications (runtime support
-- lands atomically with each; 61 is the std_signpost context end).
T["signpost 55-61 classify as supported"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          {
            op = 55,
            args = {
              { value = 0, width = 1 },
              { value = 1, width = 1 },
              { value = 4, width = 2 },
              { value = 0x8008, width = 2 },
            },
          },
          { op = 56, args = { { value = 2, width = 1 }, { value = 0, width = 2 } } },
          { op = 57, args = { { value = 3, width = 1 } } },
          { op = 58, args = {} },
          { op = 59, args = { { value = 0, width = 1 }, { value = 0x8008, width = 2 } } },
          { op = 60, args = { { value = 0x8008, width = 2 } } },
          { op = 61, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  for opcode = 55, 61 do
    Assert.isTrue(CommandCatalog.SUPPORTED[opcode], "opcode " .. opcode .. " is not marked supported")
  end
  Assert.equal(CommandCatalog.classification(55), CommandCatalog.YIELD)
  Assert.equal(CommandCatalog.classification(56), CommandCatalog.YIELD)
  Assert.equal(CommandCatalog.classification(57), CommandCatalog.YIELD)
  Assert.equal(CommandCatalog.classification(58), CommandCatalog.NATIVE_WAIT)
  Assert.equal(CommandCatalog.classification(59), CommandCatalog.NATIVE_WAIT)
  Assert.equal(CommandCatalog.classification(60), CommandCatalog.NATIVE_WAIT)
  Assert.equal(CommandCatalog.classification(61), CommandCatalog.STOP)
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.equal(#lowered.unsupported, 0)
  local report = Verifier.verifyScript(Structurer.structure(lowered, 0), ir.scripts[0], ir, lowered.omissions)
  Assert.equal(report.unsupportedCount, 0)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "signpost 55-61 must verify")
  Assert.isTrue(report.complete)
end

-- 14. Opcode 57 (SetSignpostAction) lowers its raw command code 0..4 to the
-- exact semantic command enum, and opcode 58 (WaitSignpostAction) lowers to
-- the canonical wait node with no operands. Both verify as supported with
-- provenance; unknown codes >= 5 are malformed source and never default to
-- nop.
T["set signpost action and wait signpost action lower to canonical nodes"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 57, args = { { value = 0, width = 1 } } },
          { op = 57, args = { { value = 1, width = 1 } } },
          { op = 57, args = { { value = 2, width = 1 } } },
          { op = 57, args = { { value = 3, width = 1 } } },
          { op = 57, args = { { value = 4, width = 1 } } },
          { op = 58, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local commands = { "nop", "show", "wipe_out", "wipe_in", "hide" }
  for index, command in ipairs(commands) do
    Assert.deepEqual(lowered.items[index], {
      op = "signpost_command",
      command = command,
      provenance = { offsets = { 32 + (index - 1) * 3 }, opcodes = { 57 } },
    }, "raw command " .. (index - 1) .. " must lower to " .. command)
  end
  Assert.deepEqual(lowered.items[6], {
    op = "wait_signpost_action",
    provenance = { offsets = { 47 }, opcodes = { 58 } },
  })
  local report = Verifier.verifyScript(Structurer.structure(lowered, 0), ir.scripts[0], ir, lowered.omissions)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "signpost 57/58 must verify")
  Assert.equal(report.unsupportedCount, 0)
  Assert.isTrue(report.complete)
end

-- 15. A raw SetSignpostAction command outside the pinned 0..4 range is
-- malformed source: lowering raises instead of defaulting to nop.
T["unknown signpost action command is malformed source"] = function()
  for _, raw in ipairs({ 5, 255 }) do
    local bytes = ScriptFixture.member({
      scripts = {
        {
          offset = 0x20,
          instructions = {
            { op = 57, args = { { value = raw, width = 1 } } },
            { op = 2, args = {} },
          },
        },
      },
    })
    local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
    local ok, err = pcall(SemanticLowering.lowerScript, ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
    Assert.isFalse(ok, "raw command " .. raw .. " must not lower silently")
    Assert.isTrue(
      tostring(err):find("signpost command", 1, true) ~= nil,
      "the malformed-command error names the signpost command, got: " .. tostring(err)
    )
  end
end

-- 17. Opcode 61 (ScrCmd_061, the std_signpost context end): no operands,
-- ends the script context and requests the Start Menu reopen hook. It
-- lowers to the canonical terminal request_start_menu node and verifies as
-- a stop-classified supported translation, never an unsupported node.
T["request start menu (61) lowers to the canonical terminal node"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 61, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1], {
    op = "request_start_menu",
    provenance = { offsets = { 32 }, opcodes = { 61 } },
  })
  local report = Verifier.verifyScript(Structurer.structure(lowered, 0), ir.scripts[0], ir, lowered.omissions)
  Assert.equal(report.unsupportedCount, 0)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "opcode 61 must verify")
  Assert.isTrue(report.complete)
end

-- 16. Opcode 59 (TrainerTips) lowers to the canonical typed-print node with
-- the member's message bank resolved and the raw result var preserved;
-- opcode 60 (WaitSignpost) lowers to the canonical wait node with its result
-- var. Both keep provenance and verify as supported blocking translations.
T["trainer tips and wait signpost lower to canonical nodes"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- TrainerTips: message, resultVar.
          { op = 59, args = { { value = 0, width = 1 }, { value = 0x8008, width = 2 } } },
          -- WaitSignpost: resultVar.
          { op = 60, args = { { value = 0x8008, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1], {
    op = "trainer_tips_print",
    message = { message = "external", bank = 543, id = 0 },
    result = { value = "var", id = "VAR_SPECIAL_x8008" },
    provenance = { offsets = { 32 }, opcodes = { 59 } },
  })
  Assert.deepEqual(lowered.items[2], {
    op = "wait_signpost",
    result = { value = "var", id = "VAR_SPECIAL_x8008" },
    provenance = { offsets = { 37 }, opcodes = { 60 } },
  })
  local report = Verifier.verifyScript(Structurer.structure(lowered, 0), ir.scripts[0], ir, lowered.omissions)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "signpost 59/60 must verify")
  Assert.equal(report.unsupportedCount, 0)
  Assert.isTrue(report.complete)
end

-- 18. Opcode 21 (signal_caller) is a terminal context end: a conditional
-- fallthrough chain that reaches the signal must not be peeled into a
-- structured branch (the post-signal code would land inside the branch),
-- and the verifier must accept the stop-classified translation. Post-signal
-- code decodes only when a branch target justifies it (the decoder ends
-- the script walk at the signal), so the conditional target lands inside
-- the post-signal run.
T["signal_caller ends the fallthrough chain and stays terminal"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- 0x20: compare (6 bytes) -> 0x26
          { op = 17, args = { { value = 1, width = 2 }, { value = 2, width = 2 } } },
          -- 0x26: GoToIf (7 bytes) -> 0x2D, target 0x2F (post-signal code)
          { op = 28, args = { { value = 1, width = 1 }, { target = 0x2F, width = 4 } } },
          -- 0x2D: signal_caller (2 bytes) -> 0x2F
          { op = 21, args = {} },
          -- 0x2F: Goto (6 bytes) -> 0x35, target 0x3B
          { op = 22, args = { { target = 0x3B, width = 4 } } },
          -- 0x35: SetVar (6 bytes) -> 0x3B
          { op = 41, args = { { value = 0x4001, width = 2 }, { value = 5, width = 2 } } },
          -- 0x3B: End (2 bytes) -> 0x3D
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, ir.scripts[0], ir, lowered.omissions)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "signal_caller must verify as terminal")
  Assert.isTrue(report.complete)
  -- The peel must not run: the goto_if fallback survives, and the post-signal
  -- Goto sits at the top level directly after the signal — never inside a
  -- branch that an accidental continuation could re-enter.
  local flat = {}
  local function walk(list)
    for _, step in ipairs(list) do
      if step.op == "if" then
        flat[#flat + 1] = "if"
        walk(step.yes)
        walk(step.no)
      elseif step.op ~= "label" then
        flat[#flat + 1] = step.op
      end
    end
  end
  walk(steps)
  Assert.deepEqual(flat, { "goto_if", "signal_caller", "goto", "set_var", "stop" })
end

-- 13. The canonical lowering shapes for opcodes 55 and 56: the raw
-- type/map survive exactly as source data, the message id is bank-qualified
-- from the member, and both nodes verify as supported yield boundaries with
-- provenance. Opcode 55's final operand is audited as unused by the source
-- handler and is erased from the semantic node.
T["direction and set signpost lower to canonical nodes"] = function()
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
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1], {
    op = "signpost_direction",
    message = { message = "external", bank = 543, id = 0 },
    sourceAppearance = { game = "hgss", type = 1, map = 4 },
    provenance = { offsets = { 32 }, opcodes = { 55 } },
  })
  Assert.deepEqual(lowered.items[2], {
    op = "signpost_set",
    sourceAppearance = { game = "hgss", type = 2, map = 0 },
    provenance = { offsets = { 40 }, opcodes = { 56 } },
  })
  local report = Verifier.verifyScript(Structurer.structure(lowered, 0), ir.scripts[0], ir, lowered.omissions)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "signpost 55/56 must verify")
  Assert.equal(report.unsupportedCount, 0)
  Assert.isTrue(report.complete)
end

-- FadeOutBGM/FadeInBGM are native waits in the pinned source
-- (GF_SndStartFadeOutBGM + SetupNativeScript(ScrNative_GetFadeTimer), see
-- scrcmd_sound.c), never same-tick passthroughs.
T["fade commands classify as native waits"] = function()
  Assert.equal(CommandCatalog.classification(84), CommandCatalog.NATIVE_WAIT)
  Assert.equal(CommandCatalog.classification(85), CommandCatalog.NATIVE_WAIT)
end

-- PlaySE/StopSE/WaitSE/PlayFanfare read their operand through
-- ScriptGetVar (scrcmd_sound.c), so a var-range operand must lower to a
-- value reference, not a literal sequence name.
T["se waits and fanfare var operands lower as value references"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 73, args = { { value = 0x4000, width = 2 } } },
          { op = 74, args = { { value = 0x4000, width = 2 } } },
          { op = 75, args = { { value = 0x4000, width = 2 } } },
          { op = 78, args = { { value = 0x4000, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 843, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1].sound, { value = "var", id = "VAR_0x4000" }, "PlaySE operand is a value reference")
  Assert.deepEqual(lowered.items[2].sound, { value = "var", id = "VAR_0x4000" }, "StopSE operand is a value reference")
  Assert.deepEqual(lowered.items[3].sound, { value = "var", id = "VAR_0x4000" }, "WaitSE operand is a value reference")
  Assert.deepEqual(
    lowered.items[4].fanfare,
    { value = "var", id = "VAR_0x4000" },
    "PlayFanfare operand is a value reference"
  )
end

-- both PlayCry operands are read through ScriptGetVar
-- (PlayCryEx(var1, var0, ...) in scrcmd_sound.c), so the pattern operand must
-- lower to a value reference like the species already does.
T["play cry lowers both operands as value references"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 76, args = { { value = 0x4000, width = 2 }, { value = 0x4001, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 843, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1].species, { value = "var", id = "VAR_0x4000" })
  Assert.deepEqual(
    lowered.items[1].pattern,
    { value = "var", id = "VAR_0x4001" },
    "the cry pattern operand is a value reference"
  )
end

-- once 84/85 are native waits, the verifier must accept the fade nodes
-- as the blocking translation; the emitted ops stay the single combined
-- start-and-block semantic nodes.
T["fade scripts verify as complete with blocking fade nodes"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 84, args = { { value = 0, width = 2 }, { value = 30, width = 2 } } },
          { op = 85, args = { { value = 30, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, steps, report = translate(bytes, 843, 0)
  local ops = {}
  for _, step in ipairs(steps) do
    ops[#ops + 1] = step.op
  end
  Assert.deepEqual(ops, { "fade_music_out", "fade_music_in", "stop" })
  Assert.equal(steps[1].durationTicks, 30)
  Assert.equal(steps[2].durationTicks, 30)
  Assert.isTrue(report.complete)
end

-- StopBGM reads its operand but ignores it (scrcmd_sound.c stops the
-- currently playing BGM), so the generated node never carries a music field.
T["stop bgm erases its source operand"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 81, args = { { value = 1500, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, steps, report = translate(bytes, 843, 0)
  Assert.equal(steps[1].op, "stop_music")
  Assert.isNil(steps[1].music, "the StopBGM operand is a documented erasure")
  Assert.isTrue(report.complete)
end

-- the not-yet-supported sound-adjacent opcodes (83/86/88/93) stay
-- explicit attributed unsupported nodes, never no-ops.
T["unclassified sound commands stay attributed unsupported"] = function()
  for _, opcode in ipairs({ 83, 86, 88, 93 }) do
    Assert.equal(CommandCatalog.classification(opcode), CommandCatalog.UNSUPPORTED, "opcode " .. tostring(opcode))
  end
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 86, args = { { value = 1, width = 1 }, { value = 2, width = 1 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 843, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.equal(#lowered.unsupported, 1)
  Assert.equal(lowered.unsupported[1].command, 86)
  Assert.equal(lowered.unsupported[1].originalName, "ScrCmd_086")
  local report = Verifier.verifyScript(Structurer.structure(lowered, 0), ir.scripts[0], ir, lowered.omissions)
  Assert.isFalse(report.complete)
end

-- Follower-active query semantics: opcode 729 (follower-active query)
-- reads the live controller state into its destination variable instead of
-- a constant.
T["opcode 729 reads live follower state"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 729, args = { { value = 0x8008, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1], {
    op = "follower_is_active",
    result = { value = "var", id = "VAR_SPECIAL_x8008" },
    provenance = { offsets = { 32 }, opcodes = { 729 } },
  })
  Assert.equal(#lowered.unsupported, 0)
end

-- Opcode 144 (GetFriendSprite) always has real semantics: the opposite-gender
-- friend NPC sprite constant, independent of any follower subsystem.
T["opcode 144 lowers to the friend sprite value"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 144, args = { { value = 0x8008, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1], {
    op = "set_var",
    variable = { value = "var", id = "VAR_SPECIAL_x8008" },
    value = { value = "friend_sprite_value" },
    provenance = { offsets = { 32 }, opcodes = { 144 } },
  })
  Assert.equal(#lowered.unsupported, 0)
end

-- Opcode 294 (CheckBadge) has no persisted gym-badge subsystem; every badge
-- check in the fresh-game opening window is source-correctly false, written
-- as an explicit constant result.
T["opcode 294 writes the explicit no-badge result"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 294, args = { { value = 0, width = 2 }, { value = 0x8008, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1], {
    op = "set_var",
    variable = { value = "var", id = "VAR_SPECIAL_x8008" },
    value = 0,
    provenance = { offsets = { 32 }, opcodes = { 294 } },
  })
  Assert.equal(#lowered.unsupported, 0)
end

T["opcode 596 reads live partner state while 600 stays deferred"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 596, args = { { value = 0x8008, width = 2 } } },
          { op = 600, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  Assert.equal(CommandCatalog.classification(596), CommandCatalog.CONTINUE)
  Assert.equal(CommandCatalog.classification(600), CommandCatalog.UNSUPPORTED)
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1], {
    op = "follower_partner_state",
    result = { value = "var", id = "VAR_SPECIAL_x8008" },
    provenance = { offsets = { 32 }, opcodes = { 596 } },
  })
  Assert.equal(#lowered.unsupported, 1)
  Assert.equal(lowered.unsupported[1].command, 600)
  Assert.equal(lowered.unsupported[1].originalName, "ScrCmd_600")
end

-- Opcode 582 (the source special-spawn setter) must lower to a named
-- `set_special_spawn` node carrying map/coordinates/warpId/direction rather
-- than disappearing as a noop.
T["opcode 582 lowers to a named special-spawn setter"] = function()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          {
            op = 582,
            args = { { value = 0x8008, width = 2 }, { value = 688, width = 2 }, { value = 393, width = 2 } },
          },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.deepEqual(lowered.items[1], {
    op = "set_special_spawn",
    map = { value = "var", id = "VAR_SPECIAL_x8008" },
    fieldX = 688,
    fieldZ = 393,
    warpId = -1,
    direction = "south",
    provenance = { offsets = { 32 }, opcodes = { 582 } },
  })
  Assert.equal(#lowered.unsupported, 0)
end

-- Opcode 188 (SetAvatarBits) unfolds its u16 mask into one semantic queue
-- operation per selected supported transition in fixed source bit order,
-- followed by exactly one scheduler yield -- even when the mask selects
-- nothing. Source bit 15 has no transition handler and vanishes; the raw mask
-- never survives into the generated graph. Unsupported bit 3 is tested below.
local AVATAR_TRANSITION_ORDER = {
  "walking",
  "cycling",
  "surfing",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

local function lowerSingleAvatar(opcode, operandRaw)
  local operands = {}
  if operandRaw ~= nil then
    operands[1] = { raw = operandRaw }
  end
  local ir = {
    instructions = { { opcode = opcode, operands = operands, offset = 0x20 } },
    scripts = {},
    movements = {},
  }
  ir.scripts[0] = { label = 0x20, instructions = ir.instructions }
  return SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
end

local function lowerAvatarMember(mask)
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 188, args = { { value = mask, width = 2 } } },
        },
      },
    },
  })
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  return SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
end

T["set avatar bits unfolds to ordered queue operations with one yield"] = function()
  local cases = {
    { mask = 0, queues = {} },
    { mask = 0x8000, queues = {} },
    { mask = 0x0100, queues = { "heal" } },
    { mask = 0x0900, queues = { "heal", "rocket_heal" } },
    { mask = 0x8900, queues = { "heal", "rocket_heal" } },
    { mask = 0xFFF7, queues = AVATAR_TRANSITION_ORDER },
  }
  for _, case in ipairs(cases) do
    local lowered = lowerSingleAvatar(188, case.mask)
    Assert.equal(#lowered.unsupported, 0, string.format("mask 0x%04X must not lower as unsupported", case.mask))
    local expected = {}
    for _, transition in ipairs(case.queues) do
      expected[#expected + 1] = {
        op = "queue_avatar_transition",
        transition = transition,
        provenance = { offsets = { 0x20 }, opcodes = { 188 } },
      }
    end
    expected[#expected + 1] = { op = "yield_tick" }
    Assert.deepEqual(
      lowered.items,
      expected,
      string.format("mask 0x%04X must unfold to ordered queues plus exactly one yield", case.mask)
    )
    for _, item in ipairs(lowered.items) do
      Assert.isNil(item.mask, "the raw transition mask must not survive lowering")
      if item.op == "queue_avatar_transition" then
        Assert.equal(type(item.transition), "string", "queued transitions are semantic names")
      end
    end
  end
end

T["unsupported bit-3 avatar masks lower atomically"] = function()
  for _, case in ipairs({ { mask = 0x0008 }, { mask = 0x0109 } }) do
    local lowered = lowerAvatarMember(case.mask)
    Assert.equal(#lowered.items, 1, string.format("mask 0x%04X is one source instruction", case.mask))
    Assert.equal(#lowered.unsupported, 1, string.format("mask 0x%04X has one unsupported node", case.mask))

    local node = lowered.unsupported[1]
    Assert.isTrue(node == lowered.items[1], "the unsupported node is the lowered instruction")
    Assert.equal(node.op, "unsupported")
    Assert.equal(node.command, 188)
    Assert.equal(node.originalName, "ScrCmd_SetAvatarBits")
    Assert.deepEqual(node.arguments, { case.mask })
    Assert.equal(node.sourceOffset, 0x20)
    Assert.deepEqual(node.provenance, { offsets = { 0x20 }, opcodes = { 188 } })
    Assert.equal(type(node.reason), "string")
    Assert.isTrue(node.reason:find("PLAYER_TRANSITION_x0008", 1, true) ~= nil)
    Assert.isTrue(node.reason:find("movement side effect", 1, true) ~= nil)

    local queueCount, yieldCount = 0, 0
    for _, item in ipairs(lowered.items) do
      if item.op == "queue_avatar_transition" then
        queueCount = queueCount + 1
      elseif item.op == "yield_tick" then
        yieldCount = yieldCount + 1
      end
    end
    Assert.equal(queueCount, 0, string.format("mask 0x%04X queues no partial transitions", case.mask))
    Assert.equal(yieldCount, 0, string.format("mask 0x%04X emits no synthesized yield", case.mask))
  end
end

-- Opcode 189 (UpdateAvatarState) is one same-tick apply operation with no
-- operands and no appended yield. Adjacent 188/189 pairs are never combined:
-- the queue group, its yield, and the apply node survive as separate steps.
T["update avatar state lowers to a single same-tick apply operation"] = function()
  local lowered = lowerSingleAvatar(189, nil)
  Assert.equal(#lowered.unsupported, 0)
  Assert.deepEqual(lowered.items, {
    { op = "apply_avatar_transitions", provenance = { offsets = { 0x20 }, opcodes = { 189 } } },
  })

  local ir = {
    instructions = {
      { opcode = 188, operands = { { raw = 0x0100 } }, offset = 0x20 },
      { opcode = 189, operands = {}, offset = 0x24 },
    },
    scripts = {},
    movements = {},
  }
  ir.scripts[0] = { label = 0x20, instructions = ir.instructions }
  local adjacent = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  Assert.equal(#adjacent.unsupported, 0)
  Assert.deepEqual(adjacent.items, {
    {
      op = "queue_avatar_transition",
      transition = "heal",
      provenance = { offsets = { 0x20 }, opcodes = { 188 } },
    },
    { op = "yield_tick" },
    { op = "apply_avatar_transitions", provenance = { offsets = { 0x24 }, opcodes = { 189 } } },
  })

  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 188, args = { { value = 0x0100, width = 2 } } },
          { op = 189, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, steps, report = translate(bytes, 5, 0)
  local ops = {}
  for _, step in ipairs(steps) do
    ops[#ops + 1] = step.op
    Assert.isNil(step.mask, "the raw transition mask must not survive compilation")
  end
  Assert.deepEqual(ops, { "queue_avatar_transition", "yield_tick", "apply_avatar_transitions", "stop" })
  Assert.equal(steps[1].transition, "heal")
  Assert.equal(report.unsupportedCount, 0)
end

return { tests = T }
