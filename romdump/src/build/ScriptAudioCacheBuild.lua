-- Builds script and audio derived assets for one version.

local Errors = require("libs.errors.src.Errors")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local CompilerPool = require("romdump.src.build.CompilerPool")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")

local ScriptAudioCacheBuild = {}

---@param err Errors.Error|string|nil
---@return nil, Errors.Error|string|nil
local function requireError(err)
  assert(Errors.is(err), "script/audio stage failure must be a structured error")
  return nil, err
end

-- Bounded per-bank audio build: the catalog plans every bank closure without
-- touching waves, then one closure at a time compiles, stages, and validates
-- through the audio writer, dropping each bank's decoded PCM before the next
-- bank starts. The family summary publishes only once every planned closure
-- is current.
---@param context VersionBuildContext
---@return true|nil, Errors.Error|string|nil
local function buildAudioBanks(context)
  local catalog, planErr = AudioCompiler.plan(context.romFs)
  if catalog == nil then
    return requireError(planErr)
  end
  local identity, identityErr = AudioCompiler.soundIdentity(context.romFs)
  if identity == nil then
    return requireError(identityErr)
  end
  local bankMarkers = {}
  local compiled = 0
  for _, bankPlan in ipairs(catalog.bankPlans) do
    local expected = AudioCompiler.bankMarker(identity, bankPlan)
    bankMarkers[bankPlan.bankId] = expected
    if context.forced or not AudioCache.isBankReady(context.cacheFs, bankPlan.bankId, expected) then
      local marker, bankErr = AudioCacheWriter.writeBank(context.cacheFs, context.romFs, bankPlan)
      if marker == nil then
        return requireError(bankErr)
      end
      assert(marker == expected, "a staged bank closure carries its planned marker")
      compiled = compiled + 1
    end
  end
  local summaryMarker = AudioCacheWriter.summaryMarker(catalog, bankMarkers)
  if context.forced or not AudioCacheWriter.isReady(context.cacheFs, summaryMarker) then
    AudioCacheWriter.writeSummary(context.cacheFs, catalog)
    context.log(string.format("build-cache: %s audio compiled", context.version))
  elseif compiled > 0 then
    context.log(string.format("build-cache: %s audio compiled", context.version))
  else
    context.log(string.format("build-cache: %s audio current", context.version))
  end
  return true
end

---@param context VersionBuildContext
---@return true|nil, Errors.Error|string|nil
function ScriptAudioCacheBuild.build(context)
  local producerFingerprint = assert(context.producerFingerprint, "script build requires a producer fingerprint")
  local plan = ScriptCompiler.plan(context.romFs, producerFingerprint)
  if not ScriptCacheWriter.isReady(context.cacheFs, plan.marker) then
    local pool = CompilerPool.new({
      versionId = context.version,
      mode = "batch",
      developmentRepositoryRoot = context.developmentRepositoryRoot,
    })
    local ok, failure = pcall(function()
      for _, member in ipairs(plan.members) do
        pool:request({
          kind = "script-member",
          key = "script-member:" .. plan.generationKey .. ":" .. tostring(member.memberId),
          priority = 0,
          payload = {
            generationKey = plan.generationKey,
            memberId = member.memberId,
            producerFingerprint = producerFingerprint,
          },
        })
      end
      pool:drain()
    end)
    local shutdownOk, shutdownResult = pcall(pool.shutdown, pool)
    if not ok then
      return nil, failure
    end
    if not shutdownOk then
      return nil, shutdownResult --[[@as Errors.Error|string]]
    end
    for _, member in ipairs(plan.members) do
      local state, details = pool:status("script-member:" .. plan.generationKey .. ":" .. tostring(member.memberId))
      if state ~= "ready" then
        return nil, details and details.error or "script member compilation failed"
      end
    end
    ScriptCacheWriter.finalizeGeneration(context.cacheFs, plan)
    ScriptCacheWriter.activateGeneration(context.cacheFs, plan.generationKey)
    context.log(
      string.format(
        "build-cache: %s scripts compiled (%d resources, %d members)",
        context.version,
        #plan.resources,
        #plan.members
      )
    )
  else
    context.log(string.format("build-cache: %s scripts current", context.version))
  end

  local audioReady, audioErr = buildAudioBanks(context)
  if audioReady == nil then
    return nil, audioErr
  end
  return true
end

return ScriptAudioCacheBuild
