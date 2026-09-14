-- Closed dispatch of derived-cache family jobs: the one kind/key
-- vocabulary, the fixed size policy, milestone membership, dependency
-- edges, worker execution and readiness validation shared by the
-- generation session, the compiler workers and the common batch client.
-- There is no runtime registration surface; every family resolves through
-- this table's fixed handlers, and every handler reuses its owning domain
-- compiler/writer without duplicating source semantics.

local ArtifactState = require("romdump.src.build.ArtifactState")

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
---@field presentation table<string, unknown>|nil MonPresentationCompiler.plan bundle
---@field messageBankIds integer[]|nil required message bank ids
---@field audioBankIds integer[]|nil planned audio bank ids
---@field scriptMemberIds integer[]|nil nonempty script member ids
---@field iconPageIds integer[]|nil planned icon page ids
---@field portraitPageIds integer[]|nil planned portrait page ids
---@field mapCellKeys table<integer, string[]>|nil mapId to canonical cell keys
---@field resolveMapPlan ((fun(mapId: integer): table<string, unknown>|nil))|nil cached map planner

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
  ["field-font"] = "heavy",
  actors = "heavy",
  ["mon-catalog"] = "heavy",
  ["mon-layout"] = "heavy",
  ["audio-bank"] = "heavy",
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

local BOOTSTRAP_COARSE = {
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
  "mon-catalog",
  "mon-layout",
  "message-bank:219",
  "audio-summary",
}

local function sortedJobs(jobs)
  table.sort(jobs, function(left, right)
    if left.kind == right.kind then
      return left.key < right.key
    end
    return left.kind < right.kind
  end)
  return jobs
end

---@param audioBankIds integer[]
---@return { kind: string, key: string }[]
function ArtifactJobs.bootstrapJobs(audioBankIds)
  assert(type(audioBankIds) == "table", "bootstrap membership requires the planned audio closures")
  local jobs = {}
  for _, entry in ipairs(BOOTSTRAP_COARSE) do
    local kind, key = entry:match("^([^:]+):?(.*)$")
    assert(kind, "bootstrap membership entry is malformed: " .. tostring(entry))
    if key == "" then
      key = "global"
    end
    jobs[#jobs + 1] = { kind = kind, key = key }
  end
  for _, bankId in ipairs(audioBankIds) do
    assert(type(bankId) == "number" and bankId % 1 == 0 and bankId >= 0, "audio closure needs its bank identity")
    jobs[#jobs + 1] = { kind = "audio-bank", key = tostring(bankId) }
  end
  return sortedJobs(jobs)
end

---@param lists { audioBankIds: integer[], messageBankIds: integer[], scriptMemberIds: integer[], iconPageIds: integer[], mapDataIds: integer[] }
---@return { kind: string, key: string }[]
function ArtifactJobs.fieldCoreJobs(lists)
  assert(type(lists) == "table", "field-core membership requires the planned family selections")
  local jobs = ArtifactJobs.bootstrapJobs(assert(lists.audioBankIds, "field-core needs the audio closures"))
  local messageBankIds = assert(lists.messageBankIds, "field-core needs the required message banks")
  local scriptMemberIds = assert(lists.scriptMemberIds, "field-core needs the nonempty script members")
  local iconPageIds = assert(lists.iconPageIds, "field-core needs the icon pages")
  local mapDataIds = assert(lists.mapDataIds, "field-core needs the supported field records")
  jobs[#jobs + 1] = { kind = "actors", key = "global" }
  jobs[#jobs + 1] = { kind = "starter-choice", key = "global" }
  jobs[#jobs + 1] = { kind = "items", key = "global" }
  jobs[#jobs + 1] = { kind = "bag", key = "global" }
  jobs[#jobs + 1] = { kind = "message-summary", key = "global" }
  jobs[#jobs + 1] = { kind = "script-summary", key = "global" }
  for _, bankId in ipairs(messageBankIds) do
    jobs[#jobs + 1] = { kind = "message-bank", key = tostring(bankId) }
  end
  for _, memberId in ipairs(scriptMemberIds) do
    jobs[#jobs + 1] = { kind = "script-member", key = tostring(memberId) }
  end
  for _, pageId in ipairs(iconPageIds) do
    jobs[#jobs + 1] = { kind = "mon-icon-page", key = tostring(pageId) }
  end
  for _, mapId in ipairs(mapDataIds) do
    jobs[#jobs + 1] = { kind = "map-data", key = tostring(mapId) }
  end
  return sortedJobs(jobs)
end

---@param kind string
---@param key string
---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[]
function ArtifactJobs.dependencies(kind, key, plans)
  ArtifactState.path(kind, key)
  assert(type(plans) == "table", "dependency edges require the session plans")
  local deps = {}
  if kind == "mon-layout" then
    deps[#deps + 1] = { kind = "mon-catalog", key = "global" }
  elseif kind == "mon-icon-page" or kind == "mon-portrait-page" then
    deps[#deps + 1] = { kind = "mon-layout", key = "global" }
  elseif kind == "mon-summary" then
    deps[#deps + 1] = { kind = "mon-catalog", key = "global" }
    deps[#deps + 1] = { kind = "mon-layout", key = "global" }
    for _, pageId in ipairs(assert(plans.iconPageIds, "mon summary needs the icon pages")) do
      deps[#deps + 1] = { kind = "mon-icon-page", key = tostring(pageId) }
    end
    for _, pageId in ipairs(assert(plans.portraitPageIds, "mon summary needs the portrait pages")) do
      deps[#deps + 1] = { kind = "mon-portrait-page", key = tostring(pageId) }
    end
  elseif kind == "message-summary" then
    for _, bankId in ipairs(assert(plans.messageBankIds, "message summary needs the required banks")) do
      deps[#deps + 1] = { kind = "message-bank", key = tostring(bankId) }
    end
  elseif kind == "audio-summary" then
    for _, bankId in ipairs(assert(plans.audioBankIds, "audio summary needs the bank closures")) do
      deps[#deps + 1] = { kind = "audio-bank", key = tostring(bankId) }
    end
  elseif kind == "script-summary" then
    for _, memberId in ipairs(assert(plans.scriptMemberIds, "script summary needs the nonempty members")) do
      deps[#deps + 1] = { kind = "script-member", key = tostring(memberId) }
    end
  elseif kind == "map" then
    deps[#deps + 1] = { kind = "world-catalog", key = "global" }
    deps[#deps + 1] = { kind = "field-cell-index", key = "global" }
    local cellKeys = plans.mapCellKeys and plans.mapCellKeys[tonumber(key)]
    assert(cellKeys ~= nil, "map dependencies require the resolved cell plans for map " .. key)
    for _, cellKey in ipairs(cellKeys) do
      deps[#deps + 1] = { kind = "field-cell", key = cellKey }
    end
  elseif kind == "field-cell" then
    deps[#deps + 1] = { kind = "field-cell-index", key = "global" }
  end
  return deps
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

local function executeMonLayout(artifact, context)
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local romFs = assert(context.romFs, "mon layout jobs require a source reader")
  local presentation = planPresentation(romFs, compileCatalog(romFs))
  local romSha1 = romFs:metadata().sha1
  return MonCacheWriter.stageLayout(artifact, {
    icons = presentation.icons,
    portraits = presentation.portraits,
    marker = MonCacheWriter.layoutMarker(romSha1, presentation.icons, presentation.portraits),
  })
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param pageKind "icons"|"portraits"
---@param pageId integer
---@return string
local function executeMonPage(artifact, context, pageKind, pageId)
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
  local romFs = assert(context.romFs, "mon page jobs require a source reader")
  local presentation = planPresentation(romFs, compileCatalog(romFs))
  local manifest = pageKind == "icons" and presentation.icons or presentation.portraits
  local pagePlans = pageKind == "icons" and presentation.iconPages or presentation.portraitPages
  local pagePlan = pagePlans[pageId]
  if pagePlan == nil then
    error("mon page " .. pageKind .. "/" .. tostring(pageId) .. " has no source plan", 0)
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
  local romFs = assert(context.romFs, "mon summary jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "mon summary jobs require a cache filesystem")
  local catalog = compileCatalog(romFs)
  local presentation = planPresentation(romFs, catalog)
  local iconMarkers, portraitMarkers = {}, {}
  for _, pageId in ipairs(presentation.icons.pageIds) do
    local marker = cacheFs:read(MonCache.pageMarkerPath("icons", pageId))
    if type(marker) ~= "string" or marker == "" then
      error("mon summary misses the staged icon page " .. tostring(pageId), 0)
    end
    iconMarkers[#iconMarkers + 1] = marker
  end
  for _, pageId in ipairs(presentation.portraits.pageIds) do
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

local function executeAudioBank(artifact, context, bankId)
  local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
  local romFs = assert(context.romFs, "audio bank jobs require a source reader")
  local plan, planErr = AudioCompiler.plan(romFs)
  if plan == nil then
    error(planErr, 0)
  end
  local selected = nil
  for _, bankPlan in ipairs(plan.bankPlans) do
    if bankPlan.bankId == bankId then
      selected = bankPlan
      break
    end
  end
  if selected == nil then
    error("audio bank " .. tostring(bankId) .. " has no source plan", 0)
  end
  return AudioCacheWriter.stageBank(artifact, romFs, selected)
end

local function executeAudioSummary(artifact, context)
  local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
  local romFs = assert(context.romFs, "audio summary jobs require a source reader")
  local plan, planErr = AudioCompiler.plan(romFs)
  if plan == nil then
    error(planErr, 0)
  end
  return AudioCacheWriter.stageSummary(artifact, plan)
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
---@param job ArtifactJobs.Job
---@param context table<string, unknown>
---@return string compiler marker for the receipt
local function dispatchExecute(artifact, job, context)
  local payload = job.payload or {}
  if job.kind == "world-catalog" then
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
    return executeMonLayout(artifact, context)
  elseif job.kind == "mon-icon-page" then
    return executeMonPage(artifact, context, "icons", canonicalKeyId(job.key, "page key"))
  elseif job.kind == "mon-portrait-page" then
    return executeMonPage(artifact, context, "portraits", canonicalKeyId(job.key, "page key"))
  elseif job.kind == "mon-summary" then
    return executeMonSummary(artifact, context)
  elseif job.kind == "message-bank" then
    return executeMessageBank(artifact, context, assert(tonumber(job.key), "bank key is not canonical"))
  elseif job.kind == "message-summary" then
    return executeMessageSummary(artifact, context)
  elseif job.kind == "audio-bank" then
    return executeAudioBank(artifact, context, assert(tonumber(job.key), "bank key is not canonical"))
  elseif job.kind == "audio-summary" then
    return executeAudioSummary(artifact, context)
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
---@return boolean
function ArtifactJobs.validate(cacheFs, generationId, kind, key, plans)
  local ok, ready = pcall(function()
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
      return cacheFs:read(FieldCellCache.indexMarkerPath()) == marker
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
      return MonCache.isLayoutReady(cacheFs, marker)
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
      local ScriptCache = require("libs.assets.src.ScriptCache")
      local scriptPlan = assert(plans.scriptPlan, "script members need the generation plan")
      local memberId = assert(tonumber(key), "member key is not canonical")
      return cacheFs:read(ScriptCache.memberMarkerPath(scriptPlan.generationKey, memberId)) == marker
    elseif kind == "script-summary" then
      local ScriptCache = require("libs.assets.src.ScriptCache")
      if not ScriptCache.isReady(cacheFs, marker) then
        return false
      end
      local scriptPlan = assert(plans.scriptPlan, "script summary needs the generation plan")
      for _, memberId in ipairs(assert(plans.scriptMemberIds, "script summary needs the nonempty members")) do
        local childMarker = receiptMarker(cacheFs, generationId, "script-member", tostring(memberId))
        if
          childMarker == nil
          or cacheFs:read(ScriptCache.memberMarkerPath(scriptPlan.generationKey, memberId)) ~= childMarker
        then
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
      local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
      local resolve = assert(plans.resolveMapPlan, "maps need the cached map planner")
      local mapPlan = resolve(canonicalKeyId(key, "map key"))
      if mapPlan == nil then
        return false
      end
      return MapCompilePlan.isReady(cacheFs, mapPlan)
    end
    return false
  end)
  if not ok then
    return false
  end
  return ready == true
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
