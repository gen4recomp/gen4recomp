-- Validator tests for the gen4 field-script API 1 data contract. They prove
-- the platform contract: a script can be loaded (constructor or
-- direct table), validated, and deterministically printed without any game
-- session. Rejection cases cover non-serializable data, unknown fields, API
-- version mismatches, and malformed references.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Validator = require("libs.script.src.Validator")
local S = require("gen4.script")

local T = {}

-- Public validation returns nil, err instead of raising.
---@param code string
---@param script any
---@return Errors.Error
local function invalidCode(code, script)
  local ok, err = S.validate(script)
  Assert.isNil(ok)
  Assert.isTrue(Errors.is(err), "expected Errors object, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
  return err
end

local function valid(script)
  local ok, err = S.validate(script)
  Assert.isTrue(ok, "expected valid script, got: " .. tostring(err))
end

local function womanScript()
  return S.script({
    api = 1,
    id = "new_bark.npc.woman_1",
    steps = {
      S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
      S.lockAll(),
      S.facePlayer({ actor = "self" }),
      S.if_({
        condition = S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 0),
        yes = { S.say({ message = "msg.hgss.0542.00009" }) },
        no = {
          S.if_({
            condition = S.any({
              S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 1),
              S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 2),
            }),
            yes = { S.say({ message = "msg.hgss.0542.00005" }) },
            no = {
              S.if_({
                condition = S.eq(S.var("VAR_SCENE_NEW_BARK_WEST_EXIT"), 1),
                yes = { S.say({ message = "msg.hgss.0542.00000" }) },
                no = {
                  S.bufferText({ slot = 0, value = S.playerName() }),
                  S.say({ message = S.gendered("msg.hgss.0542.00006", "msg.hgss.0542.00007") }),
                },
              }),
            },
          }),
        },
      }),
      S.releaseAll(),
    },
  })
end

local function signScript()
  return S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = {
      S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
      S.lockAll(),
      S.say({ message = "msg.hgss.0543.00097" }),
      S.releaseAll(),
    },
  })
end

function T.accepts_minimal_direct_table_script()
  valid({
    api = 1,
    id = "mod.example.sign",
    steps = { { op = "stop" } },
  })
end

function T.accepts_vertical_slice_scripts()
  valid(womanScript())
  valid(signScript())
end

function T.direct_table_equivalents_validate_identically()
  local script = S.script({
    api = 1,
    id = "new_bark.lab_sign",
    steps = { S.say({ message = "msg.hgss.0543.00097" }) },
  })
  local direct = {
    kind = "field_script",
    api = 1,
    id = "new_bark.lab_sign",
    steps = {
      {
        op = "say",
        message = "msg.hgss.0543.00097",
        bindings = {},
      },
    },
  }
  Assert.deepEqual(script, direct)
  valid(script)
  valid(direct)
end

function T.script_must_be_a_table()
  invalidCode("SCRIPT_SCHEMA_INVALID", "not a script")
  invalidCode("SCRIPT_SCHEMA_INVALID", nil)
end

function T.rejects_unsupported_api_version()
  local err = invalidCode("SCRIPT_API_UNSUPPORTED", { api = 2, id = "x", steps = { S.stop() } })
  Assert.equal(err.context.api, 2)
  Assert.equal(err.context.path, "api")
end

function T.rejects_non_integer_api()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = "1", id = "x", steps = { S.stop() } })
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1.5, id = "x", steps = { S.stop() } })
end

function T.rejects_missing_id_and_steps()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, steps = { S.stop() } })
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x" })
end

function T.rejects_unknown_script_kind()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", kind = "overworld_script", steps = { S.stop() } })
end

function T.rejects_unknown_operation()
  local err = invalidCode("SCRIPT_UNKNOWN_OPERATION", { api = 1, id = "x", steps = { { op = "teleport_to_kanto" } } })
  Assert.equal(err.context.path, "steps/0")
end

function T.signpost_operations_validate_canonical_shapes()
  valid(S.script({
    api = 1,
    id = "x",
    steps = {
      {
        op = "signpost_direction",
        message = { message = "external", bank = 542, id = 34 },
        sourceAppearance = { game = "hgss", type = 0, map = 11 },
      },
      {
        op = "signpost_set",
        sourceAppearance = { game = "hgss", type = 2, map = 0 },
      },
      S.stop(),
    },
  }))
end

-- The high-level sign operations: message is required; appearance is the
-- registered-style-id-or-semantic string (any non-empty string, the
-- catalogue resolves it at runtime) and the sign always blocks.
function T.high_level_sign_operations_validate_canonical_shapes()
  valid(S.script({
    api = 1,
    id = "x",
    steps = {
      {
        op = "sign",
        message = "msg.hgss.0542.00034",
        appearance = "mod.route_sign",
      },
      {
        op = "trainer_tip",
        message = { message = "external", bank = 542, id = 36 },
        appearance = "trainer_tip",
      },
      S.stop(),
    },
  }))
end

function T.high_level_sign_operations_reject_malformed_shapes()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "sign", appearance = "sign" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "sign", message = "msg.x", wait = "yes" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "sign", message = "msg.x", appearance = 7 } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "sign", message = "msg.x", extra = true } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "trainer_tip", appearance = "trainer_tip" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "trainer_tip", message = "msg.x", extra = true } },
  })
end

function T.trainer_tips_and_wait_signpost_validate_canonical_shapes()
  valid(S.script({
    api = 1,
    id = "x",
    steps = {
      {
        op = "trainer_tips_print",
        message = { message = "external", bank = 542, id = 34 },
        result = S.var("VAR_SPECIAL_RESULT"),
      },
      {
        op = "wait_signpost",
        result = S.var("VAR_SPECIAL_RESULT"),
      },
      S.stop(),
    },
  }))
end

function T.process_soundplate_validates_as_zero_field_operation()
  valid(S.script({
    api = 1,
    id = "x",
    steps = {
      S.processSoundplate(),
      { op = "process_soundplate" },
      S.processSoundplate({}),
    },
  }))
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "process_soundplate", force = true } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "process_soundplate", extra = 1 } },
  })
end

-- Opcode 61's terminal request_start_menu operation: no fields, accepts no
-- operands (an extra field is a schema error).
function T.request_start_menu_operation_has_no_operands()
  valid(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "request_start_menu" },
    },
  }))
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "request_start_menu", extra = true } },
  })
end

function T.trainer_tips_and_wait_signpost_reject_malformed_shapes()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "trainer_tips_print", result = S.var("VAR_SPECIAL_RESULT") } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = {
      { op = "trainer_tips_print", message = { message = "external", bank = 542, id = 34 }, result = 2 },
    },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = {
      {
        op = "trainer_tips_print",
        message = { message = "external", bank = 542, id = 34 },
        result = S.var("VAR_SPECIAL_RESULT"),
        extra = true,
      },
    },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "wait_signpost" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "wait_signpost", result = "VAR_SPECIAL_RESULT" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "wait_signpost", result = S.var("VAR_SPECIAL_RESULT"), extra = true } },
  })
end

function T.signpost_command_enum_is_exactly_the_five_semantic_strings()
  Assert.deepEqual(
    require("libs.script.src.Schema").ENUMS.signpost_command,
    { "nop", "show", "wipe_out", "wipe_in", "hide" }
  )
  for _, command in ipairs({ "nop", "show", "wipe_out", "wipe_in", "hide" }) do
    valid(S.script({
      api = 1,
      id = "x",
      steps = { { op = "signpost_command", command = command }, { op = "wait_signpost_action" }, S.stop() },
    }))
  end
end

function T.signpost_command_and_wait_reject_malformed_shapes()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "signpost_command" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "signpost_command", command = "fade_out" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "signpost_command", command = "wipe_in", extra = true } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "wait_signpost_action", extra = true } },
  })
end

function T.signpost_operations_reject_malformed_shapes()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "signpost_direction", sourceAppearance = { game = "hgss", type = 0, map = 1 } } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "signpost_set" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "signpost_set", sourceAppearance = { game = "hgss", type = 0, map = 1 }, command = "show" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = {
      {
        op = "signpost_direction",
        message = "msg.hgss.0542.00034",
        sourceAppearance = { game = "hgss", type = 0, map = 1 },
        extra = true,
      },
    },
  })
end

function T.rejects_inert_say_options()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "say", message = "msg.greeting", close = false } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "say", message = "msg.greeting", wait = "button" } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "say", message = "msg.greeting", timingProfile = "hgss" } },
  })
end

function T.rejects_resolve_common_message_bank_operation()
  invalidCode("SCRIPT_UNKNOWN_OPERATION", {
    api = 1,
    id = "x",
    steps = {
      {
        op = "resolve_common_message_bank",
        script = "common.any",
        bankResult = { id = "VAR_TEMP_x4000", value = "var" },
        memberResult = { id = "VAR_TEMP_x4001", value = "var" },
      },
    },
  })
end

function T.rejects_step_without_op()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { { message = "msg.hgss.0543.00097" } } })
end

function T.rejects_non_table_step()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { "S.stop()" } })
end

function T.rejects_missing_required_field()
  local err = invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { { op = "say" } } })
  Assert.equal(err.context.field, "message")
  Assert.equal(err.context.path, "steps/0/message")
end

function T.rejects_bad_enum_value()
  invalidCode(
    "SCRIPT_SCHEMA_INVALID",
    { api = 1, id = "x", steps = { { op = "face", actor = "elm", direction = "northwest" } } }
  )
  invalidCode(
    "SCRIPT_SCHEMA_INVALID",
    { api = 1, id = "x", steps = { S.m.walk({ direction = "south", speed = "warp" }) } }
  )
end

function T.rejects_unknown_param_type()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    params = { professor = "gym_leader_ref" },
    steps = { S.stop() },
  })
end

function T.accepts_all_param_types()
  valid({
    api = 1,
    id = "x",
    params = {
      a = "bool",
      b = "integer",
      c = "number",
      d = "string",
      e = "id",
      f = "actor_ref",
      g = "map_ref",
      h = "message_ref",
      i = "movement_ref",
      j = "serializable",
    },
    locals = { route = "string" },
    steps = { S.stop() },
  })
end

function T.rejects_undeclared_local_and_arg_usage()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.setLocal({ name = "route", value = "intro" }) },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.say({ message = S.arg("message") }) },
  })
end

function T.rejects_functions_in_script_data()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { function() end } })
  invalidCode(
    "SCRIPT_SCHEMA_INVALID",
    { api = 1, id = "x", steps = { S.stop() }, metadata = { callback = function() end } }
  )
end

function T.rejects_userdata()
  local userdata = io.open("/dev/null", "r")
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, metadata = { file = userdata } })
  if userdata then
    userdata:close()
  end
end

function T.rejects_threads()
  local thread = coroutine.create(function() end)
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, metadata = { thread = thread } })
end

function T.rejects_cyclic_tables()
  local steps = { S.stop() }
  steps[1].selfRef = steps
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = steps })
end

function T.rejects_metatables()
  local step = S.stop()
  setmetatable(step, {})
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { step } })
end

function T.rejects_non_finite_numbers()
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { { op = "wait_ticks", ticks = 1 / 0 } } })
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, metadata = { nan = 0 / 0 } })
end

function T.rejects_unknown_fields()
  local script = {
    api = 1,
    id = "x",
    steps = { { op = "stop", surprise = true } },
  }
  local err = invalidCode("SCRIPT_SCHEMA_INVALID", script)
  Assert.equal(err.context.field, "surprise")
  Assert.equal(err.context.path, "steps/0/surprise")
  invalidCode("SCRIPT_SCHEMA_INVALID", { api = 1, id = "x", steps = { S.stop() }, extra = 1 })
end

function T.validates_semantic_choose_and_rejects_malformed_choices()
  valid({
    api = 1,
    id = "mod.example.choose",
    steps = {
      S.choose({
        items = { S.choice("msg.project.take", 10), S.choice("msg.project.leave", 20) },
        result = S.var("choice"),
        cancellable = true,
        cancelValue = 20,
        placement = { mode = "auto", anchor = "auto", surface = "auto" },
      }),
    },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "choose", items = {}, result = S.var("choice"), callback = function() end } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = {
      {
        op = "choose",
        items = { S.choice("msg.project.take", 1) },
        result = S.var("choice"),
        placement = { mode = "popup" },
      },
    },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "choose", items = { { text = "msg.project.take" } }, result = S.var("choice") } },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "choose", items = { S.choice("msg.project.take", 1) } } },
  })
end

function T.semantic_choose_requires_a_cancel_value_and_a_valid_initial_cursor()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = {
      S.choose({ items = { S.choice("Take", 1) }, result = S.var("choice"), cancellable = true }),
    },
  })
  valid({
    api = 1,
    id = "x",
    steps = {
      S.choose({
        items = { S.choice("Take", 1) },
        result = S.var("choice"),
        cancellable = true,
        cancelValue = false,
      }),
    },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = {
      S.choose({ items = { S.choice("Take", 1) }, result = S.var("choice"), initialCursor = 1 }),
    },
  })
end

function T.rejects_unknown_value_kind()
  invalidCode(
    "SCRIPT_INVALID_REFERENCE",
    { api = 1, id = "x", steps = { S.setVar({ variable = "VAR_A", value = { value = "heap_pointer" } }) } }
  )
end

-- PlaySE/StopSE/WaitSE read their operand through ScriptGetVar and
-- PlayCry reads both operands that way (scrcmd_sound.c), so the public sound
-- references must accept the scalar/value-reference form like PlayFanfare.
function T.accepts_value_reference_sound_and_cry_operands()
  valid({
    api = 1,
    id = "x",
    steps = {
      S.playSound({ sound = S.var("VAR_SE") }),
      S.stopSound({ sound = S.var("VAR_SE") }),
      S.waitSound({ sound = S.var("VAR_SE") }),
      S.playCry({ species = S.var("VAR_SPECIES"), pattern = S.var("VAR_PATTERN") }),
      S.playFanfare({ fanfare = S.var("VAR_FANFARE") }),
      S.stop(),
    },
  })
  valid({
    api = 1,
    id = "x",
    steps = {
      S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
      S.playCry({ species = "SPECIES_CYNDAQUIL", pattern = 0 }),
      S.stop(),
    },
  })
end

-- The StopBGM operand is an erasure at lowering (ScrCmd_StopBGM ignores
-- its operand and stops the currently playing BGM), so the semantic
-- operation takes no fields: an optional music field would be advertised
-- and ignored.
function T.stop_music_takes_no_operand()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { { op = "stop_music", music = "SEQ_GS_NEW_BARK" } },
  })
  valid({
    api = 1,
    id = "x",
    steps = { { op = "stop_music" } },
  })
end

-- Numeric world ids are valid in id_or_var positions (the world store is
-- U16-keyed and catalog symbols resolve to those ids; a mod's scratch
-- variables beyond the catalog must be addressable by id).
function T.accepts_numeric_world_ids()
  valid({ api = 1, id = "x", steps = { S.setVar({ variable = 16416, value = 1 }), S.stop() } })
  valid({ api = 1, id = "x", steps = { S.setFlag({ flag = 0x3F3 }), S.stop() } })
end

function T.rejects_malformed_numeric_world_ids()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = 1.5, value = 1 }), S.stop() },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = -1, value = 1 }), S.stop() },
  })
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = 0x10000, value = 1 }), S.stop() },
  })
end

function T.rejects_malformed_value_reference()
  invalidCode(
    "SCRIPT_SCHEMA_INVALID",
    { api = 1, id = "x", steps = { S.setVar({ variable = "VAR_A", value = { other = 1 } }) } }
  )
end

function T.rejects_unknown_condition_kind()
  invalidCode("SCRIPT_INVALID_REFERENCE", {
    api = 1,
    id = "x",
    steps = { S.if_({ condition = { condition = "scripted_fate" }, yes = {}, no = {} }) },
  })
end

function T.rejects_bad_compare_operator()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = {
      S.if_({ condition = { condition = "compare", operator = "approx", left = 1, right = 2 }, yes = {}, no = {} }),
    },
  })
end

function T.rejects_invalid_actor_reference()
  invalidCode(
    "SCRIPT_SCHEMA_INVALID",
    { api = 1, id = "x", steps = { S.showObject({ actor = { ref = "actor", special = "the_void" } }) } }
  )
  invalidCode(
    "SCRIPT_INVALID_REFERENCE",
    { api = 1, id = "x", steps = { S.showObject({ actor = { ref = "prop", id = "sign" } }) } }
  )
end

function T.rejects_invalid_movement_action()
  invalidCode("SCRIPT_UNKNOWN_OPERATION", {
    api = 1,
    id = "x",
    steps = { S.applyMovement({ actor = "elm", movement = { { action = "moonwalk", count = 1 } } }) },
  })
end

function T.rejects_invalid_message_reference()
  local err = invalidCode(
    "SCRIPT_INVALID_REFERENCE",
    { api = 1, id = "x", steps = { S.say({ message = { text = "species_name", value = "SPECIES_PIKACHU" } }) } }
  )
  Assert.equal(err.context.path, "steps/0/message")
end

function T.rejects_bad_switch_cases()
  invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "x",
    steps = { S.switch({ value = S.var("v"), cases = { [0] = { { op = "stop" } }, a = {} } }) },
  })
end

function T.error_contexts_carry_path_and_script_id()
  local err = invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "new_bark.lab_sign",
    steps = {
      S.say({ message = "msg.hgss.0543.00097" }),
      S.if_({
        condition = S.flag("FLAG_MET_ELM"),
        yes = { { op = "face", actor = "elm", direction = "northwest" } },
        no = {},
      }),
    },
  })
  Assert.equal(err.context.scriptId, "new_bark.lab_sign")
  Assert.equal(err.context.path, "steps/1/yes/0/direction")
end

-- Exit criterion: load, normalize, validate, print — deterministically, with
-- no game session. LuaWriter output must reload to the same validated script.
function T.script_loads_validates_and_prints_round_trip()
  for _, script in ipairs({ womanScript(), signScript() }) do
    valid(script)
    local printed = LuaWriter.encode(script)
    local chunk = assert(loadstring(printed), "printed script must compile")
    local loaded = chunk()
    Assert.deepEqual(loaded, script)
    valid(loaded)
  end
end

function T.constructor_and_direct_table_forms_print_identically()
  local constructorForm = S.script({
    api = 1,
    id = "x",
    steps = { S.say({ message = "msg.hgss.0543.00097" }) },
  })
  local directForm = {
    kind = "field_script",
    api = 1,
    id = "x",
    steps = {
      {
        op = "say",
        message = "msg.hgss.0543.00097",
        bindings = {},
      },
    },
  }
  valid(constructorForm)
  valid(directForm)
  Assert.equal(LuaWriter.encode(constructorForm), LuaWriter.encode(directForm))
end

-- Validation state (script id, collected locals/args) must be per call. The
-- only way one call can observe another is a nested call running while the
-- outer call is mid-flight, so these tests interleave a second validation
-- through a debug count hook fired inside the outer call's `collectRefs`
-- (the point where the outer has already collected its local and arg usages).
-- The nested call is plain and must pass; the outer script
-- uses an undeclared local/arg and must still fail on its own merits. With
-- module-global state the nested call's reset wipes the outer's collections,
-- so the outer call wrongly succeeds and its error context reports the
-- nested script's id.
---@param outerScript table
---@param nestedScript table
---@return boolean|nil ok
---@return Errors.Error|nil err
local function validateWithNestedCall(outerScript, nestedScript)
  local nestedRan = false
  local nestedOk ---@type boolean|nil
  local nestedErr = nil
  local function hook()
    if nestedRan then
      return
    end
    local info = debug.getinfo(2, "n")
    if info and info.name == "collectRefs" then
      nestedRan = true
      nestedOk, nestedErr = Validator.validate(nestedScript)
    end
  end
  debug.sethook(hook, "", 1)
  local ok, err = Validator.validate(outerScript)
  debug.sethook()
  Assert.isTrue(nestedRan, "interleaving hook never fired; the contract is not being exercised")
  Assert.isTrue(nestedOk, "nested validation must pass: " .. tostring(nestedErr))
  return ok, err
end

function T.nested_validation_cannot_wipe_outer_collected_locals()
  local ok, err = validateWithNestedCall({
    api = 1,
    id = "outer.script",
    steps = { { op = "set_local", name = "route", value = "intro" } },
  }, { api = 1, id = "nested.script", steps = { { op = "stop" } } })
  Assert.isNil(ok, "outer call must fail: the nested call must not erase its collected locals")
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_SCHEMA_INVALID")
  Assert.equal(err.context.scriptId, "outer.script")
  Assert.equal(err.context.path, "steps/0")
  Assert.equal(err.context.name, "route")
end

function T.nested_validation_cannot_wipe_outer_collected_args()
  local ok, err = validateWithNestedCall({
    api = 1,
    id = "outer.script",
    steps = { { op = "say", message = { value = "arg", name = "text" } } },
  }, { api = 1, id = "nested.script", steps = { { op = "stop" } } })
  Assert.isNil(ok, "outer call must fail: the nested call must not erase its collected args")
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_SCHEMA_INVALID")
  Assert.equal(err.context.scriptId, "outer.script")
  Assert.equal(err.context.name, "text")
end

-- Ordinary consecutive calls never share script id or collected locals/args:
-- a failed call's dirty state must not leak into the next call's error
-- context. Validation is strict-only, so no call can weaken a later one.
function T.sequential_validation_calls_stay_isolated()
  local err1 = invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "first.script",
    steps = { S.setLocal({ name = "route", value = "intro" }) },
  })
  Assert.equal(err1.context.scriptId, "first.script")
  Assert.equal(err1.context.name, "route")

  local err2 = invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "second.script",
    steps = { { op = "stop", surprise = true } },
  })
  Assert.equal(err2.context.scriptId, "second.script")
  Assert.equal(err2.context.field, "surprise")

  valid({
    api = 1,
    id = "third.script",
    steps = { { op = "stop" } },
  })
  local err3 = invalidCode("SCRIPT_SCHEMA_INVALID", {
    api = 1,
    id = "fourth.script",
    steps = { { op = "stop", surprise = true } },
  })
  Assert.equal(err3.context.scriptId, "fourth.script")
end

return { tests = T }
