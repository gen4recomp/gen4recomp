-- DSL constructor tests. These assert the exact table output of every API 1
-- constructor, so accidental changes to operation names, value kinds, field
-- names, or defaults fail here. API 1 is the current, still-under-development
-- surface: the shapes below are the reference for this version, not a
-- permanent compatibility guarantee. Direct-table equivalence and
-- metatable-freedom are asserted separately.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")

local T = {}

-- name -> constructor invocation. Asserted to produce `expected` exactly.
local CASES = {
  -- Resource and reference constructors
  var = {
    function()
      return S.var("VAR_SCENE_ELMS_LAB")
    end,
    { value = "var", id = "VAR_SCENE_ELMS_LAB" },
  },
  local_ = {
    function()
      return S.local_("route")
    end,
    { value = "local", name = "route" },
  },
  arg = {
    function()
      return S.arg("professor")
    end,
    { value = "arg", name = "professor" },
  },
  actor = {
    function()
      return S.actor("elm")
    end,
    { ref = "actor", id = "elm" },
  },
  player = {
    function()
      return S.player()
    end,
    { ref = "actor", special = "player" },
  },
  self = {
    function()
      return S.self()
    end,
    { ref = "actor", special = "self" },
  },
  last_talked = {
    function()
      return S.lastTalked()
    end,
    { ref = "actor", special = "last_talked" },
  },
  partner = {
    function()
      return S.partner()
    end,
    { ref = "actor", special = "partner" },
  },
  external_message = {
    function()
      return S.externalMessage("msgbank", 12)
    end,
    { message = "external", bank = "msgbank", id = 12 },
  },
  choice = {
    function()
      return S.choice("msg.project.take", 10, { metadata = { hgss = 255 } })
    end,
    { text = "msg.project.take", value = 10, metadata = { hgss = 255 } },
  },

  -- Text-value constructors
  player_name = {
    function()
      return S.playerName()
    end,
    { text = "player_name" },
  },
  rival_name = {
    function()
      return S.rivalName()
    end,
    { text = "rival_name" },
  },
  friend_name = {
    function()
      return S.friendName()
    end,
    { text = "friend_name" },
  },
  integer_text_defaults = {
    function()
      return S.integerText(S.var("count"))
    end,
    { text = "integer", value = { value = "var", id = "count" }, pad = "none", sign = false },
  },
  item_name = {
    function()
      return S.itemName(S.var("item"))
    end,
    { text = "item_name", value = { value = "var", id = "item" } },
  },
  pocket_name = {
    function()
      return S.pocketName(S.var("pocket"))
    end,
    { text = "pocket_name", value = { value = "var", id = "pocket" } },
  },
  move_name = {
    function()
      return S.moveName(S.var("move"))
    end,
    { text = "move_name", value = { value = "var", id = "move" } },
  },
  tmhm_move_name = {
    function()
      return S.tmhmMoveName(S.var("tmhm"))
    end,
    { text = "tmhm_move_name", value = { value = "var", id = "tmhm" } },
  },
  species_name = {
    function()
      return S.speciesName(S.var("species"))
    end,
    { text = "species_name", value = { value = "var", id = "species" } },
  },
  party_species_name = {
    function()
      return S.partySpeciesName(0)
    end,
    { text = "party_species_name", position = 0 },
  },
  party_nickname = {
    function()
      return S.partyNickname(1)
    end,
    { text = "party_nickname", position = 1 },
  },
  trainer_class_name = {
    function()
      return S.trainerClassName(S.var("class"))
    end,
    { text = "trainer_class_name", value = { value = "var", id = "class" } },
  },
  starter_species_name = {
    function()
      return S.starterSpeciesName()
    end,
    { text = "starter_species_name" },
  },
  map_name = {
    function()
      return S.mapName(S.var("location"))
    end,
    { text = "map_name", value = { value = "var", id = "location" } },
  },
  gendered_message = {
    function()
      return S.gendered("msg.hgss.0542.00006", "msg.hgss.0542.00007")
    end,
    { text = "gendered_message", male = "msg.hgss.0542.00006", female = "msg.hgss.0542.00007" },
  },

  -- General value constructors
  flag_value = {
    function()
      return S.flagValue(S.var("flag_id"))
    end,
    { value = "flag_value", flag = { value = "var", id = "flag_id" } },
  },
  player_gender_value = {
    function()
      return S.playerGenderValue()
    end,
    { value = "player_gender_value" },
  },
  friend_sprite_value = {
    function()
      return S.friendSpriteValue()
    end,
    { value = "friend_sprite_value" },
  },
  object_id_value = {
    function()
      return S.objectIdValue(S.actor("elm"))
    end,
    { value = "object_id", ref = { ref = "actor", id = "elm" } },
  },
  trigger_background_id = {
    function()
      return S.backgroundIdValue()
    end,
    { value = "trigger_background_id" },
  },
  trigger_direction_value = {
    function()
      return S.triggerDirectionValue()
    end,
    { value = "trigger_direction" },
  },

  -- Condition constructors
  eq = {
    function()
      return S.eq(S.var("VAR_SCENE_ELMS_LAB"), 0)
    end,
    { condition = "compare", operator = "eq", left = { value = "var", id = "VAR_SCENE_ELMS_LAB" }, right = 0 },
  },
  ne = {
    function()
      return S.ne(1, 2)
    end,
    { condition = "compare", operator = "ne", left = 1, right = 2 },
  },
  lt = {
    function()
      return S.lt(1, 2)
    end,
    { condition = "compare", operator = "lt", left = 1, right = 2 },
  },
  le = {
    function()
      return S.le(1, 2)
    end,
    { condition = "compare", operator = "le", left = 1, right = 2 },
  },
  gt = {
    function()
      return S.gt(1, 2)
    end,
    { condition = "compare", operator = "gt", left = 1, right = 2 },
  },
  ge = {
    function()
      return S.ge(1, 2)
    end,
    { condition = "compare", operator = "ge", left = 1, right = 2 },
  },
  flag_condition = {
    function()
      return S.flag("FLAG_MET_ELM")
    end,
    { condition = "flag", id = "FLAG_MET_ELM", expected = true },
  },
  flag_condition_expected_false = {
    function()
      return S.flag(S.var("flag_id"))
    end,
    { condition = "flag", id = { value = "var", id = "flag_id" }, expected = true },
  },
  not_ = {
    function()
      return S.not_(S.flag("FLAG_MET_ELM"))
    end,
    { condition = "not", operand = { condition = "flag", id = "FLAG_MET_ELM", expected = true } },
  },
  all = {
    function()
      return S.all({ S.flag("A"), S.flag("B") })
    end,
    {
      condition = "all",
      conditions = {
        { condition = "flag", id = "A", expected = true },
        { condition = "flag", id = "B", expected = true },
      },
    },
  },
  any = {
    function()
      return S.any({ S.flag("A") })
    end,
    { condition = "any", conditions = { { condition = "flag", id = "A", expected = true } } },
  },
  exists = {
    function()
      return S.exists("elm")
    end,
    { condition = "actor_exists", ref = "elm" },
  },
  truthy = {
    function()
      return S.truthy(S.var("x"))
    end,
    { condition = "truthy", value = { value = "var", id = "x" } },
  },

  -- Control-flow constructors
  noop = {
    function()
      return S.noop()
    end,
    { op = "noop" },
  },
  stop = {
    function()
      return S.stop()
    end,
    { op = "stop" },
  },
  yield_tick = {
    function()
      return S.yieldTick()
    end,
    { op = "yield_tick" },
  },
  wait_ticks = {
    function()
      return S.waitTicks({ ticks = 3 })
    end,
    { op = "wait_ticks", ticks = 3 },
  },
  if_ = {
    function()
      return S.if_({ condition = S.flag("FLAG_MET_ELM"), yes = { S.stop() } })
    end,
    {
      op = "if",
      condition = { condition = "flag", id = "FLAG_MET_ELM", expected = true },
      yes = { { op = "stop" } },
      no = {},
    },
  },
  switch = {
    function()
      return S.switch({ value = S.var("VAR_SCENE_ELMS_LAB"), cases = { [0] = { S.stop() } } })
    end,
    {
      op = "switch",
      value = { value = "var", id = "VAR_SCENE_ELMS_LAB" },
      cases = { [0] = { { op = "stop" } } },
      default = {},
    },
  },
  call = {
    function()
      return S.call({ target = "common.give_item_verbose" })
    end,
    { op = "call", target = "common.give_item_verbose", args = {} },
  },
  call_with_opts = {
    function()
      return S.call({
        target = "common.give_item_verbose",
        args = { item = "ITEM_POTION" },
        result = S.local_("gaveItem"),
      })
    end,
    {
      op = "call",
      target = "common.give_item_verbose",
      args = { item = "ITEM_POTION" },
      result = { value = "local", name = "gaveItem" },
    },
  },
  call_common = {
    function()
      return S.callCommon({ target = "common.elms_lab_intro" })
    end,
    { op = "call_common", target = "common.elms_lab_intro", args = {} },
  },
  return_empty = {
    function()
      return S.return_({})
    end,
    { op = "return" },
  },
  return_value = {
    function()
      return S.return_({ value = S.var("x") })
    end,
    { op = "return", value = { value = "var", id = "x" } },
  },
  label = {
    function()
      return S.label({ name = "offset_0042" })
    end,
    { op = "label", name = "offset_0042" },
  },
  ["goto"] = {
    function()
      return S.goto_({ target = "offset_0042" })
    end,
    { op = "goto", target = "offset_0042" },
  },
  goto_if = {
    function()
      return S.gotoIf({ condition = S.eq(S.var("x"), 1), target = "offset_0042" })
    end,
    {
      op = "goto_if",
      condition = { condition = "compare", operator = "eq", left = { value = "var", id = "x" }, right = 1 },
      target = "offset_0042",
    },
  },
  compare = {
    function()
      return S.compare({ left = S.var("a"), right = S.var("b") })
    end,
    { op = "compare", left = { value = "var", id = "a" }, right = { value = "var", id = "b" } },
  },
  goto_compared = {
    function()
      return S.gotoCompared({ operator = "eq", target = "offset_0042" })
    end,
    { op = "goto_compared", operator = "eq", target = "offset_0042" },
  },
  call_compared = {
    function()
      return S.callCompared({ operator = "ne", target = "subroutine" })
    end,
    { op = "call_compared", operator = "ne", target = "subroutine" },
  },
  next = {
    function()
      return S.next()
    end,
    { op = "next" },
  },

  -- State constructors
  set_flag = {
    function()
      return S.setFlag({ flag = "FLAG_MET_ELM" })
    end,
    { op = "set_flag", flag = "FLAG_MET_ELM" },
  },
  set_flag_dynamic = {
    function()
      return S.setFlag({ flag = S.var("flag_id") })
    end,
    { op = "set_flag", flag = { value = "var", id = "flag_id" } },
  },
  clear_flag = {
    function()
      return S.clearFlag({ flag = "FLAG_MET_ELM" })
    end,
    { op = "clear_flag", flag = "FLAG_MET_ELM" },
  },
  set_var = {
    function()
      return S.setVar({ variable = "VAR_SCENE_ELMS_LAB", value = 1 })
    end,
    { op = "set_var", variable = "VAR_SCENE_ELMS_LAB", value = 1 },
  },
  copy_var = {
    function()
      return S.copyVar({ destination = "VAR_A", source = "VAR_B" })
    end,
    { op = "copy_var", destination = "VAR_A", source = "VAR_B" },
  },
  add_var = {
    function()
      return S.addVar({ variable = "VAR_A", amount = 1 })
    end,
    { op = "add_var", variable = "VAR_A", amount = 1 },
  },
  sub_var = {
    function()
      return S.subVar({ variable = "VAR_A", amount = 1 })
    end,
    { op = "sub_var", variable = "VAR_A", amount = 1 },
  },
  set_local = {
    function()
      return S.setLocal({ name = "route", value = "intro" })
    end,
    { op = "set_local", name = "route", value = "intro" },
  },
  copy_local = {
    function()
      return S.copyLocal({ destination = "a", source = "b" })
    end,
    { op = "copy_local", destination = "a", source = "b" },
  },
  add_local = {
    function()
      return S.addLocal({ name = "counter", amount = 1 })
    end,
    { op = "add_local", name = "counter", amount = 1 },
  },
  sub_local = {
    function()
      return S.subLocal({ name = "counter", amount = 1 })
    end,
    { op = "sub_local", name = "counter", amount = 1 },
  },

  -- Dialogue constructors
  say_defaults = {
    function()
      return S.say({ message = "msg.elms_lab.elm_intro" })
    end,
    {
      op = "say",
      message = "msg.elms_lab.elm_intro",
      bindings = {},
    },
  },
  say_opts = {
    function()
      return S.say({
        message = "msg.elms_lab.elm_intro",
        bindings = { [0] = S.playerName() },
      })
    end,
    {
      op = "say",
      message = "msg.elms_lab.elm_intro",
      bindings = { [0] = { text = "player_name" } },
    },
  },
  open_message = {
    function()
      return S.openMessage()
    end,
    { op = "open_message" },
  },
  message_defaults = {
    function()
      return S.message({ message = "msg.elms_lab.elm_intro" })
    end,
    { op = "message", message = "msg.elms_lab.elm_intro", waitForPrint = true, bindings = {} },
  },
  message_nowait = {
    function()
      return S.message({ message = "msg.elms_lab.elm_intro", waitForPrint = false })
    end,
    { op = "message", message = "msg.elms_lab.elm_intro", waitForPrint = false, bindings = {} },
  },
  wait_input_defaults = {
    function()
      return S.waitInput()
    end,
    { op = "wait_input", buttons = { "a", "b" }, allowDpad = false, turnPlayerOnDpad = false },
  },
  wait_input_opts = {
    function()
      return S.waitInput({ buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = true })
    end,
    { op = "wait_input", buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = true },
  },
  wait_input_or_ticks = {
    function()
      return S.waitInputOrTicks({ ticks = 30 })
    end,
    { op = "wait_input_or_ticks", ticks = 30, buttons = { "a", "b" }, allowDpad = true, turnPlayerOnDpad = false },
  },
  close_message = {
    function()
      return S.closeMessage()
    end,
    { op = "close_message", erase = true },
  },
  close_message_no_erase = {
    function()
      return S.closeMessage({ erase = false })
    end,
    { op = "close_message", erase = false },
  },
  hold_message = {
    function()
      return S.holdMessage()
    end,
    { op = "hold_message" },
  },
  ask_yes_no = {
    function()
      return S.askYesNo({ message = "msg.elms_lab.question", result = S.local_("accepted") })
    end,
    {
      op = "ask_yes_no",
      message = "msg.elms_lab.question",
      result = { value = "local", name = "accepted" },
      bindings = {},
    },
  },
  ask_yes_no_current_box = {
    function()
      return S.askYesNo({ result = S.var("VAR_SPECIAL_RESULT") })
    end,
    { op = "ask_yes_no", result = { value = "var", id = "VAR_SPECIAL_RESULT" }, bindings = {} },
  },
  buffer_text = {
    function()
      return S.bufferText({ slot = 0, value = S.playerName() })
    end,
    { op = "buffer_text", slot = 0, value = { text = "player_name" } },
  },
  show_waiting_icon = {
    function()
      return S.showWaitingIcon()
    end,
    { op = "show_waiting_icon" },
  },
  hide_waiting_icon = {
    function()
      return S.hideWaitingIcon()
    end,
    { op = "hide_waiting_icon" },
  },

  -- Lock and actor constructors
  lock_player = {
    function()
      return S.lockPlayer()
    end,
    { op = "lock_player" },
  },
  release_player = {
    function()
      return S.releasePlayer()
    end,
    { op = "release_player" },
  },
  lock_all = {
    function()
      return S.lockAll()
    end,
    { op = "lock_all" },
  },
  release_all = {
    function()
      return S.releaseAll()
    end,
    { op = "release_all" },
  },
  lock_actor = {
    function()
      return S.lockActor({ actor = "elm" })
    end,
    { op = "lock_actor", actor = "elm", waitUntilPausable = false },
  },
  lock_actor_wait = {
    function()
      return S.lockActor({ actor = S.lastTalked(), waitUntilPausable = true })
    end,
    { op = "lock_actor", actor = { ref = "actor", special = "last_talked" }, waitUntilPausable = true },
  },
  release_actor = {
    function()
      return S.releaseActor({ actor = "elm" })
    end,
    { op = "release_actor", actor = "elm" },
  },
  face_player_default = {
    function()
      return S.facePlayer({})
    end,
    { op = "face_player", actor = "self" },
  },
  face_player_explicit = {
    function()
      return S.facePlayer({ actor = "elm" })
    end,
    { op = "face_player", actor = "elm" },
  },
  face = {
    function()
      return S.face({ actor = "elm", direction = "south" })
    end,
    { op = "face", actor = "elm", direction = "south" },
  },
  show_object = {
    function()
      return S.showObject({ actor = "elm" })
    end,
    { op = "show_object", actor = "elm" },
  },
  hide_object = {
    function()
      return S.hideObject({ actor = "elm" })
    end,
    { op = "hide_object", actor = "elm" },
  },
  set_object_position = {
    function()
      return S.setObjectPosition({ actor = "elm", fieldX = 4, fieldZ = 5 })
    end,
    { op = "set_object_position", actor = "elm", fieldX = 4, fieldZ = 5 },
  },
  set_object_position_world_y = {
    function()
      return S.setObjectPosition({ actor = "elm", fieldX = 4, fieldZ = 5, worldY = 2.5 })
    end,
    { op = "set_object_position", actor = "elm", fieldX = 4, fieldZ = 5, worldY = 2.5 },
  },
  set_object_facing = {
    function()
      return S.setObjectFacing({ actor = "elm", direction = "east" })
    end,
    { op = "set_object_facing", actor = "elm", direction = "east" },
  },
  set_object_movement_type = {
    function()
      return S.setObjectMovementType({ actor = "elm", movementType = "stationary" })
    end,
    { op = "set_object_movement_type", actor = "elm", movementType = "stationary" },
  },
  get_player_coords = {
    function()
      return S.getPlayerCoords({ x = S.local_("player_x"), z = S.local_("player_z") })
    end,
    {
      op = "get_player_coords",
      x = { value = "local", name = "player_x" },
      z = { value = "local", name = "player_z" },
    },
  },
  get_object_coords = {
    function()
      return S.getObjectCoords({ actor = "elm", x = S.local_("elm_x"), z = S.local_("elm_z") })
    end,
    {
      op = "get_object_coords",
      actor = "elm",
      x = { value = "local", name = "elm_x" },
      z = { value = "local", name = "elm_z" },
    },
  },
  get_player_facing = {
    function()
      return S.getPlayerFacing({ result = S.local_("player_facing") })
    end,
    { op = "get_player_facing", result = { value = "local", name = "player_facing" } },
  },

  -- Movement constructors
  apply_movement = {
    function()
      return S.applyMovement({
        actor = "elm",
        movement = { S.m.face({ direction = "south" }), S.m.walk({ direction = "south", tiles = 2 }) },
      })
    end,
    {
      op = "apply_movement",
      actor = "elm",
      movement = {
        { action = "face", direction = "south", count = 1 },
        { action = "walk", direction = "south", speed = "normal", tiles = 2 },
      },
    },
  },
  apply_movement_with_id = {
    function()
      return S.applyMovement({
        actor = "elm",
        movement = { S.m.face({ direction = "south" }) },
        movementId = "elm_intro",
      })
    end,
    {
      op = "apply_movement",
      actor = "elm",
      movement = { { action = "face", direction = "south", count = 1 } },
      movementId = "elm_intro",
    },
  },
  wait_movement = {
    function()
      return S.waitMovement()
    end,
    { op = "wait_movement", scope = "environment" },
  },
  wait_movement_actors = {
    function()
      return S.waitMovement({ scope = "actors", actors = { "elm", "player" } })
    end,
    { op = "wait_movement", scope = "actors", actors = { "elm", "player" } },
  },
  move = {
    function()
      return S.move({ actor = "elm", movement = { S.m.walk({ direction = "south", tiles = 2 }) } })
    end,
    {
      op = "move",
      actor = "elm",
      movement = { { action = "walk", direction = "south", speed = "normal", tiles = 2 } },
    },
  },

  -- Audio constructors
  play_sound = {
    function()
      return S.playSound({ sound = "SEQ_SE_DP_SELECT" })
    end,
    { op = "play_sound", sound = "SEQ_SE_DP_SELECT" },
  },
  stop_sound = {
    function()
      return S.stopSound({ sound = "SEQ_SE_DP_SELECT" })
    end,
    { op = "stop_sound", sound = "SEQ_SE_DP_SELECT" },
  },
  wait_sound = {
    function()
      return S.waitSound({ sound = "SEQ_SE_DP_SELECT" })
    end,
    { op = "wait_sound", sound = "SEQ_SE_DP_SELECT" },
  },
  wait_sound_current = {
    function()
      return S.waitSound({})
    end,
    { op = "wait_sound" },
  },
  play_cry = {
    function()
      return S.playCry({ species = S.var("species") })
    end,
    { op = "play_cry", species = { value = "var", id = "species" }, pattern = 0 },
  },
  play_cry_pattern = {
    function()
      return S.playCry({ species = "SPECIES_PICHU", pattern = 1 })
    end,
    { op = "play_cry", species = "SPECIES_PICHU", pattern = 1 },
  },
  wait_cry = {
    function()
      return S.waitCry()
    end,
    { op = "wait_cry" },
  },
  play_fanfare = {
    function()
      return S.playFanfare({ fanfare = "SEQ_ME_POKEGET" })
    end,
    { op = "play_fanfare", fanfare = "SEQ_ME_POKEGET" },
  },
  wait_fanfare = {
    function()
      return S.waitFanfare()
    end,
    { op = "wait_fanfare" },
  },
  play_music = {
    function()
      return S.playMusic({ music = "SEQ_GS_NEW_BARK" })
    end,
    { op = "play_music", music = "SEQ_GS_NEW_BARK" },
  },
  stop_music = {
    function()
      return S.stopMusic()
    end,
    { op = "stop_music" },
  },
  reset_music = {
    function()
      return S.resetMusic()
    end,
    { op = "reset_music" },
  },
  temporary_music = {
    function()
      return S.temporaryMusic({ music = "SEQ_GS_EVENT" })
    end,
    { op = "temporary_music", music = "SEQ_GS_EVENT" },
  },
  fade_music_out = {
    function()
      return S.fadeMusicOut({ target = 0, durationTicks = 30 })
    end,
    { op = "fade_music_out", target = 0, durationTicks = 30 },
  },
  fade_music_in = {
    function()
      return S.fadeMusicIn({ durationTicks = 30 })
    end,
    { op = "fade_music_in", durationTicks = 30 },
  },
  process_soundplate = {
    function()
      return S.processSoundplate()
    end,
    { op = "process_soundplate" },
  },
  process_soundplate_explicit = {
    function()
      return S.processSoundplate({})
    end,
    { op = "process_soundplate" },
  },
  play_sound_var = {
    function()
      return S.playSound({ sound = S.var("VAR_SE") })
    end,
    { op = "play_sound", sound = { value = "var", id = "VAR_SE" } },
  },
  stop_sound_var = {
    function()
      return S.stopSound({ sound = S.var("VAR_SE") })
    end,
    { op = "stop_sound", sound = { value = "var", id = "VAR_SE" } },
  },
  wait_sound_var = {
    function()
      return S.waitSound({ sound = S.var("VAR_SE") })
    end,
    { op = "wait_sound", sound = { value = "var", id = "VAR_SE" } },
  },
  play_cry_pattern_var = {
    function()
      return S.playCry({ species = "SPECIES_CYNDAQUIL", pattern = S.var("VAR_PATTERN") })
    end,
    { op = "play_cry", species = "SPECIES_CYNDAQUIL", pattern = { value = "var", id = "VAR_PATTERN" } },
  },
  play_fanfare_var = {
    function()
      return S.playFanfare({ fanfare = S.var("VAR_FANFARE") })
    end,
    { op = "play_fanfare", fanfare = { value = "var", id = "VAR_FANFARE" } },
  },

  -- Screen, camera, and map constructors
  fade_screen = {
    function()
      return S.fadeScreen({ duration = 6, speed = 1, direction = "out", color = "black" })
    end,
    { op = "fade_screen", duration = 6, speed = 1, direction = "out", color = "black" },
  },
  wait_fade = {
    function()
      return S.waitFade()
    end,
    { op = "wait_fade" },
  },
  warp = {
    function()
      return S.warp({ map = "MAP_NEW_BARK", warp = 0, fieldX = 684, fieldZ = 393, facing = "south" })
    end,
    { op = "warp", map = "MAP_NEW_BARK", warp = 0, fieldX = 684, fieldZ = 393, facing = "south" },
  },
  set_spawn = {
    function()
      return S.setSpawn({ spawn = "SPAWN_NEW_BARK" })
    end,
    { op = "set_spawn", spawn = "SPAWN_NEW_BARK" },
  },
  shake_camera = {
    function()
      return S.shakeCamera({ amplitudeX = 2, amplitudeY = 0, intervalTicks = 2, count = 8 })
    end,
    { op = "shake_camera", amplitudeX = 2, amplitudeY = 0, intervalTicks = 2, count = 8 },
  },

  -- Signpost constructors: the high-level S.sign / S.trainerTip operations
  -- take the canonical one-table spec (defaults come from the schema) and
  -- the six generated/advanced forms map 1:1 onto the imported signpost
  -- operations.
  sign = {
    function()
      return S.sign({ message = "msg.hgss.0542.00034", appearance = "mod.route_sign" })
    end,
    { op = "sign", message = "msg.hgss.0542.00034", appearance = "mod.route_sign" },
  },
  sign_defaults = {
    function()
      return S.sign({ message = "msg.hgss.0542.00034" })
    end,
    { op = "sign", message = "msg.hgss.0542.00034", appearance = "sign" },
  },
  trainer_tip = {
    function()
      return S.trainerTip({ message = "msg.hgss.0542.00036", appearance = "trainer_tip" })
    end,
    { op = "trainer_tip", message = "msg.hgss.0542.00036", appearance = "trainer_tip" },
  },
  trainer_tip_defaults = {
    function()
      return S.trainerTip({ message = "msg.hgss.0542.00036" })
    end,
    { op = "trainer_tip", message = "msg.hgss.0542.00036", appearance = "trainer_tip" },
  },
  signpost_set = {
    function()
      return S.signpostSet({ sourceAppearance = { game = "hgss", type = 0, map = 42 } })
    end,
    { op = "signpost_set", sourceAppearance = { game = "hgss", type = 0, map = 42 } },
  },
  signpost_command = {
    function()
      return S.signpostCommand({ command = "wipe_in" })
    end,
    { op = "signpost_command", command = "wipe_in" },
  },
  wait_signpost_action = {
    function()
      return S.waitSignpostAction()
    end,
    { op = "wait_signpost_action" },
  },
  signpost_direction = {
    function()
      return S.signpostDirection({
        message = { message = "external", bank = 542, id = 34 },
        sourceAppearance = { game = "hgss", type = 0, map = 11 },
      })
    end,
    {
      op = "signpost_direction",
      message = { message = "external", bank = 542, id = 34 },
      sourceAppearance = { game = "hgss", type = 0, map = 11 },
    },
  },
  trainer_tips_print = {
    function()
      return S.trainerTipsPrint({
        message = { message = "external", bank = 542, id = 34 },
        result = S.var("VAR_SPECIAL_RESULT"),
      })
    end,
    {
      op = "trainer_tips_print",
      message = { message = "external", bank = 542, id = 34 },
      result = { value = "var", id = "VAR_SPECIAL_RESULT" },
    },
  },
  wait_signpost = {
    function()
      return S.waitSignpost({ result = S.var("VAR_SPECIAL_RESULT") })
    end,
    { op = "wait_signpost", result = { value = "var", id = "VAR_SPECIAL_RESULT" } },
  },

  -- Random and diagnostic constructors
  random = {
    function()
      return S.random({ maxExclusive = 10, result = S.local_("roll") })
    end,
    { op = "random", maxExclusive = 10, result = { value = "local", name = "roll" } },
  },
  unsupported = {
    function()
      return S.unsupported({
        command = 0x017A,
        originalName = "ScrCmd_378",
        arguments = { 4, 0x800C },
        sourceOffset = 0x92,
        reason = "no semantic adapter",
      })
    end,
    {
      op = "unsupported",
      command = 0x017A,
      originalName = "ScrCmd_378",
      arguments = { 4, 0x800C },
      sourceOffset = 0x92,
      reason = "no semantic adapter",
    },
  },
}

for name, case in pairs(CASES) do
  T["constructor_" .. name] = function()
    Assert.deepEqual(case[1](), case[2])
  end
end

-- Movement action namespace
local ACTION_CASES = {
  face = {
    function()
      return S.m.face({ direction = "south" })
    end,
    { action = "face", direction = "south", count = 1 },
  },
  face_count = {
    function()
      return S.m.face({ direction = "south", count = 2 })
    end,
    { action = "face", direction = "south", count = 2 },
  },
  walk_defaults = {
    function()
      return S.m.walk({ direction = "north" })
    end,
    { action = "walk", direction = "north", speed = "normal", tiles = 1 },
  },
  walk_opts = {
    function()
      return S.m.walk({ direction = "south", speed = "slow", tiles = 2 })
    end,
    { action = "walk", direction = "south", speed = "slow", tiles = 2 },
  },
  walk_in_place = {
    function()
      return S.m.walkInPlace({ direction = "east", speed = "fast", count = 3 })
    end,
    { action = "walk_in_place", direction = "east", speed = "fast", count = 3 },
  },
  jump = {
    function()
      return S.m.jump({ direction = "south", distance = "far", speed = "fast" })
    end,
    { action = "jump", direction = "south", distance = "far", speed = "fast", count = 1 },
  },
  delay = {
    function()
      return S.m.delay({ ticks = 15, count = 2 })
    end,
    { action = "delay", ticks = 15, count = 2 },
  },
  set_visible = {
    function()
      return S.m.setVisible({ visible = false })
    end,
    { action = "set_visible", visible = false },
  },
  lock_facing = {
    function()
      return S.m.lockFacing()
    end,
    { action = "lock_facing" },
  },
  unlock_facing = {
    function()
      return S.m.unlockFacing()
    end,
    { action = "unlock_facing" },
  },
  pause_animation = {
    function()
      return S.m.pauseAnimation()
    end,
    { action = "pause_animation" },
  },
  resume_animation = {
    function()
      return S.m.resumeAnimation()
    end,
    { action = "resume_animation" },
  },
  emote = {
    function()
      return S.m.emote({ name = "exclamation", count = 2 })
    end,
    { action = "emote", name = "exclamation", count = 2 },
  },
  gesture = {
    function()
      return S.m.gesture({ name = "give" })
    end,
    { action = "gesture", name = "give", count = 1 },
  },
  unsupported_action = {
    function()
      return S.m.unsupported({ code = 105, count = 1, originalName = "MovementAction105" })
    end,
    { action = "unsupported", code = 105, count = 1, originalName = "MovementAction105" },
  },
}

for name, case in pairs(ACTION_CASES) do
  T["movement_action_" .. name] = function()
    Assert.deepEqual(case[1](), case[2])
  end
end

function T.script_supplies_kind()
  local script = S.script({ api = 1, id = "new_bark.lab_sign", steps = { S.stop() } })
  Assert.equal(script.kind, "field_script")
end

function T.script_requires_api_id_steps()
  Assert.throws(function()
    S.script({ id = "x", steps = {} })
  end)
  Assert.throws(function()
    S.script({ api = 1, steps = {} })
  end)
  Assert.throws(function()
    S.script({ api = 1, id = "x" })
  end)
end

function T.script_does_not_mutate_given_spec()
  local spec = { api = 1, id = "new_bark.lab_sign", steps = { S.stop() } }
  local script = S.script(spec)
  Assert.isNil(spec.kind)
  Assert.equal(script.kind, "field_script")
end

-- The high-level sign constructors take one canonical spec table and must
-- not mutate the caller's table.
function T.sign_constructors_do_not_mutate_given_options()
  local signSpec = { message = "msg.hgss.0542.00034", appearance = "mod.route_sign" }
  S.sign(signSpec)
  Assert.deepEqual(signSpec, { message = "msg.hgss.0542.00034", appearance = "mod.route_sign" })
  local tipSpec = { message = "msg.hgss.0542.00036", appearance = "trainer_tip" }
  S.trainerTip(tipSpec)
  Assert.deepEqual(tipSpec, { message = "msg.hgss.0542.00036", appearance = "trainer_tip" })
end

-- There is no positional message form: the high-level sign constructors
-- accept exactly the canonical one-table spec.
function T.sign_constructors_reject_positional_message_forms()
  local ok, err = pcall(S.sign, "msg.hgss.0542.00034", { appearance = "mod.route_sign" })
  Assert.isFalse(ok, "S.sign must not accept a positional message, got: " .. tostring(err))
  local ok2, err2 = pcall(S.trainerTip, "msg.hgss.0542.00036")
  Assert.isFalse(ok2, "S.trainerTip must not accept a positional message, got: " .. tostring(err2))
end

-- signpostCommand follows the same canonical-spec rule as the other
-- constructors: only the one-table spec form is valid, never a positional
-- command string.
function T.signpost_command_rejects_the_positional_string_form()
  local ok, err = pcall(S.signpostCommand, "wipe_in")
  Assert.isFalse(ok, "S.signpostCommand must not accept a positional command, got: " .. tostring(err))
end

-- Every raw handler sees ctx.apiVersion == 1.
function T.api_version_is_one()
  Assert.equal(S.apiVersion, 1)
end

-- The inert say options are not part of the API 1 surface: the constructors
-- must not emit fields the runtime never reads.
function T.say_constructors_do_not_emit_inert_options()
  local say = S.say({ message = "msg.greeting" })
  Assert.isNil(say.close)
  Assert.isNil(say.wait)
  Assert.isNil(say.timingProfile)
end

-- resolve_common_message_bank is an unconditional no-op and has no
-- constructor on the API 1 surface.
function T.resolve_common_message_bank_constructor_is_removed()
  Assert.isNil(S.resolveCommonMessageBank)
end

-- Constructors return ordinary tables with no metatables.
local function assertNoMetatables(value, path)
  path = path or "value"
  if type(value) ~= "table" then
    return
  end
  Assert.isNil(getmetatable(value), path .. ": unexpected metatable")
  for k, v in pairs(value) do
    assertNoMetatables(k, path .. "/key")
    assertNoMetatables(v, path .. "/" .. tostring(k))
  end
end

-- Generated/import movement carriers validate through the internal schema but
-- are intentionally absent from the public constructor surface: authored
-- scripts use the semantic movement actions instead.
function T.generated_movement_carriers_stay_out_of_the_public_constructor_surface()
  Assert.isNil(S.m.revealTrainer, "trainer reveal must not be a public movement constructor")
  Assert.isNil(S.m.trajectorySegment, "trajectory segments must not be a public movement constructor")
  local reveal = S.script({
    api = 1,
    id = "test.generated_reveal_carrier",
    steps = {
      S.applyMovement({ actor = "elm", movement = { { action = "reveal_trainer" } } }),
      S.stop(),
    },
  })
  Assert.equal(S.validate(reveal), true, "generated trainer reveal tables must still validate")
  local segment = S.script({
    api = 1,
    id = "test.generated_trajectory_carrier",
    steps = {
      S.applyMovement({
        actor = "elm",
        movement = {
          {
            action = "trajectory_segment",
            deltaX = 0,
            deltaZ = 5,
            surfaceBandDelta = 1,
            direction = "south",
            ticks = 15,
          },
        },
      }),
      S.stop(),
    },
  })
  Assert.equal(S.validate(segment), true, "generated trajectory tables must still validate")
end

-- Jump displacement is a property of the semantic distance, not a second
-- numeric field: authored jump data carrying an arbitrary tile count must
-- fail strict validation, while the semantic form validates.
function T.jump_action_rejects_an_arbitrary_tile_count()
  local withTiles = S.script({
    api = 1,
    id = "test.jump_tiles",
    steps = {
      S.applyMovement({
        actor = "elm",
        movement = { S.m.jump({ direction = "east", distance = "farther", speed = "fast", tiles = 3 }) },
      }),
      S.stop(),
    },
  })
  local ok, err = S.validate(withTiles)
  Assert.isNil(ok, "a jump carrying tiles must fail validation, got: " .. tostring(err))
  Assert.notNil(err, "a rejected jump must report a schema error")
  local semantic = S.script({
    api = 1,
    id = "test.jump_semantic",
    steps = {
      S.applyMovement({
        actor = "elm",
        movement = { S.m.jump({ direction = "east", distance = "farther", speed = "fast" }) },
      }),
      S.stop(),
    },
  })
  Assert.equal(S.validate(semantic), true, "a semantic farther jump without tiles must validate")
end

function T.constructor_output_has_no_metatables()
  for name, case in pairs(CASES) do
    assertNoMetatables(case[1](), name)
  end
  for name, case in pairs(ACTION_CASES) do
    assertNoMetatables(case[1](), name)
  end
  assertNoMetatables(S.script({ api = 1, id = "x", steps = { S.stop() } }), "script")
end

return { tests = T }
