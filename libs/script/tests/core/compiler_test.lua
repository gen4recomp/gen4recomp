-- Compiler and graph tests. They pin the internal graph contract: node IDs
-- (key/src/path forms), resolved control edges, the semantic revision hash,
-- load-time structural validation, warnings, and deterministic inspection.
-- Deep-copy isolation from the authoring input is pinned in graph_test.
-- Every supported authoring construct compiles to a deterministic graph.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Compiler = require("libs.script.src.Compiler")
local Graph = require("libs.script.src.Graph")
local Sha256 = require("libs.script.src.Sha256")

local T = {}

function T.compiles_semantic_choose_as_one_runtime_node()
  local graph = assert(Compiler.compile(S.script({
    api = 1,
    id = "mod.example.choose",
    steps = {
      S.choose({
        items = { S.choice("msg.project.take", 10), S.choice("msg.project.leave", 20) },
        result = S.var("choice"),
      }),
    },
  })))
  local node = graph.nodes[graph.entry]
  Assert.equal(node.op, "choose")
  Assert.equal(node.items[2].value, 20)
  Assert.equal(node.placement.mode, "auto")
end

function T.compiles_the_public_semantic_menu_example()
  local script = require("data.scripts.examples.semantic_menu")
  local graph = assert(Compiler.compile(script))
  Assert.equal(graph.nodes[graph.entry].op, "choose")
end

---@param script table
---@param opts table?
---@return table
local function compile(script, opts)
  local graph, err = Compiler.compile(script, opts)
  if not graph then
    error("compile failed: " .. tostring(err))
  end
  return graph
end

---@param code string
---@param script any
---@param opts table|nil
---@return Errors.Error
local function compileError(code, script, opts)
  local graph, err = Compiler.compile(script, opts)
  Assert.isNil(graph)
  Assert.isTrue(Errors.is(err), "expected Errors object, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
  return err
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

-- Every-op sweep: one step per canonical operation plus a label pair for
-- local control targets. Compiles with wrapper permission for `next`.
local function allOpsScript()
  local steps = {
    S.noop(),
    S.waitTicks({ ticks = 2 }),
    S.if_({ condition = S.flag("FLAG_F"), yes = { S.next() }, no = { S.noop() } }),
    S.switch({ value = S.var("VAR_V"), cases = { [0] = { S.noop() } }, default = { S.noop(), S.stop() } }),
    S.call({ target = "sub" }),
    S.callCommon({ target = "common.example" }),
    S.compare({ left = 1, right = 2 }),
    S.setFlag({ flag = "FLAG_A" }),
    S.clearFlag({ flag = "FLAG_A" }),
    S.setVar({ variable = "VAR_A", value = 1 }),
    S.copyVar({ destination = "VAR_B", source = "VAR_A" }),
    S.addVar({ variable = "VAR_A", amount = 1 }),
    S.subVar({ variable = "VAR_A", amount = 1 }),
    S.setLocal({ name = "route", value = "intro" }),
    S.copyLocal({ destination = "r2", source = "route" }),
    S.addLocal({ name = "counter", amount = 1 }),
    S.subLocal({ name = "counter", amount = 1 }),
    S.say({ message = "msg.x" }),
    S.openMessage(),
    S.message({ message = "msg.y", waitForPrint = true }),
    S.waitInput(),
    S.waitInputOrTicks({ ticks = 3 }),
    S.closeMessage(),
    S.holdMessage(),
    S.askYesNo({ result = S.local_("yn") }),
    S.bufferText({ slot = 0, value = S.playerName() }),
    S.showWaitingIcon(),
    S.hideWaitingIcon(),
    S.lockPlayer(),
    S.releasePlayer(),
    S.lockAll(),
    S.releaseAll(),
    S.lockActor({ actor = "elm" }),
    S.releaseActor({ actor = "elm" }),
    S.facePlayer({}),
    S.face({ actor = "elm", direction = "south" }),
    S.showObject({ actor = "elm" }),
    S.hideObject({ actor = "elm" }),
    S.setObjectPosition({ actor = "elm", fieldX = 4, fieldZ = 5 }),
    S.setObjectFacing({ actor = "elm", direction = "north" }),
    S.setObjectMovementType({ actor = "elm", movementType = "stationary" }),
    S.getPlayerCoords({ x = S.local_("px"), z = S.local_("pz") }),
    S.getObjectCoords({ actor = "elm", x = S.local_("ex"), z = S.local_("ez") }),
    S.getPlayerFacing({ result = S.local_("pf") }),
    S.applyMovement({ actor = "elm", movement = { S.m.walk({ direction = "south", speed = "normal", tiles = 2 }) } }),
    S.waitMovement(),
    S.move({ actor = "elm", movement = { S.m.face({ direction = "north" }) } }),
    S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.stopSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.waitSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.playCry({ species = S.var("species"), pattern = 0 }),
    S.waitCry(),
    S.playFanfare({ fanfare = "SEQ_ME_POKEGET" }),
    S.waitFanfare(),
    S.playMusic({ music = "SEQ_GS_NEW_BARK" }),
    S.stopMusic(),
    S.resetMusic(),
    S.temporaryMusic({ music = "SEQ_GS_EVENT" }),
    S.fadeMusicOut({ target = 0, durationTicks = 30 }),
    S.fadeMusicIn({ durationTicks = 30 }),
    S.processSoundplate(),
    S.fadeScreen({ duration = 6, speed = 1, direction = "out", color = "black" }),
    S.waitFade(),
    S.warp({ map = "MAP_NEW_BARK", warp = 0, fieldX = 684, fieldZ = 393, facing = "south" }),
    S.setSpawn({ spawn = "SPAWN_NEW_BARK" }),
    S.shakeCamera({ amplitudeX = 2, amplitudeY = 0, intervalTicks = 2, count = 8 }),
    S.random({ maxExclusive = 10, result = S.local_("roll") }),
    S.unsupported({
      command = 0x017A,
      originalName = "ScrCmd_378",
      arguments = { 4, 0x800C },
      sourceOffset = 0x92,
      reason = "no semantic adapter",
    }),
    S.yieldTick(),
    S.gotoIf({ condition = S.flag("FLAG_F"), target = "sub" }),
    S.gotoCompared({ operator = "eq", target = "sub" }),
    S.goto_({ target = "sub" }),
    S.label({ name = "sub" }),
    S.callCompared({ operator = "ne", target = "sub2" }),
    S.label({ name = "sub2" }),
    S.return_({}),
  }
  return S.script({
    api = 1,
    id = "sweep.every_op",
    metadata = { generated = true },
    locals = {
      route = "string",
      r2 = "string",
      counter = "integer",
      yn = "bool",
      px = "integer",
      pz = "integer",
      ex = "integer",
      ez = "integer",
      pf = "id",
      roll = "integer",
      starter = "serializable",
    },
    steps = steps,
  })
end

-- --- Sha256 wrapper ---
--
-- The digest itself is the platform's job: Sha256.hex delegates to
-- love.data.hash, which is byte-identical to the pure-Lua implementation it
-- replaced on the FIPS 180-4 vectors ("", "abc", the fox sentence, and
-- "a" x 100000). This single test
-- pins the wrapper's own contract: lowercase 64-char hex output.

function T.sha256_wrapper_emits_lowercase_hex()
  Assert.equal(Sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end

-- --- Basic compilation ---

function T.flat_sequence_compiles_to_linear_graph()
  local graph = compile(signScript())
  Assert.equal(graph.graphSchema, "g4-script-graph-v1")
  Assert.equal(graph.api, 1)
  Assert.equal(graph.scriptId, "new_bark.lab_sign")
  Assert.equal(graph.entry, "path:steps/0")
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "play_sound",
    sound = "SEQ_SE_DP_SELECT",
    next = "path:steps/1",
  })
  Assert.deepEqual(graph.nodes["path:steps/1"], {
    op = "lock_all",
    next = "path:steps/2",
  })
  Assert.deepEqual(graph.nodes["path:steps/2"], {
    op = "say",
    message = "msg.hgss.0543.00097",
    bindings = {},
    next = "path:steps/3",
  })
  Assert.deepEqual(graph.nodes["path:steps/3"], { op = "release_all" })
end

function T.nested_if_compiles_branches()
  local graph = compile(womanScript())
  Assert.equal(graph.entry, "path:steps/0")
  Assert.deepEqual(graph.nodes["path:steps/3"], {
    op = "if",
    condition = {
      condition = "compare",
      operator = "eq",
      left = { value = "var", id = "VAR_SCENE_NEW_BARK_TOWN_OW" },
      right = 0,
    },
    yes = "path:steps/3/yes/0",
    no = "path:steps/3/no/0",
  })
  Assert.deepEqual(graph.nodes["path:steps/3/no/0/no/0"], {
    op = "if",
    condition = {
      condition = "compare",
      operator = "eq",
      left = { value = "var", id = "VAR_SCENE_NEW_BARK_WEST_EXIT" },
      right = 1,
    },
    yes = "path:steps/3/no/0/no/0/yes/0",
    no = "path:steps/3/no/0/no/0/no/0",
  })
  -- Every branch tail continues at the step after the outermost if.
  Assert.equal(graph.nodes["path:steps/3/yes/0"].next, "path:steps/4")
  Assert.equal(graph.nodes["path:steps/3/no/0/no/0/no/1"].next, "path:steps/4")
  Assert.equal(graph.nodes["path:steps/4"].op, "release_all")
end

function T.switch_compiles_cases_and_default()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.switch({
        value = S.var("VAR_V"),
        cases = { [0] = { S.noop() }, [2] = { S.noop() } },
        default = { S.noop() },
      }),
      S.setVar({ variable = "VAR_A", value = 9 }),
    },
  }))
  local node = graph.nodes["path:steps/0"]
  Assert.equal(node.op, "switch")
  Assert.equal(node.value.value, "var")
  Assert.equal(node.cases[0], "path:steps/0/0/0")
  Assert.equal(node.cases[2], "path:steps/0/2/0")
  Assert.equal(node.default, "path:steps/0/default/0")
  Assert.equal(graph.nodes["path:steps/0/0/0"].next, "path:steps/1")
  Assert.equal(graph.nodes["path:steps/0/default/0"].next, "path:steps/1")
end

function T.if_without_else_falls_through()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "if", condition = S.flag("FLAG_F"), yes = { S.noop() } },
      S.setVar({ variable = "VAR_A", value = 1 }),
    },
  }))
  local node = graph.nodes["path:steps/0"]
  Assert.equal(node.yes, "path:steps/0/yes/0")
  Assert.equal(node.no, "path:steps/1")
end

-- --- Local calls and labels ---

function T.call_to_local_label_resolves_target_node()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.call({ target = "sub" }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.label({ name = "sub" }),
      S.setFlag({ flag = "FLAG_X" }),
      S.return_({}),
    },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "call",
    target = "sub",
    args = {},
    targetNode = "path:steps/2",
    returnNode = "path:steps/1",
  })
  Assert.deepEqual(graph.nodes["path:steps/2"], {
    op = "label",
    name = "sub",
    next = "path:steps/3",
  })
  Assert.deepEqual(graph.nodes["path:steps/4"], { op = "return" })
end

function T.call_to_external_target_stays_a_script_id()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = { S.call({ target = "common.give_item_verbose", args = { item = "ITEM_POTION", quantity = 1 } }) },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "call",
    target = "common.give_item_verbose",
    args = { item = "ITEM_POTION", quantity = 1 },
  })
end

function T.goto_and_goto_if_resolve_label_targets()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.goto_({ target = "end" }),
      S.gotoIf({ condition = S.flag("FLAG_F"), target = "end" }),
      S.label({ name = "end" }),
      S.stop(),
    },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "goto",
    target = "end",
    targetNode = "path:steps/2",
  })
  Assert.deepEqual(graph.nodes["path:steps/1"], {
    op = "goto_if",
    condition = { condition = "flag", id = "FLAG_F", expected = true },
    target = "end",
    targetNode = "path:steps/2",
    next = "path:steps/2",
  })
end

function T.missing_goto_label_raises()
  compileError(
    "SCRIPT_LABEL_MISSING",
    S.script({
      api = 1,
      id = "x",
      steps = { S.goto_({ target = "nowhere" }) },
    })
  )
  compileError(
    "SCRIPT_LABEL_MISSING",
    S.script({
      api = 1,
      id = "x",
      steps = { S.gotoIf({ condition = S.flag("FLAG_F"), target = "nowhere" }) },
    })
  )
end

function T.duplicate_label_raises()
  local err = compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        S.label({ name = "a" }),
        S.goto_({ target = "skip" }),
        S.label({ name = "a" }),
        S.label({ name = "skip" }),
        S.stop(),
      },
    })
  )
  Assert.equal(err.context.label, "a")
end

-- A label inside `switch.default` is registrable: a goto targeting it
-- resolves to the default branch.
function T.switch_default_label_is_targetable()
  local graph = compile(S.script({
    api = 1,
    id = "test.switch_default_label",
    steps = {
      S.switch({
        value = S.var("VAR_SCENE"),
        cases = { [0] = { S.noop() } },
        default = {
          S.label({ name = "default_tail" }),
          S.stop(),
        },
      }),
      S.goto_({ target = "default_tail" }),
      S.stop(),
    },
  }))
  local labelId = assert(graph.labels.default_tail)
  local node = assert(graph.nodes[labelId], "the label node must exist in the graph")
  Assert.equal(node.op, "label")
end

-- A provenance-derived label must be registered and emitted under the very
-- same node ID: the old prewalk consumed the provenance suffix counter, so
-- compilation emitted the label under a suffixed second id while labels and
-- goto edges referenced the base id (a dangling edge).
function T.provenance_label_node_id_matches_its_emitted_node()
  local graph = compile(S.script({
    api = 1,
    id = "elms_lab.generated.script_001",
    metadata = {
      generated = true,
      source = {
        repository = "pret/pokeheartgold",
        commit = "c",
        path = "p",
        game = "heartgold",
        archive = "scr_seq",
        member = 843,
        scriptIndex = 9,
        sourceHash = "h",
      },
    },
    steps = {
      { op = "goto", target = "loop", provenance = { offsets = { 0x00 }, opcodes = { 18 } } },
      { op = "label", name = "loop", provenance = { offsets = { 0x04 }, opcodes = { 19 } } },
      { op = "stop", provenance = { offsets = { 0x08 }, opcodes = { 20 } } },
    },
  }))
  local labelId = assert(graph.labels.loop)
  local labelNode = assert(graph.nodes[labelId], "the registered label id must reference an emitted node")
  Assert.equal(labelNode.op, "label")
  Assert.equal(graph.nodes[graph.entry].targetNode, labelId, "the goto edge and the label node share one id")
end

function T.wrapper_next_requires_registration()
  compileError(
    "SCRIPT_WRAPPER_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = { S.next() },
    })
  )
  local graph = compile(
    S.script({
      api = 1,
      id = "x",
      steps = { S.next() },
    }),
    { allowNext = true }
  )
  Assert.isTrue(graph.usesNext)
  Assert.deepEqual(graph.nodes["path:steps/0"], { op = "next" })
end

-- --- Node IDs ---

function T.author_key_overrides_node_id()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "set_var", variable = "VAR_A", value = 1, key = "after_intro" },
      S.stop(),
    },
  }))
  Assert.equal(graph.nodes["key:after_intro"].op, "set_var")
  Assert.equal(graph.entry, "key:after_intro")
  Assert.equal(graph.nodes["key:after_intro"].next, "path:steps/1")
end

function T.duplicate_key_raises()
  compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        { op = "noop", key = "dup" },
        { op = "noop", key = "dup" },
      },
    })
  )
end

function T.generated_node_ids_use_source_provenance()
  local graph = compile(S.script({
    api = 1,
    id = "elms_lab.generated.script_000",
    metadata = {
      generated = true,
      source = {
        repository = "pret/pokeheartgold",
        commit = "dfdbbdf3273545ca35456d69bcb0ee3403f76450",
        path = "files/fielddata/script/scr_seq/scr_seq_0843_T20R0101.s",
        game = "heartgold",
        archive = "scr_seq",
        member = 843,
        scriptIndex = 9,
        sourceHash = "h",
      },
    },
    steps = {
      { op = "play_sound", sound = "SEQ_SE_DP_SELECT", provenance = { offsets = { 0x00 }, opcodes = { 73 } } },
      {
        op = "say",
        message = "msg.hgss.0543.00097",
        provenance = { offsets = { 0x04, 0x08, 0x0C }, opcodes = { 45, 50, 53 } },
      },
    },
  }))
  Assert.equal(graph.entry, "src:0843:009:0000")
  Assert.equal(graph.nodes["src:0843:009:0000"].sound, "SEQ_SE_DP_SELECT")
  Assert.equal(graph.nodes["src:0843:009:0004/say"].op, "say")
  Assert.deepEqual(
    graph.nodes["src:0843:009:0004/say"].source,
    { offsets = { 0x04, 0x08, 0x0C }, opcodes = { 45, 50, 53 } }
  )
end

function T.step_provenance_without_member_metadata_raises()
  compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = {
        { op = "play_sound", sound = "SEQ_SE_DP_SELECT", provenance = { offsets = { 0x00 }, opcodes = { 73 } } },
      },
    })
  )
end

-- --- Normalization ---

function T.direct_and_constructor_forms_compile_identically()
  local constructorForm = S.script({
    api = 1,
    id = "x",
    steps = { S.waitInput() },
  })
  local directForm = {
    kind = "field_script",
    api = 1,
    id = "x",
    steps = { { op = "wait_input" } },
  }
  local g1 = compile(constructorForm)
  local g2 = compile(directForm)
  Assert.deepEqual(g1.nodes, g2.nodes)
  Assert.equal(g1.revision, g2.revision)
end

function T.defaults_are_normalized_into_nodes()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = { { op = "wait_input" } },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"], {
    op = "wait_input",
    buttons = { "a", "b" },
    allowDpad = false,
    turnPlayerOnDpad = false,
  })
end

function T.string_actors_normalize_to_references()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "face_player", actor = "self" },
      { op = "face", actor = "elm", direction = "south" },
    },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"].actor, { ref = "actor", special = "self" })
  Assert.deepEqual(graph.nodes["path:steps/1"].actor, { ref = "actor", id = "elm" })
end

function T.condition_defaults_normalize()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "if", condition = S.flag("FLAG_F"), yes = { S.noop() } },
    },
  }))
  Assert.deepEqual(graph.nodes["path:steps/0"].condition, { condition = "flag", id = "FLAG_F", expected = true })
end

-- --- Revision hash ---

-- The revision covers the serialized projection, whose node map is keyed
-- by node ID. Generated `src:` node IDs embed provenance-derived identity
-- (metadata.source member/scriptIndex and provenance.offsets[1]) and `key:`
-- node IDs embed the author key, so edits to those fields change the
-- revision for nodes of that kind. Only the node `source` payload (opcodes
-- etc.) and the non-identity metadata fields are excluded. The tests below
-- pin that actual contract.

-- One generated two-step script whose provenance/metadata dimensions can be
-- varied one at a time, so each revision change is attributable to exactly
-- the varied dimension.
---@param overrides { source: table|nil, step1: table|nil, coverage: table|nil }|nil
---@return table
local function generatedScript(overrides)
  overrides = overrides or {}
  local source = {
    repository = "pret/pokeheartgold",
    commit = "dfdb",
    path = "files/fielddata/script/scr_seq/scr_seq_0843_T20R0101.s",
    game = "heartgold",
    archive = "scr_seq",
    member = 843,
    scriptIndex = 9,
    sourceHash = "h1",
  }
  local coverage = { complete = true, unsupportedCount = 0 }
  local steps = {
    { op = "play_sound", sound = "SEQ_SE_DP_SELECT", provenance = { offsets = { 0x00 }, opcodes = { 73 } } },
    {
      op = "say",
      message = "msg.hgss.0543.00097",
      provenance = { offsets = { 0x04, 0x08, 0x0C }, opcodes = { 45, 50, 53 } },
    },
  }
  if overrides.source then
    for k, v in pairs(overrides.source) do
      source[k] = v
    end
  end
  if overrides.coverage then
    coverage = overrides.coverage
  end
  if overrides.step1 then
    for k, v in pairs(overrides.step1) do
      steps[1][k] = v
    end
  end
  return S.script({
    api = 1,
    id = "new_bark.lab_sign",
    metadata = { generated = true, source = source, coverage = coverage },
    steps = steps,
  })
end

function T.compile_is_deterministic()
  local g1 = compile(signScript())
  local g2 = compile(signScript())
  Assert.equal(g1.revision, g2.revision)
  Assert.deepEqual(g1.nodes, g2.nodes)
  Assert.equal(#g1.revision, 64)
end

function T.metadata_source_and_coverage_edits_do_not_change_the_revision()
  local base = compile(generatedScript())
  local edited = compile(generatedScript({
    source = { commit = "OTHER-COMMIT", path = "some/other/path.s", sourceHash = "h2" },
    coverage = { complete = false, unsupportedCount = 1 },
  }))
  Assert.equal(base.revision, edited.revision)
end

-- Provenance offsets drive the `src:` node IDs, and the projection is keyed
-- by node ID: moving a step's source offset changes the revision even though
-- every semantic field is unchanged.
function T.provenance_offset_edits_change_the_revision()
  local base = compile(generatedScript())
  local shifted = compile(generatedScript({ step1 = { provenance = { offsets = { 0x10 }, opcodes = { 73 } } } }))
  Assert.isFalse(base.revision == shifted.revision, "offset edit must change the revision")
end

-- metadata.source member/scriptIndex are embedded in `src:` node IDs, so they
-- are revision inputs like offsets, not excluded metadata.
function T.metadata_source_identity_edits_change_the_revision()
  local base = compile(generatedScript())
  local member = compile(generatedScript({ source = { member = 844 } }))
  local scriptIndex = compile(generatedScript({ source = { scriptIndex = 10 } }))
  Assert.isFalse(base.revision == member.revision, "member edit must change the revision")
  Assert.isFalse(base.revision == scriptIndex.revision, "scriptIndex edit must change the revision")
end

-- An author `key` becomes the node ID (`key:<key>`), so it is revision input.
function T.author_key_edits_change_the_revision()
  local function keyed(key)
    return S.script({
      api = 1,
      id = "x",
      steps = {
        { op = "noop", key = key },
      },
    })
  end
  Assert.isFalse(
    compile(keyed("first")).revision == compile(keyed("second")).revision,
    "author key edit must change the revision"
  )
end

-- The node `source` payload (provenance opcodes etc.) is the one provenance
-- channel the projection excludes: edits that keep the same node IDs leave
-- the revision untouched.
function T.provenance_payload_edits_keep_the_revision()
  local base = compile(generatedScript())
  local opcodes = compile(generatedScript({ step1 = { provenance = { offsets = { 0x00 }, opcodes = { 99 } } } }))
  Assert.equal(base.revision, opcodes.revision, "opcode-only edit must not change the revision")
end

-- `copy_var` owns the `source` operand name, but the compiler maps step
-- provenance onto the node `source` field for provenance-carrying steps.
-- The generated common.signpost resource carries both on its copy_var
-- steps: the compiled node must keep the var-ref operand, never the
-- provenance payload (clobbering it faults the runtime handler with
-- EVENT_VAR_ID_INVALID when the operand table reaches WorldState).
function T.provenance_must_not_clobber_a_copy_var_source_operand()
  local graph = compile(S.script({
    api = 1,
    id = "common.signpost",
    metadata = {
      generated = true,
      source = {
        repository = "g4recomp",
        path = "romfs/a/0/1/2",
        game = "heartgold",
        archive = "scr_seq",
        member = 3,
        scriptIndex = 0,
      },
    },
    steps = {
      {
        op = "copy_var",
        destination = { id = "VAR_SPECIAL_x8008", value = "var" },
        source = { id = "VAR_SPECIAL_RESULT", value = "var" },
        provenance = { offsets = { 1176 }, opcodes = { 42 } },
      },
      S.stop(),
    },
  }))
  local node = graph.nodes[graph.entry]
  Assert.equal(node.op, "copy_var")
  Assert.deepEqual(node.source, { id = "VAR_SPECIAL_RESULT", value = "var" })
end

-- copy_var's `source` is a real semantic operand, not a provenance payload:
-- an edit to it must change the revision like any operand (the projection
-- excludes only the provenance payload channel, never operands).
function T.copy_var_source_operand_edits_change_the_revision()
  local function scriptWith(source)
    return S.script({
      api = 1,
      id = "x",
      metadata = { generated = true, source = { member = 3, scriptIndex = 0 } },
      steps = {
        {
          op = "copy_var",
          destination = { id = "VAR_X", value = "var" },
          source = source,
          provenance = { offsets = { 4 }, opcodes = { 42 } },
        },
        S.stop(),
      },
    })
  end
  local a = compile(scriptWith({ id = "VAR_A", value = "var" }))
  local b = compile(scriptWith({ id = "VAR_B", value = "var" }))
  Assert.isFalse(a.revision == b.revision, "copy_var source operand edit must change the revision")
end

function T.semantic_edits_change_revision()
  local base = S.script({
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = "VAR_A", value = 1 }), S.setFlag({ flag = "FLAG_X" }) },
  })
  local g1 = compile(base)

  local value = S.script({
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = "VAR_A", value = 2 }), S.setFlag({ flag = "FLAG_X" }) },
  })
  Assert.isFalse(g1.revision == compile(value).revision, "operand change must change revision")

  local op = S.script({
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = "VAR_A", value = 1 }), S.clearFlag({ flag = "FLAG_X" }) },
  })
  Assert.isFalse(g1.revision == compile(op).revision, "op change must change revision")

  local added = S.script({
    api = 1,
    id = "x",
    steps = { S.setVar({ variable = "VAR_A", value = 1 }), S.setFlag({ flag = "FLAG_X" }), S.noop() },
  })
  Assert.isFalse(g1.revision == compile(added).revision, "added step must change revision")

  local condition = S.script({
    api = 1,
    id = "x",
    steps = {
      S.if_({ condition = S.eq(S.var("VAR_A"), 1), yes = { S.setVar({ variable = "VAR_A", value = 1 }) } }),
      S.setFlag({ flag = "FLAG_X" }),
    },
  })
  local condition2 = S.script({
    api = 1,
    id = "x",
    steps = {
      S.if_({ condition = S.eq(S.var("VAR_A"), 2), yes = { S.setVar({ variable = "VAR_A", value = 1 }) } }),
      S.setFlag({ flag = "FLAG_X" }),
    },
  })
  Assert.isFalse(compile(condition).revision == compile(condition2).revision, "condition change must change revision")
end

function T.declared_params_and_locals_are_in_the_revision()
  local base = S.script({
    api = 1,
    id = "x",
    params = { professor = "actor_ref" },
    locals = { route = "string" },
    steps = { S.stop() },
  })
  local renamed = S.script({
    api = 1,
    id = "x",
    params = { professor = "actor_ref" },
    locals = { path_ = "string" },
    steps = { S.stop() },
  })
  Assert.isFalse(compile(base).revision == compile(renamed).revision, "declared local change must change revision")
end

-- --- Structural validation ---

function T.compile_propagates_validator_errors()
  compileError(
    "SCRIPT_UNKNOWN_OPERATION",
    S.script({
      api = 1,
      id = "x",
      steps = { { op = "teleport_to_kanto" } },
    })
  )
  compileError(
    "SCRIPT_SCHEMA_INVALID",
    S.script({
      api = 1,
      id = "x",
      steps = { S.stop() },
      metadata = { callback = function() end },
    })
  )
end

-- Recursive local call cycles compile: call targets resolve structurally,
-- and the scheduler's deterministic per-run node budget faults non-yielding
-- recursion at runtime.
function T.recursive_call_cycle_compiles()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.call({ target = "a" }),
      S.label({ name = "a" }),
      S.call({ target = "b" }),
      S.label({ name = "b" }),
      S.call({ target = "a" }),
    },
  }))
  Assert.equal(graph.nodes["path:steps/0"].targetNode, "path:steps/1")
  Assert.equal(graph.nodes["path:steps/2"].targetNode, "path:steps/3")
  Assert.equal(graph.nodes["path:steps/4"].targetNode, "path:steps/1")
end

function T.self_recursive_call_compiles()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.label({ name = "a" }),
      S.call({ target = "a" }),
    },
  }))
  Assert.equal(graph.entry, "path:steps/0")
  Assert.equal(graph.nodes["path:steps/1"].targetNode, "path:steps/0")
end

-- A fallthrough label chain whose tail calls back into its own head is a
-- recursive cycle too; it compiles and the budget decides at runtime.
function T.fallthrough_label_chain_cycle_compiles()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.label({ name = "a" }),
      S.label({ name = "b" }),
      S.call({ target = "a" }),
    },
  }))
  Assert.equal(graph.nodes["path:steps/2"].targetNode, "path:steps/0")
end

-- Call cycles compile with or without blocking ops in the cycle: a
-- two-label cycle through waitTicks subroutines, and a self-call that sits
-- after a stop. The scheduler budget decides at runtime.
function T.recursive_call_cycles_compile_regardless_of_blocking_ops()
  compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.call({ target = "a" }),
      S.label({ name = "a" }),
      S.waitTicks({ ticks = 2 }),
      S.call({ target = "b" }),
      S.label({ name = "b" }),
      S.waitTicks({ ticks = 2 }),
      S.call({ target = "a" }),
    },
  }))
  compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.label({ name = "a" }),
      S.stop(),
      S.call({ target = "a" }),
    },
  }))
end

function T.call_to_later_label_compiles()
  compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.call({ target = "sub" }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.label({ name = "sub" }),
      S.setFlag({ flag = "FLAG_X" }),
      S.return_({}),
    },
  }))
end

function T.maximum_static_nesting_is_enforced()
  local current = { S.noop() }
  for _ = 1, 70 do
    current = { S.if_({ condition = S.flag("FLAG_F"), yes = current }) }
  end
  compileError("SCRIPT_SCHEMA_INVALID", S.script({ api = 1, id = "x", steps = current }))

  local shallow = { S.noop() }
  for _ = 1, 60 do
    shallow = { S.if_({ condition = S.flag("FLAG_F"), yes = shallow }) }
  end
  compile(S.script({ api = 1, id = "x", steps = shallow }))
end

-- --- Unsupported reachability ---

function T.reachable_unsupported_flags_the_graph()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.unsupported({
        command = 0x017A,
        originalName = "ScrCmd_378",
        arguments = { 4, 0x800C },
        sourceOffset = 0x92,
        reason = "no semantic adapter",
      }),
      S.setVar({ variable = "VAR_A", value = 1 }),
    },
  }))
  Assert.isTrue(graph.hasUnsupported)
  Assert.deepEqual(graph.unsupportedNodes, { "path:steps/0" })
end

function T.unreachable_unsupported_does_not_disable_the_graph()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.stop(),
      S.unsupported({ command = 1, originalName = "X", reason = "dead" }),
    },
  }))
  Assert.isFalse(graph.hasUnsupported)
end

function T.unsupported_behind_unconditional_jump_is_ignored()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.goto_({ target = "end" }),
      S.unsupported({ command = 1, originalName = "X", reason = "dead" }),
      S.label({ name = "end" }),
      S.stop(),
    },
  }))
  Assert.isFalse(graph.hasUnsupported)
end

-- --- Warnings ---

local function warningMessages(graph)
  local out = {}
  for _, w in ipairs(graph.warnings) do
    out[#out + 1] = w.nodeId .. ": " .. w.message
  end
  return out
end

local function countNodes(graph)
  local count = 0
  for _ in pairs(graph.nodes) do
    count = count + 1
  end
  return count
end

function T.empty_branches_warn()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      { op = "if", condition = S.flag("FLAG_F"), yes = {}, no = { S.noop() } },
      { op = "switch", value = S.var("VAR_V"), cases = { [0] = {} }, default = { S.noop() } },
    },
  }))
  local warnings = warningMessages(graph)
  Assert.isTrue(#warnings == 2, "expected 2 warnings, got: " .. #warnings)
  Assert.isTrue(warnings[1]:find("empty yes branch") ~= nil, warnings[1])
  Assert.isTrue(warnings[2]:find("empty switch case") ~= nil, warnings[2])
end

function T.unreachable_nodes_warn()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.stop(),
      S.setVar({ variable = "VAR_A", value = 1 }),
    },
  }))
  Assert.deepEqual(warningMessages(graph), { "path:steps/1: unreachable node" })
end

function T.handwritten_fallback_control_warns_but_generated_does_not()
  local function fallbackScript()
    return S.script({
      api = 1,
      id = "x",
      steps = {
        S.goto_({ target = "end" }),
        S.label({ name = "end" }),
        S.stop(),
      },
    })
  end
  local handwritten = compile(fallbackScript())
  Assert.deepEqual(warningMessages(handwritten), {
    "path:steps/0: handwritten script uses label/goto fallback",
    "path:steps/1: handwritten script uses label/goto fallback",
  })

  local generated = compile(S.script({
    api = 1,
    id = "x",
    metadata = { generated = true },
    steps = {
      S.goto_({ target = "end" }),
      S.label({ name = "end" }),
      S.stop(),
    },
  }))
  Assert.equal(#generated.warnings, 0)
end

function T.warnings_are_deterministically_ordered()
  local function script()
    return S.script({
      api = 1,
      id = "x",
      steps = {
        S.stop(),
        S.goto_({ target = "end" }),
        S.label({ name = "end" }),
      },
    })
  end
  local g1 = compile(script())
  local g2 = compile(script())
  Assert.deepEqual(g1.warnings, g2.warnings)
  Assert.equal(Graph.inspect(g1), Graph.inspect(g2))
end

-- --- Graph inspection and the every-op sweep ---

function T.inspect_is_deterministic_and_identifying()
  local g1 = compile(signScript())
  local g2 = compile(signScript())
  Assert.equal(Graph.inspect(g1), Graph.inspect(g2))
  local other = compile(S.script({ api = 1, id = "y", steps = { S.stop() } }))
  Assert.isFalse(Graph.inspect(g1) == Graph.inspect(other))
  Assert.isTrue(Graph.inspect(g1):find('graphSchema = "g4-script-graph-v1"', 1, true) ~= nil)
  Assert.isTrue(Graph.inspect(g1):find(g1.revision) ~= nil)
end

function T.every_supported_operation_compiles_to_a_graph()
  local script = allOpsScript()
  local graph = compile(script, { allowNext = true })
  Assert.equal(countNodes(graph), #script.steps + 5)
  Assert.equal(graph.usesNext, true)
  Assert.equal(graph.hasUnsupported, true)
  Assert.equal(#graph.warnings, 0)
  Assert.equal(graph.entry, "path:steps/0")
  local revisit = compile(allOpsScript(), { allowNext = true })
  Assert.equal(graph.revision, revisit.revision)
end

function T.empty_script_compiles()
  local graph = compile(S.script({ api = 1, id = "x", steps = {} }))
  Assert.isNil(graph.entry)
  Assert.equal(next(graph.nodes), nil)
  Assert.equal(graph.hasUnsupported, false)
end

function T.graph_carries_declarations()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    params = { professor = "actor_ref" },
    locals = { route = "string" },
    steps = { S.stop() },
  }))
  Assert.deepEqual(graph.params, { professor = "actor_ref" })
  Assert.deepEqual(graph.locals, { route = "string" })
end

function T.reachable_nodes_follows_deterministic_order()
  local graph = compile(womanScript())
  local order = Graph.reachableNodes(graph)
  Assert.equal(order[1], graph.entry)
  local seen = {}
  for _, id in ipairs(order) do
    Assert.isNil(seen[id], "reachable order must not repeat nodes")
    seen[id] = true
  end
  Assert.equal(#order, countNodes(graph))
end

-- --- Per-call state isolation ---

-- Compiling script B between two compiles of script A must not leak A's
-- labels, warnings, nodes, used node ids, or wrapper flag into B, nor leave
-- any residue that changes a later A.
function T.compiler_calls_do_not_contaminate_one_another()
  local a = S.script({
    api = 1,
    id = "a",
    steps = {
      S.goto_({ target = "end" }),
      S.label({ name = "end" }),
      S.stop(),
      S.setVar({ variable = "VAR_A", value = 1 }),
    },
  })
  local function b()
    return S.script({
      api = 1,
      id = "b",
      metadata = { generated = true, source = { member = 843, scriptIndex = 9 } },
      steps = {
        { op = "noop", provenance = { offsets = { 0x00 }, opcodes = { 0 } } },
      },
    })
  end
  local g1 = compile(a)
  local gb1 = compile(b())
  local g2 = compile(a)
  local gb2 = compile(b())
  Assert.deepEqual(g1.nodes, g2.nodes)
  Assert.deepEqual(g1.warnings, g2.warnings)
  Assert.deepEqual(g1.labels, g2.labels)
  Assert.equal(g1.revision, g2.revision)
  -- B keeps its own node ids and carries none of A's labels or warnings.
  Assert.equal(gb1.entry, "src:0843:009:0000")
  Assert.equal(gb2.entry, "src:0843:009:0000")
  Assert.equal(next(gb1.labels), nil, "B must not inherit A's labels")
  Assert.equal(next(gb2.labels), nil, "B must not inherit A's labels")
  Assert.equal(#gb1.warnings, 0)
  Assert.equal(#gb2.warnings, 0)
  -- A must not inherit B's provenance-derived nodes.
  Assert.equal(g2.nodes["src:0843:009:0000"], nil, "A must not inherit B's nodes")
  Assert.deepEqual(gb1.nodes, gb2.nodes)
end

-- A failed call must not leave its opts or partial state for the next call:
-- wrapper registration is per invocation.
function T.failed_compile_does_not_contaminate_later_calls()
  local script = S.script({ api = 1, id = "x", steps = { S.next() } })
  compileError("SCRIPT_WRAPPER_INVALID", script)
  local graph = compile(script, { allowNext = true })
  Assert.isTrue(graph.usesNext)
  compileError("SCRIPT_WRAPPER_INVALID", script)
end

-- The provenance node-id dedup counter starts fresh per call, so identical
-- generated scripts compile to identical ids every time.
function T.used_node_ids_reset_per_call()
  local function generated()
    return S.script({
      api = 1,
      id = "x",
      metadata = { generated = true, source = { member = 843, scriptIndex = 9 } },
      steps = {
        { op = "noop", provenance = { offsets = { 0x00 }, opcodes = { 0 } } },
      },
    })
  end
  local g1 = compile(generated())
  local g2 = compile(generated())
  Assert.equal(g1.entry, "src:0843:009:0000")
  Assert.equal(g2.entry, "src:0843:009:0000")
  Assert.deepEqual(g1.nodes, g2.nodes)
  Assert.equal(g1.revision, g2.revision)
end

-- opts is the one unvalidated compiler input: a metatable on opts can trigger
-- a nested compile while the outer compile is mid-flight. Compiler state must
-- be per call, so neither graph can absorb the other's nodes.
function T.reentrant_compile_does_not_contaminate_either_graph()
  local outer = S.script({
    api = 1,
    id = "outer",
    steps = { S.next(), S.setFlag({ flag = "FLAG_F" }) },
  })
  local inner = S.script({
    api = 1,
    id = "inner",
    steps = { S.setVar({ variable = "VAR_A", value = 1 }) },
  })
  local captured = {}
  local opts = setmetatable({}, {
    __index = function()
      captured.graph = compile(inner)
      return true
    end,
  })
  local graph = compile(outer, opts)
  Assert.isTrue(captured.graph ~= nil, "nested compile must have run")
  Assert.isTrue(graph.usesNext)
  Assert.deepEqual(graph.nodes["path:steps/0"], { op = "next" })
  Assert.deepEqual(graph.nodes["path:steps/1"], { op = "set_flag", flag = "FLAG_F" })
  Assert.deepEqual(captured.graph.nodes["path:steps/0"], { op = "set_var", variable = "VAR_A", value = 1 })
end

function T.process_soundplate_compiles_with_a_linear_next_edge()
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.processSoundplate(),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    },
  }))
  Assert.equal(graph.entry, "path:steps/0")
  Assert.equal(graph.nodes["path:steps/0"].op, "process_soundplate")
  Assert.equal(graph.nodes["path:steps/0"].next, "path:steps/1")
  Assert.equal(graph.nodes["path:steps/1"].op, "set_var")
end

function T.process_soundplate_is_not_in_terminator_or_no_chain_tables()
  -- process_soundplate must not be a terminator: it compiles with a next edge
  -- like other same-tick audio ops, not like stop/signal_caller.
  local graph = compile(S.script({
    api = 1,
    id = "x",
    steps = {
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.processSoundplate(),
      S.setVar({ variable = "VAR_B", value = 2 }),
      S.stop(),
    },
  }))
  Assert.equal(graph.nodes["path:steps/1"].op, "process_soundplate")
  Assert.notNil(graph.nodes["path:steps/1"].next, "process_soundplate must carry a next edge")
end

return { tests = T }
