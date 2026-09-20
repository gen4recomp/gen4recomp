-- The derived-cache job vocabulary is one closed literal set shared by the
-- generation session, the compiler workers, and the common batch client. A
-- kind outside the set is rejected at the validation boundary; there is no
-- runtime registration surface that could let producers diverge.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

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

-- The complete inventory enumerates incrementally through one canonical
-- iterator: draining it covers exactly the materialized list, each job
-- exactly once, under canonical identity. The interactive session consumes
-- the same iterator a bounded chunk at a time instead of materializing
-- the whole corpus in one update.
local function sweepPlans()
  local matrices = {}
  for matrixMemberId = 1, 3 do
    local cells = {}
    for index = 0, 9 do
      cells[#cells + 1] = { matrixMemberId = matrixMemberId, index = index }
    end
    matrices[#matrices + 1] = { matrixMemberId = matrixMemberId, cells = cells }
  end
  return {
    messageBankIds = { 1, 219 },
    audioBankIds = { 3, 7 },
    scriptMemberIds = { 5, 149 },
    iconPageIds = { 0, 1 },
    portraitPageIds = { 0 },
    mapDataIds = { 2, 4 },
    indexBundle = { index = { matrices = matrices }, indexMarker = "sweep-index-marker" },
    mapIds = { 7, 9 },
  }
end

function T.complete_inventory_drains_the_incremental_enumerator()
  local plans = sweepPlans()
  local expected = ArtifactJobs.completeJobs(plans)
  Assert.isTrue(#expected > 40, "the sweep fixture spans dozens of jobs")
  local iterate = ArtifactJobs.completeIterator(plans)
  Assert.isTrue(type(iterate) == "function", "the producer inventory enumerates incrementally")
  local seen = {}
  local count = 0
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    count = count + 1
    Assert.isNil(seen[job.jobKey], "the enumerator visits each job once: " .. tostring(job.jobKey))
    seen[job.jobKey] = true
    Assert.equal(job.jobKey, job.kind .. ":" .. job.key, "enumerated identities stay canonical")
  end
  Assert.equal(count, #expected, "the enumerator covers the complete inventory")
  for _, job in ipairs(expected) do
    Assert.isTrue(seen[job.jobKey] == true, "the enumerator visits " .. job.jobKey)
  end
end

-- A published message bank validates warm through the worker-facing
-- wrapper without a source reader: the authoritative family rule decides
-- reuse, and a missing bank validates cold. No ROM handle is opened.
local function publishWarmBank(cacheFs, generation, bankId)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local marker = "worker-warm-marker-" .. tostring(bankId)
  cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "message-bank",
    key = tostring(bankId),
    marker = marker,
  })
  cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
  cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
  })
end

function T.worker_validation_reuses_published_families_without_source()
  local producerId = "d" .. string.rep("3", 64)
  local generation = "worker-validation-generation"
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  publishWarmBank(cacheFs, generation, 219)
  local context = { cacheFs = cacheFs, versionId = "heartgold" }
  local warm = {
    kind = "message-bank",
    key = "219",
    generationId = generation,
    producerFingerprint = producerId,
  }
  Assert.isTrue(ArtifactJobs.validateCurrent(warm, context) == true, "a published bank validates warm without source")
  Assert.isNil(context.romFs, "warm validation opens no source reader")
  local cold = {
    kind = "message-bank",
    key = "220",
    generationId = generation,
    producerFingerprint = producerId,
  }
  Assert.isFalse(ArtifactJobs.validateCurrent(cold, context), "a missing bank validates cold")
end

-- The worker-local source-plan memo reads the published inventory once
-- per worker generation: two lookups share one read, an identity change
-- re-reads, and a mismatched identity is rejected without poisoning
-- the memo.
local function warmSourceCache(generation, producerId)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(SourcePlan.PATH, {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = string.rep("b", 40),
    generationId = generation,
    producerId = producerId,
    world = { maps = { { id = 7 } }, analysis = { excluded = {} } },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "memo-index-marker" },
    scriptPlan = { members = { { memberId = 1 } }, generationKey = "memo-script-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    messageBankIds = FieldMessageCompiler.requiredBankIds(),
    mapDataIds = FieldMapDataCompiler.supportedMapIds(),
    mapCellKeys = { [7] = {} },
  })
  return cacheFs
end

function T.worker_source_plan_memo_reads_once_per_generation()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local producerId = "d" .. string.rep("3", 64)
  local generation = "memo-generation"
  local cacheFs = warmSourceCache(generation, producerId)
  local reads = 0
  local realRead = SourcePlan.read
  SourcePlan.read = function(cache, identity)
    reads = reads + 1
    return realRead(cache, identity)
  end
  local ok, failure = pcall(function()
    local context = { cacheFs = cacheFs, versionId = "heartgold" }
    local identity = { versionId = "heartgold", generationId = generation, producerId = producerId }
    local first = assert(ArtifactJobs.sourcePlanForContext(context, identity))
    local second = assert(ArtifactJobs.sourcePlanForContext(context, identity))
    Assert.isTrue(first == second, "the same generation memoizes its record")
    Assert.equal(reads, 1, "two source-plan-dependent lookups read once")
    local stale = { versionId = "heartgold", generationId = generation, producerId = "d" .. string.rep("9", 64) }
    local rejected, reason = ArtifactJobs.sourcePlanForContext(context, stale)
    Assert.isNil(rejected, "a mismatched producer identity is rejected")
    Assert.notNil(reason, "the rejection names its cause")
    local rotatedGeneration = "memo-generation-next"
    local rotatedCache = warmSourceCache(rotatedGeneration, producerId)
    context.cacheFs = rotatedCache
    local rotated = { versionId = "heartgold", generationId = rotatedGeneration, producerId = producerId }
    Assert.notNil(ArtifactJobs.sourcePlanForContext(context, rotated), "a replaced generation reads its own record")
    Assert.equal(reads, 3, "identity changes re-read through the validating reader")
  end)
  SourcePlan.read = realRead
  if not ok then
    error(failure, 0)
  end
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
