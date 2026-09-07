-- Public gen4 field-script DSL, API 1: the current module version and the
-- only import mods and content use:
--
--     local S = require("gen4.script")
--
-- It re-exports every DSL constructor plus the API version constant and a
-- development `validate` helper, and must never expose the physical engine
-- directory layout. API 1 is not declared stable: until stability is
-- explicitly declared the surface stays minimal and incompatible cleanup is
-- allowed, so constructor shapes, operation names, field names, and defaults
-- may change between versions; libs/script/tests/core pins the current
-- shapes verbatim.

local Dsl = require("libs.script.src.Dsl")
local Schema = require("libs.script.src.Schema")
local Validator = require("libs.script.src.Validator")

local S = {}

for name, constructor in pairs(Dsl) do
  S[name] = constructor
end

S.apiVersion = Schema.API_VERSION

-- Development helper: validates a script resource without a game session.
-- Returns true, or nil plus an Errors object with code SCRIPT_* and a
-- `path`-attributed context. Validation is strict-only: unknown fields are
-- always rejected.
---@param script unknown
---@return boolean|nil, Errors.Error|nil
function S.validate(script)
  return Validator.validate(script)
end

return S
