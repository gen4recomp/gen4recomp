-- The derived-cache job vocabulary is one closed literal set shared by the
-- generation session, the compiler workers, and the common batch client. A
-- kind outside the set is rejected at the validation boundary; there is no
-- runtime registration surface that could let producers diverge.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
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
  "items",
  "bag",
  "mon-catalog",
  "mon-layout",
  "mon-icon-page",
  "mon-portrait-page",
  "mon-summary",
  "message-bank",
  "message-summary",
  "audio-bank",
  "audio-catalog",
  "audio-summary",
  "script-member",
  "script-summary",
  "map-data",
  "field-cell",
  "map",
  "source-plan",
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
  ["items"] = "global",
  ["bag"] = "global",
  ["mon-catalog"] = "global",
  ["mon-layout"] = "global",
  ["mon-icon-page"] = "3",
  ["mon-portrait-page"] = "12",
  ["mon-summary"] = "global",
  ["message-bank"] = "219",
  ["message-summary"] = "global",
  ["audio-bank"] = "7",
  ["audio-catalog"] = "global",
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

-- Unknown dynamic membership is incomplete, never an empty final list;
-- known-empty lists are complete. Callers may record and wake from
-- incomplete edges but never dispatch a parent from them.
function T.dependencies_report_completeness_for_unknown_and_known_empty_membership()
  local mapOk, mapDeps, mapComplete = pcall(ArtifactJobs.dependencies, "map", "7", {})
  Assert.isTrue(mapOk, "unknown map membership reports instead of raising")
  Assert.isFalse(mapComplete, "unknown map membership is incomplete")
  Assert.isTrue(type(mapDeps) == "table", "incomplete planning still reports its known edges")
  local mapSet = {}
  for _, dep in ipairs(assert(mapDeps, "incomplete planning reports known edges")) do
    mapSet[dep.kind .. ":" .. dep.key] = true
  end
  Assert.isTrue(mapSet["world-catalog:global"] == true, "incomplete map planning keeps its catalog edge")
  Assert.isTrue(mapSet["field-cell-index:global"] == true, "incomplete map planning keeps its index edge")

  local summaryDeps, summaryComplete =
    ArtifactJobs.dependencies("mon-summary", "global", { iconPageIds = {}, portraitPageIds = {} })
  Assert.isTrue(summaryComplete, "known-empty page membership is complete")
  local summarySet = {}
  for _, dep in ipairs(assert(summaryDeps, "complete planning reports its edges")) do
    summarySet[dep.kind .. ":" .. dep.key] = true
  end
  Assert.isTrue(summarySet["mon-catalog:global"] == true, "the complete summary keeps its catalog edge")
  Assert.isTrue(summarySet["mon-layout:global"] == true, "the complete summary keeps its layout edge")

  local messageDeps, messageComplete = ArtifactJobs.dependencies("message-summary", "global", { messageBankIds = {} })
  Assert.isTrue(messageComplete, "a known-empty bank closure is complete")
  Assert.deepEqual(messageDeps, {}, "a known-empty closure carries no child edges")

  local scriptOk, _, scriptComplete = pcall(ArtifactJobs.dependencies, "script-summary", "global", {})
  Assert.isTrue(scriptOk, "unknown script membership reports instead of raising")
  Assert.isFalse(scriptComplete, "unknown script membership is incomplete")

  local audioOk, _, audioComplete = pcall(ArtifactJobs.dependencies, "audio-summary", "global", {})
  Assert.isTrue(audioOk, "unknown audio membership reports instead of raising")
  Assert.isFalse(audioComplete, "unknown audio membership is incomplete")
end

-- The audio catalog is a heavy closed job: it plans the normalized index
-- without compiling banks and stages only the runtime index plus its
-- catalog completion.
function T.audio_catalog_maps_to_the_heavy_lane()
  Assert.equal(ArtifactJobs.sizeClass("audio-catalog"), "heavy")
  local path = assert(ArtifactState.path("audio-catalog", "global"))
  Assert.equal(path, "data/generated/jobs/audio-catalog/global.lua")
end

local function oakAudioPlan()
  return {
    index = {
      sequences = {
        [2] = { id = 2, bankId = 10 },
        [100] = { id = 100, symbol = "SEQ_GS_STARTING", bankId = 20 },
        [101] = { id = 101, symbol = "SEQ_GS_STARTING2", bankId = 20 },
        [102] = { id = 102, symbol = "SEQ_SE_DP_BOWA2", bankId = 30 },
        [103] = { id = 103, symbol = "SEQ_SE_DP_SELECT", bankId = 30 },
        [104] = { id = 104, symbol = "SEQ_SE_GS_HERO_SHUKUSHOU", bankId = 40 },
      },
      sequenceBySymbol = {
        SEQ_GS_STARTING = 100,
        SEQ_GS_STARTING2 = 101,
        SEQ_SE_DP_BOWA2 = 102,
        SEQ_SE_DP_SELECT = 103,
        SEQ_SE_GS_HERO_SHUKUSHOU = 104,
      },
    },
  }
end

-- Final New Game intro membership is exactly the static Oak closure plus
-- the deduplicated audio-bank closures behind the six semantic sequence
-- references and the direct Marill cry bank: unrelated banks, the full
-- audio summary, and field geometry never join.
function T.new_game_intro_membership_resolves_only_exact_oak_audio_closures()
  local jobs, complete = ArtifactJobs.newGameIntroJobs(oakAudioPlan())
  Assert.isTrue(complete, "resolved audio membership is final")
  local set = {}
  for _, job in ipairs(jobs) do
    local key = job.kind .. ":" .. job.key
    Assert.isNil(set[key], "intro membership carries no duplicate: " .. key)
    set[key] = true
  end
  for _, expected in ipairs({
    "source-plan:global",
    "field-ui:global",
    "field-font:global",
    "intro:global",
    "new-game-init:global",
    "mon-catalog:global",
    "items:global",
    "message-bank:219",
    "audio-catalog:global",
    "audio-bank:10",
    "audio-bank:20",
    "audio-bank:30",
    "audio-bank:40",
    "audio-bank:184",
  }) do
    Assert.isTrue(set[expected] == true, "intro membership carries " .. expected)
  end
  Assert.isNil(set["audio-bank:999"], "unrelated banks stay out of the intro closure")
  Assert.isNil(set["audio-summary:global"], "the full audio summary stays out of the intro closure")
  Assert.isNil(set["field-core:global"], "field core stays out of the intro closure")
  Assert.isNil(set["actors:global"], "field actors stay out of the intro closure")
end

-- Without source audio membership the roster stays unresolved: static
-- members plus the source-plan owner, never final.
function T.new_game_intro_without_source_audio_is_unresolved()
  local jobs, complete = ArtifactJobs.newGameIntroJobs(nil)
  Assert.isFalse(complete, "unresolved audio membership is unresolved")
  local set = {}
  for _, job in ipairs(jobs) do
    set[job.kind .. ":" .. job.key] = true
  end
  Assert.isTrue(set["source-plan:global"] == true, "the unresolved roster keeps its source owner")
  Assert.isTrue(set["audio-catalog:global"] == true, "the unresolved roster keeps the catalog")
  Assert.isNil(set["audio-bank:184"], "no bank closure is final before source adoption")
end

-- A missing Oak audio reference fails loudly naming the semantic
-- reference instead of silently omitting its bank.
function T.new_game_intro_names_its_missing_audio_reference()
  local plan = oakAudioPlan()
  plan.index.sequenceBySymbol.SEQ_SE_DP_SELECT = nil
  local ok, err = pcall(ArtifactJobs.newGameIntroJobs, plan)
  Assert.isFalse(ok, "a missing Oak sequence reference fails membership")
  Assert.isTrue(
    tostring(err):find("SEQ_SE_DP_SELECT", 1, true) ~= nil,
    "the failure names the missing semantic reference: " .. tostring(err)
  )
end

return { metadata = { capabilities = {} }, tests = T }
