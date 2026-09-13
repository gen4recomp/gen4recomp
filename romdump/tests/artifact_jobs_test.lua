-- The derived-cache job vocabulary is one closed literal set shared by the
-- generation session, the compiler workers, and the common batch client. A
-- kind outside the set is rejected at the validation boundary; there is no
-- runtime registration surface that could let producers diverge.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")

local T = {}

-- Every family the session can plan, execute, and validate, keyed exactly as
-- the worker channel addresses it. Coarse families and summaries use the
-- global key; paged and per-member families use their canonical selectors.
local CLOSED_KINDS = {
  "world-catalog",
  "field-cell-index",
  "field-camera",
  "field-weather",
  "field-effects",
  "field-emotes",
  "field-ui",
  "field-font",
  "intro",
  "new-game-init",
  "actors",
  "starter-choice",
  "mon-catalog",
  "mon-layout",
  "mon-icon-page",
  "mon-portrait-page",
  "mon-summary",
  "message-bank",
  "message-summary",
  "audio-bank",
  "audio-summary",
  "script-member",
  "script-summary",
  "map-data",
  "field-cell",
  "map",
}

local CANONICAL_KEYS = {
  ["world-catalog"] = "global",
  ["field-cell-index"] = "global",
  ["field-camera"] = "global",
  ["field-weather"] = "global",
  ["field-effects"] = "global",
  ["field-emotes"] = "global",
  ["field-ui"] = "global",
  ["field-font"] = "global",
  ["intro"] = "global",
  ["new-game-init"] = "global",
  ["actors"] = "global",
  ["starter-choice"] = "global",
  ["mon-catalog"] = "global",
  ["mon-layout"] = "global",
  ["mon-icon-page"] = "3",
  ["mon-portrait-page"] = "12",
  ["mon-summary"] = "global",
  ["message-bank"] = "219",
  ["message-summary"] = "global",
  ["audio-bank"] = "7",
  ["audio-summary"] = "global",
  ["script-member"] = "149",
  ["script-summary"] = "global",
  ["map-data"] = "7",
  ["field-cell"] = "12-5",
  ["map"] = "7",
}

function T.closed_vocabulary_matches_the_single_handler_set()
  local actual = {}
  for kind in pairs(ArtifactState.KINDS) do
    actual[#actual + 1] = kind
  end
  table.sort(actual)
  local expected = {}
  for _, kind in ipairs(CLOSED_KINDS) do
    expected[#expected + 1] = kind
  end
  table.sort(expected)
  Assert.deepEqual(actual, expected)
end

function T.every_family_key_shape_resolves_to_a_receipt_path()
  for kind, key in pairs(CANONICAL_KEYS) do
    local path = assert(ArtifactState.path(kind, key))
    Assert.equal(path, "data/generated/jobs/" .. kind .. "/" .. key .. ".lua")
  end
end

function T.unknown_kinds_are_rejected_before_planning()
  for _, kind in ipairs({ "world", "field-map-data", "portrait", "maps", "", "MAP" }) do
    local ok = pcall(ArtifactState.path, kind, "global")
    Assert.isFalse(ok, "kind must be rejected: " .. tostring(kind))
  end
end

function T.malformed_keys_are_rejected_for_their_kind()
  local cases = {
    { kind = "map", key = "" },
    { kind = "map", key = "1-2" },
    { kind = "map", key = "seven" },
    { kind = "field-cell", key = "12" },
    { kind = "field-cell", key = "abc" },
    { kind = "field-cell", key = "1-2-3" },
    { kind = "mon-icon-page", key = "3-4" },
    { kind = "message-bank", key = "bank" },
    { kind = "script-member", key = "-1" },
    { kind = "audio-bank", key = "01" },
  }
  for _, case in ipairs(cases) do
    local ok = pcall(ArtifactState.path, case.kind, case.key)
    Assert.isFalse(ok, "key must be rejected: " .. case.kind .. "/" .. tostring(case.key))
  end
end

function T.vocabulary_has_no_runtime_registration_surface()
  -- The vocabulary table is closed by construction; read it as an open map
  -- to prove no registration surface exists.
  ---@type table<string, unknown>
  local vocabulary = ArtifactState
  Assert.isNil(vocabulary.register)
  Assert.isNil(vocabulary.extend)
  Assert.isNil(vocabulary.addKind)
end

return { metadata = { capabilities = {} }, tests = T }
