-- Analyzes, compiles, and stages the map world for one version.

local Errors = require("libs.errors.src.Errors")
local MapAnalysis = require("romdump.src.digest.map.MapAnalysis")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local WorldManifest = require("romdump.src.digest.map.WorldManifest")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")

local MapCacheBuild = {}

---@param context VersionBuildContext
---@return table<string, unknown>|nil, Errors.Error|string|nil
function MapCacheBuild.build(context)
  local fieldCellBundle, fieldCellErr = FieldCellCompiler.compile(context.romFs)
  if not fieldCellBundle then
    assert(Errors.is(fieldCellErr), "field cell stage failure must be a structured error")
    return nil, fieldCellErr
  end
  if context.forced or not FieldCellCacheWriter.isReady(context.cacheFs, fieldCellBundle.marker) then
    FieldCellCacheWriter.write(context.cacheFs, fieldCellBundle)
    context.log(string.format("build-cache: %s physical field cells compiled", context.version))
  else
    context.log(string.format("build-cache: %s physical field cells current", context.version))
  end

  local entries, excluded, compileExcluded = {}, {}, {}
  for _, result in ipairs(MapAnalysis.analyze(context.romFs)) do
    if result.status == "excluded" then
      excluded[#excluded + 1] = {
        id = result.id,
        symbol = result.symbol,
        reason = result.reason,
        matchCount = result.matchCount,
      }
    else
      local bundle, compileErr = MapAssetCompiler.compile(context.romFs, result.id)
      if not bundle then
        assert(Errors.is(compileErr), "compiler failure must be a structured error")
        compileErr = compileErr --[[@as Errors.Error]]
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
        if context.forced or not MapAssetCache.isReady(context.cacheFs, bundle.mapId, bundle.marker) then
          MapCacheWriter.write(context.cacheFs, bundle)
          context.log(string.format("build-cache: %s map %d compiled", context.version, bundle.mapId))
        else
          context.log(string.format("build-cache: %s map %d current", context.version, bundle.mapId))
        end
        for _, entry in ipairs(bundle.unresolvedMaterials) do
          context.log(
            string.format(
              "build-cache: %s map %d unresolved %s %s: material %s of %s %s:%d wants %s from %s",
              context.version,
              bundle.mapId,
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
          id = bundle.mapId,
          symbol = bundle.scene.mapSymbol,
          mapCode = result.mapCode,
          mapSection = result.mapSection,
          mapSectionNativeId = result.mapSectionNativeId,
          followMode = result.followMode,
          width = bundle.scene.matrix.width,
          height = bundle.scene.matrix.height,
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
