-- Closed dispatch of derived-cache family jobs: the one kind/key
-- vocabulary, the fixed size policy, milestone membership, dependency
-- edges, worker execution and readiness validation shared by the
-- generation session, the compiler workers and the common batch client.
-- There is no runtime registration surface; every family resolves through
-- this table's fixed handlers, and every handler reuses its owning domain
-- compiler/writer without duplicating source semantics.

local ArtifactState = require("romdump.src.build.ArtifactState")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

---@class ArtifactJobs.Job
---@field kind string
---@field key string
---@field generationId string
---@field epoch integer
---@field stageName string
---@field producerFingerprint string|nil
---@field payload table<string, unknown>|nil scalar selectors for the worker

---@class ArtifactJobs.Plans
---@field indexBundle table<string, unknown>|nil FieldCellCompiler.compileIndex bundle
---@field scriptPlan table<string, unknown>|nil ScriptCompiler.plan bundle
---@field audioPlan table<string, unknown>|nil AudioCompiler.plan index and bank closures
---@field presentation table<string, unknown>|nil MonPresentationCompiler.plan bundle
---@field messageBankIds integer[]|nil required message bank ids
---@field audioBankIds integer[]|nil planned audio bank ids
---@field scriptMemberIds integer[]|nil nonempty script member ids
---@field iconPageIds integer[]|nil planned icon page ids
---@field portraitPageIds integer[]|nil planned portrait page ids
---@field mapDataIds integer[]|nil supported field record ids
---@field mapIds integer[]|nil loadable world map ids
---@field mapCellKeys table<integer, string[]>|nil mapId to canonical cell keys
---@field world table<string, unknown>|nil WorldManifest.compileCatalog bundle

local ArtifactJobs = {}

ArtifactJobs.MILESTONE_SCHEMA = "g4-cache-milestone-v1"

local PRIORITY = {
  required = 0,
  near = 10,
  sweep = 100,
}

local SIZE_CLASS = {
  ["world-catalog"] = "normal",
  ["field-cell-index"] = "normal",
  ["field-camera"] = "normal",
  ["field-weather"] = "normal",
  ["field-effects"] = "normal",
  ["field-emotes"] = "normal",
  ["field-ui"] = "normal",
  intro = "normal",
  ["new-game-init"] = "normal",
  ["starter-choice"] = "normal",
  items = "normal",
  bag = "normal",
  ["mon-icon-page"] = "normal",
  ["mon-portrait-page"] = "normal",
  ["map-data"] = "normal",
  ["message-summary"] = "normal",
  ["mon-summary"] = "normal",
  ["source-plan"] = "heavy",
  ["field-font"] = "heavy",
  actors = "heavy",
  ["mon-catalog"] = "heavy",
  ["mon-layout"] = "heavy",
  ["audio-bank"] = "heavy",
  ["audio-catalog"] = "heavy",
  ["audio-summary"] = "heavy",
  ["script-member"] = "heavy",
  ["script-summary"] = "heavy",
  ["message-bank"] = "heavy",
  ["field-cell"] = "jumbo",
  map = "jumbo",
}

---@param urgency string
---@return integer
function ArtifactJobs.priorityFor(urgency)
  local priority = PRIORITY[urgency]
  assert(priority ~= nil, "job urgency must be required, near, or sweep: " .. tostring(urgency))
  return priority
end

---@param kind string
---@return string
function ArtifactJobs.sizeClass(kind)
  local size = SIZE_CLASS[kind]
  assert(size ~= nil, "unknown artifact kind: " .. tostring(kind))
  return size
end

---@param kind string
---@param key string
---@return string
function ArtifactJobs.jobKey(kind, key)
  ArtifactState.path(kind, key)
  return kind .. ":" .. key
end

local function sortedJobs(jobs)
  table.sort(jobs, function(left, right)
    if left.kind == right.kind then
      return left.key < right.key
    end
    return left.kind < right.kind
  end)
  return jobs
end

---@return { kind: string, key: string }[]
function ArtifactJobs.bootstrapJobs()
  return { { kind = "field-font", key = "global" } }
end

---@param entries string[] fixed kind[:key] members, bare kinds read global
---@return { kind: string, key: string }[]
local function fixedJobs(entries)
  local jobs = {}
  for _, entry in ipairs(entries) do
    local kind, key = entry:match("^([^:]+):?(.*)$")
    assert(kind, "milestone membership entry is malformed: " .. tostring(entry))
    if key == "" then
      key = "global"
    end
    jobs[#jobs + 1] = { kind = kind, key = key }
  end
  return jobs
end

-- The exact semantic audio references the current New Game/Oak path can
-- touch: the standard cry sequence plus every symbolic sequence the Oak
-- timeline and profile flow play, resolved against the adopted normalized
-- audio index. Resolved bank ids are never spelled here.
local NEW_GAME_AUDIO_SEQUENCES = {
  2,
  "SEQ_GS_STARTING",
  "SEQ_GS_STARTING2",
  "SEQ_SE_DP_BOWA2",
  "SEQ_SE_DP_SELECT",
  "SEQ_SE_GS_HERO_SHUKUSHOU",
}
-- Cry playback resolves the species directly as a bank, never through
-- sequence metadata, so the Marill species bank joins independently.
local NEW_GAME_DIRECT_AUDIO_BANKS = { 184 }

local NEW_GAME_INTRO_STATIC = {
  { kind = "source-plan", key = "global" },
  { kind = "field-ui", key = "global" },
  { kind = "field-font", key = "global" },
  { kind = "intro", key = "global" },
  { kind = "new-game-init", key = "global" },
  { kind = "mon-catalog", key = "global" },
  { kind = "items", key = "global" },
  { kind = "message-bank", key = "219" },
  { kind = "audio-catalog", key = "global" },
}

---@param audioPlan table<string, unknown>|nil adopted normalized audio membership
---@return { kind: string, key: string }[] roster
---@return boolean complete true once source audio membership resolved the bank closures
function ArtifactJobs.newGameIntroJobs(audioPlan)
  local jobs = {}
  for _, member in ipairs(NEW_GAME_INTRO_STATIC) do
    jobs[#jobs + 1] = { kind = member.kind, key = member.key }
  end
  if audioPlan == nil then
    return sortedJobs(jobs), false
  end
  assert(type(audioPlan) == "table", "intro audio membership requires the adopted audio plan")
  local index = assert(audioPlan.index, "intro audio membership requires the adopted audio index")
  assert(type(index.sequences) == "table", "intro audio membership requires the adopted sequences")
  assert(type(index.sequenceBySymbol) == "table", "intro audio membership requires the adopted sequence symbols")
  local seen = {}
  local function addBank(bankId, reference)
    assert(
      type(bankId) == "number" and bankId % 1 == 0 and bankId >= 0,
      "intro audio reference resolves to no bank: " .. tostring(reference)
    )
    local key = tostring(bankId)
    if not seen[key] then
      seen[key] = true
      jobs[#jobs + 1] = { kind = "audio-bank", key = key }
    end
  end
  for _, reference in ipairs(NEW_GAME_AUDIO_SEQUENCES) do
    local sequenceId = reference
    if type(reference) == "string" then
      sequenceId = index.sequenceBySymbol[reference]
      if sequenceId == nil then
        error("intro audio reference has no adopted sequence: " .. reference, 0)
      end
    end
    local entry = index.sequences[sequenceId]
    if type(entry) ~= "table" then
      error("intro audio reference has no adopted sequence: " .. tostring(reference), 0)
    end
    addBank(entry.bankId, reference)
  end
  for _, bankId in ipairs(NEW_GAME_DIRECT_AUDIO_BANKS) do
    addBank(bankId, bankId)
  end
  return sortedJobs(jobs), true
end

-- The smallest closure that can determine and request a target location:
-- source inventory plus the structural world and cell catalogs. It never
-- enumerates family summaries or per-map/per-bank corpus membership.
local FIELD_PLANNING_JOBS = {
  "source-plan:global",
  "world-catalog:global",
  "field-cell-index:global",
}

-- The static generated services the field runtime consumes eagerly: world
-- and cell catalogs, presentation services, actor/mon/item/bag catalogs,
-- the two protocol menu label banks (Start Menu plus the standard list
-- menu script hosts acquire synchronously), the shared transition/door
-- sound-effect bank (transition exitSound/door symbols live in Lua constant
-- tables no map closure can reach), the audio catalog and the script
-- summary. It never contains intro setup, whole-family summaries, or a
-- per-map/per-bank corpus enumeration.
local FIELD_RUNTIME_JOBS = {
  "world-catalog:global",
  "field-cell-index:global",
  "field-camera:global",
  "field-weather:global",
  "field-effects:global",
  "field-emotes:global",
  "field-ui:global",
  "field-font:global",
  "actors:global",
  "mon-catalog:global",
  "mon-layout:global",
  "items:global",
  "bag:global",
  "starter-choice:global",
  "message-bank:" .. tostring(MenuProtocol.START_MENU_MESSAGE_BANK),
  "message-bank:" .. tostring(MenuProtocol.STANDARD_MESSAGE_BANK),
  "audio-bank:750",
  "audio-catalog:global",
  "script-summary:global",
}

---@return { kind: string, key: string }[]
function ArtifactJobs.fieldPlanningJobs()
  return sortedJobs(fixedJobs(FIELD_PLANNING_JOBS))
end

---@return { kind: string, key: string }[]
function ArtifactJobs.fieldRuntimeJobs()
  return sortedJobs(fixedJobs(FIELD_RUNTIME_JOBS))
end

---@param kind string
---@param key string
---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[] currently known prerequisites
---@return boolean complete true once planning prerequisites are adopted and the list is final
function ArtifactJobs.dependencies(kind, key, plans)
  ArtifactState.path(kind, key)
  assert(type(plans) == "table", "dependency edges require the session plans")
  local deps = {}
  -- False until the planning prerequisites behind this list are satisfied
  -- and adopted. Callers may record and wake from incomplete edges but must
  -- never dispatch a parent from them, and must never read nil membership
  -- as a known-empty final list.
  local complete = true
  local function awaitMembership()
    complete = false
  end
  if kind == "source-plan" then
    -- The worker inventory plans no prerequisite.
  elseif kind == "mon-layout" then
    deps[#deps + 1] = { kind = "mon-catalog", key = "global" }
  elseif kind == "mon-icon-page" or kind == "mon-portrait-page" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
    deps[#deps + 1] = { kind = "mon-layout", key = "global" }
    local pages = kind == "mon-icon-page" and plans.iconPageIds or plans.portraitPageIds
    if pages == nil then
      awaitMembership()
    end
  elseif kind == "mon-summary" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
    deps[#deps + 1] = { kind = "mon-catalog", key = "global" }
    deps[#deps + 1] = { kind = "mon-layout", key = "global" }
    if plans.iconPageIds == nil or plans.portraitPageIds == nil then
      awaitMembership()
    else
      for _, pageId in ipairs(plans.iconPageIds) do
        deps[#deps + 1] = { kind = "mon-icon-page", key = tostring(pageId) }
      end
      for _, pageId in ipairs(plans.portraitPageIds) do
        deps[#deps + 1] = { kind = "mon-portrait-page", key = tostring(pageId) }
      end
    end
  elseif kind == "message-summary" then
    for _, bankId in ipairs(assert(plans.messageBankIds, "message summary needs the required banks")) do
      deps[#deps + 1] = { kind = "message-bank", key = tostring(bankId) }
    end
  elseif kind == "audio-catalog" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
  elseif kind == "audio-summary" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
    deps[#deps + 1] = { kind = "audio-catalog", key = "global" }
    if plans.audioBankIds == nil then
      awaitMembership()
    else
      for _, bankId in ipairs(plans.audioBankIds) do
        deps[#deps + 1] = { kind = "audio-bank", key = tostring(bankId) }
      end
    end
  elseif kind == "script-summary" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
    if plans.scriptMemberIds == nil then
      awaitMembership()
    else
      for _, memberId in ipairs(plans.scriptMemberIds) do
        deps[#deps + 1] = { kind = "script-member", key = tostring(memberId) }
      end
    end
  elseif kind == "script-member" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
  elseif kind == "audio-bank" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
  elseif kind == "map" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
    deps[#deps + 1] = { kind = "world-catalog", key = "global" }
    deps[#deps + 1] = { kind = "field-cell-index", key = "global" }
    local cellKeys = plans.mapCellKeys and plans.mapCellKeys[tonumber(key)]
    if cellKeys == nil then
      awaitMembership()
    else
      for _, cellKey in ipairs(cellKeys) do
        deps[#deps + 1] = { kind = "field-cell", key = cellKey }
      end
    end
  elseif kind == "field-cell" then
    deps[#deps + 1] = { kind = "source-plan", key = "global" }
    deps[#deps + 1] = { kind = "field-cell-index", key = "global" }
  end
  return deps, complete
end

local function failArtifact(artifact, failure, traceback)
  local ok, finalizeError = pcall(artifact.finishFailure, artifact, failure, traceback)
  if not ok then
    error(finalizeError, 0)
  end
end

---@param context table<string, unknown>
---@param key string
local function closeFamilySession(context, key)
  local session = context[key]
  if type(session) == "table" and type(session.close) == "function" then
    context[key] = nil
    pcall(session.close, session)
  end
end

---@param context table<string, unknown>
function ArtifactJobs.closeSessions(context)
  assert(type(context) == "table", "worker sessions require a context table")
  closeFamilySession(context, "scriptSession")
  context.scriptPlan = nil
  context.scriptGenerationKey = nil
  closeFamilySession(context, "messageSession")
  closeFamilySession(context, "mapdataSession")
  closeFamilySession(context, "audioSession")
  context.audioSessionKey = nil
end

local function messageSessionFor(context)
  local session = context.messageSession
  if session == nil then
    local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
    local romFs = assert(context.romFs, "message jobs require a source reader")
    session = FieldMessageCompiler.newSession(romFs)
    context.messageSession = session
  end
  return session
end

local function mapdataSessionFor(context)
  local session = context.mapdataSession
  if session == nil then
    local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
    local romFs = assert(context.romFs, "field-data jobs require a source reader")
    session = FieldMapDataCompiler.newSession(romFs)
    context.mapdataSession = session
  end
  return session
end

local function scriptSessionFor(context, generationKey, producerFingerprint)
  if context.scriptGenerationKey ~= generationKey then
    closeFamilySession(context, "scriptSession")
    context.scriptGenerationKey = generationKey
    context.scriptPlan = nil
  end
  local plan = context.scriptPlan
  if plan == nil then
    local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
    local romFs = assert(context.romFs, "script jobs require a source reader")
    plan = ScriptCompiler.plan(romFs, producerFingerprint)
    assert(plan.generationKey == generationKey, "script job generation does not match the source plan")
    context.scriptPlan = plan
  end
  local session = context.scriptSession
  if session == nil then
    local ScriptCompileSession = require("romdump.src.digest.script.ScriptCompileSession")
    local romFs = assert(context.romFs, "script jobs require a source reader")
    session = ScriptCompileSession.new(romFs, plan)
    context.scriptSession = session
  end
  return plan, session
end

---@param romFs table<string, unknown>
---@return table<string, unknown> catalog
local function compileCatalog(romFs)
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local catalog, catalogErr = MonCatalogCompiler.compileCatalog(romFs)
  if catalog == nil then
    error(catalogErr, 0)
  end
  return catalog
end

---@param romFs table<string, unknown>
---@param catalog table<string, unknown>
---@return table<string, unknown> presentation
local function planPresentation(romFs, catalog)
  local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
  local presentation, presentationErr = MonPresentationCompiler.plan(romFs, catalog)
  if presentation == nil then
    error(presentationErr, 0)
  end
  return presentation
end

---@param compile fun(): table<string, unknown>?, unknown
---@param label string
---@return table<string, unknown>
local function compileOrRaise(compile, label)
  local bundle, failure = compile()
  if bundle == nil then
    error(failure or (label .. " compilation failed"), 0)
  end
  return bundle
end

---@param key string canonical decimal job key
---@param what string key label for diagnostics
---@return integer
local function canonicalKeyId(key, what)
  local id = assert(tonumber(key), what .. " is not canonical")
  assert(type(id) == "number" and id % 1 == 0, what .. " is not canonical")
  return id --[[@as integer]]
end

local function executeWorldCatalog(artifact, context)
  local WorldManifest = require("romdump.src.digest.map.WorldManifest")
  local romFs = assert(context.romFs, "world catalog jobs require a source reader")
  local bundle = WorldManifest.compileCatalog(romFs)
  return WorldManifest.stageCatalog(artifact, bundle)
end

local function executeCellIndex(artifact, context, producer)
  local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")
  local romFs = assert(context.romFs, "cell index jobs require a source reader")
  local bundle = compileOrRaise(function()
    return FieldCellCompiler.compileIndex(romFs, producer)
  end, "cell index")
  artifact:addOwnedRoot(FieldCellCache.indexPath())
  artifact:addOwnedRoot(FieldCellCache.indexMarkerPath())
  local stage = artifact:stageFs()
  FieldCellCacheWriter.stageIndex(stage, bundle.index)
  stage:write(FieldCellCache.indexMarkerPath(), assert(bundle.indexMarker, "cell index carries no marker"))
  return bundle.indexMarker
end

local function executeFieldFont(artifact, context)
  local Compiler = require("romdump.src.digest.ui.FieldFontCompiler")
  local Writer = require("romdump.src.digest.ui.FieldFontCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field font")
  return Writer.stage(artifact, bundle)
end

local function executeFieldCamera(artifact, context)
  local Compiler = require("romdump.src.digest.field.FieldCameraCompiler")
  local Writer = require("romdump.src.digest.field.FieldCameraCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field camera")
  return Writer.stage(artifact, bundle)
end

local function executeStarterChoice(artifact, context)
  local Compiler = require("romdump.src.digest.newgame.StarterChoiceAssetCompiler")
  local Writer = require("romdump.src.digest.newgame.StarterChoiceAssetCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "starter choice")
  return Writer.stage(artifact, bundle)
end

local function executeIntro(artifact, context)
  local Compiler = require("romdump.src.digest.newgame.IntroAssetCompiler")
  local Writer = require("romdump.src.digest.newgame.IntroAssetCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs), nil
  end, "intro assets")
  return Writer.stage(artifact, bundle)
end

local function executeFieldWeather(artifact, context)
  local Compiler = require("romdump.src.digest.field.FieldWeatherCompiler")
  local Writer = require("romdump.src.digest.field.FieldWeatherCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field weather")
  return Writer.stage(artifact, bundle)
end

local function executeFieldEffects(artifact, context)
  local Compiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
  local Writer = require("romdump.src.digest.field.FieldEntranceIndicatorCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs), nil
  end, "field effects")
  return Writer.stage(artifact, bundle)
end

local function executeFieldUi(artifact, context)
  local Compiler = require("romdump.src.digest.ui.FieldUiCompiler")
  local Writer = require("romdump.src.digest.ui.FieldUiCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field ui")
  return Writer.stage(artifact, bundle)
end

local function executeFieldEmotes(artifact, context)
  local Compiler = require("romdump.src.digest.actor.FieldActorEmoteCompiler")
  local Writer = require("romdump.src.digest.actor.FieldActorEmoteCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs), nil
  end, "field emotes")
  return Writer.stage(artifact, bundle)
end

local function executeNewGameInit(artifact, context)
  local NewGameInitCompiler = require("romdump.src.digest.newgame.NewGameInitCompiler")
  local NewGameInitCacheWriter = require("romdump.src.digest.newgame.NewGameInitCacheWriter")
  local romFs = assert(context.romFs, "initializer jobs require a source reader")
  local compiled, compileErr = NewGameInitCompiler.compileFromRom(romFs)
  if compiled == nil then
    error(compileErr, 0)
  end
  return NewGameInitCacheWriter.stage(artifact, { artifact = compiled.artifact, marker = compiled.marker })
end

local function executeActors(artifact, context)
  local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
  local FollowingMonVisualCompiler = require("romdump.src.digest.actor.FollowingMonVisualCompiler")
  local FieldActorCacheWriter = require("romdump.src.digest.actor.FieldActorCacheWriter")
  local romFs = assert(context.romFs, "actor jobs require a source reader")
  local actor = compileOrRaise(function()
    return FieldActorCompiler.compile(romFs)
  end, "field actors")
  local follower = compileOrRaise(function()
    return FollowingMonVisualCompiler.compile(romFs)
  end, "follower visuals")
  FollowingMonVisualCompiler.mergeIntoActorBundle(actor, follower)
  return FieldActorCacheWriter.stage(artifact, actor)
end

local function executeItems(artifact, context)
  local ItemCatalogCompiler = require("romdump.src.digest.items.ItemCatalogCompiler")
  local ItemCacheWriter = require("romdump.src.digest.items.ItemCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return ItemCatalogCompiler.compileAll(romFs)
  end, "items")
  return ItemCacheWriter.stage(artifact, bundle)
end

local function executeBag(artifact, context)
  local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
  local BagCacheWriter = require("romdump.src.digest.ui.BagCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return BagAssetCompiler.compile(romFs)
  end, "bag")
  return BagCacheWriter.stage(artifact, bundle)
end

local function executeMonCatalog(artifact, context)
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local romFs = assert(context.romFs, "mon catalog jobs require a source reader")
  local catalog = compileCatalog(romFs)
  local romSha1 = romFs:metadata().sha1
  return MonCacheWriter.stageCatalog(artifact, {
    catalog = catalog,
    marker = MonCacheWriter.catalogMarker(romSha1, catalog),
  })
end

local function executeMonLayout(artifact, context, generationId)
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local romFs = assert(context.romFs, "mon layout jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "mon layout jobs require a cache filesystem")
  assert(type(generationId) == "string" and generationId ~= "", "mon layout jobs require a generation")
  local catalog = MonCache.loadCatalog(cacheFs)
  local presentation = planPresentation(romFs, catalog)
  local romSha1 = romFs:metadata().sha1
  return MonCacheWriter.stageLayout(artifact, {
    icons = presentation.icons,
    portraits = presentation.portraits,
    marker = MonCacheWriter.layoutMarker(romSha1, presentation.icons, presentation.portraits),
    pagePlans = { iconPages = presentation.iconPages, portraitPages = presentation.portraitPages },
    generationId = generationId,
  })
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param pageKind "icons"|"portraits"
---@param pageId integer
---@param generationId string
---@return string
local function executeMonPage(artifact, context, pageKind, pageId, generationId)
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local romFs = assert(context.romFs, "mon page jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "mon page jobs require a cache filesystem")
  assert(type(generationId) == "string" and generationId ~= "", "mon page jobs require a generation")
  local layoutMarker = cacheFs:read(MonCache.layoutMarkerPath())
  if type(layoutMarker) ~= "string" or layoutMarker == "" then
    error("mon page " .. pageKind .. "/" .. tostring(pageId) .. " has no published layout", 0)
  end
  local pagePlan, planReason = MonCacheWriter.loadPagePlan(cacheFs, generationId, pageKind, pageId, layoutMarker)
  if pagePlan == nil then
    error("mon page " .. pageKind .. "/" .. tostring(pageId) .. " has no source plan: " .. tostring(planReason), 0)
  end
  local manifestPath = pageKind == "icons" and MonCache.iconManifestPath() or MonCache.portraitManifestPath()
  local manifestOk, manifest = pcall(cacheFs.loadLua, cacheFs, manifestPath)
  if not manifestOk or type(manifest) ~= "table" then
    error("mon page " .. pageKind .. "/" .. tostring(pageId) .. " has no published manifest", 0)
  end
  if pageKind == "icons" then
    local valid, schemaErr = pcall(MonAssetSchema.assertIconManifest, manifest)
    if not valid then
      error(schemaErr, 0)
    end
  else
    local valid, schemaErr = pcall(MonAssetSchema.assertPortraitManifest, manifest)
    if not valid then
      error(schemaErr, 0)
    end
  end
  local page, pageErr = MonPresentationCompiler.compilePage(romFs, pageKind, pagePlan)
  if page == nil then
    error(pageErr, 0)
  end
  local marker = MonCacheWriter.pageMarker(romFs:metadata().sha1, pageKind, pageId, manifest)
  return MonCacheWriter.stagePage(artifact, {
    kind = pageKind,
    pageId = pageId,
    width = page.width,
    height = page.height,
    pixels = page.pixels,
    marker = marker,
  })
end

local function executeMonSummary(artifact, context)
  local Hashing = require("romdump.src.digest.Hashing")
  local MonSources = require("romdump.src.config.MonSources")
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local romFs = assert(context.romFs, "mon summary jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "mon summary jobs require a cache filesystem")
  local catalog = MonCache.loadCatalog(cacheFs)
  local icons = cacheFs:loadLua(MonCache.iconManifestPath())
  MonAssetSchema.assertIconManifest(icons)
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  MonAssetSchema.assertPortraitManifest(portraits)
  assert(icons ~= nil and portraits ~= nil, "mon summary requires its published manifests")
  local iconMarkers, portraitMarkers = {}, {}
  for _, pageId in ipairs(icons.pageIds) do
    local marker = cacheFs:read(MonCache.pageMarkerPath("icons", pageId))
    if type(marker) ~= "string" or marker == "" then
      error("mon summary misses the staged icon page " .. tostring(pageId), 0)
    end
    iconMarkers[#iconMarkers + 1] = marker
  end
  for _, pageId in ipairs(portraits.pageIds) do
    local marker = cacheFs:read(MonCache.pageMarkerPath("portraits", pageId))
    if type(marker) ~= "string" or marker == "" then
      error("mon summary misses the staged portrait page " .. tostring(pageId), 0)
    end
    portraitMarkers[#portraitMarkers + 1] = marker
  end
  local index = MonCacheWriter.buildIndex(catalog.version, Hashing.hashLua(catalog), iconMarkers, portraitMarkers)
  return MonCacheWriter.stageSummary(artifact, index, {
    schema = "g4-mon-provenance-v1",
    source = MonSources.provenance,
    rom = { version = catalog.version.id, sha1 = romFs:metadata().sha1 },
  })
end

local function executeMessageBank(artifact, context, bankId)
  local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
  local session = messageSessionFor(context)
  local bundle, bankErr = session:compileBank(bankId)
  if bundle == nil then
    error(bankErr, 0)
  end
  return FieldMessageCacheWriter.stageBank(artifact, bundle)
end

local function executeMessageSummary(artifact, context)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
  local romFs = assert(context.romFs, "message summary jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "message summary jobs require a cache filesystem")
  local index = {
    schema = FieldMessageCache.INDEX_SCHEMA,
    version = romFs:version(),
    bankIds = FieldMessageCompiler.requiredBankIds(),
  }
  local bankMarkers = {}
  for _, bankId in ipairs(index.bankIds) do
    local marker = cacheFs:read(FieldMessageCache.bankMarkerPath(bankId))
    if type(marker) ~= "string" or marker == "" then
      error("message summary misses the staged bank " .. tostring(bankId), 0)
    end
    bankMarkers[bankId] = marker
  end
  return FieldMessageCacheWriter.stageSummary(artifact, index, bankMarkers)
end

--- The borrowed immutable generation source record behind every audio
--- leaf job: resolved once per worker generation through the worker
--- source-plan memo, never re-planned per leaf and never mutated here.
---@param context table<string, unknown>
---@param job { generationId: string, producerFingerprint: string|nil, payload: table<string, unknown> }
---@param operation string
---@return table<string, unknown>
local function generationAudioSource(context, job, operation)
  local producerId = assert(job.producerFingerprint, operation .. " require a producer")
  local payload = job.payload
  local versionId = (type(payload) == "table" and payload.versionId) or context.versionId
  assert(type(versionId) == "string" and versionId ~= "", operation .. " require the version")
  local source, sourceErr = ArtifactJobs.sourcePlanForContext(context, {
    versionId = versionId,
    generationId = assert(job.generationId, operation .. " require a generation"),
    producerId = producerId,
  })
  if source == nil then
    error(sourceErr, 0)
  end
  return source
end

--- The one audio archive session for the worker source generation,
--- selected from the memoized adopted plan like every other family
--- session: version, generation, and producer scope it, the adopted sound
--- identity verifies it, and a changed scope closes it before a new one
--- opens. Decoded waves stay per bank job; the session retains only the
--- immutable archive view and lookup.
---@param context table<string, unknown>
---@param job { generationId: string, producerFingerprint: string|nil, payload: table<string, unknown> }
---@param source table<string, unknown>
---@return table<string, unknown>
local function audioSessionForContext(context, job, source)
  local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local romFs = assert(context.romFs, "audio bank jobs require a source reader")
  local producerId = assert(job.producerFingerprint, "audio bank jobs require a producer")
  local payload = job.payload
  local versionId = (type(payload) == "table" and payload.versionId) or context.versionId
  assert(type(versionId) == "string" and versionId ~= "", "audio bank jobs require the version")
  local key = versionId
    .. "\0"
    .. assert(job.generationId, "audio bank jobs require a generation")
    .. "\0"
    .. producerId
  local session = context.audioSession
  if type(session) ~= "table" or context.audioSessionKey ~= key then
    closeFamilySession(context, "audioSession")
    context.audioSessionKey = nil
    local audioIdentity = assert(source.audioIdentity, "audio bank jobs require the published sound identity")
    ---@cast audioIdentity table<string, unknown>
    local opened, openErr = AudioCompiler.openSession(romFs, audioIdentity)
    if opened == nil then
      error(assert(openErr), 0)
    end
    session = opened
    context.audioSession = session
    context.audioSessionKey = key
  end
  return session
end

local function executeAudioBank(artifact, context, job, bankId)
  local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
  local source = generationAudioSource(context, job, "audio bank jobs")
  local audioPlan = assert(source.audioPlan, "audio bank jobs require the published audio membership")
  ---@cast audioPlan table<string, unknown>
  local selected = nil
  for _, bankPlan in ipairs(assert(audioPlan.bankPlans, "audio bank jobs require the published bank closures")) do
    ---@cast bankPlan table<string, unknown>
    if bankPlan.bankId == bankId then
      selected = bankPlan
      break
    end
  end
  if selected == nil then
    error("audio bank " .. tostring(bankId) .. " is not a member of the published audio plan", 0)
  end
  return AudioCacheWriter.stageBank(artifact, audioSessionForContext(context, job, source), selected)
end

local function executeAudioCatalog(artifact, context, job)
  local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
  local source = generationAudioSource(context, job, "audio catalog jobs")
  local audioPlan = assert(source.audioPlan, "audio catalog jobs require the published audio membership")
  local audioIdentity = assert(source.audioIdentity, "audio catalog jobs require the published sound identity")
  return AudioCacheWriter.stageCatalog(artifact, audioPlan, audioIdentity)
end

local function executeAudioSummary(artifact, context, job)
  local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
  local source = generationAudioSource(context, job, "audio summary jobs")
  local audioPlan = assert(source.audioPlan, "audio summary jobs require the published audio membership")
  return AudioCacheWriter.stageSummary(artifact, audioPlan)
end

local function executeScriptMember(artifact, context, memberId, generationKey, producer)
  local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
  local plan, session = scriptSessionFor(context, generationKey, producer)
  local member, memberErr = session:compileMember(memberId)
  if member == nil then
    error(memberErr, 0)
  end
  return ScriptCacheWriter.stageMember(artifact, plan, member)
end

local function executeScriptSummary(artifact, context, producer)
  local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
  local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
  local romFs = assert(context.romFs, "script summary jobs require a source reader")
  local plan = ScriptCompiler.plan(romFs, producer)
  return ScriptCacheWriter.stageSummary(artifact, plan)
end

local function executeMapData(artifact, context, mapId)
  local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
  local session = mapdataSessionFor(context)
  local bundle, bundleErr = session:compile(mapId)
  if bundle == nil then
    error(bundleErr or ("map-data record " .. tostring(mapId) .. " is not supported"), 0)
  end
  return FieldMapDataCacheWriter.stage(artifact, bundle)
end

local function executeFieldCell(artifact, context, payload, producer)
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
  local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")
  local descriptor = {
    matrixMemberId = assert(payload.matrixMemberId, "field-cell jobs require matrixMemberId"),
    index = assert(payload.index, "field-cell jobs require index"),
    x = assert(payload.x, "field-cell jobs require x"),
    z = assert(payload.z, "field-cell jobs require z"),
    mapHeaderId = assert(payload.mapHeaderId, "field-cell jobs require mapHeaderId"),
    altitude = assert(payload.altitude, "field-cell jobs require altitude"),
    landDataMemberId = assert(payload.landDataMemberId, "field-cell jobs require landDataMemberId"),
    areaDataMemberId = assert(payload.areaDataMemberId, "field-cell jobs require areaDataMemberId"),
    file = FieldCellCache.cellPath(payload.matrixMemberId, payload.index),
  }
  local scratch = context.fieldCellScratch or {}
  context.fieldCellScratch = scratch
  scratch.geometryArena = context.geometryArena
  scratch.gxScratch = context.gxScratch
  scratch.terrainScratch = context.terrainScratch
  local romFs = assert(context.romFs, "field-cell jobs require a source reader")
  local compiled = FieldCellCompiler.compileCell(romFs, descriptor, scratch, producer)
  FieldCellCacheWriter.stagePrepared(artifact, descriptor, compiled)
  return compiled.cell.cellMarker
end

local function executeMap(artifact, context, mapId, producer)
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
  local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
  local romFs = assert(context.romFs, "map jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "map jobs require a cache filesystem")
  local bundle = compileOrRaise(function()
    return MapAssetCompiler.compile(romFs, mapId, {
      cacheFs = cacheFs,
      fieldCellIndex = FieldCellCache.loadIndex(cacheFs),
      producerFingerprint = producer,
      geometryArena = context.geometryArena,
      gxScratch = context.gxScratch,
      terrainScratch = context.terrainScratch,
    })
  end, "map " .. tostring(mapId))
  MapCacheWriter.stage(artifact, bundle)
  return bundle.marker
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job { generationId: string, producerFingerprint: string|nil }
---@return string compiler marker for the receipt
local function executeSourcePlan(artifact, context, job)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local romFs = assert(context.romFs, "source inventory jobs require a source reader")
  local versionId = assert(context.versionId, "source inventory jobs require a version")
  local plan = SourcePlan.compile(romFs, {
    versionId = versionId,
    generationId = assert(job.generationId, "source inventory jobs require a generation"),
    producerId = assert(job.producerFingerprint, "source inventory jobs require a producer"),
  })
  return SourcePlan.stage(artifact, plan)
end

---@param artifact table<string, unknown>
---@param job ArtifactJobs.Job
---@param context table<string, unknown>
---@return string compiler marker for the receipt
local function dispatchExecute(artifact, job, context)
  local payload = job.payload or {}
  if job.kind == "source-plan" then
    return executeSourcePlan(artifact, context, job)
  elseif job.kind == "world-catalog" then
    return executeWorldCatalog(artifact, context)
  elseif job.kind == "field-cell-index" then
    return executeCellIndex(artifact, context, assert(job.producerFingerprint, "index jobs require a producer"))
  elseif job.kind == "field-camera" then
    return executeFieldCamera(artifact, context)
  elseif job.kind == "field-weather" then
    return executeFieldWeather(artifact, context)
  elseif job.kind == "field-effects" then
    return executeFieldEffects(artifact, context)
  elseif job.kind == "field-emotes" then
    return executeFieldEmotes(artifact, context)
  elseif job.kind == "field-ui" then
    return executeFieldUi(artifact, context)
  elseif job.kind == "field-font" then
    return executeFieldFont(artifact, context)
  elseif job.kind == "intro" then
    return executeIntro(artifact, context)
  elseif job.kind == "starter-choice" then
    return executeStarterChoice(artifact, context)
  elseif job.kind == "new-game-init" then
    return executeNewGameInit(artifact, context)
  elseif job.kind == "actors" then
    return executeActors(artifact, context)
  elseif job.kind == "items" then
    return executeItems(artifact, context)
  elseif job.kind == "bag" then
    return executeBag(artifact, context)
  elseif job.kind == "mon-catalog" then
    return executeMonCatalog(artifact, context)
  elseif job.kind == "mon-layout" then
    return executeMonLayout(artifact, context, assert(job.generationId, "mon layout jobs require a generation"))
  elseif job.kind == "mon-icon-page" then
    return executeMonPage(
      artifact,
      context,
      "icons",
      canonicalKeyId(job.key, "page key"),
      assert(job.generationId, "mon page jobs require a generation")
    )
  elseif job.kind == "mon-portrait-page" then
    return executeMonPage(
      artifact,
      context,
      "portraits",
      canonicalKeyId(job.key, "page key"),
      assert(job.generationId, "mon page jobs require a generation")
    )
  elseif job.kind == "mon-summary" then
    return executeMonSummary(artifact, context)
  elseif job.kind == "message-bank" then
    return executeMessageBank(artifact, context, assert(tonumber(job.key), "bank key is not canonical"))
  elseif job.kind == "message-summary" then
    return executeMessageSummary(artifact, context)
  elseif job.kind == "audio-bank" then
    return executeAudioBank(artifact, context, job, assert(tonumber(job.key), "bank key is not canonical"))
  elseif job.kind == "audio-catalog" then
    return executeAudioCatalog(artifact, context, job)
  elseif job.kind == "audio-summary" then
    return executeAudioSummary(artifact, context, job)
  elseif job.kind == "script-member" then
    return executeScriptMember(
      artifact,
      context,
      assert(payload.memberId, "script member jobs require memberId"),
      assert(payload.generationKey, "script member jobs require generationKey"),
      assert(job.producerFingerprint, "script member jobs require a producer")
    )
  elseif job.kind == "script-summary" then
    return executeScriptSummary(artifact, context, assert(job.producerFingerprint, "summary jobs require a producer"))
  elseif job.kind == "map-data" then
    return executeMapData(artifact, context, assert(tonumber(job.key), "map key is not canonical"))
  elseif job.kind == "field-cell" then
    return executeFieldCell(artifact, context, payload, assert(job.producerFingerprint, "cell jobs require a producer"))
  elseif job.kind == "map" then
    return executeMap(
      artifact,
      context,
      assert(tonumber(job.key), "map key is not canonical"),
      assert(job.producerFingerprint, "map jobs require a producer")
    )
  end
  error("unsupported compiler job kind: " .. tostring(job.kind), 0)
end

---@param job ArtifactJobs.Job
---@param context table<string, unknown>
---@return { stageName: string, result: table<string, unknown> }
function ArtifactJobs.execute(job, context)
  assert(type(job) == "table", "worker job must be a table")
  assert(type(job.kind) == "string" and job.kind ~= "", "worker job kind is required")
  assert(type(job.key) == "string" and job.key ~= "", "worker job key is required")
  ArtifactState.path(job.kind, job.key)
  assert(context and context.romFs and context.cacheFs, "worker context is incomplete")
  assert(type(job.stageName) == "string", "worker job stage name is required")
  assert(type(job.generationId) == "string" and job.generationId ~= "", "worker job generation is required")
  assert(type(job.epoch) == "number" and job.epoch % 1 == 0, "worker job epoch must be an integer")
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local artifact = PreparedArtifact.new({
    cacheFs = context.cacheFs,
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.kind .. ":" .. job.key,
    stageName = job.stageName,
  })
  -- Workers arrive through two shapes: the pool forwards scalar selectors
  -- inside payload, while direct execution flattens them beside the job
  -- identity. Merge both into one selector view; explicit top-level fields
  -- win over the payload table.
  local select = {}
  if type(job.payload) == "table" then
    for field, value in pairs(job.payload) do
      select[field] = value
    end
  end
  for field, value in pairs(job) do
    if field ~= "payload" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
      select[field] = value
    end
  end
  local normalized = {
    kind = job.kind,
    key = job.key,
    generationId = job.generationId,
    producerFingerprint = select.producerFingerprint,
    payload = select,
  }
  local ok, marker = xpcall(function()
    return dispatchExecute(artifact, normalized, context)
  end, function(failure)
    return { failure = failure, traceback = debug.traceback("", 2) }
  end)
  if not ok then
    local info = marker --[[@as { failure: unknown, traceback: string }]]
    failArtifact(artifact, info.failure, info.traceback)
    error(info.failure, 0)
  end
  assert(type(marker) == "string" and marker ~= "", "family execution carries no marker")
  artifact:finishSuccess({ marker = marker })
  return { stageName = job.stageName, result = { marker = marker } }
end

---@param cacheFs table<string, unknown>
---@param generationId string
---@param receiptKind string
---@param receiptKey string
---@return string|nil marker
local function receiptMarker(cacheFs, generationId, receiptKind, receiptKey)
  local ok, receipt = pcall(ArtifactState.read, cacheFs, generationId, receiptKind, receiptKey)
  if not ok or type(receipt) ~= "table" then
    return nil
  end
  local marker = receipt.marker
  if type(marker) ~= "string" or marker == "" then
    return nil
  end
  return marker
end

---@param cacheFs table<string, unknown>
---@param generationId string
---@param childKind string
---@param childKey string
---@param ready fun(marker: string): boolean
---@return boolean
local function childReady(cacheFs, generationId, childKind, childKey, ready)
  local marker = receiptMarker(cacheFs, generationId, childKind, childKey)
  if marker == nil then
    return false
  end
  return ready(marker)
end

---@param cacheFs table<string, unknown>
---@param generationId string
---@param kind string
---@param key string
---@param plans ArtifactJobs.Plans
---@param identity { versionId: string, generationId: string, producerId: string }|nil expected source identity, mandatory for source-plan
---@return boolean
---@return table<string, unknown>|nil validated source plan on source-plan success for immediate adoption
function ArtifactJobs.validate(cacheFs, generationId, kind, key, plans, identity)
  if kind == "source-plan" then
    assert(type(identity) == "table", "source-plan validation requires its expected identity")
    assert(
      type(identity.versionId) == "string" and identity.versionId ~= "",
      "source-plan validation requires the expected version"
    )
    assert(
      type(identity.generationId) == "string" and identity.generationId ~= "",
      "source-plan validation requires the expected generation"
    )
    assert(
      type(identity.producerId) == "string" and identity.producerId ~= "",
      "source-plan validation requires the expected producer"
    )
  end
  local ok, ready, validatedPlan = pcall(function()
    ArtifactState.path(kind, key)
    assert(type(plans) == "table", "readiness validation requires the session plans")
    local marker = receiptMarker(cacheFs, generationId, kind, key)
    if marker == nil then
      return false
    end
    if kind == "world-catalog" then
      local MapAssetCache = require("libs.assets.src.MapAssetCache")
      return MapAssetCache.isStructuralWorld(cacheFs:loadLua(MapAssetCache.worldPath()))
    elseif kind == "field-cell-index" then
      local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
      if cacheFs:read(FieldCellCache.indexMarkerPath()) ~= marker then
        return false
      end
      local indexOk, index = pcall(cacheFs.loadLua, cacheFs, FieldCellCache.indexPath())
      if not indexOk or not FieldCellCache.validateIndex(index) then
        return false
      end
      return true
    elseif kind == "field-camera" then
      local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
      return FieldCameraCache.isReady(cacheFs, marker)
    elseif kind == "field-weather" then
      local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
      return FieldWeatherCache.isReady(cacheFs, marker)
    elseif kind == "field-effects" then
      local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
      return FieldEffectAssetCache.isReady(cacheFs, marker)
    elseif kind == "field-emotes" then
      local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
      return FieldEmoteAssetCache.isReady(cacheFs, marker)
    elseif kind == "field-ui" then
      local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
      return FieldUiAssetCache.isReady(cacheFs, marker)
    elseif kind == "field-font" then
      local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
      return FieldFontCache.isReady(cacheFs, marker)
    elseif kind == "intro" then
      local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
      return IntroAssetCache.isReady(cacheFs, marker)
    elseif kind == "new-game-init" then
      local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")
      return NewGameInitCache.isReady(cacheFs, marker)
    elseif kind == "actors" then
      local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
      return FieldActorCache.isReady(cacheFs, marker)
    elseif kind == "starter-choice" then
      local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
      return StarterChoiceAssetCache.isReady(cacheFs, marker)
    elseif kind == "items" then
      local ItemCache = require("libs.assets.src.ItemCache")
      return ItemCache.isReady(cacheFs, marker)
    elseif kind == "bag" then
      local BagCache = require("libs.assets.src.BagCache")
      return BagCache.isReady(cacheFs, marker)
    elseif kind == "mon-catalog" then
      local MonCache = require("libs.assets.src.MonCache")
      return MonCache.isCatalogReady(cacheFs, marker)
    elseif kind == "mon-layout" then
      local MonCache = require("libs.assets.src.MonCache")
      if not MonCache.isLayoutReady(cacheFs, marker) then
        return false
      end
      local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
      local ready, _ = MonCacheWriter.isLayoutSourceReady(cacheFs, generationId, marker)
      return ready == true
    elseif kind == "mon-icon-page" then
      local MonCache = require("libs.assets.src.MonCache")
      return MonCache.isPageReady(cacheFs, "icons", canonicalKeyId(key, "page key"), marker)
    elseif kind == "mon-portrait-page" then
      local MonCache = require("libs.assets.src.MonCache")
      return MonCache.isPageReady(cacheFs, "portraits", canonicalKeyId(key, "page key"), marker)
    elseif kind == "mon-summary" then
      local MonCache = require("libs.assets.src.MonCache")
      if not MonCache.isReady(cacheFs, marker) then
        return false
      end
      for _, pageId in ipairs(assert(plans.iconPageIds, "mon summary needs the icon pages")) do
        local pageKey = tostring(pageId)
        if
          not childReady(cacheFs, generationId, "mon-icon-page", pageKey, function(childMarker)
            return MonCache.isPageReady(cacheFs, "icons", pageId, childMarker)
          end)
        then
          return false
        end
      end
      for _, pageId in ipairs(assert(plans.portraitPageIds, "mon summary needs the portrait pages")) do
        local pageKey = tostring(pageId)
        if
          not childReady(cacheFs, generationId, "mon-portrait-page", pageKey, function(childMarker)
            return MonCache.isPageReady(cacheFs, "portraits", pageId, childMarker)
          end)
        then
          return false
        end
      end
      return true
    elseif kind == "message-bank" then
      local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
      return FieldMessageCache.isBankReady(cacheFs, canonicalKeyId(key, "bank key"), marker)
    elseif kind == "message-summary" then
      local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
      if not FieldMessageCache.isReady(cacheFs, marker) then
        return false
      end
      for _, bankId in ipairs(assert(plans.messageBankIds, "message summary needs the required banks")) do
        if
          not childReady(cacheFs, generationId, "message-bank", tostring(bankId), function(childMarker)
            return FieldMessageCache.isBankReady(cacheFs, bankId, childMarker)
          end)
        then
          return false
        end
      end
      return true
    elseif kind == "audio-bank" then
      local AudioCache = require("libs.assets.src.audio.AudioCache")
      return AudioCache.isBankReady(cacheFs, canonicalKeyId(key, "bank key"), marker)
    elseif kind == "audio-catalog" then
      local AudioCache = require("libs.assets.src.audio.AudioCache")
      return AudioCache.isCatalogReady(cacheFs, marker)
    elseif kind == "audio-summary" then
      local AudioCache = require("libs.assets.src.audio.AudioCache")
      if not AudioCache.isReady(cacheFs, marker) then
        return false
      end
      for _, bankId in ipairs(assert(plans.audioBankIds, "audio summary needs the bank closures")) do
        if
          not childReady(cacheFs, generationId, "audio-bank", tostring(bankId), function(childMarker)
            return AudioCache.isBankReady(cacheFs, bankId, childMarker)
          end)
        then
          return false
        end
      end
      return true
    elseif kind == "script-member" then
      local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
      local scriptPlan = assert(plans.scriptPlan, "script members need the generation plan")
      local memberId = canonicalKeyId(key, "member key")
      local ready, _ = ScriptCacheWriter.isMemberReady(cacheFs, scriptPlan, memberId)
      return ready == true
    elseif kind == "script-summary" then
      local ScriptCache = require("libs.assets.src.ScriptCache")
      if not ScriptCache.isReady(cacheFs, marker) then
        return false
      end
      local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
      local scriptPlan = assert(plans.scriptPlan, "script summary needs the generation plan")
      for _, memberId in ipairs(assert(plans.scriptMemberIds, "script summary needs the nonempty members")) do
        if receiptMarker(cacheFs, generationId, "script-member", tostring(memberId)) == nil then
          return false
        end
        local ready, _ = ScriptCacheWriter.isMemberReady(cacheFs, scriptPlan, memberId)
        if not ready then
          return false
        end
      end
      return true
    elseif kind == "map-data" then
      local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
      return FieldMapDataCache.isReady(cacheFs, tonumber(key), marker)
    elseif kind == "field-cell" then
      local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
      local matrixMemberId, index = key:match("^([0-9]+)-([0-9]+)$")
      local descriptor = nil
      for _, matrix in ipairs(assert(plans.indexBundle, "cells need the canonical index").index.matrices) do
        if matrix.matrixMemberId == tonumber(matrixMemberId) then
          for _, cell in ipairs(matrix.cells) do
            if cell.index == tonumber(index) then
              descriptor = cell
              break
            end
          end
        end
        if descriptor ~= nil then
          break
        end
      end
      if descriptor == nil then
        return false
      end
      return FieldCellCache.isCellReady(cacheFs, descriptor, marker)
    elseif kind == "map" then
      local MapAssetCache = require("libs.assets.src.MapAssetCache")
      return MapAssetCache.isReady(cacheFs, canonicalKeyId(key, "map key"), marker)
    elseif kind == "source-plan" then
      local SourcePlan = require("romdump.src.build.SourcePlan")
      if marker ~= SourcePlan.marker(generationId) then
        return false
      end
      -- The expected identity always comes from the caller, never from the
      -- record being validated. The full reader is the single authority:
      -- any record it rejects is not ready, exactly once.
      local expected = assert(identity, "source-plan validation requires its expected identity")
      local plan, _ = SourcePlan.read(cacheFs, expected)
      if plan == nil then
        return false
      end
      return true, plan
    end
    return false
  end)
  if not ok then
    return false
  end
  if ready ~= true then
    return false
  end
  return true, validatedPlan
end

---@param cacheFs CacheFs
---@param identity { versionId: string, generationId: string, producerId: string }
---@return ArtifactJobs.Plans|nil
---@return string|nil
function ArtifactJobs.publishedPlans(cacheFs, identity)
  assert(cacheFs and cacheFs.read and cacheFs.loadLua, "published plans require a cache filesystem")
  assert(type(identity) == "table", "published plans require the generation identity")
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local plan, planReason = SourcePlan.read(cacheFs, identity)
  if plan == nil then
    return nil, planReason
  end
  local MonCache = require("libs.assets.src.MonCache")
  local catalogOk, catalog = pcall(MonCache.loadCatalog, cacheFs)
  if not catalogOk or type(catalog) ~= "table" then
    return nil, "mon catalog is not published"
  end
  local layoutMarker = cacheFs:read(MonCache.layoutMarkerPath())
  if type(layoutMarker) ~= "string" or layoutMarker == "" then
    return nil, "mon layout is not published"
  end
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local layoutReady, layoutReason = MonCacheWriter.isLayoutSourceReady(
    cacheFs,
    assert(identity.generationId, "published plans need a generation"),
    layoutMarker
  )
  if not layoutReady then
    return nil, layoutReason
  end
  local index = cacheFs:loadLua(MonCacheWriter.sourcePlanIndexPath())
  if type(index) ~= "table" then
    return nil, "mon page membership is not published"
  end
  local icons = cacheFs:loadLua(MonCache.iconManifestPath())
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if type(icons) ~= "table" or type(portraits) ~= "table" then
    return nil, "mon manifests are not published"
  end
  local audioBankIds = {}
  ---@cast plan table<string, unknown>
  local audioPlan = assert(plan.audioPlan, "published plans need the audio membership")
  ---@cast audioPlan table<string, unknown>
  local audioBankPlans = audioPlan.bankPlans
  ---@cast audioBankPlans table[]
  for _, bankPlan in ipairs(audioBankPlans) do
    audioBankIds[#audioBankIds + 1] = assert(bankPlan.bankId, "published plans need the audio bank identity")
  end
  table.sort(audioBankIds)
  local scriptMemberIds = {}
  local scriptPlan = assert(plan.scriptPlan, "published plans need the script membership")
  ---@cast scriptPlan table<string, unknown>
  local scriptMembers = scriptPlan.members
  ---@cast scriptMembers table[]
  for _, member in ipairs(scriptMembers) do
    scriptMemberIds[#scriptMemberIds + 1] = assert(member.memberId, "published plans need the script member identity")
  end
  table.sort(scriptMemberIds)
  local mapIds = {}
  local world = assert(plan.world, "published plans need the world membership")
  ---@cast world table<string, unknown>
  local worldMaps = world.maps
  ---@cast worldMaps table[]
  for _, record in ipairs(worldMaps) do
    mapIds[#mapIds + 1] = assert(record.id, "published plans need the world map identity")
  end
  table.sort(mapIds)
  return {
    indexBundle = plan.fieldCellIndexBundle,
    scriptPlan = plan.scriptPlan,
    audioPlan = plan.audioPlan,
    messageBankIds = plan.messageBankIds,
    audioBankIds = audioBankIds,
    scriptMemberIds = scriptMemberIds,
    iconPageIds = assert(index.iconPageIds, "published plans need the icon pages"),
    portraitPageIds = assert(index.portraitPageIds, "published plans need the portrait pages"),
    mapDataIds = plan.mapDataIds,
    mapIds = mapIds,
    mapCellKeys = plan.mapCellKeys,
    world = plan.world,
    presentation = { icons = icons, portraits = portraits },
  }
end

-- Canonical complete-inventory order behind both the materialized list
-- and the resumable enumerator: the fixed global closure first, then one
-- dynamic family after another in the same sequence. The enumerator
-- yields one logical job per call without building, sorting, or copying
-- the corpus, so interactive sweep can advance a bounded chunk per
-- update; draining it reproduces the complete list below.
-- Aggregate summaries enumerate last: registering one before its leaves
-- would expand the whole leaf family through ordinary dependency edges.
local COMPLETE_TRAIL_SUMMARIES = {
  "mon-summary",
  "message-summary",
  "audio-summary",
  "script-summary",
}

local COMPLETE_STATIC_GLOBALS = {
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
  "audio-catalog",
}

-- Producer-internal generation source-plan memo for compiler-worker
-- context. The worker owns the memo for one VM: it returns the validated
-- record for the worker's current version/generation/producer identity
-- and re-reads through the validating reader whenever that identity
-- changes. The record is borrowed immutable; it carries no ROM handle
-- and never reaches runtime packages.
---@param context table<string, unknown>
---@param identity { versionId: string, generationId: string, producerId: string }
---@return table<string, unknown>|nil
---@return string|nil
function ArtifactJobs.sourcePlanForContext(context, identity)
  assert(type(context) == "table", "worker source plans require a context table")
  assert(type(identity) == "table", "worker source plans require the generation identity")
  assert(type(identity.versionId) == "string" and identity.versionId ~= "", "worker source plans require the version")
  assert(
    type(identity.generationId) == "string" and identity.generationId ~= "",
    "worker source plans require the generation"
  )
  assert(
    type(identity.producerId) == "string" and identity.producerId ~= "",
    "worker source plans require the producer"
  )
  local memo = context.sourcePlanMemo
  if
    type(memo) == "table"
    and memo.versionId == identity.versionId
    and memo.generationId == identity.generationId
    and memo.producerId == identity.producerId
    and type(memo.plan) == "table"
  then
    return memo.plan
  end
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local cacheFs = assert(context.cacheFs, "worker source plans require a cache filesystem")
  local plan, reason = SourcePlan.read(cacheFs, identity)
  if plan == nil then
    return nil, reason
  end
  context.sourcePlanMemo = {
    versionId = identity.versionId,
    generationId = identity.generationId,
    producerId = identity.producerId,
    plan = plan,
  }
  return plan
end

---@param audioPlan table<string, unknown>
---@return integer[]
local function sourceAudioBankIds(audioPlan)
  local ids = {}
  for _, bankPlan in ipairs(assert(audioPlan.bankPlans, "worker validation needs the audio bank closures")) do
    ids[#ids + 1] = assert(bankPlan.bankId, "worker validation needs the audio bank identity")
  end
  table.sort(ids)
  return ids
end

---@param scriptPlan table<string, unknown>
---@return integer[]
local function sourceScriptMemberIds(scriptPlan)
  local ids = {}
  for _, member in ipairs(assert(scriptPlan.members, "worker validation needs the script membership")) do
    ids[#ids + 1] = assert(member.memberId, "worker validation needs the script member identity")
  end
  table.sort(ids)
  return ids
end

---@param world table<string, unknown>
---@return integer[]
local function sourceMapIds(world)
  local ids = {}
  for _, record in ipairs(assert(world.maps, "worker validation needs the world membership")) do
    ids[#ids + 1] = assert(record.id, "worker validation needs the world map identity")
  end
  table.sort(ids)
  return ids
end

-- Worker-facing readiness wrapper around the one authoritative family
-- validator. It assembles the minimal plan envelope for the job:
-- source-static selections always, the worker generation memo for
-- source-derived families, the published mon page index for mon summary
-- work. Families independent of the source inventory never force a
-- source-plan read. A false answer means compile, never job failure.
---@param job { kind: string, key: string, generationId: string, producerFingerprint: string|nil, versionId: string|nil, payload: table<string, unknown>|nil }
---@param context table<string, unknown>
---@return boolean
function ArtifactJobs.validateCurrent(job, context)
  assert(type(job) == "table", "worker validation requires a job")
  assert(type(job.kind) == "string" and job.kind ~= "", "worker validation requires the job kind")
  assert(type(job.key) == "string" and job.key ~= "", "worker validation requires the job key")
  ArtifactState.path(job.kind, job.key)
  assert(type(context) == "table", "worker validation requires a context table")
  local cacheFs = assert(context.cacheFs, "worker validation requires a cache filesystem")
  assert(type(job.generationId) == "string" and job.generationId ~= "", "worker validation requires the job generation")
  local versionId = job.versionId or context.versionId
  assert(type(versionId) == "string" and versionId ~= "", "worker validation requires the version")
  local producerId = job.producerFingerprint
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local plans = {
    messageBankIds = FieldMessageCompiler.requiredBankIds(),
    mapDataIds = FieldMapDataCompiler.supportedMapIds(),
  }
  if
    job.kind == "field-cell"
    or job.kind == "script-member"
    or job.kind == "script-summary"
    or job.kind == "audio-summary"
  then
    if type(producerId) ~= "string" or producerId == "" then
      return false
    end
    local source, _ = ArtifactJobs.sourcePlanForContext(context, {
      versionId = versionId,
      generationId = job.generationId,
      producerId = producerId,
    })
    if source == nil then
      return false
    end
    ---@cast source table<string, unknown>
    plans.indexBundle = source.fieldCellIndexBundle
    plans.scriptPlan = source.scriptPlan
    plans.audioPlan = source.audioPlan
    plans.messageBankIds = source.messageBankIds
    plans.mapDataIds = source.mapDataIds
    plans.mapCellKeys = source.mapCellKeys
    plans.world = source.world
    plans.audioBankIds = sourceAudioBankIds(assert(source.audioPlan, "worker validation needs the audio membership"))
    plans.scriptMemberIds =
      sourceScriptMemberIds(assert(source.scriptPlan, "worker validation needs the script membership"))
    plans.mapIds = sourceMapIds(assert(source.world, "worker validation needs the world membership"))
  elseif job.kind == "mon-summary" then
    local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
    local ok, index = pcall(cacheFs.loadLua, cacheFs, MonCacheWriter.sourcePlanIndexPath())
    if not ok or type(index) ~= "table" then
      return false
    end
    ---@cast index table<string, unknown>
    plans.iconPageIds = index.iconPageIds
    plans.portraitPageIds = index.portraitPageIds
  elseif job.kind == "source-plan" then
    if type(producerId) ~= "string" or producerId == "" then
      return false
    end
  end
  -- The source inventory is the only family that reads the producer
  -- identity, and it returns above unless the producer is present, so
  -- an absent producer below is never consulted.
  return ArtifactJobs.validate(cacheFs, job.generationId, job.kind, job.key, plans, {
    versionId = versionId,
    generationId = job.generationId,
    producerId = producerId or "",
  })
end

---@param plans ArtifactJobs.Plans
---@return fun(): { kind: string, key: string, jobKey: string }|nil
function ArtifactJobs.completeIterator(plans)
  assert(type(plans) == "table", "complete inventory requires its published plans")
  local messageBankIds = assert(plans.messageBankIds, "complete inventory needs the message banks")
  local audioBankIds = assert(plans.audioBankIds, "complete inventory needs the audio banks")
  local scriptMemberIds = assert(plans.scriptMemberIds, "complete inventory needs the script members")
  local iconPageIds = assert(plans.iconPageIds, "complete inventory needs the icon pages")
  local portraitPageIds = assert(plans.portraitPageIds, "complete inventory needs the portrait pages")
  local mapDataIds = assert(plans.mapDataIds, "complete inventory needs the field records")
  local mapIds = assert(plans.mapIds, "complete inventory needs the world maps")
  local indexBundle = assert(plans.indexBundle, "complete inventory needs the canonical cell index")
  ---@cast indexBundle table<string, unknown>
  local cellIndex = assert(indexBundle.index, "complete inventory needs the canonical cell index")
  ---@cast cellIndex table<string, unknown>
  local matrices = assert(cellIndex.matrices, "complete inventory needs the canonical cell index")
  ---@cast matrices table[]
  local function identify(kind, key)
    return { kind = kind, key = key, jobKey = ArtifactJobs.jobKey(kind, key) }
  end
  local phase = 0
  local position = 1
  local matrixPosition = 1
  local cellPosition = 1
  local function nextComplete()
    while true do
      if phase == 0 then
        phase, position = 1, 1
        return identify("source-plan", "global")
      elseif phase == 1 then
        if position <= #COMPLETE_STATIC_GLOBALS then
          local kind = COMPLETE_STATIC_GLOBALS[position]
          position = position + 1
          return identify(kind, "global")
        end
        phase, position = 2, 1
      elseif phase == 2 then
        if position <= #messageBankIds then
          local bankId = messageBankIds[position]
          position = position + 1
          return identify("message-bank", tostring(bankId))
        end
        phase, position = 3, 1
      elseif phase == 3 then
        if position <= #audioBankIds then
          local bankId = audioBankIds[position]
          position = position + 1
          return identify("audio-bank", tostring(bankId))
        end
        phase, position = 4, 1
      elseif phase == 4 then
        if position <= #scriptMemberIds then
          local memberId = scriptMemberIds[position]
          position = position + 1
          return identify("script-member", tostring(memberId))
        end
        phase, position = 5, 1
      elseif phase == 5 then
        if position <= #iconPageIds then
          local pageId = iconPageIds[position]
          position = position + 1
          return identify("mon-icon-page", tostring(pageId))
        end
        phase, position = 6, 1
      elseif phase == 6 then
        if position <= #portraitPageIds then
          local pageId = portraitPageIds[position]
          position = position + 1
          return identify("mon-portrait-page", tostring(pageId))
        end
        phase, position = 7, 1
      elseif phase == 7 then
        if position <= #mapDataIds then
          local mapId = mapDataIds[position]
          position = position + 1
          return identify("map-data", tostring(mapId))
        end
        phase = 8
      elseif phase == 8 then
        while matrixPosition <= #matrices do
          local cells = matrices[matrixPosition].cells
          if cellPosition <= #cells then
            local descriptor = cells[cellPosition]
            cellPosition = cellPosition + 1
            return identify("field-cell", descriptor.matrixMemberId .. "-" .. descriptor.index)
          end
          matrixPosition = matrixPosition + 1
          cellPosition = 1
        end
        phase, position = 9, 1
      elseif phase == 9 then
        if position <= #mapIds then
          local mapId = mapIds[position]
          position = position + 1
          return identify("map", tostring(mapId))
        end
        phase, position = 10, 1
      elseif phase == 10 then
        -- Aggregate summaries close the enumeration so background
        -- registration meets already-ready leaves instead of expanding
        -- whole families at once. The enumerated set is unchanged; only
        -- the deterministic order moves.
        if position <= #COMPLETE_TRAIL_SUMMARIES then
          local kind = COMPLETE_TRAIL_SUMMARIES[position]
          position = position + 1
          return identify(kind, "global")
        end
        return nil
      else
        return nil
      end
    end
  end
  return nextComplete
end

---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string, jobKey: string }[]
function ArtifactJobs.completeJobs(plans)
  assert(type(plans) == "table", "complete inventory requires its published plans")
  local jobs = {}
  local seen = {}
  local iterate = ArtifactJobs.completeIterator(plans)
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    if not seen[job.jobKey] then
      seen[job.jobKey] = true
      jobs[#jobs + 1] = job
    end
  end
  table.sort(jobs, function(left, right)
    if left.kind == right.kind then
      local leftId, rightId = tonumber(left.key), tonumber(right.key)
      if leftId ~= nil and rightId ~= nil then
        return leftId < rightId
      end
      return left.key < right.key
    end
    return left.kind < right.kind
  end)
  return jobs
end

---@param catalog table<string, unknown> mon semantic catalog with species/forms
---@param actorSpriteIds table<integer, boolean> merged actor index membership
---@return true|nil
---@return string|nil
function ArtifactJobs.checkFollowers(catalog, actorSpriteIds)
  if type(catalog) ~= "table" or type(catalog.species) ~= "table" then
    return nil, "mon catalog carries no species table"
  end
  if type(actorSpriteIds) ~= "table" then
    return nil, "merged actor index is unavailable"
  end
  for speciesKey, species in pairs(catalog.species) do
    if type(species) == "table" and type(species.forms) == "table" then
      for formId, form in pairs(species.forms) do
        if type(form) == "table" and form.follower ~= nil then
          local refs = { form.follower.visualId }
          if form.follower.female ~= nil then
            refs[#refs + 1] = form.follower.female.visualId
          end
          for _, visualId in ipairs(refs) do
            if not actorSpriteIds[visualId] then
              return nil,
                "catalog follower visual " .. tostring(visualId) .. " for " .. tostring(speciesKey) .. "/" .. tostring(
                  formId
                ) .. " is absent from the merged actor index"
            end
          end
        end
      end
    end
  end
  return true
end

return ArtifactJobs
