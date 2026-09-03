-- DSL constructors for the gen4 field-script platform, API 1. Constructors
-- return ordinary serializable Lua tables whose shapes follow the schema
-- (libs/script/src/Schema.lua) and are pinned by the DSL tests for
-- this version. API 1 is the current surface and is not declared stable:
-- the shapes are the reference for this version, not a permanent guarantee.
-- Defaults come from the schema so the doc generator, validator, and
-- constructors can never drift. Every step and movement-action constructor
-- takes exactly one canonical spec table (the schema field names); there is
-- no positional form and no shape guessing. Value, condition, actor, and
-- text reference constructors take their unambiguous scalar arguments.

local Schema = require("libs.script.src.Schema")

local M = {}

local function copyDefault(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = v
  end
  return out
end

local function defaultsFor(fields)
  local out = {}
  for name, spec in pairs(fields) do
    if spec.default ~= nil then
      out[name] = copyDefault(spec.default)
    end
  end
  return out
end

local function mergeFields(kind, given)
  local fields = kind.fields
  local out = defaultsFor(fields)
  for k, v in pairs(given or {}) do
    out[k] = v
  end
  return out
end

-- One canonical step or movement-action constructor: `kind` names the
-- schema operation/action, `given` the single spec table.
local function op(kind, given)
  local spec = Schema.OPERATIONS[kind]
  assert(spec, "unknown operation: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.op = kind
  return out
end

local function value(kind, given)
  local spec = Schema.VALUES[kind]
  assert(spec, "unknown value kind: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.value = kind
  return out
end

local function text(kind, given)
  local spec = Schema.TEXT_VALUES[kind]
  assert(spec, "unknown text kind: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.text = kind
  return out
end

local function cond(kind, given)
  local spec = Schema.CONDITIONS[kind]
  assert(spec, "unknown condition kind: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.condition = kind
  return out
end

local function action(kind, given)
  local spec = Schema.MOVEMENT_ACTIONS[kind]
  assert(spec, "unknown movement action: " .. tostring(kind))
  local out = mergeFields(spec, given)
  out.action = kind
  return out
end

-- Resource and reference constructors

function M.script(spec)
  assert(type(spec) == "table", "script spec must be a table")
  assert(spec.api ~= nil, "script api is required")
  assert(type(spec.api) == "number" and spec.api % 1 == 0 and spec.api == spec.api, "script api must be an integer")
  assert(type(spec.id) == "string" and #spec.id > 0, "script id must be a non-empty string")
  assert(type(spec.steps) == "table", "script steps must be a table")
  local out = {}
  for k, v in pairs(spec) do
    out[k] = v
  end
  out.kind = Schema.SCRIPT_KIND
  return out
end

function M.var(id)
  assert(type(id) == "string" and #id > 0, "variable id must be a non-empty string")
  return value("var", { id = id })
end

function M.local_(name)
  assert(type(name) == "string" and #name > 0, "local name must be a non-empty string")
  return value("local", { name = name })
end

function M.arg(name)
  assert(type(name) == "string" and #name > 0, "arg name must be a non-empty string")
  return value("arg", { name = name })
end

function M.actor(id)
  assert(type(id) == "string" and #id > 0, "actor id must be a non-empty string")
  return { ref = "actor", id = id }
end

function M.player()
  return { ref = "actor", special = "player" }
end

function M.self()
  return { ref = "actor", special = "self" }
end

function M.lastTalked()
  return { ref = "actor", special = "last_talked" }
end

function M.partner()
  return { ref = "actor", special = "partner" }
end

function M.cameraTarget()
  return { ref = "actor", special = "camera_target" }
end

-- A numeric local map-object index, resolved against the current map at
-- runtime (the pinned HGSS object-id path).
function M.actorIndex(index)
  assert(type(index) == "number" and index % 1 == 0 and index == index, "actor map index must be an integer")
  return { ref = "actor", mapIndex = index }
end

function M.externalMessage(bank, id)
  return { message = "external", bank = bank, id = id }
end

-- Text-value constructors

function M.playerName()
  return text("player_name")
end
function M.rivalName()
  return text("rival_name")
end
function M.friendName()
  return text("friend_name")
end

function M.integerText(v)
  return text("integer", { value = v })
end

function M.itemName(v)
  return text("item_name", { value = v })
end
function M.pocketName(v)
  return text("pocket_name", { value = v })
end
function M.moveName(v)
  return text("move_name", { value = v })
end
function M.tmhmMoveName(v)
  return text("tmhm_move_name", { value = v })
end
function M.speciesName(v)
  return text("species_name", { value = v })
end

function M.partySpeciesName(position)
  assert(type(position) == "number" and position % 1 == 0, "party position must be an integer")
  return text("party_species_name", { position = position })
end

function M.partyNickname(position)
  assert(type(position) == "number" and position % 1 == 0, "party position must be an integer")
  return text("party_nickname", { position = position })
end

function M.partyMonMoveName(position, moveSlot)
  assert(type(position) == "number" and position % 1 == 0, "party position must be an integer")
  assert(type(moveSlot) == "number" and moveSlot % 1 == 0, "move slot must be an integer")
  return text("party_mon_move_name", { position = position, moveSlot = moveSlot })
end

function M.natureName(v)
  return text("nature_name", { value = v })
end

function M.trainerClassName(v)
  return text("trainer_class_name", { value = v })
end
function M.starterSpeciesName()
  return text("starter_species_name")
end
function M.mapName(v)
  return text("map_name", { value = v })
end

function M.gendered(maleMessage, femaleMessage)
  return text("gendered_message", { male = maleMessage, female = femaleMessage })
end

-- General value constructors

function M.flagValue(flag)
  return value("flag_value", { flag = flag })
end

function M.playerGenderValue()
  return value("player_gender_value")
end

function M.friendSpriteValue()
  return value("friend_sprite_value")
end

function M.objectIdValue(ref)
  return value("object_id", { ref = ref })
end

function M.backgroundIdValue()
  return value("trigger_background_id")
end

function M.triggerDirectionValue()
  return value("trigger_direction")
end

-- Condition constructors

local function compareOp(operator, a, b)
  return cond("compare", { operator = operator, left = a, right = b })
end

function M.eq(a, b)
  return compareOp("eq", a, b)
end
function M.ne(a, b)
  return compareOp("ne", a, b)
end
function M.lt(a, b)
  return compareOp("lt", a, b)
end
function M.le(a, b)
  return compareOp("le", a, b)
end
function M.gt(a, b)
  return compareOp("gt", a, b)
end
function M.ge(a, b)
  return compareOp("ge", a, b)
end

function M.flag(flag)
  return cond("flag", { id = flag })
end

function M.not_(condition)
  return cond("not", { operand = condition })
end

function M.all(conditions)
  assert(type(conditions) == "table", "conditions must be a table")
  return cond("all", { conditions = conditions })
end

function M.any(conditions)
  assert(type(conditions) == "table", "conditions must be a table")
  return cond("any", { conditions = conditions })
end

function M.exists(actorRef)
  return cond("actor_exists", { ref = actorRef })
end

function M.truthy(v)
  return cond("truthy", { value = v })
end

-- Control-flow constructors (all spec-table forms)

function M.noop(spec)
  return op("noop", spec)
end
function M.stop(spec)
  return op("stop", spec)
end
function M.yieldTick(spec)
  return op("yield_tick", spec)
end

function M.setAuxiliaryUiVisible(spec)
  return op("set_auxiliary_ui_visible", spec)
end

function M.contextChoice(spec)
  return op("context_choice", spec)
end

-- One serializable semantic menu entry. `metadata` is opaque to the core.
function M.choice(messageRef, choiceValue, opts)
  assert(opts == nil or type(opts) == "table", "choice options must be a table")
  local out = { text = messageRef, value = choiceValue }
  for key, option in pairs(opts or {}) do
    out[key] = option
  end
  return out
end

function M.choose(spec)
  return op("choose", spec)
end

function M.waitTicks(spec)
  return op("wait_ticks", spec)
end

function M.if_(spec)
  assert(type(spec) == "table", "if spec must be a table")
  return op("if", spec)
end

function M.switch(spec)
  assert(type(spec) == "table", "switch spec must be a table")
  return op("switch", spec)
end

function M.call(spec)
  return op("call", spec)
end
function M.callCommon(spec)
  return op("call_common", spec)
end

function M.return_(spec)
  return op("return", spec)
end

function M.label(spec)
  return op("label", spec)
end
function M.goto_(spec)
  return op("goto", spec)
end
function M.gotoIf(spec)
  return op("goto_if", spec)
end
function M.gotoScript(spec)
  return op("goto_script", spec)
end

function M.compare(spec)
  return op("compare", spec)
end
function M.gotoCompared(spec)
  return op("goto_compared", spec)
end
function M.callCompared(spec)
  return op("call_compared", spec)
end

function M.next(spec)
  return op("next", spec)
end

-- State constructors

function M.setFlag(spec)
  return op("set_flag", spec)
end
function M.clearFlag(spec)
  return op("clear_flag", spec)
end
function M.changeWeather(spec)
  return op("change_weather", spec)
end
function M.setVar(spec)
  return op("set_var", spec)
end
function M.copyVar(spec)
  return op("copy_var", spec)
end
function M.addVar(spec)
  return op("add_var", spec)
end
function M.subVar(spec)
  return op("sub_var", spec)
end
function M.setLocal(spec)
  return op("set_local", spec)
end
function M.copyLocal(spec)
  return op("copy_local", spec)
end
function M.addLocal(spec)
  return op("add_local", spec)
end
function M.subLocal(spec)
  return op("sub_local", spec)
end

-- Dialogue constructors

function M.say(spec)
  return op("say", spec)
end
function M.openMessage(spec)
  return op("open_message", spec)
end
function M.message(spec)
  return op("message", spec)
end
function M.waitInput(spec)
  return op("wait_input", spec)
end
function M.waitInputOrTicks(spec)
  return op("wait_input_or_ticks", spec)
end
function M.closeMessage(spec)
  return op("close_message", spec)
end
function M.holdMessage(spec)
  return op("hold_message", spec)
end
function M.askYesNo(spec)
  return op("ask_yes_no", spec)
end
function M.bufferText(spec)
  return op("buffer_text", spec)
end
function M.showWaitingIcon(spec)
  return op("show_waiting_icon", spec)
end
function M.hideWaitingIcon(spec)
  return op("hide_waiting_icon", spec)
end

-- Lock and actor constructors

function M.lockPlayer(spec)
  return op("lock_player", spec)
end
function M.releasePlayer(spec)
  return op("release_player", spec)
end
function M.lockAll(spec)
  return op("lock_all", spec)
end
function M.releaseAll(spec)
  return op("release_all", spec)
end
function M.lockActor(spec)
  return op("lock_actor", spec)
end
function M.releaseActor(spec)
  return op("release_actor", spec)
end
function M.facePlayer(spec)
  return op("face_player", spec)
end
function M.face(spec)
  return op("face", spec)
end
function M.showObject(spec)
  return op("show_object", spec)
end
function M.hideObject(spec)
  return op("hide_object", spec)
end
function M.setObjectPosition(spec)
  return op("set_object_position", spec)
end
function M.setObjectFacing(spec)
  return op("set_object_facing", spec)
end
function M.setObjectMovementType(spec)
  return op("set_object_movement_type", spec)
end
function M.getPlayerCoords(spec)
  return op("get_player_coords", spec)
end
function M.getObjectCoords(spec)
  return op("get_object_coords", spec)
end
function M.getPlayerFacing(spec)
  return op("get_player_facing", spec)
end

-- Generated/advanced source-faithful menu builder forms. These deliberately
-- mirror the imported HGSS operations; semantic `choose` is added separately.
function M.menuBegin(spec)
  return op("menu_begin", spec)
end

function M.menuAdd(spec)
  return op("menu_add", spec)
end

function M.menuExec(spec)
  return op("menu_exec", spec)
end

-- High-level signpost constructors: the semantic mod-facing S.sign /
-- S.trainerTip operations take the canonical one-table spec (the schema
-- field names); there is no positional message form. The six
-- generated/advanced forms below map 1:1 onto the imported signpost
-- operations and are never rewritten into the high-level helpers.
function M.sign(spec)
  assert(type(spec) == "table", "sign spec must be a table")
  return op("sign", spec)
end

function M.trainerTip(spec)
  assert(type(spec) == "table", "trainer tip spec must be a table")
  return op("trainer_tip", spec)
end

function M.signpostSet(spec)
  return op("signpost_set", spec)
end

function M.signpostCommand(spec)
  return op("signpost_command", spec)
end

function M.waitSignpostAction(spec)
  return op("wait_signpost_action", spec)
end

function M.signpostDirection(spec)
  return op("signpost_direction", spec)
end

function M.trainerTipsPrint(spec)
  return op("trainer_tips_print", spec)
end

function M.waitSignpost(spec)
  return op("wait_signpost", spec)
end

-- Movement constructors (spec-table forms)

function M.applyMovement(spec)
  return op("apply_movement", spec)
end
function M.waitMovement(spec)
  return op("wait_movement", spec)
end
function M.move(spec)
  return op("move", spec)
end

M.m = {}

function M.m.face(spec)
  return action("face", spec)
end
function M.m.walk(spec)
  return action("walk", spec)
end
function M.m.walkInPlace(spec)
  return action("walk_in_place", spec)
end
function M.m.jump(spec)
  return action("jump", spec)
end
function M.m.delay(spec)
  return action("delay", spec)
end
function M.m.setVisible(spec)
  return action("set_visible", spec)
end
function M.m.lockFacing(spec)
  return action("lock_facing", spec)
end
function M.m.unlockFacing(spec)
  return action("unlock_facing", spec)
end
function M.m.pauseAnimation(spec)
  return action("pause_animation", spec)
end
function M.m.resumeAnimation(spec)
  return action("resume_animation", spec)
end
function M.m.emote(spec)
  return action("emote", spec)
end
function M.m.gesture(spec)
  return action("gesture", spec)
end
function M.m.unsupported(spec)
  return action("unsupported", spec)
end

-- Audio constructors

function M.playSound(spec)
  return op("play_sound", spec)
end
function M.stopSound(spec)
  return op("stop_sound", spec)
end
function M.waitSound(spec)
  return op("wait_sound", spec)
end
function M.playCry(spec)
  return op("play_cry", spec)
end
function M.waitCry(spec)
  return op("wait_cry", spec)
end
function M.playFanfare(spec)
  return op("play_fanfare", spec)
end
function M.waitFanfare(spec)
  return op("wait_fanfare", spec)
end
function M.playMusic(spec)
  return op("play_music", spec)
end
function M.stopMusic(spec)
  return op("stop_music", spec)
end
function M.resetMusic(spec)
  return op("reset_music", spec)
end
function M.temporaryMusic(spec)
  return op("temporary_music", spec)
end
function M.fadeMusicOut(spec)
  return op("fade_music_out", spec)
end
function M.fadeMusicIn(spec)
  return op("fade_music_in", spec)
end
function M.processSoundplate(spec)
  return op("process_soundplate", spec)
end

-- Screen, camera, and map constructors

function M.fadeScreen(spec)
  return op("fade_screen", spec)
end
function M.waitFade(spec)
  return op("wait_fade", spec)
end
function M.warp(spec)
  return op("warp", spec)
end
function M.setSpawn(spec)
  return op("set_spawn", spec)
end
function M.shakeCamera(spec)
  return op("shake_camera", spec)
end
function M.actorOscillate(spec)
  return op("actor_oscillate", spec)
end

-- Random and diagnostic constructors

function M.random(spec)
  return op("random", spec)
end

-- Mon and party constructors. Each takes the single canonical spec table
-- named by the schema fields; slots are zero-based party positions.
function M.giveMon(spec)
  return op("give_mon", spec)
end
function M.returnLoanMon(spec)
  return op("return_loan_mon", spec)
end
function M.setMonMove(spec)
  return op("set_mon_move", spec)
end
function M.monHasMove(spec)
  return op("mon_has_move", spec)
end
function M.partySlotWithMove(spec)
  return op("party_slot_with_move", spec)
end
function M.countMonMoves(spec)
  return op("count_mon_moves", spec)
end
function M.monForgetMove(spec)
  return op("mon_forget_move", spec)
end
function M.monGetMove(spec)
  return op("mon_get_move", spec)
end
function M.partyCount(spec)
  return op("party_count", spec)
end
function M.partyCountNotEgg(spec)
  return op("party_count_not_egg", spec)
end
function M.partyCountEgg(spec)
  return op("party_count_egg", spec)
end
function M.countAliveMons(spec)
  return op("count_alive_mons", spec)
end
function M.partyCountAtOrBelowLevel(spec)
  return op("party_count_at_or_below_level", spec)
end
function M.countSpecies(spec)
  return op("count_species", spec)
end
function M.partySlotWithSpecies(spec)
  return op("party_slot_with_species", spec)
end
function M.partySlotWithNature(spec)
  return op("party_slot_with_nature", spec)
end
function M.partySlotWithFatefulEncounter(spec)
  return op("party_slot_with_fateful_encounter", spec)
end
function M.partyMonSpecies(spec)
  return op("party_mon_species", spec)
end
function M.partyMonIsMine(spec)
  return op("party_mon_is_mine", spec)
end
function M.partyMonNature(spec)
  return op("party_mon_nature", spec)
end
function M.partyMonFriendship(spec)
  return op("party_mon_friendship", spec)
end
function M.monAddFriendship(spec)
  return op("mon_add_friendship", spec)
end
function M.monSubFriendship(spec)
  return op("mon_sub_friendship", spec)
end
function M.partyMonGender(spec)
  return op("party_mon_gender", spec)
end
function M.partyMonContestValue(spec)
  return op("party_mon_contest_value", spec)
end
function M.monAddContestValue(spec)
  return op("mon_add_contest_value", spec)
end
function M.partyMonForm(spec)
  return op("party_mon_form", spec)
end
function M.partyMonRibbonCount(spec)
  return op("party_mon_ribbon_count", spec)
end
function M.partyRibbonCount(spec)
  return op("party_ribbon_count", spec)
end
function M.partyHasPokerus(spec)
  return op("party_has_pokerus", spec)
end
function M.partyLead(spec)
  return op("party_lead", spec)
end
function M.partyLeadAlive(spec)
  return op("party_lead_alive", spec)
end
function M.partyLegalCheck(spec)
  return op("party_legal_check", spec)
end
function M.checkKyogreGroudon(spec)
  return op("check_kyogre_groudon", spec)
end
function M.healParty(spec)
  return op("heal_party", spec)
end
function M.unsupported(spec)
  return op("unsupported", spec)
end

return M
