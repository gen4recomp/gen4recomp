-- Data-level validation for gen4 field-script resources, API 1. The validator
-- checks the script resource schema, API version, serializability (no
-- functions, userdata, threads, metatables, cycles, or non-finite numbers),
-- operation field shapes, enum values, reference forms, and declared
-- locals/args. It never executes gameplay and never mutates its input.
-- Graph-level checks (labels, call targets, reachability, lock balance) belong
-- to the compiler. Validation is strict-only: unknown fields are rejected
-- unconditionally.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local Schema = require("libs.script.src.Schema")

local Validator = {}

-- Validation state (script id, collected locals/args) is local to each
-- `_validate` call: the call builds a context table and threads it through
-- every helper, so a nested validation cannot contaminate the outer call.
-- The lookup sets below are immutable and built once at load.

local ENUM_SETS = {}
for name, values in pairs(Schema.ENUMS) do
  local set = {}
  for _, v in ipairs(values) do
    set[v] = true
  end
  ENUM_SETS[name] = set
end

local PARAM_TYPES_SET = {}
for _, ty in ipairs(Schema.PARAM_TYPES) do
  PARAM_TYPES_SET[ty] = true
end

local ACTOR_SPECIALS_SET = {}
for _, special in ipairs(Schema.ACTOR_SPECIALS) do
  ACTOR_SPECIALS_SET[special] = true
end

-- Field-type checkers, filled below; declared up front so checkFields can
-- close over it.
local CHECKERS = {}

---@param context table<string, unknown>
---@param code string
---@param path string
---@param message string
---@param extra table<string, unknown>|nil
local function fail(context, code, path, message, extra)
  local ctx = { path = path }
  if context.scriptId then
    ctx.scriptId = context.scriptId
  end
  if extra then
    for k, v in pairs(extra) do
      ctx[k] = v
    end
  end
  Errors.raise(code, message, ctx)
end

local function isScalar(v)
  local ty = type(v)
  return ty == "number" or ty == "string" or ty == "boolean"
end

local function checkSerializable(context, value, path, seen)
  local ty = type(value)
  if ty == "table" then
    if getmetatable(value) ~= nil then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "script data must not carry metatables")
    end
    if seen[value] then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "script data must be acyclic (cycle detected)")
    end
    seen[value] = true
    for k, v in pairs(value) do
      if type(k) ~= "number" and type(k) ~= "string" then
        fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "script data keys must be numbers or strings")
      end
      checkSerializable(context, v, path .. "/" .. tostring(k), seen)
    end
    seen[value] = nil
  elseif ty == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "script data must not contain non-finite numbers")
    end
  elseif ty ~= "string" and ty ~= "boolean" then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      path,
      "script data must be numbers, strings, booleans, or tables (got " .. ty .. ")"
    )
  end
end

-- Reference and shape checkers. Each raises on failure.

local function checkArray(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected an array", { field = field })
  end
  local count = #v
  for k in pairs(v) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > count then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a contiguous array", { field = field })
    end
  end
  return count
end

-- Check a table's fields against a schema spec. `skipKeys` names keys that
-- are legal on the table but are not schema fields (discriminator keys such
-- as `op` or `value`). Unknown fields are always rejected. Field-level
-- failures and nested checkers report the exact field path; the root `steps`
-- field reads as `steps/N` to match the node-path style used by graph node IDs.
local function fieldPath(path, name)
  if path == "script" and name == "steps" then
    return "steps"
  end
  return path .. "/" .. name
end

local function checkFields(context, owner, fieldSpecs, given, path, skipKeys)
  for name, spec in pairs(fieldSpecs) do
    local v = given[name]
    if v == nil then
      if spec.required then
        fail(
          context,
          ScriptErrors.SCRIPT_SCHEMA_INVALID,
          fieldPath(path, name),
          "missing required field",
          { field = name, op = owner }
        )
      end
    else
      local ty = spec.type
      if ty:sub(1, 5) == "enum:" then
        local set = ENUM_SETS[ty:sub(6)]
        assert(set, "unknown enum in schema: " .. ty)
        if not set[v] then
          fail(
            context,
            ScriptErrors.SCRIPT_SCHEMA_INVALID,
            fieldPath(path, name),
            "invalid enum value for " .. ty,
            { field = name, op = owner, value = v }
          )
        end
      else
        local checker = CHECKERS[ty]
        assert(checker, "no checker registered for field type: " .. ty)
        checker(context, v, fieldPath(path, name), name)
      end
    end
  end
  for name in pairs(given) do
    if fieldSpecs[name] == nil and not (skipKeys and skipKeys[name]) then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        fieldPath(path, name),
        "unknown field",
        { field = name, op = owner }
      )
    end
  end
end

local EXTERNAL_MESSAGE_FIELDS = {
  bank = { type = "scalar_or_value", required = true },
  id = { type = "scalar_or_value", required = true },
}

local function checkValueRef(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a value reference", { field = field })
  end
  local kind = v.value
  if type(kind) ~= "string" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a value reference with a kind", { field = field })
  end
  local spec = Schema.VALUES[kind]
  if not spec then
    fail(context, ScriptErrors.SCRIPT_INVALID_REFERENCE, path, "unknown value kind", { field = field, kind = kind })
  end
  checkFields(context, kind, spec.fields, v, path, { value = true })
end

local function checkVarRef(context, v, path, field)
  checkValueRef(context, v, path, field)
  if v.value ~= "var" then
    fail(
      context,
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      path,
      "expected a variable reference",
      { field = field, kind = v.value }
    )
  end
end

local function checkTextValue(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a text value", { field = field })
  end
  local kind = v.text
  if type(kind) ~= "string" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a text value with a kind", { field = field })
  end
  local spec = Schema.TEXT_VALUES[kind]
  if not spec then
    fail(context, ScriptErrors.SCRIPT_INVALID_REFERENCE, path, "unknown text kind", { field = field, kind = kind })
  end
  checkFields(context, kind, spec.fields, v, path, { text = true })
end

local function checkCondition(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a condition", { field = field })
  end
  local kind = v.condition
  if type(kind) ~= "string" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a condition with a kind", { field = field })
  end
  local spec = Schema.CONDITIONS[kind]
  if not spec then
    fail(context, ScriptErrors.SCRIPT_INVALID_REFERENCE, path, "unknown condition kind", { field = field, kind = kind })
  end
  checkFields(context, kind, spec.fields, v, path, { condition = true })
end

local function checkActor(context, v, path, field)
  if type(v) == "string" then
    if #v == 0 then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "actor id must not be empty", { field = field })
    end
    return
  end
  if type(v) ~= "table" or v.ref ~= "actor" then
    fail(context, ScriptErrors.SCRIPT_INVALID_REFERENCE, path, "expected an actor reference", { field = field })
  end
  if type(v.id) == "string" and #v.id > 0 then
    return
  end
  if type(v.special) == "string" and ACTOR_SPECIALS_SET[v.special] then
    return
  end
  -- A numeric local map-object index, resolved against the current map at
  -- runtime (the pinned MapObjectManager_GetFirstActiveObjectByID path).
  if type(v.mapIndex) == "number" and v.mapIndex >= 0 and v.mapIndex == math.floor(v.mapIndex) then
    return
  end
  fail(
    context,
    ScriptErrors.SCRIPT_SCHEMA_INVALID,
    path,
    "actor reference must carry id, a known special, or a map index",
    { field = field, special = v.special }
  )
end

local function checkMessage(context, v, path, field)
  if type(v) == "string" then
    if #v == 0 then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "message id must not be empty", { field = field })
    end
    return
  end
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a message reference", { field = field })
  end
  if v.value ~= nil then
    checkValueRef(context, v, path, field)
    return
  end
  if v.message == "external" then
    checkFields(context, "external_message", EXTERNAL_MESSAGE_FIELDS, v, path, { message = true })
    return
  end
  if v.text == "gendered_message" then
    checkTextValue(context, v, path, field)
    return
  end
  fail(context, ScriptErrors.SCRIPT_INVALID_REFERENCE, path, "unknown message reference form", { field = field })
end

local function checkMovement(context, v, path, field)
  local count = checkArray(context, v, path, field)
  for i = 1, count do
    local item = v[i]
    local actionPath = path .. "/" .. tostring(i - 1)
    if type(item) ~= "table" then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        actionPath,
        "movement action must be a table",
        { field = field }
      )
    end
    local name = item.action
    if type(name) ~= "string" then
      fail(
        context,
        ScriptErrors.SCRIPT_UNKNOWN_OPERATION,
        actionPath,
        "movement action is missing a name",
        { field = field }
      )
    end
    local spec = Schema.MOVEMENT_ACTIONS[name]
    if not spec then
      fail(
        context,
        ScriptErrors.SCRIPT_UNKNOWN_OPERATION,
        actionPath,
        "unknown movement action",
        { field = field, action = name }
      )
    end
    checkFields(context, name, spec.fields, item, actionPath, { action = true })
  end
end

local function checkMenuStep(context, step, path)
  if step.cancellable == true and step.cancelValue == nil then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      fieldPath(path, "cancelValue"),
      "cancellable semantic menus require a cancellation result",
      { field = "cancelValue", op = "choose" }
    )
  end
  if step.initialCursor ~= nil and (step.initialCursor < 0 or step.initialCursor >= #step.items) then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      fieldPath(path, "initialCursor"),
      "semantic menu initial cursor is out of range",
      { field = "initialCursor", op = "choose" }
    )
  end
end

-- The low-level compare-state branches need either a local label target or a
-- cross-script reference.
local function checkCompareBranchStep(context, step, path, name)
  if step.target == nil and step.script == nil then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      path,
      "compare-state branch requires a target or a script reference",
      { op = name }
    )
  end
  if step.script ~= nil and step.target ~= nil then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      path,
      "compare-state branch must not combine a local target with a script",
      { op = name }
    )
  end
end

local function recordLocalUsage(context, step, path, name)
  if name == "set_local" or name == "add_local" or name == "sub_local" then
    context.usedLocals[step.name] = path
  elseif name == "copy_local" then
    context.usedLocals[step.destination] = path
    context.usedLocals[step.source] = path
  end
end

local function checkStep(context, step, path)
  if type(step) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "step must be a table")
  end
  local name = step.op
  if type(name) ~= "string" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "step is missing an op")
  end
  local spec = Schema.OPERATIONS[name]
  if not spec then
    fail(context, ScriptErrors.SCRIPT_UNKNOWN_OPERATION, path, "unknown operation", { op = name })
  end
  checkFields(context, name, spec.fields, step, path, { op = true })
  if name == "choose" then
    checkMenuStep(context, step, path)
  elseif name == "goto_compared" or name == "call_compared" then
    checkCompareBranchStep(context, step, path, name)
  end
  recordLocalUsage(context, step, path, name)
end

local function checkSteps(context, v, path, field)
  local count = checkArray(context, v, path, field)
  for i = 1, count do
    checkStep(context, v[i], path .. "/" .. tostring(i - 1))
  end
end

local function collectRefs(context, value, path)
  if type(value) ~= "table" then
    return
  end
  if value.value == "local" and type(value.name) == "string" then
    context.usedLocals[value.name] = path
  elseif value.value == "arg" and type(value.name) == "string" then
    context.usedArgs[value.name] = path
  end
  for k, v in pairs(value) do
    if type(k) ~= "table" then
      collectRefs(context, v, path .. "/" .. tostring(k))
    end
  end
end

local function checkDeclarationMap(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a declaration table", { field = field })
  end
  for name, ty in pairs(v) do
    if type(name) ~= "string" or #name == 0 then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        path,
        "declaration names must be non-empty strings",
        { field = field }
      )
    end
    if not PARAM_TYPES_SET[ty] then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        path,
        "unknown declared type",
        { field = field, name = name, declaredType = ty }
      )
    end
  end
end

local function checkArgValue(context, v, path, field)
  if isScalar(v) then
    return
  end
  if type(v) ~= "table" then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      path,
      "arg must be a scalar, value, actor, or text reference",
      { field = field }
    )
  end
  if v.value ~= nil then
    checkValueRef(context, v, path, field)
    return
  end
  if v.text ~= nil then
    checkTextValue(context, v, path, field)
    return
  end
  checkActor(context, v, path, field)
end

local function checkString(context, v, path, field)
  if type(v) ~= "string" or #v == 0 then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a non-empty string", { field = field })
  end
end
local function checkInteger(context, v, path, field)
  if type(v) ~= "number" or v % 1 ~= 0 then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected an integer", { field = field, value = v })
  end
end
local function checkNumber(context, v, path, field)
  if type(v) ~= "number" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a number", { field = field })
  end
end
local function checkBoolean(context, v, path, field)
  if type(v) ~= "boolean" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a boolean", { field = field })
  end
end
local function checkScalar(context, v, path, field)
  if not isScalar(v) then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a scalar literal", { field = field })
  end
end
local function checkScalarOrValue(context, v, path, field)
  if isScalar(v) then
    return
  end
  checkValueRef(context, v, path, field)
end
CHECKERS.value = checkValueRef
CHECKERS.text_value = checkTextValue
-- A world id or a variable reference. World ids are the U16 keys of the
-- world store (catalog symbols resolve to them at runtime), so a numeric id
-- is valid exactly when it satisfies the store's range contract.
local function checkIdOrVar(context, v, path, field)
  if type(v) == "string" and #v > 0 then
    return
  end
  if type(v) == "number" then
    if v ~= math.floor(v) or v < 0 or v > 0xFFFF then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        path,
        "world id must be an unsigned 16-bit integer",
        { field = field, id = v }
      )
    end
    return
  end
  checkVarRef(context, v, path, field)
end
CHECKERS.actor = checkActor
local function checkActorList(context, v, path, field)
  local count = checkArray(context, v, path, field)
  for i = 1, count do
    checkActor(context, v[i], path .. "/" .. tostring(i - 1), field)
  end
end
CHECKERS.condition = checkCondition
local function checkConditionList(context, v, path, field)
  local count = checkArray(context, v, path, field)
  for i = 1, count do
    checkCondition(context, v[i], path .. "/" .. tostring(i - 1), field)
  end
end
CHECKERS.message = checkMessage
CHECKERS.movement = checkMovement
CHECKERS.steps = checkSteps
local function checkCases(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a cases table", { field = field })
  end
  for k, caseSteps in pairs(v) do
    if type(k) ~= "number" or k % 1 ~= 0 then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        path,
        "switch cases must be integer-keyed",
        { field = field, key = tostring(k) }
      )
    end
    checkSteps(context, caseSteps, path .. "/" .. tostring(k))
  end
end
local function checkArgs(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected an args table", { field = field })
  end
  for k, arg in pairs(v) do
    if type(k) ~= "string" then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "args must be named", { field = field })
    end
    checkArgValue(context, arg, path .. "/" .. k, field)
  end
end
local function checkBindings(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a bindings table", { field = field })
  end
  for slot, textValue in pairs(v) do
    if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 7 then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        path,
        "binding slots must be integers in 0..7",
        { field = field, slot = tostring(slot) }
      )
    end
    checkTextValue(context, textValue, path .. "/" .. tostring(slot), field)
  end
end
local function checkBufferSlot(context, v, path, field)
  if type(v) ~= "number" or v % 1 ~= 0 or v < 0 or v > 7 then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      path,
      "buffer slot must be an integer in 0..7",
      { field = field, slot = v }
    )
  end
end
local function checkButtons(context, v, path, field)
  local count = checkArray(context, v, path, field)
  local set = ENUM_SETS.button
  for i = 1, count do
    if not set[v[i]] then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "invalid button", { field = field, button = v[i] })
    end
  end
end
local function checkScalarList(context, v, path, field)
  local count = checkArray(context, v, path, field)
  for i = 1, count do
    if not isScalar(v[i]) then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "arguments must be scalars", { field = field })
    end
  end
end
local function checkMenuPlacement(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a menu placement table", { field = field })
  end
  local fields = {
    mode = { type = "enum:menu_placement_mode", required = true },
    anchor = { type = "enum:menu_anchor", required = true },
    surface = { type = "enum:menu_surface", required = true },
  }
  checkFields(context, "placement", fields, v, path)
end
local function checkMenuItems(context, v, path, field)
  local count = checkArray(context, v, path, field)
  if count == 0 then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "menu requires at least one item", { field = field })
  end
  local fields = {
    text = { type = "message", required = true },
    value = { type = "scalar_or_value", required = true },
    metadata = { type = "serializable" },
  }
  for i = 1, count do
    local item = v[i]
    local itemPath = path .. "/" .. tostring(i - 1)
    if type(item) ~= "table" then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, itemPath, "menu item must be a table", { field = field })
    end
    checkFields(context, "choice", fields, item, itemPath)
  end
end
local function checkSourceProvenance(context, v, path, field)
  if type(v) ~= "table" then
    fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "expected a source provenance table", { field = field })
  end
  local offsets = v.offsets
  local opcodes = v.opcodes
  local count = checkArray(context, offsets, path .. "/offsets", field)
  if count == 0 then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      path,
      "source provenance must name at least one offset",
      { field = field }
    )
  end
  if type(opcodes) ~= "table" or #opcodes ~= count then
    fail(
      context,
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      path,
      "source offsets and opcodes must be arrays of equal length",
      { field = field }
    )
  end
  for i = 1, count do
    if type(offsets[i]) ~= "number" or offsets[i] % 1 ~= 0 then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        path .. "/offsets/" .. tostring(i - 1),
        "source offsets must be integers",
        { field = field }
      )
    end
    if type(opcodes[i]) ~= "number" or opcodes[i] % 1 ~= 0 then
      fail(
        context,
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        path .. "/opcodes/" .. tostring(i - 1),
        "source opcodes must be integers",
        { field = field }
      )
    end
  end
end
CHECKERS.params = checkDeclarationMap
CHECKERS.locals = checkDeclarationMap
local function checkSerializableField() end

CHECKERS.string = checkString
CHECKERS.integer = checkInteger
CHECKERS.number = checkNumber
CHECKERS.boolean = checkBoolean
CHECKERS.scalar = checkScalar
CHECKERS.scalar_or_value = checkScalarOrValue
CHECKERS.value = checkValueRef
CHECKERS.text_value = checkTextValue
CHECKERS.id_or_var = checkIdOrVar
CHECKERS.actor = checkActor
CHECKERS.actor_list = checkActorList
CHECKERS.condition = checkCondition
CHECKERS.condition_list = checkConditionList
CHECKERS.message = checkMessage
CHECKERS.movement = checkMovement
CHECKERS.steps = checkSteps
CHECKERS.cases = checkCases
CHECKERS.args = checkArgs
CHECKERS.bindings = checkBindings
CHECKERS.buffer_slot = checkBufferSlot
CHECKERS.buttons = checkButtons
CHECKERS.scalar_list = checkScalarList
CHECKERS.menu_placement = checkMenuPlacement
CHECKERS.menu_items = checkMenuItems
CHECKERS.source_provenance = checkSourceProvenance
CHECKERS.params = checkDeclarationMap
CHECKERS.locals = checkDeclarationMap
CHECKERS.serializable = checkSerializableField

function Validator._validate(script)
  local context = {
    scriptId = nil,
    usedLocals = {},
    usedArgs = {},
  }
  if type(script) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "script must be a table", { path = "script" })
  end
  context.scriptId = type(script.id) == "string" and script.id or nil
  checkSerializable(context, script, "script", {})
  checkFields(context, "script", Schema.SCRIPT.fields, script, "script")
  if script.api ~= Schema.API_VERSION then
    Errors.raise(
      ScriptErrors.SCRIPT_API_UNSUPPORTED,
      string.format("api %s is not supported (supported major: %d)", tostring(script.api), Schema.API_VERSION),
      { path = "api", scriptId = context.scriptId, api = script.api }
    )
  end
  collectRefs(context, script.steps, "steps")
  for name, path in pairs(context.usedLocals) do
    local declared = script.locals and script.locals[name]
    if declared == nil then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "local is not declared", { name = name })
    end
  end
  for name, path in pairs(context.usedArgs) do
    local declared = script.params and script.params[name]
    if declared == nil then
      fail(context, ScriptErrors.SCRIPT_SCHEMA_INVALID, path, "arg is not declared", { name = name })
    end
  end
  return true
end

---@param script unknown
---@return boolean|nil, Errors.Error|nil
function Validator.validate(script)
  local ok, err = pcall(Validator._validate, script)
  if ok then
    return true
  end
  if Errors.is(err) then
    local thrown = err --[[@as unknown]]
    return nil, thrown
  end
  error(err, 0)
end

return Validator
