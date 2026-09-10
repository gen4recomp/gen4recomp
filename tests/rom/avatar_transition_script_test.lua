-- ROM-gated avatar-transition lowering coverage: current retail SetAvatarBits
-- (188) and UpdateAvatarState (189) call sites select only supported semantic
-- transitions and preserve source ordering/timing. Representative flows
-- pinned here are the Pokemon Center heal/restore choreography (member 3),
-- the Rocket-costume switches (member 94), and the Pokeathlon switches
-- (member 167). Full-script acceptance is out of scope: neighboring
-- unsupported commands never fail this suite.

local Assert = require("tests.support.Assert")
local FieldScripts = require("tests.rom.support.FieldScripts")
local PlayerAvatar = require("romdump.src.reference.hgss.player_avatar")

local T = {}

-- Explicit retail flows: the Pokemon Center heal/restore choreography, the
-- Rocket-costume switches, and the Pokeathlon switches. Literal member
-- data, never discovered; only these members are decoded.
local SAMPLE_MEMBERS = { 3, 94, 167 }

local function provenanceMatches(item, offset, opcode)
  local provenance = item.provenance
  return provenance ~= nil and provenance.offsets[1] == offset and provenance.opcodes[1] == opcode
end

T["retail supported avatar transition sites remain supported"] = function(romFs)
  local archive, memberIrs = FieldScripts.decodeMembers(romFs, SAMPLE_MEMBERS)
  local queueSites = 0
  local applySites = 0
  local seenTransitions = {}
  local memberQueueMasks = {}
  local memberApplyCount = {}

  local function recordMemberMasks(member, mask)
    local masks = memberQueueMasks[member]
    if masks == nil then
      masks = {}
      memberQueueMasks[member] = masks
    end
    masks[#masks + 1] = mask
  end

  FieldScripts.eachScript(archive, memberIrs, function(member, index, _, lowered)
    local script = memberIrs[member].scripts[index]
    for _, ins in ipairs(script.instructions) do
      if ins.opcode == 188 then
        queueSites = queueSites + 1
        local mask = ins.operands[1] and ins.operands[1].raw
        Assert.equal(
          type(mask),
          "number",
          string.format("member %d script %d: the queue mask is an immediate", member, index)
        )
        Assert.isTrue(mask >= 0 and mask <= 0xFFFF, "the queue mask fits in one unsigned word")
        recordMemberMasks(member, mask)
        local expected, unsupportedBits = PlayerAvatar.transitionsForMask(mask)
        Assert.deepEqual(
          unsupportedBits,
          {},
          string.format(
            "member %d script %d offset 0x%X: the retail mask selects no unsupported bits",
            member,
            index,
            ins.offset
          )
        )
        for _, name in ipairs(expected) do
          seenTransitions[name] = true
        end
        local queues = {}
        local lastQueueIndex = 0
        for itemIndex, item in ipairs(lowered.items) do
          if provenanceMatches(item, ins.offset, 188) then
            Assert.equal(item.op, "queue_avatar_transition")
            Assert.equal(type(item.transition), "string")
            Assert.isNil(item.mask, "the raw mask must not survive lowering")
            queues[#queues + 1] = item.transition
            lastQueueIndex = itemIndex
          end
        end
        local names = {}
        for _, name in ipairs(queues) do
          names[#names + 1] = name
        end
        Assert.deepEqual(
          names,
          expected,
          string.format(
            "member %d script %d offset 0x%X: selected transitions lower in source order",
            member,
            index,
            ins.offset
          )
        )
        if #expected > 0 then
          local follower = lowered.items[lastQueueIndex + 1]
          Assert.notNil(follower, "a queue group is always followed by its yield")
          Assert.equal(follower.op, "yield_tick", "every queue group ends in exactly one yield")
        end
        for _, node in ipairs(lowered.unsupported) do
          Assert.isTrue(
            node.command ~= 188 or node.sourceOffset ~= ins.offset,
            string.format(
              "member %d script %d offset 0x%X: the queue command must not lower as unsupported",
              member,
              index,
              ins.offset
            )
          )
        end
      elseif ins.opcode == 189 then
        applySites = applySites + 1
        memberApplyCount[member] = (memberApplyCount[member] or 0) + 1
        local applies = 0
        for _, item in ipairs(lowered.items) do
          if provenanceMatches(item, ins.offset, 189) then
            applies = applies + 1
            Assert.equal(item.op, "apply_avatar_transitions")
            Assert.isNil(item.mask, "the apply carries no source operands")
          end
        end
        Assert.equal(
          applies,
          1,
          string.format(
            "member %d script %d offset 0x%X: the apply command is one same-tick operation",
            member,
            index,
            ins.offset
          )
        )
        for _, node in ipairs(lowered.unsupported) do
          Assert.isTrue(
            node.command ~= 189 or node.sourceOffset ~= ins.offset,
            string.format(
              "member %d script %d offset 0x%X: the apply command must not lower as unsupported",
              member,
              index,
              ins.offset
            )
          )
        end
      end
    end
  end)

  Assert.isTrue(queueSites >= 1, "the retail corpus must reach the queue command")
  Assert.isTrue(applySites >= 1, "the retail corpus must reach the apply command")

  -- The Pokemon Center heal/restore flow queues both heal visuals.
  local centerMasks = memberQueueMasks[3] or {}
  Assert.isTrue(#centerMasks >= 1, "the Center flow must queue avatar transitions")
  local centerNames = {}
  for _, mask in ipairs(centerMasks) do
    for _, name in ipairs(PlayerAvatar.transitionsForMask(mask)) do
      centerNames[name] = true
    end
  end
  Assert.isTrue(centerNames.heal, "the Center flow must queue the heal visual")
  Assert.isTrue(centerNames.rocket_heal, "the Center flow must queue the rocket heal visual")
  Assert.isTrue((memberApplyCount[3] or 0) >= 1, "the Center flow must apply its queued transitions")

  -- The Rocket-costume flow switches the rocket visual.
  local rocketNames = {}
  for _, mask in ipairs(memberQueueMasks[94] or {}) do
    for _, name in ipairs(PlayerAvatar.transitionsForMask(mask)) do
      rocketNames[name] = true
    end
  end
  Assert.isTrue(rocketNames.rocket, "the Rocket flow must queue the rocket visual")
  Assert.isTrue((memberApplyCount[94] or 0) >= 1, "the Rocket flow must apply its queued transitions")

  -- The Pokeathlon flow switches the pokeathlon visual.
  local domeNames = {}
  for _, mask in ipairs(memberQueueMasks[167] or {}) do
    for _, name in ipairs(PlayerAvatar.transitionsForMask(mask)) do
      domeNames[name] = true
    end
  end
  Assert.isTrue(domeNames.pokeathlon, "the Pokeathlon flow must queue the pokeathlon visual")
  Assert.isTrue((memberApplyCount[167] or 0) >= 1, "the Pokeathlon flow must apply its queued transitions")

  Assert.isTrue(seenTransitions.walking, "the corpus must queue the walking restore visual")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
