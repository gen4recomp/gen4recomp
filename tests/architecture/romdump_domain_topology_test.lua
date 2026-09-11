-- Static contract guard: keeps source digestion grouped by semantic domain while
-- leaving producer APIs, cache writers, and generated values unchanged.

local Assert = require("tests.support.Assert")

local T = {}

local BASE = love.filesystem.getSourceBaseDirectory()
local DIGEST_SOURCE_ROOT = "romdump/src/digest"
local OLD_MODULE_PREFIX = "romdump.src.digest."

local DOMAINS = {
  map = {
    "AreaData",
    "BuildingModelCompiler",
    "BuildingPlacement",
    "BuildingTransform",
    "HgssBdhc",
    "LandData",
    "MapAnalysis",
    "MapAssetCompiler",
    "MapAssetInspector",
    "MapCacheWriter",
    "MapCatalog",
    "MapCellSelector",
    "MapCompilePlan",
    "MapMatrix",
    "MapResolver",
    "MapUnits",
    "NeighborChunkCompiler",
    "NeighborPlan",
    "TerrainAnimationCompiler",
    "TerrainBoundaryConformer",
    "TerrainInspector",
    "WorldManifest",
    "ZoneEvents",
  },
  model = {
    "BuildModelAnimList",
    "DynamicModelCompiler",
    "MapPropAnimCompiler",
    "MaterialCompiler",
    "MeshCompiler",
    "ModelAssetCompiler",
    "NsbcaClipCompiler",
    "NsbmaClipCompiler",
    "NsbmdDynamicModel",
    "NsbmdStaticTransforms",
    "NsbmdTransformProgram",
    "NsbtaClipCompiler",
    "NsbtpClipCompiler",
    "SbcInventory",
    "TextureMatrixState",
  },
  actor = {
    "FieldActorCacheWriter",
    "FieldActorCompiler",
    "FieldActorEmoteCacheWriter",
    "FieldActorEmoteCompiler",
    "FieldActorFrames",
    "FieldActorGraphics",
    "FieldActorModel",
    "FieldActorStaticModel",
    "FieldActorTimeline",
    "FollowingMonVisualCompiler",
  },
  mons = {
    "MonCacheWriter",
    "MonCatalogCompiler",
    "MonPresentationCompiler",
  },
  items = {
    "ItemCacheWriter",
    "ItemCatalogCompiler",
    "ItemPresentationCompiler",
  },
  field = {
    "FieldCameraCacheWriter",
    "FieldCameraCompiler",
    "FieldCameraDiscovery",
    "FieldCameraInspector",
    "FieldCellCacheWriter",
    "FieldCellCompiler",
    "FieldEffectPatternAnimation",
    "FieldEntranceIndicatorCacheWriter",
    "FieldEntranceIndicatorCompiler",
    "FieldMapDataCacheWriter",
    "FieldMapDataCompiler",
    "FieldMapDataInspector",
    "FieldTextureAnimation",
    "FieldWeatherCacheWriter",
    "FieldWeatherCompiler",
    "HgssCameraTable",
    "HgssFieldEdgeColors",
    "HgssFieldFog",
    "HgssFieldLightProfile",
    "HgssFieldLighting",
    "HgssFieldMaterial",
    "HgssObjectMovement",
    "HgssPermissionGrid",
    "HgssSoundplate",
  },
  ui = {
    "BagAssetCompiler",
    "BagCacheWriter",
    "BagPresentationCompiler",
    "FieldFontCacheWriter",
    "FieldFontCompiler",
    "FieldFontDecoder",
    "FieldMessageBank",
    "FieldMessageCacheWriter",
    "FieldMessageCompiler",
    "FieldMessageTokenizer",
    "FieldUiCacheWriter",
    "FieldUiCompiler",
    "G2dDecoder",
    "G2dRasterizer",
  },
  newgame = {
    "IntroAssetCacheWriter",
    "IntroAssetCompiler",
    "IntroAssetImage",
    "IntroRasterizer",
    "IntroObjPaletteResolver",
    "NewGameInitCacheWriter",
    "NewGameInitCompiler",
    "StarterChoiceAssetCacheWriter",
    "StarterChoiceAssetCompiler",
  },
}

local EXISTING_DOMAINS = {
  audio = {
    "AudioCacheWriter",
    "AudioCompiler",
    "SequenceLowering",
    "SequenceReachability",
  },
  script = {
    "Cfg",
    "CommandCatalog",
    "Coverage",
    "LuaEmitter",
    "MovementDecoder",
    "RawIr",
    "ScriptBinaryDecoder",
    "ScriptCacheWriter",
    "ScriptCompileSession",
    "ScriptCompiler",
    "ScriptHeader",
    "SemanticLowering",
    "SourceCatalog",
    "Structurer",
    "VanillaBindingIdentity",
    "Verifier",
    "lowering/AudioHandlers",
    "lowering/ControlHandlers",
    "lowering/FieldHandlers",
    "lowering/Operands",
  },
}

local ROOT_UTILITIES = { "Hashing", "Lz10" }

local function pathExists(path)
  local handle = io.open(BASE .. "/" .. path, "r")
  if handle == nil then
    return false
  end
  handle:close()
  return true
end

local function luaFilesUnder(root)
  local command = "find '" .. BASE .. "/" .. root .. "' -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. root)
  local prefix = BASE .. "/"
  local files = {}
  for line in pipe:lines() do
    assert(line:sub(1, #prefix) == prefix, "unexpected path outside the repository: " .. line)
    files[#files + 1] = line:sub(#prefix + 1)
  end
  pipe:close()
  return files
end

local function expectedDigestFiles()
  local expected = {}
  for domain, modules in pairs(DOMAINS) do
    for _, moduleName in ipairs(modules) do
      expected[DIGEST_SOURCE_ROOT .. "/" .. domain .. "/" .. moduleName .. ".lua"] = true
    end
  end
  for domain, modules in pairs(EXISTING_DOMAINS) do
    for _, moduleName in ipairs(modules) do
      expected[DIGEST_SOURCE_ROOT .. "/" .. domain .. "/" .. moduleName .. ".lua"] = true
    end
  end
  for _, moduleName in ipairs(ROOT_UTILITIES) do
    expected[DIGEST_SOURCE_ROOT .. "/" .. moduleName .. ".lua"] = true
  end
  return expected
end

local function movedModuleNames()
  local names = {}
  for _, modules in pairs(DOMAINS) do
    for _, moduleName in ipairs(modules) do
      names[moduleName] = true
    end
  end
  names.AudioCacheWriter = true
  names.ScriptCacheWriter = true
  names.ScriptHeader = true
  return names
end

local function staleRequires()
  local stale = {}
  local moved = movedModuleNames()
  local requirePatterns = {
    'require%s*%(%s*"([^"]+)"%s*%)',
    'require%s*"([^"]+)"',
  }
  for _, root in ipairs({ "app", "game", "libs", "romdump", "tests" }) do
    for _, path in ipairs(luaFilesUnder(root)) do
      local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
      local content = handle:read("*a")
      handle:close()
      for _, pattern in ipairs(requirePatterns) do
        for moduleName in content:gmatch(pattern) do
          local oldName = moduleName:match("^" .. OLD_MODULE_PREFIX .. "(.+)$")
          if oldName ~= nil and moved[oldName] then
            stale[#stale + 1] = path .. " requires " .. moduleName
          end
        end
      end
    end
  end
  table.sort(stale)
  return stale
end

local function requireFromNewPath(domain, moduleName)
  local path = "romdump.src.digest." .. domain .. "." .. moduleName
  local ok, loaded = pcall(require, path)
  Assert.isTrue(ok, "digest module must load from its domain path: " .. tostring(loaded))
  Assert.equal(type(loaded), "table", "digest module must retain its table module contract: " .. path)
end

function T.digest_modules_have_exact_shallow_domain_inventory()
  local expected = expectedDigestFiles()
  local unexpected = {}
  for _, path in ipairs(luaFilesUnder(DIGEST_SOURCE_ROOT)) do
    if not expected[path] then
      unexpected[#unexpected + 1] = path
    end
  end
  for path in pairs(expected) do
    Assert.isTrue(pathExists(path), "digest module is missing from its target domain: " .. path)
  end
  table.sort(unexpected)
  Assert.isTrue(
    #unexpected == 0,
    "unexpected digest files remain or technical-stage directories were added:\n" .. table.concat(unexpected, "\n")
  )
end

function T.representative_digest_modules_load_from_each_domain_path()
  requireFromNewPath("map", "MapAssetCompiler")
  requireFromNewPath("model", "ModelAssetCompiler")
  requireFromNewPath("actor", "FieldActorCompiler")
  requireFromNewPath("field", "FieldMapDataCompiler")
  requireFromNewPath("ui", "FieldUiCompiler")
  requireFromNewPath("newgame", "IntroAssetCompiler")
  requireFromNewPath("mons", "MonCatalogCompiler")
  requireFromNewPath("items", "ItemCatalogCompiler")
  requireFromNewPath("audio", "AudioCompiler")
  requireFromNewPath("script", "ScriptCompiler")
end

function T.old_digest_paths_and_requires_are_absent()
  local violations = {}
  for _, modules in pairs(DOMAINS) do
    for _, moduleName in ipairs(modules) do
      local path = DIGEST_SOURCE_ROOT .. "/" .. moduleName .. ".lua"
      if pathExists(path) then
        violations[#violations + 1] = path
      end
    end
  end
  for _, moduleName in ipairs({ "AudioCacheWriter", "ScriptCacheWriter", "ScriptHeader" }) do
    local path = DIGEST_SOURCE_ROOT .. "/" .. moduleName .. ".lua"
    if pathExists(path) then
      violations[#violations + 1] = path
    end
  end
  for _, path in ipairs(staleRequires()) do
    violations[#violations + 1] = path
  end
  table.sort(violations)
  Assert.isTrue(#violations == 0, "old digest module files or requires remain:\n" .. table.concat(violations, "\n"))
end

return { tests = T }
