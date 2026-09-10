-- Analyzes, compiles, and stages the map world for one version.

local Errors = require("libs.errors.src.Errors")
local MapAnalysis = require("romdump.src.digest.map.MapAnalysis")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local WorldManifest = require("romdump.src.digest.map.WorldManifest")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local CompilerPool = require("romdump.src.build.CompilerPool")

local MapCacheBuild = {}

---@param context VersionBuildContext
---@return table<string, unknown>|nil, Errors.Error|string|nil
function MapCacheBuild.build(context)
  local entries, excluded, compileExcluded = {}, {}, {}
  local analyses = MapAnalysis.analyze(context.romFs)
  local pool = CompilerPool.new({
    versionId = context.version,
    mode = "batch",
    developmentRepositoryRoot = context.developmentRepositoryRoot,
  })
  if type(FieldCellCompiler.compileIndex) == "function" then
    local indexBundle, indexErr = FieldCellCompiler.compileIndex(context.romFs, context.producerFingerprint)
    if not indexBundle then
      pool:shutdown()
      assert(Errors.is(indexErr), "field cell index failure must be a structured error")
      return nil, indexErr
    end
    local indexMarker = context.cacheFs:read(FieldCellCache.indexMarkerPath())
    if context.forced or indexMarker ~= indexBundle.indexMarker then
      FieldCellCacheWriter.writeIndex(context.cacheFs, indexBundle)
    end
    for _, matrix in ipairs(indexBundle.index.matrices) do
      for _, descriptor in ipairs(matrix.cells) do
        local expected = assert(FieldCellCompiler.planCell(context.romFs, descriptor, context.producerFingerprint))
        if context.forced or not FieldCellCache.isCellReady(context.cacheFs, descriptor, expected.expectedMarker) then
          pool:request({
            kind = "field-cell",
            key = expected.jobIdentity,
            priority = 0,
            payload = {
              matrixMemberId = descriptor.matrixMemberId,
              index = descriptor.index,
              x = descriptor.x,
              z = descriptor.z,
              mapHeaderId = descriptor.mapHeaderId,
              altitude = descriptor.altitude,
              landDataMemberId = descriptor.landDataMemberId,
              areaDataMemberId = descriptor.areaDataMemberId,
              producerFingerprint = context.producerFingerprint,
            },
          })
        end
      end
    end
    pool:drain()
    for _, matrix in ipairs(indexBundle.index.matrices) do
      for _, descriptor in ipairs(matrix.cells) do
        local key = "field-cell:" .. descriptor.matrixMemberId .. ":" .. descriptor.index
        local state, details = pool:status(key)
        if state == "failed" then
          local failure = assert(details and details.error)
          assert(Errors.is(failure), "field-cell worker failure must be structured")
          pool:shutdown()
          return nil, failure
        end
        local expected = assert(FieldCellCompiler.planCell(context.romFs, descriptor, context.producerFingerprint))
        assert(
          FieldCellCache.isCellReady(context.cacheFs, descriptor, expected.expectedMarker),
          "field-cell job did not publish a ready cell"
        )
      end
    end
    local corpusMarker = indexBundle.marker
    if context.forced or not FieldCellCache.isReady(context.cacheFs, corpusMarker) then
      FieldCellCacheWriter.writeComplete(context.cacheFs, corpusMarker)
    end
    context.log(string.format("build-cache: %s physical field cells current", context.version))
  else
    local fieldCellBundle, fieldCellErr = FieldCellCompiler.compile(context.romFs)
    if not fieldCellBundle then
      pool:shutdown()
      assert(Errors.is(fieldCellErr), "field cell stage failure must be a structured error")
      return nil, fieldCellErr
    end
    if context.forced or not FieldCellCacheWriter.isReady(context.cacheFs, fieldCellBundle.marker) then
      FieldCellCacheWriter.write(context.cacheFs, fieldCellBundle)
      context.log(string.format("build-cache: %s physical field cells compiled", context.version))
    else
      context.log(string.format("build-cache: %s physical field cells current", context.version))
    end
  end

  local oldReady = {}
  local resolved = {}
  local ok, failure = xpcall(function()
    for _, result in ipairs(analyses) do
      if result.status == "excluded" then
        excluded[#excluded + 1] = {
          id = result.id,
          symbol = result.symbol,
          reason = result.reason,
          matchCount = result.matchCount,
        }
      else
        resolved[#resolved + 1] = result
        local oldMarker = context.cacheFs:read(MapAssetCache.mapDir(result.id) .. "/complete")
        oldReady[result.id] = oldMarker ~= nil and MapAssetCache.isReady(context.cacheFs, result.id, oldMarker)
        pool:request({
          kind = "map",
          key = "map:" .. result.id,
          priority = 0,
          payload = { mapId = result.id, producerFingerprint = context.producerFingerprint },
        })
      end
    end
    pool:drain()
  end, debug.traceback)
  local shutdownOk, shutdownError = pcall(pool.shutdown, pool)
  if not ok then
    error(failure, 0)
  end
  if not shutdownOk then
    error(shutdownError, 0)
  end

  for _, result in ipairs(resolved) do
    local state, details = pool:status("map:" .. result.id)
    if state == "failed" then
      local compileErr = assert(details and details.error, "map worker failure has no error")
      assert(Errors.is(compileErr), "compiler failure must be a structured error")
      compileExcluded[#compileExcluded + 1] = {
        id = result.id,
        symbol = result.symbol,
        errorCode = compileErr.code,
        message = compileErr.message,
        context = compileErr.context,
      }
      context.log(
        string.format("build-cache: %s map %d excluded: %s", context.version, result.id, Errors.format(compileErr))
      )
    else
      assert(state == "ready" and details and details.result, "map worker did not produce a ready result")
      local compiled = details.result
      assert(compiled.mapId == result.id, "map worker returned the wrong map")
      if context.forced or not oldReady[result.id] then
        context.log(string.format("build-cache: %s map %d compiled", context.version, result.id))
      else
        context.log(string.format("build-cache: %s map %d current", context.version, result.id))
      end
      for _, entry in ipairs(compiled.unresolvedMaterials) do
        context.log(
          string.format(
            "build-cache: %s map %d unresolved %s %s: material %s of %s %s:%d wants %s from %s",
            context.version,
            result.id,
            entry.role,
            entry.kind,
            entry.material,
            entry.modelName,
            entry.modelArchive,
            entry.modelMemberId,
            entry.name,
            entry.source
          )
        )
      end
      entries[#entries + 1] = {
        id = result.id,
        symbol = compiled.mapSymbol,
        mapCode = result.mapCode,
        mapSection = result.mapSection,
        mapSectionNativeId = result.mapSectionNativeId,
        followMode = result.followMode,
        width = compiled.width,
        height = compiled.height,
        matrix = {
          memberId = result.matrixMemberId,
          x = result.matrixX,
          z = result.matrixZ,
          index = result.matrixIndex,
          landDataMemberId = result.landDataMemberId,
          selection = result.source,
          matchCount = result.matchCount,
        },
      }
    end
  end
  local world = WorldManifest.stage(context.cacheFs, entries, excluded, compileExcluded)
  context.log(
    string.format(
      "build-cache: %s world.lua staged (%d maps, %d unresolved cells, %d compile-excluded)",
      context.version,
      #entries,
      #excluded,
      #compileExcluded
    )
  )
  return {
    world = world,
    hasCompileExclusions = #compileExcluded > 0,
    exclusionCount = #compileExcluded,
  }
end

return MapCacheBuild
