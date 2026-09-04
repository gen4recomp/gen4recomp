-- Script lowering handlers for field interactions and actor/UI operations.
local Operands = require("romdump.src.digest.script.lowering.Operands")
local MovementDecoder = require("romdump.src.digest.script.MovementDecoder")
local SignpostCommands = require("romdump.src.reference.hgss.signpost_commands")
local PlayerAvatar = require("romdump.src.reference.hgss.player_avatar")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local Errors = require("libs.errors.src.Errors")
local HgssObjectMovement = require("romdump.src.digest.field.HgssObjectMovement")

-- Field-only operand normalization follows the pinned field direction table,
-- message-symbol format, and scrcmd.h actor specials.
local DIRECTION_BY_CODE = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" }
local STRING_SPECIALS = { obj_player = "player", obj_partner_poke = "partner" }
local NUMERIC_SPECIALS = {
  [255] = "player",
  [253] = "partner",
  [241] = "camera_target",
}

local function normalizeFacing(value)
  if type(value) ~= "number" then
    return value
  end
  local direction = DIRECTION_BY_CODE[value]
  assert(direction ~= nil, "unknown direction code " .. tostring(value))
  return direction
end

local function messageRef(symbol)
  if type(symbol) ~= "string" then
    return symbol
  end
  local bank, index = symbol:match("^msg_(%d+)_%w+_(%d+)$")
  if bank == nil then
    return symbol
  end
  return string.format("msg.hgss.%04d.%05d", tonumber(bank), tonumber(index))
end

local function actorRef(value)
  local raw = Operands.operandValue(value)
  local special
  if type(raw) == "number" then
    special = NUMERIC_SPECIALS[raw]
  elseif type(raw) == "string" then
    special = STRING_SPECIALS[raw]
  end
  if special ~= nil then
    return { ref = "actor", special = special }
  end
  if type(raw) == "string" then
    return { ref = "actor", id = raw }
  end
  return { ref = "actor", mapIndex = raw }
end

local function movementFor(movementLabel, memberIr, _)
  local offset = tonumber(movementLabel:sub(2), 16)
  local block = memberIr.movements[offset]
  if block == nil then
    return { { action = "unsupported", code = 0, count = 0, originalName = movementLabel } },
      false,
      { code = 0, originalName = movementLabel, reason = "movement block not found" }
  end
  local actions = {}
  local unsupported = nil
  for _, action in ipairs(block.actions) do
    local decoded, err = MovementDecoder.decode(action)
    if err ~= nil then
      if unsupported == nil then
        unsupported = err
      end
      actions[#actions + 1] = {
        action = "unsupported",
        code = action.movementCode or 0,
        count = action.count,
        originalName = action.name,
      }
    else
      assert(decoded ~= nil)
      for _, step in ipairs(decoded) do
        actions[#actions + 1] = step
      end
    end
  end
  return actions, unsupported == nil, unsupported
end

local function nonNpcMessage(ins)
  return {
    op = "message",
    message = messageRef(Operands.operandValue(ins.operands[1])),
    waitForPrint = false,
  }
end

local function npcMessage(ins)
  return { op = "npc_msg", message = messageRef(Operands.operandValue(ins.operands[1])) }
end

local function nonNpcMessageVar(ins)
  return {
    op = "message",
    message = Operands.varRef(ins.operands[1]),
    waitForPrint = false,
  }
end

local function npcMessageVar(ins)
  return { op = "npc_msg_var", message = Operands.varRef(ins.operands[1]) }
end

local function waitInput()
  return { op = "wait_input", buttons = { "a", "b" } }
end

local function waitInputTurn()
  return { op = "wait_input", buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = true }
end

local function waitInputNoTurn()
  return { op = "wait_input", buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = false }
end

local function openMessage()
  return { op = "open_message" }
end

local function closeMessage()
  return "unfolded"
end -- consumed by the say fold

local function holdMessage()
  return { op = "hold_message" }
end

local function directionSignpost(ins, memberIr)
  -- DirectionSignpost message, type, map: the source handler never reads
  -- or writes the final operand (audited unused), so it is erased here —
  -- the raw decoded instruction operands keep it for source auditing, the
  -- semantic node does not. The message id is a direct index into the
  -- member's message bank (the decoder does not bank-resolve 55); the
  -- runtime resolves it.
  assert(memberIr.messageBank ~= nil, "direction signpost requires a script message bank")
  return {
    op = "signpost_direction",
    message = { message = "external", bank = memberIr.messageBank, id = Operands.operandValue(ins.operands[1]) },
    sourceAppearance = {
      game = "hgss",
      type = Operands.operandValue(ins.operands[2]),
      map = Operands.operandValue(ins.operands[3]),
    },
  }
end

local function setSignpostMap(ins)
  -- SetSignpostMap type, map: writes the source appearance and queues
  -- SHOW without executing it (the field signpost update runs it later).
  return {
    op = "signpost_set",
    sourceAppearance = {
      game = "hgss",
      type = Operands.operandValue(ins.operands[1]),
      map = Operands.operandValue(ins.operands[2]),
    },
  }
end

local function setSignpostAction(ins)
  -- SetSignpostAction command: the raw MAPSIGNCOMMAND_* code 0..4 lowers
  -- to the semantic command enum (nop/show/wipe_out/wipe_in/hide). An
  -- unknown code is malformed source and never defaults to nop.
  local raw = Operands.operandValue(ins.operands[1])
  local command = SignpostCommands.semanticName(raw)
  assert(command ~= nil, "unknown signpost command code " .. tostring(raw))
  return { op = "signpost_command", command = command }
end

local function waitSignpostAction()
  -- WaitSignpostAction: blocks until the command returns to nop; the
  -- runtime wait task polls the signpost host's command.
  return { op = "wait_signpost_action" }
end

local function trainerTipsPrint(ins, memberIr)
  -- TrainerTips message, resultVar: prints into the existing signpost
  -- window at the player's text speed. The message id is a direct index
  -- into the member's message bank (the decoder does not bank-resolve
  -- 59); the runtime resolves it. The result var rides the task result.
  assert(memberIr.messageBank ~= nil, "trainer tips requires a script message bank")
  return {
    op = "trainer_tips_print",
    message = { message = "external", bank = memberIr.messageBank, id = Operands.operandValue(ins.operands[1]) },
    result = Operands.varRef(ins.operands[2]),
  }
end

local function waitSignpost(ins)
  -- WaitSignpost resultVar: waits for A/B/directional dismissal of the
  -- presented signpost window; the result var rides the task result.
  return {
    op = "wait_signpost",
    result = Operands.varRef(ins.operands[1]),
  }
end

local function requestStartMenu()
  -- ScrCmd_061 (std_signpost's hide-branch tail): no operands; installs
  -- the Start Menu reopen end callback and returns FALSE, ending the
  -- script context. The runtime request_start_menu handler routes the
  -- reopen request through the startMenuReopen service and stops.
  return { op = "request_start_menu" }
end

local function askYesNo(ins)
  return { op = "ask_yes_no", result = Operands.varRef(ins.operands[1] or 0) }
end

local function applyMovement(ins, memberIr, provenance)
  local movementLabel = Operands.operandValue(ins.operands[2])
  local actions, complete, unsupported = movementFor(movementLabel, memberIr, provenance)
  return {
    op = "apply_movement",
    actor = actorRef(ins.operands[1]),
    movement = actions,
    movementComplete = complete,
    movementUnsupported = unsupported,
  }
end

local function waitMovement()
  return { op = "wait_movement" }
end

local function lockAll()
  return { op = "lock_all" }
end

local function releaseAll()
  return { op = "release_all" }
end

local function lockActor(ins)
  return { op = "lock_actor", actor = actorRef(ins.operands[1]) }
end

local function releaseActor(ins)
  return { op = "release_actor", actor = actorRef(ins.operands[1]) }
end

local function showObject(ins)
  return { op = "show_object", actor = actorRef(ins.operands[1]) }
end

local function hideObject(ins)
  return { op = "hide_object", actor = actorRef(ins.operands[1]) }
end

local function facePlayer()
  return { op = "face_player" }
end

local function getPlayerCoords(ins)
  return {
    op = "get_player_coords",
    x = Operands.varRef(ins.operands[1]),
    z = Operands.varRef(ins.operands[2]),
  }
end

local function getObjectCoords(ins)
  return {
    op = "get_object_coords",
    actor = actorRef(ins.operands[1]),
    x = Operands.varRef(ins.operands[2]),
    z = Operands.varRef(ins.operands[3]),
  }
end

local function genderedMessage(ins)
  return {
    op = "npc_msg",
    message = {
      text = "gendered_message",
      male = messageRef(Operands.operandValue(ins.operands[1])),
      female = messageRef(Operands.operandValue(ins.operands[2])),
    },
  }
end

local function yieldFollowerCheck()
  -- ScrCmd_609 settles/updates the active follower and yields one scheduler
  -- tick; the controller settles through the normal fixed-tick update during
  -- the yield, with or without an installed partner.
  return { op = "yield_tick" }
end

-- ScrCmd_SetAvatarBits (188): fully supported masks queue one semantic
-- transition per set source bit in fixed source bit order, then yield one
-- script update exactly like the source TRUE return. Bit 15 has no transition
-- handler and selects nothing; bit 3 has an unmodeled movement side effect
-- and makes the whole source instruction unsupported. The raw mask never
-- survives into the generated graph. The mask validates as a u16 producer
-- invariant with no clamping.
local function setAvatarBits(ins)
  local mask = Operands.operandValue(ins.operands[1])
  local transitions, unsupportedBits = PlayerAvatar.transitionsForMask(mask)
  if #unsupportedBits > 0 then
    return {
      op = "unsupported",
      command = 188,
      originalName = "ScrCmd_SetAvatarBits",
      arguments = { mask },
      sourceOffset = ins.offset,
      reason = "PLAYER_TRANSITION_x0008 has an unmodeled movement side effect",
    }
  end
  local steps = {}
  for _, transition in ipairs(transitions) do
    steps[#steps + 1] = { op = "queue_avatar_transition", transition = transition }
  end
  steps[#steps + 1] = { op = "yield_tick" }
  return { steps = steps }
end

-- ScrCmd_UpdateAvatarState (189): applies the pending transition set in
-- source order and continues in the same script tick (the source FALSE
-- return); never a yield or a block.
local function updateAvatarState(_)
  return { op = "apply_avatar_transitions" }
end

-- Follower lowering. Every operation below routes to the one field
-- following controller through the injected collaborator; the node op
-- already names the behavior, so the runtime never switches on opcodes.
local function followerPartnerState(ins)
  -- ScrCmd_596 writes the partner-state query into its result variable.
  return { op = "follower_partner_state", result = Operands.varRef(ins.operands[1]) }
end

local function followerFacePlayer()
  return { op = "follower_face_player" }
end

local function followerSetPaused(ins)
  -- ScrCmd_ToggleFollowingPokemonMovement carries 0 (resume) or 1 (pause);
  -- the value rides through so scripts driving it from a variable keep
  -- working.
  return { op = "follower_set_paused", paused = Operands.varRef(ins.operands[1]) }
end

local function followerWait()
  return { op = "follower_wait" }
end

local function followerStartMovement(ins)
  -- ScrCmd_FollowingPokemonMovement carries a movement code in the shared
  -- movement family (corpus: 48 fast zero jump, 55 fast near jump). Decode
  -- it at lowering so the runtime executes one ordinary scripted action; a
  -- code outside the supported matrix stays an explicit unsupported node.
  local code = Operands.operandValue(ins.operands[1])
  local decoded = MovementDecoder.decode({ movementCode = code, count = 1 })
  if decoded == nil then
    return {
      op = "unsupported",
      command = 604,
      arguments = { code },
      sourceOffset = ins.offset,
      reason = "ScrCmd_FollowingPokemonMovement movement code outside the supported matrix",
    }
  end
  return { op = "follower_start_movement", movement = decoded[1] }
end

local function followerReposition(ins)
  -- The player-relative partner placement carries two bytes: the first
  -- selects the tile offset around the player (0 north, 1 south, 2 west,
  -- 3 east, anything else the player tile itself) and the second faces the
  -- partner. Both ride through for the controller's direct placement on the
  -- same tick.
  return {
    op = "follower_reposition",
    a = Operands.operandValue(ins.operands[1]),
    b = Operands.operandValue(ins.operands[2]),
  }
end

local function followerIsEventTrigger(ins)
  -- ScrCmd_FollowerPokeIsEventTrigger carries its kind, a trigger parameter,
  -- and the result variable (corpus kinds 1/2 with two variable operands).
  return {
    op = "follower_is_event_trigger",
    kind = Operands.operandValue(ins.operands[1]),
    param = Operands.varRef(ins.operands[2]),
    result = Operands.varRef(ins.operands[3]),
  }
end

local function followerIsActive(ins)
  -- ScrCmd_729 writes the live active-state query into its result variable.
  return { op = "follower_is_active", result = Operands.varRef(ins.operands[1]) }
end

local function followerTransition()
  -- The follower transition carries no operands. It starts one transient
  -- visual through the transition owner and continues in the same tick; the
  -- field fixed tick advances the visual afterwards.
  return { op = "follower_transition" }
end

local function setSpecialSpawn(ins)
  return {
    op = "set_special_spawn",
    map = Operands.varRef(ins.operands[1]),
    fieldX = Operands.varRef(ins.operands[2]),
    fieldZ = Operands.varRef(ins.operands[3]),
    warpId = -1,
    direction = "south",
  }
end

local function setBadgeInactive(ins)
  return { op = "set_var", variable = Operands.varRef(ins.operands[2]), value = 0 }
end

local function setFriendSprite(ins)
  return { op = "set_var", variable = Operands.varRef(ins.operands[1]), value = { value = "friend_sprite_value" } }
end

local function warp(ins)
  -- Warp map, warp, x, z, dir: coordinates and direction may be variable
  -- operands; numeric directions normalize to the string enum.
  return {
    op = "warp",
    map = Operands.varRef(ins.operands[1]),
    warp = Operands.varRef(ins.operands[2]),
    fieldX = Operands.varRef(ins.operands[3]),
    fieldZ = Operands.varRef(ins.operands[4]),
    facing = normalizeFacing(Operands.operandValue(ins.operands[5])),
  }
end

local function bufferPlayerName(ins)
  return { op = "buffer_text", slot = Operands.operandValue(ins.operands[1]), value = { text = "player_name" } }
end

local function bufferRivalName(ins)
  return { op = "buffer_text", slot = Operands.operandValue(ins.operands[1]), value = { text = "rival_name" } }
end

local function bufferFriendName(ins)
  return { op = "buffer_text", slot = Operands.operandValue(ins.operands[1]), value = { text = "friend_name" } }
end

local function bufferPartySpeciesName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "party_species_name", position = Operands.operandValue(ins.operands[2]) },
  }
end

local function bufferItemName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "item_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferPocketName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "pocket_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferTmhmMoveName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "tmhm_move_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferMoveName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "move_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferInteger(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "integer", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferPartyNickname(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "party_nickname", position = Operands.operandValue(ins.operands[2]) },
  }
end

local function bufferTrainerClassName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "trainer_class_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferSpeciesName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "species_name", value = Operands.operandValue(ins.operands[2]) },
  }
end

local function bufferStarterSpeciesName(ins)
  return { op = "buffer_text", slot = Operands.operandValue(ins.operands[1]), value = { text = "starter_species_name" } }
end

-- Mon and party lowering. Every handler converts source operands to
-- semantic DSL values: party/move slots ride value-or-variable references,
-- native species/move/item/ability identities ride through as scalars for
-- the service to resolve once through the catalog, and result operands
-- ride output variable references. Source timing stays immediate: every
-- node below is a same-tick operation. No handler fabricates a fallback
-- write and no runtime branch switches on the source opcode afterwards.

-- The source default-ability sentinels: 0 (observed in every vanilla
-- gift) and 0xFFFF both keep the PID-selected ability instead of naming
-- one. A nonzero operand is a native ability identity.
local DEFAULT_ABILITY_SENTINELS = { [0] = true, [0xFFFF] = true }

local function abilityOrNil(operand)
  local raw = Operands.operandValue(operand)
  if DEFAULT_ABILITY_SENTINELS[raw] then
    return nil
  end
  return Operands.varRef(operand)
end

-- ScrCmd_ChooseStarter carries no operands. It lowers to the blocking
-- starter operation: the runtime pre-creates all three candidates, runs
-- the modal choice, and publishes the confirmed instance before the
-- script continues with its own story flags.
local function chooseStarter(_)
  return { op = "choose_starter" }
end

local function giveMon(ins)
  -- ScrCmd_GiveMon species, level, held item, form, ability, result: the
  -- current map section resolves at the service before creation, creation
  -- consumes its exact draws even when the party is full, and only the
  -- Pokedex update is omitted.
  return {
    op = "give_mon",
    species = Operands.varRef(ins.operands[1]),
    level = Operands.varRef(ins.operands[2]),
    heldItem = Operands.varRef(ins.operands[3]),
    form = Operands.varRef(ins.operands[4]),
    ability = abilityOrNil(ins.operands[5]),
    result = Operands.varRef(ins.operands[6]),
  }
end

local function returnLoanMon(ins)
  return {
    op = "return_loan_mon",
    slot = Operands.varRef(ins.operands[1]),
  }
end

local function setMonMove(ins)
  return {
    op = "set_mon_move",
    slot = Operands.varRef(ins.operands[1]),
    moveSlot = Operands.varRef(ins.operands[2]),
    move = Operands.varRef(ins.operands[3]),
  }
end

local function monHasMove(ins)
  -- ScrCmd_MonHasMove result, move, slot: the result comes first.
  return {
    op = "mon_has_move",
    result = Operands.varRef(ins.operands[1]),
    move = Operands.varRef(ins.operands[2]),
    slot = Operands.varRef(ins.operands[3]),
  }
end

local function partySlotWithMove(ins)
  -- ScrCmd_GetPartySlotWithMove result, move.
  return {
    op = "party_slot_with_move",
    result = Operands.varRef(ins.operands[1]),
    move = Operands.varRef(ins.operands[2]),
  }
end

local function countMonMoves(ins)
  -- ScrCmd_CountMonMoves result, slot.
  return {
    op = "count_mon_moves",
    result = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

local function monForgetMove(ins)
  return {
    op = "mon_forget_move",
    slot = Operands.varRef(ins.operands[1]),
    moveSlot = Operands.varRef(ins.operands[2]),
  }
end

local function monGetMove(ins)
  -- ScrCmd_MonGetMove result, slot, move slot.
  return {
    op = "mon_get_move",
    result = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
    moveSlot = Operands.varRef(ins.operands[3]),
  }
end

local function partyCount(ins)
  return { op = "party_count", result = Operands.varRef(ins.operands[1]) }
end

local function partyCountNotEgg(ins)
  return { op = "party_count_not_egg", result = Operands.varRef(ins.operands[1]) }
end

local function partyCountEgg(ins)
  return { op = "party_count_egg", result = Operands.varRef(ins.operands[1]) }
end

local function partyCountAtOrBelowLevel(ins)
  -- ScrCmd_PartyCountMonsAtOrBelowLevel result, level.
  return {
    op = "party_count_at_or_below_level",
    result = Operands.varRef(ins.operands[1]),
    level = Operands.varRef(ins.operands[2]),
  }
end

local function countSpecies(ins)
  -- ScrCmd_CountPartyMonsOfSpecies result, species.
  return {
    op = "count_species",
    result = Operands.varRef(ins.operands[1]),
    species = Operands.varRef(ins.operands[2]),
  }
end

local function partySlotWithSpecies(ins)
  -- ScrCmd_GetPartySlotWithSpecies result, species.
  return {
    op = "party_slot_with_species",
    result = Operands.varRef(ins.operands[1]),
    species = Operands.varRef(ins.operands[2]),
  }
end

local function partySlotWithNature(ins)
  -- ScrCmd_GetPartySlotWithNature result, nature, matching the other
  -- party search commands. The command is unreached in the vanilla
  -- corpus; the order follows the search family.
  return {
    op = "party_slot_with_nature",
    result = Operands.varRef(ins.operands[1]),
    nature = Operands.varRef(ins.operands[2]),
  }
end

local function partySlotWithFatefulEncounter(ins)
  -- ScrCmd_GetPartySlotWithFatefulEncounter result, species.
  return {
    op = "party_slot_with_fateful_encounter",
    result = Operands.varRef(ins.operands[1]),
    species = Operands.varRef(ins.operands[2]),
  }
end

local function countAliveMons(ins)
  -- ScrCmd_CountAliveMons result, excluded slot: the count covers every
  -- conscious non-egg party mon except the slot operand, which carries
  -- the party size when nothing is excluded.
  return {
    op = "count_alive_mons",
    result = Operands.varRef(ins.operands[1]),
    excludeSlot = Operands.varRef(ins.operands[2]),
  }
end

local function partyMonSpecies(ins)
  return {
    op = "party_mon_species",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

local function partyMonIsMine(ins)
  return {
    op = "party_mon_is_mine",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

local function partyMonNature(ins)
  return {
    op = "party_mon_nature",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

local function partyMonFriendship(ins)
  -- ScrCmd_MonGetFriendship result, slot.
  return {
    op = "party_mon_friendship",
    result = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

local function monAddFriendship(ins)
  -- ScrCmd_MonAddFriendship amount, slot: the amount comes first.
  return {
    op = "mon_add_friendship",
    amount = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

local function monSubFriendship(ins)
  -- ScrCmd_MonSubtractFriendship amount, slot, matching the addition.
  return {
    op = "mon_sub_friendship",
    amount = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

local function partyMonGender(ins)
  return {
    op = "party_mon_gender",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

local function partyMonContestValue(ins)
  return {
    op = "party_mon_contest_value",
    slot = Operands.varRef(ins.operands[1]),
    contestType = Operands.varRef(ins.operands[2]),
    result = Operands.varRef(ins.operands[3]),
  }
end

local function monAddContestValue(ins)
  return {
    op = "mon_add_contest_value",
    slot = Operands.varRef(ins.operands[1]),
    contestType = Operands.varRef(ins.operands[2]),
    amount = Operands.varRef(ins.operands[3]),
  }
end

local function partyMonForm(ins)
  return {
    op = "party_mon_form",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

local function partyMonRibbonCount(ins)
  return {
    op = "party_mon_ribbon_count",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

local function partyRibbonCount(ins)
  return { op = "party_ribbon_count", result = Operands.varRef(ins.operands[1]) }
end

local function partyHasPokerus(ins)
  return { op = "party_has_pokerus", result = Operands.varRef(ins.operands[1]) }
end

local function partyLead(ins)
  return { op = "party_lead", result = Operands.varRef(ins.operands[1]) }
end

local function partyLeadAlive(ins)
  return { op = "party_lead_alive", result = Operands.varRef(ins.operands[1]) }
end

-- The shared party-screen selection context. Opcode 349 opens the screen
-- in selection mode (PARTY_MENU_CONTEXT_3: every occupied slot selects, B
-- cancels) and blocks; the completed slot parks on the script instance
-- (the same instance-scoped handoff the menu builder uses) for the
-- companion result command. Opcode 351 reads that handoff into its result
-- variable.
local function partySelectUI()
  return { op = "party_select" }
end

local function partySelectionResult(ins)
  return { op = "party_select_result", result = Operands.varRef(ins.operands[1]) }
end
local function partyLegalCheck(ins)
  return { op = "party_legal_check", result = Operands.varRef(ins.operands[1]) }
end

local function checkKyogreGroudon(ins)
  return { op = "check_kyogre_groudon", result = Operands.varRef(ins.operands[1]) }
end

local function healParty()
  return { op = "heal_party" }
end

local function bufferNatureName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "nature_name", value = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferPartyMonMoveName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = {
      text = "party_mon_move_name",
      position = Operands.varRef(ins.operands[2]),
      moveSlot = Operands.varRef(ins.operands[3]),
    },
  }
end

local function bufferPartyMonSpeciesNameIndef(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "party_species_name", position = Operands.varRef(ins.operands[2]) },
  }
end

local function bufferMapName(ins)
  return {
    op = "buffer_text",
    slot = Operands.operandValue(ins.operands[1]),
    value = { text = "map_name", value = Operands.operandValue(ins.operands[2]) },
  }
end

local function setObjectPosition(ins)
  return {
    op = "set_object_position",
    actor = actorRef(ins.operands[1]),
    fieldX = Operands.varRef(ins.operands[2]),
    fieldZ = Operands.varRef(ins.operands[3]),
  }
end

local function flagAction(ins, flag)
  local mode = Operands.operandValue(ins.operands[1])
  if mode == 0 then
    return { op = "clear_flag", flag = flag }
  end
  if mode == 1 then
    return { op = "set_flag", flag = flag }
  end
  if mode == 2 then
    return {
      op = "set_var",
      variable = Operands.varRef(ins.operands[2]),
      value = { value = "flag_value", flag = flag },
    }
  end
  Errors.raise("SCRIPT_UNKNOWN_FLAG_ACTION", "unknown flag action mode", {
    sourceOffset = ins.offset,
    opcode = ins.opcode,
    mode = mode,
  })
end

local function flashEffect()
  return {
    steps = {
      { op = "change_weather", weatherId = 12 },
      { op = "yield_tick" },
    },
  }
end

local function flashAction(ins)
  return flagAction(ins, "FLAG_SYS_FLASH")
end

local function defogAction(ins)
  return flagAction(ins, "FLAG_SYS_DEFOG")
end

local function movePersonFacing(ins)
  -- ScrCmd_MovePersonFacing reads objectId, x, y, z, direction.
  local actor = actorRef(ins.operands[1])
  return {
    steps = {
      {
        op = "set_object_position",
        actor = actor,
        fieldX = Operands.varRef(ins.operands[2]),
        worldY = Operands.varRef(ins.operands[3]),
        fieldZ = Operands.varRef(ins.operands[4]),
      },
      {
        op = "set_object_facing",
        actor = actor,
        direction = normalizeFacing(Operands.operandValue(ins.operands[5])),
      },
    },
  }
end

local function setObjectMovementType(ins)
  local rawMovement = Operands.operandValue(ins.operands[2])
  local ok, movementType = pcall(HgssObjectMovement.semanticType, rawMovement)
  if not ok then
    Errors.raise(
      "SCRIPT_UNKNOWN_OBJECT_MOVEMENT",
      "SetObjectMovementType has an invalid movement selector",
      { sourceOffset = ins.offset, opcode = ins.opcode, movement = rawMovement }
    )
  end
  return {
    op = "set_object_movement_type",
    actor = actorRef(ins.operands[1]),
    movementType = movementType,
  }
end

local function setObjectFacing(ins)
  return {
    op = "set_object_facing",
    actor = actorRef(ins.operands[1]),
    direction = normalizeFacing(Operands.operandValue(ins.operands[2])),
  }
end

local function showWaitingIcon()
  return { op = "show_waiting_icon" }
end

local function hideWaitingIcon()
  return { op = "hide_waiting_icon" }
end

local function waitInputOrTicks(ins)
  return { op = "wait_input_or_ticks", ticks = Operands.operandValue(ins.operands[1]) }
end

local function showObjectAt(ins)
  return { op = "show_object", actor = actorRef(ins.operands[1]) }
end

local function waitButton()
  return "unfolded"
end

local function externalMessage(ins)
  return {
    op = "message",
    message = { message = "external", bank = Operands.varRef(ins.operands[1]), id = Operands.varRef(ins.operands[2]) },
    waitForPrint = false,
  }
end

local function externalMessageWait(ins)
  return {
    op = "message",
    message = { message = "external", bank = Operands.varRef(ins.operands[1]), id = Operands.varRef(ins.operands[2]) },
    waitForPrint = true,
  }
end

local function standardMenuBegin(ins)
  return {
    op = "menu_begin",
    messageSource = "standard",
    sourcePlacement = {
      system = MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT,
      x = Operands.operandValue(ins.operands[1]),
      y = Operands.operandValue(ins.operands[2]),
    },
    initialCursor = Operands.operandValue(ins.operands[3]),
    cancellable = Operands.operandValue(ins.operands[4]) ~= 0,
    result = Operands.varRef(ins.operands[5]),
  }
end

local function scriptMenuBegin(ins, memberIr)
  assert(memberIr.messageBank ~= nil, "script menu requires a current script message bank")
  return {
    op = "menu_begin",
    messageSource = { kind = "script", bank = memberIr.messageBank },
    sourcePlacement = {
      system = MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT,
      x = Operands.operandValue(ins.operands[1]),
      y = Operands.operandValue(ins.operands[2]),
    },
    initialCursor = Operands.operandValue(ins.operands[3]),
    cancellable = Operands.operandValue(ins.operands[4]) ~= 0,
    result = Operands.varRef(ins.operands[5]),
  }
end

local function menuAdd(ins)
  return {
    op = "menu_add",
    messageId = Operands.varRef(ins.operands[1]),
    vanillaMetadata = Operands.varRef(ins.operands[2]),
    value = Operands.varRef(ins.operands[3]),
  }
end

local function menuExecute()
  return { op = "menu_exec" }
end

local function lockLastTalkedActor()
  return { op = "lock_actor", actor = { ref = "actor", special = "last_talked" }, waitUntilPausable = true }
end

local function hideAuxiliaryUi()
  return { op = "set_auxiliary_ui_visible", visible = false }
end

local function showAuxiliaryUi()
  return { op = "set_auxiliary_ui_visible", visible = true }
end

local function contextChoice(ins)
  return { op = "context_choice", result = Operands.varRef(ins.operands[1]) }
end

local function processSoundplate()
  return { op = "process_soundplate" }
end

local function actorOscillate(ins)
  local sourceAmplitudeX = Operands.varRef(ins.operands[4])
  local sourceAmplitudeZ = Operands.varRef(ins.operands[5])
  if type(sourceAmplitudeX) ~= "number" or type(sourceAmplitudeZ) ~= "number" then
    return {
      op = "unsupported",
      command = 523,
      arguments = {
        Operands.operandValue(ins.operands[1]),
        Operands.operandValue(ins.operands[2]),
        Operands.operandValue(ins.operands[3]),
        Operands.operandValue(ins.operands[4]),
        Operands.operandValue(ins.operands[5]),
      },
      sourceOffset = ins.offset,
      reason = "ScrCmd_523 variable amplitude operands are unsupported",
    }
  end
  return {
    op = "actor_oscillate",
    actor = actorRef(ins.operands[1]),
    cycles = Operands.varRef(ins.operands[2]),
    degreesPerTick = Operands.varRef(ins.operands[3]),
    amplitudeX = sourceAmplitudeX / 16,
    amplitudeZ = sourceAmplitudeZ / 16,
  }
end

return {
  [44] = nonNpcMessage,
  [45] = npcMessage,
  [46] = nonNpcMessageVar,
  [47] = npcMessageVar,
  [49] = waitInput,
  [50] = waitInputTurn,
  [51] = waitInputNoTurn,
  [52] = openMessage,
  [53] = closeMessage,
  [54] = holdMessage,
  [55] = directionSignpost,
  [56] = setSignpostMap,
  [57] = setSignpostAction,
  [58] = waitSignpostAction,
  [59] = trainerTipsPrint,
  [60] = waitSignpost,
  [61] = requestStartMenu,
  [63] = askYesNo,
  [94] = applyMovement,
  [95] = waitMovement,
  [96] = lockAll,
  [97] = releaseAll,
  [98] = lockActor,
  [99] = releaseActor,
  [100] = showObject,
  [101] = hideObject,
  [104] = facePlayer,
  [105] = getPlayerCoords,
  [106] = getObjectCoords,
  [132] = genderedMessage,
  [144] = setFriendSprite,
  [176] = warp,
  [188] = setAvatarBits,
  [189] = updateAvatarState,
  [190] = bufferPlayerName,
  [191] = bufferRivalName,
  [192] = bufferFriendName,
  [193] = bufferPartySpeciesName,
  [194] = bufferItemName,
  [195] = bufferPocketName,
  [196] = bufferTmhmMoveName,
  [197] = bufferMoveName,
  [198] = bufferInteger,
  [199] = bufferPartyNickname,
  [200] = bufferTrainerClassName,
  [202] = bufferSpeciesName,
  [203] = bufferStarterSpeciesName,
  [137] = giveMon,
  [167] = chooseStarter,
  [139] = setMonMove,
  [140] = monHasMove,
  [141] = partySlotWithMove,
  [238] = partyHasPokerus,
  [239] = partyMonGender,
  [282] = healParty,
  [332] = partyCount,
  [349] = partySelectUI,
  [351] = partySelectionResult,
  [337] = bufferNatureName,
  [354] = partyMonSpecies,
  [355] = partyMonIsMine,
  [356] = partyCountNotEgg,
  [359] = partyCountEgg,
  [357] = countAliveMons,
  [364] = returnLoanMon,
  [382] = partyMonFriendship,
  [383] = monAddFriendship,
  [384] = monSubFriendship,
  [396] = countMonMoves,
  [397] = monForgetMove,
  [398] = monGetMove,
  [399] = bufferPartyMonMoveName,
  [434] = partyCountAtOrBelowLevel,
  [457] = partyMonNature,
  [458] = partySlotWithNature,
  [478] = partyMonRibbonCount,
  [479] = partyRibbonCount,
  [496] = partyLead,
  [529] = partyLeadAlive,
  [542] = partyMonContestValue,
  [584] = partyLegalCheck,
  [632] = countSpecies,
  [647] = partySlotWithSpecies,
  [676] = partyMonForm,
  [688] = partySlotWithFatefulEncounter,
  [827] = partyMonForm,
  [828] = monAddContestValue,
  [836] = checkKyogreGroudon,
  [845] = bufferPartyMonSpeciesNameIndef,
  [210] = bufferMapName,
  [338] = setObjectPosition,
  [339] = movePersonFacing,
  [340] = setObjectMovementType,
  [341] = setObjectFacing,
  [345] = showWaitingIcon,
  [346] = hideWaitingIcon,
  [348] = waitInputOrTicks,
  [375] = showObjectAt,
  [438] = waitButton,
  [439] = externalMessage,
  [440] = externalMessageWait,
  [749] = standardMenuBegin,
  [750] = scriptMenuBegin,
  [751] = menuAdd,
  [752] = menuExecute,
  [581] = lockLastTalkedActor,
  [582] = setSpecialSpawn,
  [596] = followerPartnerState,
  [601] = followerFacePlayer,
  [602] = followerSetPaused,
  [603] = followerWait,
  [604] = followerStartMovement,
  [605] = followerReposition,
  [608] = followerTransition,
  [609] = yieldFollowerCheck,
  [698] = followerIsEventTrigger,
  [729] = followerIsActive,
  [294] = setBadgeInactive,
  [746] = hideAuxiliaryUi,
  [747] = showAuxiliaryUi,
  [748] = contextChoice,
  [726] = processSoundplate,
  [523] = actorOscillate,
  [181] = flashEffect,
  [401] = flashAction,
  [402] = defogAction,
}
