-- Opcode 173's vanilla Bug Contest target is kept visible as unsupported.

local Assert = require("tests.support.Assert")
local FieldScripts = require("tests.rom.support.FieldScripts")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")

local T = {}

function T.vanilla_bug_contest_nickname_target_is_not_executable(romFs)
  local archive, members = FieldScripts.decodeMembers(romFs, { 151 })
  local member = assert(members[151], "field-script member 151 must be present")
  local found = false

  for scriptIndex, script in pairs(member.scripts) do
    local hasBugContestTarget = false
    for _, instruction in ipairs(script.instructions) do
      if instruction.opcode == 173 and instruction.operands[1].raw == 255 then
        hasBugContestTarget = true
        break
      end
    end
    if hasBugContestTarget then
      found = true
      local lowered = SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
      local steps = Structurer.structure(lowered, scriptIndex)
      local report = Verifier.verifyScript(steps, script, member, lowered.omissions)
      local unsupported = false
      for _, node in ipairs(lowered.unsupported) do
        if node.command == 173 and node.arguments[1] == 255 then
          unsupported = true
          Assert.equal(node.op, "unsupported")
          Assert.isTrue(node.reason:find("Bug Contest", 1, true) ~= nil)
        end
      end
      Assert.isTrue(unsupported, "literal Bug Contest target must remain an explicit unsupported node")
      Assert.isFalse(report.complete, "a script with the unsupported target cannot be complete")
    end
  end

  Assert.isTrue(found, "vanilla field-script member 151 must contain NicknameInput 255")
  Assert.isTrue(archive:memberCount() > 151)
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.tags = { "script", "corpus", "nickname" }
return suite
