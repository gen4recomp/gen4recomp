-- Worker-compiled, controller-consumed inventory of one generation's source
-- membership: which maps, cells, scripts, audio closures, message banks and
-- field records the dump carries, with explicit exclusion reasons and the
-- canonical cell keys behind every loadable map. Data only: no functions,
-- ROM bytes, open archives, userdata, decoded pixels or repeated full map
-- matrices cross the worker boundary. The generation session and the batch
-- audit read the same staged record instead of probing ROM on the
-- controller. Source policy stays with the existing family owners; this
-- module only assembles, checks and stages their data-only answers.

local Errors = require("libs.errors.src.Errors")

local SourcePlan = {}

SourcePlan.PATH = "data/generated/producer/source-plan.lua"
SourcePlan.SCHEMA = "g4-source-plan-v2"

---@param generationId string
---@return string
function SourcePlan.marker(generationId)
  assert(type(generationId) == "string" and generationId ~= "", "source inventory marker needs its generation")
  return SourcePlan.SCHEMA .. ":" .. generationId
end

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function isAscendingUniqueIds(values)
  if type(values) ~= "table" then
    return false
  end
  local previous = nil
  for _, value in ipairs(values) do
    if not isInteger(value) or value < 0 then
      return false
    end
    if previous ~= nil and value <= previous then
      return false
    end
    previous = value
  end
  return true
end

local function isAscendingUniqueKeys(values)
  if type(values) ~= "table" then
    return false
  end
  local previous = nil
  for _, value in ipairs(values) do
    if type(value) ~= "string" then
      return false
    end
    if previous ~= nil and value <= previous then
      return false
    end
    previous = value
  end
  return true
end

---@param value unknown
---@param trail table<string, boolean>
---@return true|nil
---@return string|nil
local function checkDataOnly(value, trail)
  local kind = type(value)
  if kind == "string" or kind == "boolean" then
    return true
  end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, "source inventory carries a non-finite number"
    end
    return true
  end
  if kind ~= "table" then
    return nil, "source inventory carries a non-data value of type " .. kind
  end
  if trail[value] then
    return nil, "source inventory carries a cyclic reference"
  end
  trail[value] = true
  for key, entry in pairs(value) do
    local keyKind = type(key)
    if keyKind ~= "string" and keyKind ~= "number" and keyKind ~= "boolean" then
      trail[value] = nil
      return nil, "source inventory carries a non-data key"
    end
    local ok, reason = checkDataOnly(entry, trail)
    if not ok then
      trail[value] = nil
      return nil, reason
    end
  end
  trail[value] = nil
  return true
end

local function sortedUnique(values)
  table.sort(values)
  local out = {}
  local previous = nil
  for _, value in ipairs(values) do
    if value ~= previous then
      out[#out + 1] = value
      previous = value
    end
  end
  return out
end

local function equalIdLists(values, expected)
  if #values ~= #expected then
    return false
  end
  for index, value in ipairs(values) do
    if value ~= expected[index] then
      return false
    end
  end
  return true
end

---@param plan table<string, unknown>
---@param identity { versionId: string, generationId: string, producerId: string }
---@return true|nil
---@return string|nil
function SourcePlan.validate(plan, identity)
  assert(type(identity) == "table", "source inventory validation requires its generation identity")
  if type(plan) ~= "table" then
    return nil, "source inventory is not a table"
  end
  local allowed = {
    schema = true,
    versionId = true,
    romSha1 = true,
    generationId = true,
    producerId = true,
    world = true,
    fieldCellIndexBundle = true,
    scriptPlan = true,
    audioPlan = true,
    audioIdentity = true,
    messageBankIds = true,
    mapDataIds = true,
    mapCellKeys = true,
  }
  for field in pairs(plan) do
    if not allowed[field] then
      return nil, "source inventory carries an unknown field " .. tostring(field)
    end
  end
  for field in pairs(allowed) do
    if plan[field] == nil then
      return nil, "source inventory is missing " .. field
    end
  end
  if plan.schema ~= SourcePlan.SCHEMA then
    return nil, "source inventory schema mismatch"
  end
  if plan.versionId ~= identity.versionId then
    return nil, "source inventory version is not current"
  end
  if plan.generationId ~= identity.generationId then
    return nil, "source inventory generation is not current"
  end
  if plan.producerId ~= identity.producerId then
    return nil, "source inventory producer is not current"
  end
  if type(plan.romSha1) ~= "string" or plan.romSha1:match("^[0-9a-fA-F]+$") == nil or #plan.romSha1 ~= 40 then
    return nil, "source inventory carries no ROM identity"
  end
  local ok, reason = checkDataOnly(plan, {})
  if not ok then
    return nil, reason
  end
  local world = plan.world --[[@as table<string, unknown>]]
  if type(world) ~= "table" then
    return nil, "source inventory carries no world membership"
  end
  local worldMaps = world.maps --[[@as table[] ]]
  if type(worldMaps) ~= "table" then
    return nil, "source inventory carries no world membership"
  end
  local worldIds = {}
  do
    local seen = {}
    for _, record in ipairs(worldMaps) do
      if type(record) ~= "table" or not isInteger(record.id) or record.id < 0 then
        return nil, "source inventory carries an unidentified world map"
      end
      if seen[record.id] then
        return nil, "source inventory carries a duplicate world map " .. tostring(record.id)
      end
      seen[record.id] = true
      worldIds[#worldIds + 1] = record.id
    end
  end
  table.sort(worldIds)
  local analysis = world.analysis
  local excluded = type(analysis) == "table" and analysis.excluded or nil --[[@as table[]|nil ]]
  if type(excluded) ~= "table" then
    return nil, "source inventory carries no source exclusion analysis"
  end
  for _, record in ipairs(excluded) do
    if
      type(record) ~= "table"
      or not isInteger(record.id)
      or type(record.reason) ~= "string"
      or record.reason == ""
    then
      return nil, "source inventory carries an unexplained source exclusion"
    end
  end
  local bundle = plan.fieldCellIndexBundle --[[@as table<string, unknown>]]
  if type(bundle) ~= "table" or type(bundle.index) ~= "table" or type(bundle.indexMarker) ~= "string" then
    return nil, "source inventory carries no canonical cell index"
  end
  local cells = {}
  local bundleIndex = bundle.index --[[@as table<string, unknown> ]]
  local matrices = type(bundleIndex) == "table" and bundleIndex.matrices or nil --[[@as table[]|nil ]]
  if type(matrices) ~= "table" then
    return nil, "source inventory carries no canonical cell index"
  end
  for _, matrix in ipairs(matrices) do
    if type(matrix) ~= "table" or not isInteger(matrix.matrixMemberId) or type(matrix.cells) ~= "table" then
      return nil, "source inventory carries an unidentified cell matrix"
    end
    for _, descriptor in ipairs(matrix.cells) do
      if
        type(descriptor) ~= "table"
        or descriptor.matrixMemberId ~= matrix.matrixMemberId
        or not isInteger(descriptor.index)
      then
        return nil, "source inventory carries an unidentified cell"
      end
      cells[descriptor.matrixMemberId .. "-" .. descriptor.index] = true
    end
  end
  local scriptPlan = plan.scriptPlan --[[@as table<string, unknown>]]
  if type(scriptPlan) ~= "table" then
    return nil, "source inventory carries no script membership"
  end
  local scriptMembers = scriptPlan.members --[[@as table[] ]]
  if type(scriptMembers) ~= "table" then
    return nil, "source inventory carries no script membership"
  end
  if type(scriptPlan.generationKey) ~= "string" or scriptPlan.generationKey == "" then
    return nil, "source inventory carries no script generation"
  end
  do
    local previous = nil
    for _, member in ipairs(scriptMembers) do
      if type(member) ~= "table" or not isInteger(member.memberId) or member.memberId < 0 then
        return nil, "source inventory carries an unidentified script member"
      end
      if previous ~= nil and member.memberId <= previous then
        return nil, "source inventory script members are not ascending and unique"
      end
      previous = member.memberId
    end
  end
  local audioPlan = plan.audioPlan --[[@as table<string, unknown>]]
  if type(audioPlan) ~= "table" then
    return nil, "source inventory carries no audio membership"
  end
  local audioBankPlans = audioPlan.bankPlans --[[@as table[] ]]
  if type(audioPlan) ~= "table" or type(audioPlan.index) ~= "table" or type(audioBankPlans) ~= "table" then
    return nil, "source inventory carries no audio membership"
  end
  do
    local previous = nil
    for _, bankPlan in ipairs(audioBankPlans) do
      if type(bankPlan) ~= "table" or not isInteger(bankPlan.bankId) or bankPlan.bankId < 0 then
        return nil, "source inventory carries an unidentified audio bank"
      end
      if previous ~= nil and bankPlan.bankId <= previous then
        return nil, "source inventory audio banks are not ascending and unique"
      end
      previous = bankPlan.bankId
    end
  end
  local audioIdentity = plan.audioIdentity --[[@as table<string, unknown>]]
  if type(audioIdentity) ~= "table" then
    return nil, "source inventory carries no sound archive identity"
  end
  do
    local fields = 0
    for _ in pairs(audioIdentity) do
      fields = fields + 1
    end
    if fields ~= 3 then
      return nil, "source inventory sound archive identity carries an unexpected field"
    end
  end
  if
    type(audioIdentity.romSha1) ~= "string"
    or #audioIdentity.romSha1 ~= 40
    or audioIdentity.romSha1:match("^[0-9a-fA-F]+$") == nil
  then
    return nil, "source inventory sound archive identity carries no ROM identity"
  end
  if
    type(audioIdentity.sdatSha1) ~= "string"
    or #audioIdentity.sdatSha1 ~= 40
    or audioIdentity.sdatSha1:match("^[0-9a-fA-F]+$") == nil
  then
    return nil, "source inventory sound archive identity carries no archive digest"
  end
  if not isInteger(audioIdentity.sdatFileId) or audioIdentity.sdatFileId < 0 then
    return nil, "source inventory sound archive identity carries no archive file identity"
  end
  if audioIdentity.romSha1 ~= plan.romSha1 then
    return nil, "source inventory sound archive identity disagrees with the ROM identity"
  end
  if not isAscendingUniqueIds(plan.messageBankIds) then
    return nil, "source inventory message banks are not ascending and unique"
  end
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  if
    not equalIdLists(plan.messageBankIds --[[@as integer[] ]], FieldMessageCompiler.requiredBankIds())
  then
    return nil, "source inventory message banks disagree with the required banks"
  end
  if not isAscendingUniqueIds(plan.mapDataIds) then
    return nil, "source inventory field records are not ascending and unique"
  end
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  if
    not equalIdLists(plan.mapDataIds --[[@as integer[] ]], FieldMapDataCompiler.supportedMapIds())
  then
    return nil, "source inventory field records disagree with the supported records"
  end
  local mapCellKeys = plan.mapCellKeys --[[@as table<integer, string[]> ]]
  if type(mapCellKeys) ~= "table" then
    return nil, "source inventory carries no map cell keys"
  end
  do
    local keyed = {}
    for mapId in pairs(mapCellKeys) do
      if not isInteger(mapId) or mapId < 0 then
        return nil, "source inventory carries an unidentified map cell record"
      end
      keyed[#keyed + 1] = mapId
    end
    table.sort(keyed)
    if not equalIdLists(keyed, worldIds) then
      return nil, "source inventory map membership is incomplete"
    end
    for _, mapId in ipairs(keyed) do
      local keys = mapCellKeys[mapId]
      if not isAscendingUniqueKeys(keys) then
        return nil, "source inventory cell keys for map " .. tostring(mapId) .. " are not sorted and unique"
      end
      ---@cast keys string[]
      for _, key in ipairs(keys) do
        if key:match("^[0-9]+-[0-9]+$") == nil or cells[key] == nil then
          return nil, "source inventory cell key " .. key .. " for map " .. tostring(mapId) .. " is not canonical"
        end
      end
    end
  end
  return true
end

---@param romFs table<string, unknown> RomFs-shaped source filesystem
---@param identity { versionId: string, generationId: string, producerId: string }
---@return table<string, unknown>
function SourcePlan.compile(romFs, identity)
  assert(romFs and romFs.openNarc and romFs.metadata, "source inventory compilation requires a RomFs-shaped object")
  assert(type(identity) == "table", "source inventory compilation requires its generation identity")
  local versionId = identity.versionId
  assert(type(versionId) == "string" and versionId ~= "", "source inventory compilation requires a version")
  local generationId = identity.generationId
  assert(type(generationId) == "string" and generationId ~= "", "source inventory compilation requires a generation")
  local producerId = identity.producerId
  assert(type(producerId) == "string" and producerId ~= "", "source inventory compilation requires a producer")
  if type(romFs.version) == "function" then
    assert(romFs:version() == versionId, "source inventory version does not match its source reader")
  end
  local WorldManifest = require("romdump.src.digest.map.WorldManifest")
  local world = WorldManifest.compileCatalog(romFs)
  local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
  local fieldCellIndexBundle, indexErr = FieldCellCompiler.compileIndex(romFs, producerId)
  if fieldCellIndexBundle == nil then
    error(indexErr, 0)
  end
  local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
  local scriptPlan = ScriptCompiler.plan(romFs, producerId)
  local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local audioSource, audioSourceErr = AudioCompiler.planSource(romFs)
  if audioSource == nil then
    error(audioSourceErr, 0)
  end
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local messageBankIds = FieldMessageCompiler.requiredBankIds()
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local mapDataIds = FieldMapDataCompiler.supportedMapIds()
  local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
  local mapCellKeys = {}
  ---@cast world table<string, unknown>
  for _, record in ipairs(assert(world.maps, "source inventory world carries no maps")) do
    ---@cast record table<string, unknown>
    assert(isInteger(record.id), "source inventory world carries an unidentified map")
    -- Roster enumeration is topology only: no per-map content planning
    -- and no leaf cell planning. The projection keys translate into the
    -- unchanged dash-joined mapCellKeys shape the inventory validates.
    local ok, topologyKeys, topologyErr = pcall(MapCompilePlan.cellKeys, romFs, fieldCellIndexBundle.index, record.id)
    if not ok then
      Errors.raise("SOURCE_PLAN_MAP_FAILED", "loadable map " .. tostring(record.id) .. " cannot be planned", {
        mapId = record.id,
      })
    end
    if topologyKeys == nil then
      Errors.raise(
        "SOURCE_PLAN_MAP_FAILED",
        "loadable map " .. tostring(record.id) .. " cannot be planned: " .. tostring(topologyErr),
        { mapId = record.id }
      )
    end
    assert(type(topologyKeys) == "table", "loadable map enumeration must produce its cell keys")
    local keys = {}
    for _, topologyKey in ipairs(topologyKeys) do
      local matrixMemberId, index = tostring(topologyKey):match("^(%d+):(%d+)$")
      assert(matrixMemberId ~= nil and index ~= nil, "topology enumeration carries a non-canonical cell key")
      keys[#keys + 1] = matrixMemberId .. "-" .. index
    end
    mapCellKeys[record.id] = sortedUnique(keys)
  end
  local metadata = romFs:metadata()
  assert(
    type(metadata) == "table" and type(metadata.sha1) == "string",
    "source inventory source carries no ROM identity"
  )
  local plan = {
    schema = SourcePlan.SCHEMA,
    versionId = versionId,
    romSha1 = metadata.sha1,
    generationId = generationId,
    producerId = producerId,
    world = world,
    fieldCellIndexBundle = fieldCellIndexBundle,
    scriptPlan = scriptPlan,
    audioPlan = audioSource.plan,
    audioIdentity = audioSource.identity,
    messageBankIds = messageBankIds,
    mapDataIds = mapDataIds,
    mapCellKeys = mapCellKeys,
  }
  local valid, reason = SourcePlan.validate(plan, identity)
  if not valid then
    error(reason, 0)
  end
  return plan
end

---@param cacheFs CacheFs
---@param identity { versionId: string, generationId: string, producerId: string }
---@return table<string, unknown>|nil
---@return string|nil
function SourcePlan.read(cacheFs, identity)
  assert(cacheFs and cacheFs.loadLua, "source inventory reads require a cache filesystem")
  assert(type(identity) == "table", "source inventory reads require the generation identity")
  local ok, record = pcall(cacheFs.loadLua, cacheFs, SourcePlan.PATH)
  if not ok or type(record) ~= "table" then
    return nil, "no published source inventory"
  end
  local valid, reason = SourcePlan.validate(record, identity)
  if not valid then
    return nil, reason
  end
  return record
end

---@param artifact PreparedArtifact
---@param plan table<string, unknown>
---@return string
function SourcePlan.stage(artifact, plan)
  assert(artifact and artifact.stageFs, "source inventory staging requires a PreparedArtifact")
  assert(type(plan) == "table", "source inventory staging requires its inventory")
  local generationId = plan.generationId
  assert(type(generationId) == "string" and generationId ~= "", "source inventory staging needs its generation")
  artifact:addOwnedRoot(SourcePlan.PATH)
  local stage = artifact:stageFs()
  stage:writeLua(SourcePlan.PATH, plan)
  local readback = stage:loadLua(SourcePlan.PATH)
  assert(type(readback) == "table", "staged source inventory did not read back")
  local valid, reason = SourcePlan.validate(readback, {
    versionId = plan.versionId,
    generationId = plan.generationId,
    producerId = plan.producerId,
  })
  if not valid then
    Errors.raise("SOURCE_PLAN_READBACK_FAILED", "staged source inventory did not read back", {
      reason = tostring(reason),
    })
  end
  return SourcePlan.marker(generationId)
end

return SourcePlan
