-- Authoritative executable schema for the gen4 field-script DSL, API 1. This
-- is the single source of truth for operation names, field names, types,
-- defaults, enums, and the normative constructor index. Field shapes, enums,
-- and the constructor index live here and nowhere else.
local Schema = {}

Schema.API_VERSION = 1
Schema.SCRIPT_KIND = "field_script"
Schema.SCHEMA_NAME = "gen4-script-schema-v1"

-- Declared param/local value types.
Schema.PARAM_TYPES = {
  "bool",
  "integer",
  "number",
  "string",
  "id",
  "actor_ref",
  "map_ref",
  "message_ref",
  "movement_ref",
  "serializable",
}

-- Enum values. Field specs reference these as "enum:<name>".
Schema.ENUMS = {
  script_kind = { Schema.SCRIPT_KIND },
  direction = { "north", "south", "west", "east" },
  speed = {
    "slower",
    "slow",
    "normal",
    "fast",
    "faster",
    "slightly_fast",
    "slightly_faster",
    "fastest",
    "run",
    "hgss_96",
    "hgss_97",
    "hgss_98",
    "hgss_99",
  },
  jump_distance = { "zero", "near", "far", "farther" },
  text_pad = { "none", "zero", "space" },
  movement_scope = { "environment", "actors" },
  compare_operator = { "lt", "eq", "gt", "le", "ge", "ne" },
  emote = { "exclamation", "exclamation_alt", "question" },
  gesture = { "warp_out", "warp_in", "nurse_bow", "give", "receive" },
  fade_direction = { "in", "out" },
  fade_color = { "black", "white" },
  button = { "a", "b" },
  menu_placement_mode = { "auto", "floating", "docked" },
  menu_anchor = { "auto", "top_left", "top_right", "bottom_left", "bottom_right", "bottom", "side" },
  menu_surface = { "auto", "main", "auxiliary" },
  -- The five MAPSIGNCOMMAND_* values as the semantic command enum; numeric
  -- source codes never appear at runtime (lowering converts them).
  signpost_command = { "nop", "show", "wipe_out", "wipe_in", "hide" },
}

Schema.ACTOR_SPECIALS = { "player", "self", "last_talked", "partner", "camera_target" }

-- Script resource schema . `kind` is constructor-supplied;
-- direct tables may omit it.
Schema.SCRIPT = {
  fields = {
    kind = { type = "enum:script_kind", default = Schema.SCRIPT_KIND },
    api = { type = "integer", required = true },
    id = { type = "string", required = true },
    params = { type = "params" },
    locals = { type = "locals" },
    replaces = { type = "string" },
    steps = { type = "steps", required = true },
    metadata = { type = "serializable" },
  },
}

-- General value references. Each kind's fields
-- are validated against its own spec; unknown kinds are invalid references.
Schema.VALUES = {
  var = { fields = { id = { type = "string", required = true } } },
  ["local"] = { fields = { name = { type = "string", required = true } } },
  arg = { fields = { name = { type = "string", required = true } } },
  flag_value = { fields = { flag = { type = "id_or_var", required = true } } },
  player_gender_value = { fields = {} },
  friend_sprite_value = { fields = {} },
  object_id = { fields = { ref = { type = "actor", required = true } } },
  trigger_background_id = { fields = {} },
  trigger_direction = { fields = {} },
}

-- Text-value descriptors. Descriptors are never
-- eagerly rendered strings.
Schema.TEXT_VALUES = {
  player_name = { fields = {} },
  rival_name = { fields = {} },
  friend_name = { fields = {} },
  integer = {
    fields = {
      value = { type = "scalar_or_value", required = true },
      width = { type = "integer" },
      pad = { type = "enum:text_pad", default = "none" },
      sign = { type = "boolean", default = false },
    },
  },
  item_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  pocket_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  move_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  tmhm_move_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  species_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  party_species_name = { fields = { position = { type = "scalar_or_value", required = true } } },
  party_nickname = { fields = { position = { type = "scalar_or_value", required = true } } },
  party_mon_move_name = {
    fields = {
      position = { type = "scalar_or_value", required = true },
      moveSlot = { type = "scalar_or_value", required = true },
    },
  },
  nature_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  trainer_class_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  starter_species_name = { fields = {} },
  map_name = { fields = { value = { type = "scalar_or_value", required = true } } },
  gendered_message = {
    fields = {
      male = { type = "message", required = true },
      female = { type = "message", required = true },
    },
  },
}

-- Condition references.
Schema.CONDITIONS = {
  compare = {
    fields = {
      operator = { type = "enum:compare_operator", required = true },
      left = { type = "scalar_or_value", required = true },
      right = { type = "scalar_or_value", required = true },
    },
  },
  flag = {
    fields = {
      id = { type = "id_or_var", required = true },
      expected = { type = "boolean", default = true },
    },
  },
  ["not"] = { fields = { operand = { type = "condition", required = true } } },
  all = { fields = { conditions = { type = "condition_list", default = {} } } },
  any = { fields = { conditions = { type = "condition_list", default = {} } } },
  actor_exists = { fields = { ref = { type = "actor", required = true } } },
  truthy = { fields = { value = { type = "scalar_or_value", required = true } } },
}

-- Movement actions. A movement sequence is an
-- array of these. `reveal_trainer` and `trajectory_segment` are generated
-- import carriers: they validate and execute like any other action but have
-- no public constructor.
Schema.MOVEMENT_ACTIONS = {
  face = {
    fields = {
      direction = { type = "enum:direction", required = true },
      count = { type = "integer", default = 1 },
    },
  },
  walk = {
    fields = {
      direction = { type = "enum:direction", required = true },
      speed = { type = "enum:speed", default = "normal" },
      tiles = { type = "integer", default = 1 },
    },
  },
  walk_in_place = {
    fields = {
      direction = { type = "enum:direction", required = true },
      speed = { type = "enum:speed", default = "normal" },
      count = { type = "integer", default = 1 },
    },
  },
  jump = {
    fields = {
      direction = { type = "enum:direction", required = true },
      distance = { type = "enum:jump_distance", default = "zero" },
      speed = { type = "enum:speed", default = "fast" },
      count = { type = "integer", default = 1 },
    },
  },
  delay = {
    fields = {
      ticks = { type = "integer", required = true },
      count = { type = "integer", default = 1 },
    },
  },
  set_visible = { fields = { visible = { type = "boolean", required = true } } },
  lock_facing = { fields = {} },
  unlock_facing = { fields = {} },
  pause_animation = { fields = {} },
  resume_animation = { fields = {} },
  emote = {
    fields = {
      name = { type = "enum:emote", required = true },
      count = { type = "integer", default = 1 },
    },
  },
  gesture = {
    fields = {
      name = { type = "enum:gesture", required = true },
      count = { type = "integer", default = 1 },
    },
  },
  reveal_trainer = {
    fields = {
      count = { type = "integer", default = 1 },
    },
  },
  trajectory_segment = {
    fields = {
      deltaX = { type = "integer", required = true },
      deltaZ = { type = "integer", required = true },
      surfaceBandDelta = { type = "integer", required = true },
      direction = { type = "enum:direction", required = true },
      ticks = { type = "integer", required = true },
    },
  },
  unsupported = {
    fields = {
      code = { type = "integer", required = true },
      count = { type = "integer", default = 1 },
      originalName = { type = "string" },
    },
  },
}

-- Canonical operations . Every step is a table with `op` set
-- to one of these names and the declared fields; unknown fields are rejected.
Schema.OPERATIONS = {
  noop = { fields = {} },
  stop = { fields = {} },
  yield_tick = { fields = {} },
  change_weather = {
    fields = {
      weatherId = { type = "integer", required = true },
    },
  },
  set_auxiliary_ui_visible = {
    fields = {
      visible = { type = "boolean", required = true },
    },
  },
  context_choice = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  wait_ticks = {
    fields = {
      ticks = { type = "integer", required = true },
      -- Observable countdown mirror : when the source
      -- destination variable is read elsewhere, the task mirrors the
      -- countdown into it exactly like ScrCmd_Wait + RunPauseTimer (initial
      -- write at creation, one decrement per poll). Without this field the
      -- countdown stays internal to the task state.
      countdownVariable = { type = "id_or_var" },
    },
  },
  ["if"] = {
    fields = {
      condition = { type = "condition", required = true },
      yes = { type = "steps", required = true },
      no = { type = "steps", default = {} },
    },
  },
  switch = {
    fields = {
      value = { type = "scalar_or_value", required = true },
      cases = { type = "cases", required = true },
      default = { type = "steps", default = {} },
    },
  },
  call = {
    fields = {
      target = { type = "string", required = true },
      -- Optional cross-script entry label: the call enters the composed
      -- target at this label instead of its entry (shared script tails).
      -- Only valid when the target is not a local label.
      label = { type = "string" },
      args = { type = "args", default = {} },
      result = { type = "value" },
    },
  },
  call_common = {
    fields = {
      target = { type = "string", required = true },
      args = { type = "args", default = {} },
    },
  },
  -- Translator-internal caller-signal operation : lowered from
  -- HGSS `RestartCurrentScript` inside verified common-script contexts. Not
  -- exposed as a public constructor; generated scripts may use it and
  -- handwritten scripts are warned.
  signal_caller = { fields = {} },
  -- Generated HGSS avatar-transition carriers: one opaque queued transition
  -- per selected source bit (opcode 188, always followed by a yield_tick
  -- node) and one same-tick pending-set apply (opcode 189). The transition
  -- name is semantic only; no source bit positions or state numbers survive
  -- lowering, and there is no public constructor for either operation.
  queue_avatar_transition = {
    fields = {
      transition = { type = "string", required = true },
    },
  },
  apply_avatar_transitions = { fields = {} },
  ["return"] = { fields = { value = { type = "scalar_or_value" } } },
  label = { fields = { name = { type = "string", required = true } } },
  ["goto"] = { fields = { target = { type = "string", required = true } } },
  goto_if = {
    fields = {
      condition = { type = "condition", required = true },
      target = { type = "string", required = true },
    },
  },
  -- Cross-script jump (shared script tails, rows 22/28):
  -- a same-context, same-tick jump into another script's graph, resolved
  -- through the composition registry at runtime like the raw-Lua escape
  -- hatch. `label` names an entry point inside the target; without it the
  -- jump lands on the composed target's entry. Handwritten scripts are
  -- warned (same bucket as label/goto fallback).
  goto_script = {
    fields = {
      script = { type = "string", required = true },
      label = { type = "string" },
    },
  },
  compare = {
    fields = {
      left = { type = "scalar_or_value", required = true },
      right = { type = "scalar_or_value", required = true },
    },
  },
  goto_compared = {
    fields = {
      operator = { type = "enum:compare_operator", required = true },
      -- Either a local label `target` or a cross-script reference (`script`
      -- plus optional `label`), resolved through the composition registry at
      -- runtime; the compare state is consumed exactly as the source does.
      target = { type = "string" },
      script = { type = "string" },
      label = { type = "string" },
    },
  },
  call_compared = {
    fields = {
      operator = { type = "enum:compare_operator", required = true },
      target = { type = "string" },
      script = { type = "string" },
      label = { type = "string" },
    },
  },
  next = { fields = {} },
  set_flag = { fields = { flag = { type = "id_or_var", required = true } } },
  clear_flag = { fields = { flag = { type = "id_or_var", required = true } } },
  set_var = {
    fields = {
      variable = { type = "id_or_var", required = true },
      value = { type = "scalar_or_value", required = true },
    },
  },
  copy_var = {
    fields = {
      destination = { type = "id_or_var", required = true },
      source = { type = "id_or_var", required = true },
    },
  },
  add_var = {
    fields = {
      variable = { type = "id_or_var", required = true },
      amount = { type = "scalar_or_value", required = true },
    },
  },
  sub_var = {
    fields = {
      variable = { type = "id_or_var", required = true },
      amount = { type = "scalar_or_value", required = true },
    },
  },
  set_local = {
    fields = {
      name = { type = "string", required = true },
      value = { type = "scalar", required = true },
    },
  },
  copy_local = {
    fields = {
      destination = { type = "string", required = true },
      source = { type = "string", required = true },
    },
  },
  add_local = {
    fields = {
      name = { type = "string", required = true },
      amount = { type = "scalar", required = true },
    },
  },
  sub_local = {
    fields = {
      name = { type = "string", required = true },
      amount = { type = "scalar", required = true },
    },
  },
  say = {
    fields = {
      message = { type = "message", required = true },
      bindings = { type = "bindings", default = {} },
    },
  },
  open_message = { fields = {} },
  -- Generated/advanced imported-HGSS signpost operations. The signpost
  -- window is a persistent structure, not a dialogue box; the controller owns
  -- the command state machine. `sourceAppearance` preserves the raw source
  -- type/map presentation data. Opcode 55's final operand is audited as
  -- unused by the source handler and stays in the raw decoded operands;
  -- executable nodes never carry it.
  signpost_direction = {
    fields = {
      message = { type = "message", required = true },
      sourceAppearance = { type = "serializable", required = true },
    },
  },
  signpost_set = {
    fields = {
      sourceAppearance = { type = "serializable", required = true },
    },
  },
  -- Opcode 57: assign one of the five signpost commands to the persistent
  -- signpost window (a bare assignment, no busy guard); the controller
  -- returns it to nop only when the action completes. Opcode 58 waits for
  -- the command to return to nop, continuing in the same tick when it
  -- already is.
  signpost_command = {
    fields = {
      command = { type = "enum:signpost_command", required = true },
    },
  },
  wait_signpost_action = { fields = {} },
  -- Opcode 59: type the message into the existing signpost window at the
  -- player's configured text speed; the result var receives the completion
  -- value through the task result (2 normal, 0 on a directional interrupt).
  trainer_tips_print = {
    fields = {
      message = { type = "message", required = true },
      result = { type = "value", required = true },
    },
  },
  -- Opcode 60: wait for A/B or a directional dismissal of the presented
  -- signpost window; the result var receives 0 through the task result.
  wait_signpost = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  -- High-level handwritten-signpost operations (the mod-facing S.sign /
  -- S.trainerTip API). They present the signpost window with a catalogued
  -- style id or a semantic appearance value -- never source-only type/map
  -- data -- and delegate to the same ScriptSignpostHost /
  -- FieldSignpostController primitives as the imported operations; the
  -- sign task owns the complete open -> dismiss -> close
  -- lifecycle, so S.sign is always blocking. Imported ROM scripts never
  -- lower to these operations.
  sign = {
    fields = {
      message = { type = "message", required = true },
      -- A catalogued style id or the semantic "sign" (resolved to the
      -- hgss.signpost built-in at script execution).
      appearance = { type = "string", default = "sign" },
    },
  },
  trainer_tip = {
    fields = {
      message = { type = "message", required = true },
      appearance = { type = "string", default = "trainer_tip" },
    },
  },
  -- Opcode 61 (ScrCmd_061, std_signpost's hide-branch tail): no operands.
  -- Ends the script context and requests the Start Menu reopen hook
  -- through the startMenuReopen service; a missing service is an
  -- attributed fault, never a silent close.
  request_start_menu = { fields = {} },
  message = {
    fields = {
      message = { type = "message", required = true },
      waitForPrint = { type = "boolean", default = true },
      bindings = { type = "bindings", default = {} },
    },
  },
  wait_input = {
    fields = {
      buttons = { type = "buttons", default = { "a", "b" } },
      allowDpad = { type = "boolean", default = false },
      turnPlayerOnDpad = { type = "boolean", default = false },
    },
  },
  wait_input_or_ticks = {
    fields = {
      ticks = { type = "integer", required = true },
      buttons = { type = "buttons", default = { "a", "b" } },
      allowDpad = { type = "boolean", default = true },
      turnPlayerOnDpad = { type = "boolean", default = false },
    },
  },
  close_message = { fields = { erase = { type = "boolean", default = true } } },
  hold_message = { fields = {} },
  ask_yes_no = {
    fields = {
      message = { type = "message" },
      result = { type = "value", required = true },
      bindings = { type = "bindings", default = {} },
    },
  },
  -- Public semantic menu. Its result values belong to items, never visual
  -- positions; presentation consumes placement only as a hint.
  choose = {
    fields = {
      items = { type = "menu_items", required = true },
      result = { type = "value", required = true },
      cancellable = { type = "boolean", default = false },
      cancelValue = { type = "scalar_or_value" },
      initialCursor = { type = "integer", default = 0 },
      placement = { type = "menu_placement", default = { mode = "auto", anchor = "auto", surface = "auto" } },
    },
  },
  -- Generated/advanced HGSS menu-builder operations. Handwritten scripts
  -- use `choose`; these preserve the source protocol's message-bank details.
  menu_begin = {
    fields = {
      messageSource = { type = "serializable", required = true },
      sourcePlacement = { type = "serializable", required = true },
      initialCursor = { type = "integer", required = true },
      cancellable = { type = "boolean", required = true },
      result = { type = "value", required = true },
    },
  },
  menu_add = {
    fields = {
      messageId = { type = "scalar_or_value", required = true },
      vanillaMetadata = { type = "scalar_or_value", required = true },
      value = { type = "scalar_or_value", required = true },
    },
  },
  menu_exec = { fields = {} },
  buffer_text = {
    fields = {
      slot = { type = "buffer_slot", required = true },
      value = { type = "text_value", required = true },
    },
  },
  show_waiting_icon = { fields = {} },
  hide_waiting_icon = { fields = {} },
  lock_player = { fields = {} },
  release_player = { fields = {} },
  lock_all = { fields = {} },
  release_all = { fields = {} },
  lock_actor = {
    fields = {
      actor = { type = "actor", required = true },
      waitUntilPausable = { type = "boolean", default = false },
    },
  },
  release_actor = { fields = { actor = { type = "actor", required = true } } },
  face_player = { fields = { actor = { type = "actor", default = "self" } } },
  face = {
    fields = {
      actor = { type = "actor", required = true },
      direction = { type = "enum:direction", required = true },
    },
  },
  show_object = { fields = { actor = { type = "actor", required = true } } },
  hide_object = { fields = { actor = { type = "actor", required = true } } },
  set_object_position = {
    fields = {
      actor = { type = "actor", required = true },
      fieldX = { type = "scalar_or_value", required = true },
      fieldZ = { type = "scalar_or_value", required = true },
      worldY = { type = "scalar_or_value" },
    },
  },
  set_object_facing = {
    fields = {
      actor = { type = "actor", required = true },
      direction = { type = "enum:direction", required = true },
    },
  },
  set_object_movement_type = {
    fields = {
      actor = { type = "actor", required = true },
      movementType = { type = "string", required = true },
    },
  },
  get_player_coords = {
    fields = {
      x = { type = "value", required = true },
      z = { type = "value", required = true },
    },
  },
  get_object_coords = {
    fields = {
      actor = { type = "actor", required = true },
      x = { type = "value", required = true },
      z = { type = "value", required = true },
    },
  },
  get_player_facing = { fields = { result = { type = "value", required = true } } },
  apply_movement = {
    fields = {
      actor = { type = "actor", required = true },
      movement = { type = "movement", required = true },
      movementId = { type = "string" },
    },
  },
  wait_movement = {
    fields = {
      scope = { type = "enum:movement_scope", default = "environment" },
      actors = { type = "actor_list" },
    },
  },
  move = {
    fields = {
      actor = { type = "actor", required = true },
      movement = { type = "movement", required = true },
      movementId = { type = "string" },
    },
  },
  play_sound = { fields = { sound = { type = "scalar_or_value", required = true } } },
  stop_sound = { fields = { sound = { type = "scalar_or_value", required = true } } },
  wait_sound = { fields = { sound = { type = "scalar_or_value", required = true } } },
  play_cry = {
    fields = {
      species = { type = "scalar_or_value", required = true },
      form = { type = "scalar_or_value", default = 0 },
    },
  },
  wait_cry = { fields = {} },
  play_fanfare = { fields = { fanfare = { type = "scalar_or_value", required = true } } },
  wait_fanfare = { fields = {} },
  play_music = { fields = { music = { type = "string", required = true } } },
  -- The StopBGM operand is an erasure at lowering (ScrCmd_StopBGM ignores
  -- it and stops the currently playing BGM), so the semantic operation
  -- takes no fields: an optional music field would be advertised and
  -- ignored.
  stop_music = { fields = {} },
  reset_music = { fields = {} },
  temporary_music = { fields = { music = { type = "string", required = true } } },
  fade_music_out = {
    fields = {
      target = { type = "integer", default = 0 },
      durationTicks = { type = "integer", required = true },
    },
  },
  fade_music_in = { fields = { durationTicks = { type = "integer", required = true } } },
  process_soundplate = { fields = {} },
  fade_screen = {
    fields = {
      duration = { type = "integer", required = true },
      speed = { type = "integer", required = true },
      direction = { type = "enum:fade_direction", required = true },
      color = { type = "enum:fade_color", required = true },
    },
  },
  wait_fade = { fields = {} },
  warp = {
    fields = {
      map = { type = "scalar_or_value", required = true },
      warp = { type = "scalar_or_value", required = true },
      fieldX = { type = "scalar_or_value", required = true },
      fieldZ = { type = "scalar_or_value", required = true },
      facing = { type = "scalar_or_value", required = true },
    },
  },
  set_spawn = { fields = { spawn = { type = "string", required = true } } },
  -- The source special-spawn setter (opcode 582): records a pending spawn
  -- location distinct from `set_spawn`'s named spawn-point concept. warpId
  -- and direction are source constants (-1, south) at every current call
  -- site, not scalar_or_value operands.
  set_special_spawn = {
    fields = {
      map = { type = "scalar_or_value", required = true },
      fieldX = { type = "scalar_or_value", required = true },
      fieldZ = { type = "scalar_or_value", required = true },
      warpId = { type = "integer", required = true },
      direction = { type = "enum:direction", required = true },
    },
  },
  shake_camera = {
    fields = {
      amplitudeX = { type = "number", required = true },
      amplitudeY = { type = "number", required = true },
      intervalTicks = { type = "integer", required = true },
      count = { type = "integer", required = true },
    },
  },
  actor_oscillate = {
    fields = {
      actor = { type = "actor", required = true },
      cycles = { type = "scalar_or_value", required = true },
      degreesPerTick = { type = "scalar_or_value", required = true },
      amplitudeX = { type = "scalar_or_value", required = true },
      amplitudeZ = { type = "scalar_or_value", required = true },
    },
  },
  random = {
    fields = {
      maxExclusive = { type = "integer", required = true },
      result = { type = "value", required = true },
    },
  },
  -- Mon and party operations. Every node names a semantic service behavior;
  -- no node carries a source opcode, and slot positions are zero-based party
  -- slots. Search results write the zero-based slot or 6 when no mon
  -- matches; boolean results write 1 or 0.
  give_mon = {
    fields = {
      species = { type = "scalar_or_value", required = true },
      level = { type = "scalar_or_value", required = true },
      heldItem = { type = "scalar_or_value" },
      form = { type = "scalar_or_value" },
      ability = { type = "scalar_or_value" },
      result = { type = "value", required = true },
    },
  },
  -- Blocking starter selection. The runtime pre-creates the three
  -- provider-ordered candidates, runs the modal choice, and publishes the
  -- exact confirmed instance; the resumed script owns its story flags.
  choose_starter = { fields = {} },
  return_loan_mon = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value" },
    },
  },
  set_mon_move = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      moveSlot = { type = "scalar_or_value", required = true },
      move = { type = "scalar_or_value", required = true },
    },
  },
  mon_has_move = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      move = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_slot_with_move = {
    fields = {
      move = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  count_mon_moves = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  mon_forget_move = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      moveSlot = { type = "scalar_or_value", required = true },
    },
  },
  mon_get_move = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      moveSlot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_count = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  party_count_not_egg = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  party_count_egg = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  count_alive_mons = {
    fields = {
      excludeSlot = { type = "scalar_or_value" },
      result = { type = "value", required = true },
    },
  },
  party_count_at_or_below_level = {
    fields = {
      level = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  count_species = {
    fields = {
      species = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_slot_with_species = {
    fields = {
      species = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_slot_with_nature = {
    fields = {
      nature = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_slot_with_fateful_encounter = {
    fields = {
      species = { type = "scalar_or_value" },
      result = { type = "value", required = true },
    },
  },
  party_mon_species = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_mon_is_mine = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_mon_nature = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_mon_friendship = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  mon_add_friendship = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      amount = { type = "scalar_or_value", required = true },
    },
  },
  mon_sub_friendship = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      amount = { type = "scalar_or_value", required = true },
    },
  },
  party_mon_gender = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_mon_contest_value = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      contestType = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  mon_add_contest_value = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      contestType = { type = "scalar_or_value", required = true },
      amount = { type = "scalar_or_value", required = true },
    },
  },
  party_mon_form = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_mon_ribbon_count = {
    fields = {
      slot = { type = "scalar_or_value", required = true },
      result = { type = "value", required = true },
    },
  },
  party_ribbon_count = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  party_has_pokerus = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  party_lead = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  party_lead_alive = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  party_legal_check = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  check_kyogre_groudon = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  heal_party = { fields = {} },
  -- Party-screen selection. The launch node blocks on the party_select
  -- task with the source selection context; the completed slot parks on
  -- the script instance for the companion result node, which copies it
  -- (or the source cancellation value) into its variable and rejects
  -- anything else.
  party_select = { fields = {} },
  party_select_result = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  -- Follower operations. Every node routes to the one field following
  -- controller through the injected collaborator; boolean results write 1
  -- or 0, and the explicit movement carries one decoded movement action.
  follower_is_active = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  follower_partner_state = {
    fields = {
      result = { type = "value", required = true },
    },
  },
  follower_face_player = { fields = {} },
  follower_set_paused = {
    fields = {
      paused = { type = "scalar_or_value", required = true },
    },
  },
  follower_wait = { fields = {} },
  follower_start_movement = {
    fields = {
      movement = { type = "movement_action", required = true },
    },
  },
  follower_reposition = {
    fields = {
      a = { type = "scalar_or_value", required = true },
      b = { type = "scalar_or_value", required = true },
    },
  },
  follower_is_event_trigger = {
    fields = {
      kind = { type = "scalar_or_value", required = true },
      param = { type = "scalar_or_value" },
      result = { type = "value", required = true },
    },
  },
  unsupported = {
    fields = {
      command = { type = "integer", required = true },
      originalName = { type = "string" },
      arguments = { type = "scalar_list", default = {} },
      sourceOffset = { type = "integer" },
      reason = { type = "string" },
    },
  },
}

-- Step-level fields shared by every operation . `key`
-- stabilizes a node's identity in the node map across non-semantic edits;
-- `provenance` carries source offsets/opcodes and drives generated `src:`
-- node IDs (the compiler maps it onto the node's `source` field). The step
-- field is named `provenance` because `copy_var` owns the `source` operand
-- name; the compiler keeps an operation-owned `source` operand and never
-- lets the provenance payload clobber it. Both are additive API 1 fields:
-- identity and provenance, never runtime semantics. Both drive node IDs,
-- and node IDs are revision inputs: the graph revision hashes a projection
-- keyed by node ID, so author `key` edits change the revision, and
-- provenance identity edits do too for generated `src:` nodes. Only the
-- node `source` provenance payload (opcodes, ...) is excluded from that
-- hash.
Schema.STEP_FIELDS = {
  key = { type = "string" },
  provenance = { type = "source_provenance" },
}
for _, op in pairs(Schema.OPERATIONS) do
  for name, spec in pairs(Schema.STEP_FIELDS) do
    op.fields[name] = spec
  end
end

-- Normative constructor index. Grouped exactly like the schema tables.
Schema.CONSTRUCTORS = {
  {
    section = "Resource and reference constructors",
    rows = {
      {
        signature = "S.script(spec)",
        canonical = 'kind="field_script"',
        notes = "Requires api, id, and steps; supplies kind.",
      },
      { signature = "S.var(id)", canonical = 'value="var"', notes = "Persistent/project-owned variable reference." },
      {
        signature = "S.local_(name)",
        canonical = 'value="local"',
        notes = "Instance-local reference. Trailing underscore is part of API.",
      },
      { signature = "S.arg(name)", canonical = 'value="arg"', notes = "Call argument reference." },
      { signature = "S.actor(id)", canonical = 'ref="actor", id=id', notes = "Map/public actor ID." },
      { signature = "S.player()", canonical = 'ref="actor", special="player"', notes = "" },
      { signature = "S.self()", canonical = 'ref="actor", special="self"', notes = "Trigger-owning object." },
      { signature = "S.lastTalked()", canonical = 'ref="actor", special="last_talked"', notes = "" },
      { signature = "S.partner()", canonical = 'ref="actor", special="partner"', notes = "" },
      { signature = "S.cameraTarget()", canonical = 'ref="actor", special="camera_target"', notes = "" },
      {
        signature = "S.actorIndex(index)",
        canonical = 'ref="actor", mapIndex=index',
        notes = "Numeric local map-object index resolved against the current map at runtime.",
      },
      {
        signature = "S.externalMessage(bank, id)",
        canonical = 'message="external"',
        notes = "Both operands may be values.",
      },
    },
  },
  {
    section = "Text-value constructors",
    rows = {
      { signature = "S.playerName()", canonical = "text=player_name", notes = "" },
      { signature = "S.rivalName()", canonical = "text=rival_name", notes = "" },
      { signature = "S.friendName()", canonical = "text=friend_name", notes = "" },
      { signature = "S.integerText(value)", canonical = "text=integer", notes = "" },
      { signature = "S.itemName(value)", canonical = "text=item_name", notes = "" },
      { signature = "S.pocketName(value)", canonical = "text=pocket_name", notes = "" },
      { signature = "S.moveName(value)", canonical = "text=move_name", notes = "" },
      { signature = "S.tmhmMoveName(value)", canonical = "text=tmhm_move_name", notes = "" },
      { signature = "S.speciesName(value)", canonical = "text=species_name", notes = "" },
      {
        signature = "S.partySpeciesName(position)",
        canonical = "text=party_species_name",
        notes = "Read-only party lookup.",
      },
      { signature = "S.partyNickname(position)", canonical = "text=party_nickname", notes = "Read-only party lookup." },
      {
        signature = "S.partyMonMoveName(position, moveSlot)",
        canonical = "text=party_mon_move_name",
        notes = "Read-only party lookup.",
      },
      { signature = "S.natureName(value)", canonical = "text=nature_name", notes = "Native 0..24 nature identity." },
      { signature = "S.trainerClassName(value)", canonical = "text=trainer_class_name", notes = "" },
      {
        signature = "S.starterSpeciesName()",
        canonical = "text=starter_species_name",
        notes = "Read-only world-state lookup.",
      },
      { signature = "S.mapName(value)", canonical = "text=map_name", notes = "" },
      {
        signature = "S.gendered(maleMessage, femaleMessage)",
        canonical = "text=gendered_message",
        notes = "Message selection, not rendered text concatenation.",
      },
    },
  },
  {
    section = "General value constructors",
    rows = {
      {
        signature = "S.flagValue(flag)",
        canonical = "value=flag_value",
        notes = "Returns numeric 1 or 0; flag may be static or dynamic.",
      },
      {
        signature = "S.playerGenderValue()",
        canonical = "value=player_gender_value",
        notes = "HGSS-compatible numeric value.",
      },
      {
        signature = "S.friendSpriteValue()",
        canonical = "value=friend_sprite_value",
        notes = "Opposite-gender friend NPC sprite constant.",
      },
      {
        signature = "S.objectIdValue(ref)",
        canonical = "value=object_id",
        notes = "Used by imported trigger comparisons.",
      },
      {
        signature = "S.backgroundIdValue()",
        canonical = "value=trigger_background_id",
        notes = "Reads current trigger context.",
      },
      {
        signature = "S.triggerDirectionValue()",
        canonical = "value=trigger_direction",
        notes = "Reads normalized trigger direction.",
      },
    },
  },
  {
    section = "Condition constructors",
    rows = {
      { signature = "S.eq(a, b)", canonical = "compare eq", notes = "" },
      { signature = "S.ne(a, b)", canonical = "compare ne", notes = "" },
      { signature = "S.lt(a, b)", canonical = "compare lt", notes = "" },
      { signature = "S.le(a, b)", canonical = "compare le", notes = "" },
      { signature = "S.gt(a, b)", canonical = "compare gt", notes = "" },
      { signature = "S.ge(a, b)", canonical = "compare ge", notes = "" },
      { signature = "S.flag(idOrValue)", canonical = "flag", notes = "expected true." },
      { signature = "S.not_(condition)", canonical = "not", notes = "Trailing underscore is part of API." },
      { signature = "S.all(conditions)", canonical = "all", notes = "Empty list is true." },
      { signature = "S.any(conditions)", canonical = "any", notes = "Empty list is false." },
      { signature = "S.exists(actorRef)", canonical = "actor_exists", notes = "" },
      { signature = "S.truthy(value)", canonical = "truthy", notes = "Only false and nil are false." },
    },
  },
  {
    section = "Control-flow constructors",
    notes = "All step constructors take one canonical spec table (the schema field names); generated scripts emit raw canonical step tables and never call these.",
    rows = {
      { signature = "S.noop(spec)", canonical = "op=noop", notes = "spec optional." },
      { signature = "S.stop(spec)", canonical = "op=stop", notes = "Normal script completion; spec optional." },
      {
        signature = "S.yieldTick(spec)",
        canonical = "op=yield_tick",
        notes = "Generated/advanced explicit one-tick source yield; spec optional.",
      },
      {
        signature = "S.setAuxiliaryUiVisible(spec)",
        canonical = "op=set_auxiliary_ui_visible",
        notes = "spec={visible=boolean}; imported HGSS visibility synchronization blocks as needed.",
      },
      {
        signature = "S.choose(spec)",
        canonical = "op=choose",
        notes = "Semantic field menu; spec={items,result,cancellable=false,cancelValue=nil,initialCursor=0,placement={mode=auto,anchor=auto,surface=auto}}. Cancellable menus require cancelValue (false is valid); initialCursor must identify an item. Directional navigation follows the resolved layout: single-column left/right is a no-op and multi-column movement uses neighboring rows and columns. No callbacks.",
      },
      {
        signature = "S.waitTicks(spec)",
        canonical = "op=wait_ticks",
        notes = "spec={ticks>=1,countdownVariable=nil}; first poll next tick, continuation one tick after completion; countdownVariable mirrors the countdown into an observable variable like the source engine.",
      },
      { signature = "S.if_(spec)", canonical = "op=if", notes = "spec={condition,yes={},no={}}." },
      { signature = "S.switch(spec)", canonical = "op=switch", notes = "spec={value,cases,default={}}." },
      {
        signature = "S.call(spec)",
        canonical = "op=call",
        notes = "spec={target,args={},result=nil,label=nil}; label enters the composed target at a label instead of its entry.",
      },
      {
        signature = "S.callCommon(spec)",
        canonical = "op=call_common",
        notes = "Generated/advanced common child context; spec={target,args={}}.",
      },
      {
        signature = "S.return_(spec)",
        canonical = "op=return",
        notes = "Trailing underscore is part of API; spec={value=nil}.",
      },
      { signature = "S.label(spec)", canonical = "op=label", notes = "spec={name}; generated fallback." },
      { signature = "S.goto_(spec)", canonical = "op=goto", notes = "spec={target}; generated fallback." },
      {
        signature = "S.gotoIf(spec)",
        canonical = "op=goto_if",
        notes = "spec={condition,target}; generated fallback.",
      },
      {
        signature = "S.gotoScript(spec)",
        canonical = "op=goto_script",
        notes = "spec={script,label=nil}; cross-script same-context jump (shared script tails); resolved through the composition registry at runtime; handwritten scripts are warned.",
      },
      {
        signature = "S.compare(spec)",
        canonical = "op=compare",
        notes = "spec={left,right}; generated low-level fallback.",
      },
      {
        signature = "S.gotoCompared(spec)",
        canonical = "op=goto_compared",
        notes = "spec={operator,target=nil,script=nil,label=nil}; the script/label form is cross-script, resolved through the composition registry at runtime.",
      },
      {
        signature = "S.callCompared(spec)",
        canonical = "op=call_compared",
        notes = "spec={operator,target=nil,script=nil,label=nil}; the script/label form is cross-script.",
      },
      { signature = "S.next(spec)", canonical = "op=next", notes = "Wrapper resources only; spec optional." },
    },
  },
  {
    section = "Field-menu constructors",
    rows = {
      {
        signature = "S.choice(messageRef, value, opts=nil)",
        canonical = "{text=messageRef,value=value}",
        notes = "opts={metadata=nil}; metadata is serializable opaque item data. Placement modes: auto, floating, docked; anchors: auto, top_left, top_right, bottom_left, bottom_right, bottom, side; surfaces: auto, main, auxiliary.",
      },
      {
        signature = "S.menuBegin(spec)",
        canonical = "op=menu_begin",
        notes = "Generated/advanced imported-HGSS builder form.",
      },
      {
        signature = "S.menuAdd(spec)",
        canonical = "op=menu_add",
        notes = "Generated/advanced imported-HGSS builder form.",
      },
      {
        signature = "S.menuExec(spec)",
        canonical = "op=menu_exec",
        notes = "Generated/advanced imported-HGSS builder form.",
      },
    },
  },
  {
    section = "Signpost constructors",
    notes = "S.sign and S.trainerTip are the high-level semantic surface: they present the signpost window with a catalogued style id or the semantic appearance value (never source-only type/map data) and delegate to the same signpost host/controller primitives as the imported operations. The six generated/advanced forms map 1:1 onto the imported signpost operations.",
    rows = {
      {
        signature = "S.sign(spec)",
        canonical = "op=sign",
        notes = 'spec={message,appearance="sign"}; appearance is a catalogued style id or the semantic "sign".',
      },
      {
        signature = "S.trainerTip(spec)",
        canonical = "op=trainer_tip",
        notes = 'spec={message,appearance="trainer_tip"}; types at the player text speed and waits for dismissal.',
      },
      {
        signature = "S.signpostSet(spec)",
        canonical = "op=signpost_set",
        notes = "Generated/advanced imported-HGSS form; spec={sourceAppearance={game,type,map}}.",
      },
      {
        signature = "S.signpostCommand(spec)",
        canonical = "op=signpost_command",
        notes = "Generated/advanced; spec={command}; command is one of the semantic strings (nop/show/wipe_out/wipe_in/hide).",
      },
      {
        signature = "S.waitSignpostAction(spec)",
        canonical = "op=wait_signpost_action",
        notes = "Generated/advanced imported-HGSS form; spec optional.",
      },
      {
        signature = "S.signpostDirection(spec)",
        canonical = "op=signpost_direction",
        notes = "Generated/advanced imported-HGSS form.",
      },
      {
        signature = "S.trainerTipsPrint(spec)",
        canonical = "op=trainer_tips_print",
        notes = "Generated/advanced imported-HGSS form.",
      },
      {
        signature = "S.waitSignpost(spec)",
        canonical = "op=wait_signpost",
        notes = "Generated/advanced imported-HGSS form.",
      },
    },
  },
  {
    section = "State constructors",
    rows = {
      { signature = "S.setFlag(spec)", canonical = "op=set_flag", notes = "spec={flag}." },
      { signature = "S.clearFlag(spec)", canonical = "op=clear_flag", notes = "spec={flag}." },
      { signature = "S.setVar(spec)", canonical = "op=set_var", notes = "spec={variable,value}." },
      {
        signature = "S.copyVar(spec)",
        canonical = "op=copy_var",
        notes = "spec={destination,source}; source is a variable ID.",
      },
      { signature = "S.addVar(spec)", canonical = "op=add_var", notes = "spec={variable,amount}." },
      { signature = "S.subVar(spec)", canonical = "op=sub_var", notes = "spec={variable,amount}." },
      { signature = "S.setLocal(spec)", canonical = "op=set_local", notes = "spec={name,value}." },
      { signature = "S.copyLocal(spec)", canonical = "op=copy_local", notes = "spec={destination,source}." },
      { signature = "S.addLocal(spec)", canonical = "op=add_local", notes = "spec={name,amount}." },
      { signature = "S.subLocal(spec)", canonical = "op=sub_local", notes = "spec={name,amount}." },
    },
  },
  {
    section = "Dialogue constructors",
    rows = {
      {
        signature = "S.say(spec)",
        canonical = "op=say",
        notes = "spec={message,bindings={}}.",
      },
      { signature = "S.openMessage(spec)", canonical = "op=open_message", notes = "spec optional." },
      {
        signature = "S.message(spec)",
        canonical = "op=message",
        notes = "spec={message,waitForPrint=true,bindings={}}; generated scripts emit waitForPrint explicitly.",
      },
      { signature = "S.waitInput(spec)", canonical = "op=wait_input", notes = "spec={buttons={a,b},allowDpad=false}." },
      {
        signature = "S.waitInputOrTicks(spec)",
        canonical = "op=wait_input_or_ticks",
        notes = 'spec={ticks,buttons={"a","b"},allowDpad=true,turnPlayerOnDpad=false}.',
      },
      { signature = "S.closeMessage(spec)", canonical = "op=close_message", notes = "spec={erase=true}." },
      { signature = "S.holdMessage(spec)", canonical = "op=hold_message", notes = "spec optional." },
      {
        signature = "S.askYesNo(spec)",
        canonical = "op=ask_yes_no",
        notes = "spec={message=nil,result,bindings={}}; message=nil uses current box.",
      },
      { signature = "S.bufferText(spec)", canonical = "op=buffer_text", notes = "spec={slot 0..7,value}." },
      { signature = "S.showWaitingIcon(spec)", canonical = "op=show_waiting_icon", notes = "spec optional." },
      { signature = "S.hideWaitingIcon(spec)", canonical = "op=hide_waiting_icon", notes = "spec optional." },
    },
  },
  {
    section = "Lock and actor constructors",
    rows = {
      {
        signature = "S.lockPlayer(spec)",
        canonical = "op=lock_player",
        notes = "Player input and interaction only; spec optional.",
      },
      { signature = "S.releasePlayer(spec)", canonical = "op=release_player", notes = "spec optional." },
      {
        signature = "S.lockAll(spec)",
        canonical = "op=lock_all",
        notes = "Player plus autonomous behavior; returns yield_tick or blocks until pausable; spec optional.",
      },
      {
        signature = "S.releaseAll(spec)",
        canonical = "op=release_all",
        notes = "Handwritten semantic is immediate; imported HGSS emits a following yield_tick; spec optional.",
      },
      {
        signature = "S.lockActor(spec)",
        canonical = "op=lock_actor",
        notes = "spec={actor,waitUntilPausable=false}; imported LockLastTalked sets true.",
      },
      { signature = "S.releaseActor(spec)", canonical = "op=release_actor", notes = "spec={actor}." },
      {
        signature = "S.facePlayer(spec)",
        canonical = "op=face_player",
        notes = 'spec={actor=nil}; actor defaults to "self" when omitted.',
      },
      {
        signature = "S.face(spec)",
        canonical = "op=face",
        notes = "spec={actor,direction}; immediate facing operation.",
      },
      { signature = "S.showObject(spec)", canonical = "op=show_object", notes = "spec={actor}." },
      { signature = "S.hideObject(spec)", canonical = "op=hide_object", notes = "spec={actor}." },
      {
        signature = "S.setObjectPosition(spec)",
        canonical = "op=set_object_position",
        notes = "spec={actor,fieldX,fieldZ,worldY=nil}.",
      },
      { signature = "S.setObjectFacing(spec)", canonical = "op=set_object_facing", notes = "spec={actor,direction}." },
      {
        signature = "S.setObjectMovementType(spec)",
        canonical = "op=set_object_movement_type",
        notes = "spec={actor,movementType}.",
      },
      { signature = "S.getPlayerCoords(spec)", canonical = "op=get_player_coords", notes = "spec={x,z} result refs." },
      {
        signature = "S.getObjectCoords(spec)",
        canonical = "op=get_object_coords",
        notes = "spec={actor,x,z} result refs.",
      },
      { signature = "S.getPlayerFacing(spec)", canonical = "op=get_player_facing", notes = "spec={result}." },
    },
  },
  {
    section = "Movement constructors",
    rows = {
      {
        signature = "S.applyMovement(spec)",
        canonical = "op=apply_movement",
        notes = "spec={actor,movement,{movementId=nil}}; non-blocking.",
      },
      {
        signature = "S.waitMovement(spec)",
        canonical = "op=wait_movement",
        notes = 'spec=nil means current environment generation; actor scope uses {scope="actors",actors={...}}.',
      },
      { signature = "S.move(spec)", canonical = "op=move", notes = "spec={actor,movement}; blocking convenience." },
    },
  },
  {
    section = "Movement action namespace",
    rows = {
      { signature = "S.m.face(spec)", canonical = "action=face", notes = "spec={direction,count=1}." },
      { signature = "S.m.walk(spec)", canonical = "action=walk", notes = 'spec={direction,speed="normal",tiles=1}.' },
      {
        signature = "S.m.walkInPlace(spec)",
        canonical = "action=walk_in_place",
        notes = 'spec={direction,speed="normal",count=1}.',
      },
      {
        signature = "S.m.jump(spec)",
        canonical = "action=jump",
        notes = 'spec={direction,distance="zero",speed="fast",count=1}.',
      },
      { signature = "S.m.delay(spec)", canonical = "action=delay", notes = "spec={ticks,count=1}." },
      { signature = "S.m.setVisible(spec)", canonical = "action=set_visible", notes = "spec={visible}." },
      { signature = "S.m.lockFacing(spec)", canonical = "action=lock_facing", notes = "spec optional." },
      { signature = "S.m.unlockFacing(spec)", canonical = "action=unlock_facing", notes = "spec optional." },
      { signature = "S.m.pauseAnimation(spec)", canonical = "action=pause_animation", notes = "spec optional." },
      { signature = "S.m.resumeAnimation(spec)", canonical = "action=resume_animation", notes = "spec optional." },
      { signature = "S.m.emote(spec)", canonical = "action=emote", notes = "spec={name,count=1}." },
      { signature = "S.m.gesture(spec)", canonical = "action=gesture", notes = "spec={name,count=1}." },
      {
        signature = "S.m.unsupported(spec)",
        canonical = "action=unsupported",
        notes = "Requires source code/count metadata.",
      },
    },
  },
  {
    section = "Audio constructors",
    rows = {
      { signature = "S.playSound(spec)", canonical = "op=play_sound", notes = "spec={sound}." },
      { signature = "S.stopSound(spec)", canonical = "op=stop_sound", notes = "spec={sound}." },
      { signature = "S.waitSound(spec)", canonical = "op=wait_sound", notes = "spec={sound}." },
      { signature = "S.playCry(spec)", canonical = "op=play_cry", notes = "spec={species,form=0}." },
      { signature = "S.waitCry(spec)", canonical = "op=wait_cry", notes = "spec optional." },
      { signature = "S.playFanfare(spec)", canonical = "op=play_fanfare", notes = "spec={fanfare}." },
      { signature = "S.waitFanfare(spec)", canonical = "op=wait_fanfare", notes = "spec optional." },
      { signature = "S.playMusic(spec)", canonical = "op=play_music", notes = "spec={music}." },
      {
        signature = "S.stopMusic(spec)",
        canonical = "op=stop_music",
        notes = "spec optional; stops the active field BGM.",
      },
      { signature = "S.resetMusic(spec)", canonical = "op=reset_music", notes = "spec optional." },
      { signature = "S.temporaryMusic(spec)", canonical = "op=temporary_music", notes = "spec={music}." },
      { signature = "S.fadeMusicOut(spec)", canonical = "op=fade_music_out", notes = "spec={target=0,durationTicks}." },
      { signature = "S.fadeMusicIn(spec)", canonical = "op=fade_music_in", notes = "spec={durationTicks}." },
      { signature = "S.processSoundplate(spec)", canonical = "op=process_soundplate", notes = "spec optional." },
    },
  },
  {
    section = "Screen, camera, and map constructors",
    rows = {
      {
        signature = "S.fadeScreen(spec)",
        canonical = "op=fade_screen",
        notes = "Requires source kind/speed/direction/color or normalized equivalents.",
      },
      { signature = "S.waitFade(spec)", canonical = "op=wait_fade", notes = "spec optional." },
      { signature = "S.warp(spec)", canonical = "op=warp", notes = "Requires map and target coordinates/warp." },
      { signature = "S.setSpawn(spec)", canonical = "op=set_spawn", notes = "spec={spawn}." },
      {
        signature = "S.shakeCamera(spec)",
        canonical = "op=shake_camera",
        notes = "Requires amplitude/interval/count fields.",
      },
    },
  },
  {
    section = "Random and diagnostic constructors",
    rows = {
      { signature = "S.random(spec)", canonical = "op=random", notes = "spec={maxExclusive,result}." },
      {
        signature = "S.unsupported(spec)",
        canonical = "op=unsupported",
        notes = "Requires command/name/source metadata sufficient for diagnostics.",
      },
    },
  },
  {
    section = "Mon and party constructors",
    notes = "Semantic mon/party operations executed through the injected mons service. Slots are zero-based party positions; search results write the slot or 6 when no mon matches; boolean results write 1 or 0.",
    rows = {
      {
        signature = "S.giveMon(spec)",
        canonical = "op=give_mon",
        notes = "spec={species,level,heldItem?,form?,ability?,result}.",
      },
      {
        signature = "S.returnLoanMon(spec)",
        canonical = "op=return_loan_mon",
        notes = "spec={slot,result?}.",
      },
      {
        signature = "S.setMonMove(spec)",
        canonical = "op=set_mon_move",
        notes = "spec={slot,moveSlot,move}.",
      },
      {
        signature = "S.monHasMove(spec)",
        canonical = "op=mon_has_move",
        notes = "spec={slot,move,result}.",
      },
      {
        signature = "S.partySlotWithMove(spec)",
        canonical = "op=party_slot_with_move",
        notes = "spec={move,result}.",
      },
      {
        signature = "S.countMonMoves(spec)",
        canonical = "op=count_mon_moves",
        notes = "spec={slot,result}.",
      },
      {
        signature = "S.monForgetMove(spec)",
        canonical = "op=mon_forget_move",
        notes = "spec={slot,moveSlot}.",
      },
      {
        signature = "S.monGetMove(spec)",
        canonical = "op=mon_get_move",
        notes = "spec={slot,moveSlot,result}; the result is the native move identity.",
      },
      {
        signature = "S.partyCount(spec)",
        canonical = "op=party_count",
        notes = "spec={result}.",
      },
      {
        signature = "S.partyCountNotEgg(spec)",
        canonical = "op=party_count_not_egg",
        notes = "spec={result}.",
      },
      {
        signature = "S.partyCountEgg(spec)",
        canonical = "op=party_count_egg",
        notes = "spec={result}.",
      },
      {
        signature = "S.countAliveMons(spec)",
        canonical = "op=count_alive_mons",
        notes = "spec={excludeSlot?,result}; party members only, never PC storage.",
      },
      {
        signature = "S.partyCountAtOrBelowLevel(spec)",
        canonical = "op=party_count_at_or_below_level",
        notes = "spec={level,result}.",
      },
      {
        signature = "S.countSpecies(spec)",
        canonical = "op=count_species",
        notes = "spec={species,result}.",
      },
      {
        signature = "S.partySlotWithSpecies(spec)",
        canonical = "op=party_slot_with_species",
        notes = "spec={species,result}.",
      },
      {
        signature = "S.partySlotWithNature(spec)",
        canonical = "op=party_slot_with_nature",
        notes = "spec={nature,result}.",
      },
      {
        signature = "S.partySlotWithFatefulEncounter(spec)",
        canonical = "op=party_slot_with_fateful_encounter",
        notes = "spec={species?,result}.",
      },
      {
        signature = "S.partyMonSpecies(spec)",
        canonical = "op=party_mon_species",
        notes = "spec={slot,result}; the result is the native species identity.",
      },
      {
        signature = "S.partyMonIsMine(spec)",
        canonical = "op=party_mon_is_mine",
        notes = "spec={slot,result}.",
      },
      {
        signature = "S.partyMonNature(spec)",
        canonical = "op=party_mon_nature",
        notes = "spec={slot,result}.",
      },
      {
        signature = "S.partyMonFriendship(spec)",
        canonical = "op=party_mon_friendship",
        notes = "spec={slot,result}.",
      },
      {
        signature = "S.monAddFriendship(spec)",
        canonical = "op=mon_add_friendship",
        notes = "spec={slot,amount}; clamped to 0..255.",
      },
      {
        signature = "S.monSubFriendship(spec)",
        canonical = "op=mon_sub_friendship",
        notes = "spec={slot,amount}; clamped to 0..255.",
      },
      {
        signature = "S.partyMonGender(spec)",
        canonical = "op=party_mon_gender",
        notes = "spec={slot,result}; 0 male, 1 female, 2 genderless.",
      },
      {
        signature = "S.partyMonContestValue(spec)",
        canonical = "op=party_mon_contest_value",
        notes = "spec={slot,contestType,result}.",
      },
      {
        signature = "S.monAddContestValue(spec)",
        canonical = "op=mon_add_contest_value",
        notes = "spec={slot,contestType,amount}; clamped to 0..255.",
      },
      {
        signature = "S.partyMonForm(spec)",
        canonical = "op=party_mon_form",
        notes = "spec={slot,result}.",
      },
      {
        signature = "S.partyMonRibbonCount(spec)",
        canonical = "op=party_mon_ribbon_count",
        notes = "spec={slot,result}.",
      },
      {
        signature = "S.partyRibbonCount(spec)",
        canonical = "op=party_ribbon_count",
        notes = "spec={result}.",
      },
      {
        signature = "S.partyHasPokerus(spec)",
        canonical = "op=party_has_pokerus",
        notes = "spec={result}.",
      },
      {
        signature = "S.partyLead(spec)",
        canonical = "op=party_lead",
        notes = "spec={result}; 6 when the party is empty.",
      },
      {
        signature = "S.partyLeadAlive(spec)",
        canonical = "op=party_lead_alive",
        notes = "spec={result}; 6 when no mon is conscious.",
      },
      {
        signature = "S.partyLegalCheck(spec)",
        canonical = "op=party_legal_check",
        notes = "spec={result}.",
      },
      {
        signature = "S.checkKyogreGroudon(spec)",
        canonical = "op=check_kyogre_groudon",
        notes = "spec={result}.",
      },
      { signature = "S.healParty(spec)", canonical = "op=heal_party", notes = "Restores the party to full health." },
      {
        signature = "S.chooseStarter(spec)",
        canonical = "op=choose_starter",
        notes = "spec optional; the blocking starter application publishes the confirmed candidate.",
      },
      {
        signature = "S.partySelect(spec)",
        canonical = "op=party_select",
        notes = "Blocks on the party screen in selection mode.",
      },
      {
        signature = "S.partySelectResult(spec)",
        canonical = "op=party_select_result",
        notes = "spec={result}; copies the slot or 255 on cancel.",
      },
    },
  },
}

return Schema
