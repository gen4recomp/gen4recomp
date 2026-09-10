-- Builds script and audio derived assets for one version.

local Errors = require("libs.errors.src.Errors")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local CompilerPool = require("romdump.src.build.CompilerPool")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")

local ScriptAudioCacheBuild = {}

---@param bundle table<string, unknown>|nil
---@param err Errors.Error|string|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
local function requireBundle(bundle, err)
  if bundle then
    return bundle
  end
  assert(Errors.is(err), "script/audio stage failure must be a structured error")
  return nil, err
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

  local audioBundle, audioErr = AudioCompiler.compile(context.romFs)
  local audio = requireBundle(audioBundle, audioErr)
  if not audio then
    return nil, audioErr
  end
  if context.forced or not AudioCacheWriter.isReady(context.cacheFs, audio.marker) then
    AudioCacheWriter.write(context.cacheFs, audio)
    context.log(string.format("build-cache: %s audio compiled", context.version))
  else
    context.log(string.format("build-cache: %s audio current", context.version))
  end
  return true
end

return ScriptAudioCacheBuild
