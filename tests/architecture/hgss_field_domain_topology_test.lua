-- Static contract guard: keeps reusable HGSS field mechanisms grouped by
-- semantic owner while preserving the existing sibling package boundaries.

local Assert = require("tests.support.Assert")

local T = {}

local BASE = love.filesystem.getSourceBaseDirectory()
local HGSS_SOURCE_ROOT = "libs/hgss/src"
local FIELD_SOURCE_ROOT = HGSS_SOURCE_ROOT .. "/field"
local OLD_MODULE_PREFIX = "libs.hgss.src.field."

local DOMAINS = {
  actors = {
    "FieldActorAutonomy",
    "FieldActorDefinitionProvider",
    "FieldActorManager",
    "FieldActorOccupancy",
    "FieldActorPersistence",
    "FieldActorStore",
    "FieldObjectActor",
    "FieldPlayer",
    "FieldPlayerAvatarState",
    "FieldPlayerVisual",
  },
  world = {
    "CollisionGrid",
    "FieldCoverage",
    "FieldGrid",
    "FieldMapLoader",
    "FieldNavigationBoundary",
    "FieldRegion",
    "FieldResidencyCoordinator",
    "FieldTerrainEffectController",
    "FieldTerrainResponse",
    "FieldTraversal",
    "FieldWeatherResolver",
    "FieldZoneController",
    "FieldZoneIdentity",
    "MapProps",
    "MetatileBehavior",
    "ModelDoorMetadata",
    "SurfaceResolver",
    "TerrainSurface",
  },
  interaction = {
    "ContextChoiceProvider",
    "FieldEventResolver",
    "FieldInteractionResolver",
    "FieldMessageProvider",
    "FieldSignpostController",
  },
  transition = {
    "DoorSound",
    "DoorTiles",
    "FieldEntranceIndicator",
    "FieldScriptScreenFade",
    "FieldTransition",
    "FieldTransitionFade",
    "FieldTransitionProfile",
    "TransitionTrigger",
    "WarpSystem",
  },
}

local FIELD_COORDINATION = {
  "CameraHistory",
  "FieldApplicationHost",
  "FieldApplicationIds",
  "FieldApplicationRegistry",
  "FieldCamera",
  "FieldCoordinates",
  "FieldErrors",
  "FieldEventState",
  "FieldInput",
  "FieldMapEntryController",
  "FieldSession",
  "FieldWindowStyles",
  "FollowingMonController",
  "FollowingMonTransitionController",
  "MapInitScriptController",
  "StartMenuLayout",
}

local PRESENTATION = { "BillboardTransform" }

local EXISTING_SIBLINGS = {
  audio = "libs.hgss.src.audio.AudioRuntime",
  mons = "libs.hgss.src.mons.HgssMonService",
  presentation = "libs.hgss.src.presentation.FieldViewport",
  save = "libs.hgss.src.save.GameSave",
  script = "libs.hgss.src.script.Composition",
  ui = "libs.hgss.src.ui.FieldDialogueController",
}

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

local function expectedFiles()
  local expected = {}
  for domain, modules in pairs(DOMAINS) do
    for _, moduleName in ipairs(modules) do
      expected[HGSS_SOURCE_ROOT .. "/" .. domain .. "/" .. moduleName .. ".lua"] = true
    end
  end
  for _, moduleName in ipairs(FIELD_COORDINATION) do
    expected[FIELD_SOURCE_ROOT .. "/" .. moduleName .. ".lua"] = true
  end
  for _, moduleName in ipairs(PRESENTATION) do
    expected[HGSS_SOURCE_ROOT .. "/presentation/" .. moduleName .. ".lua"] = true
  end
  for sibling in pairs(EXISTING_SIBLINGS) do
    for _, path in ipairs(luaFilesUnder(HGSS_SOURCE_ROOT .. "/" .. sibling)) do
      expected[path] = true
    end
  end
  return expected
end

local function movedModuleNames()
  local moved = {}
  for _, modules in pairs(DOMAINS) do
    for _, moduleName in ipairs(modules) do
      moved[moduleName] = true
    end
  end
  for _, moduleName in ipairs(PRESENTATION) do
    moved[moduleName] = true
  end
  return moved
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

local function requireFromNewPath(moduleName, label)
  local sourcePath = moduleName:gsub("%.", "/") .. ".lua"
  Assert.isTrue(pathExists(sourcePath), label .. " is missing from its owner path: " .. sourcePath)
  local ok, loaded = pcall(require, moduleName)
  Assert.isTrue(ok, label .. " must load from its owner path: " .. tostring(loaded))
  Assert.equal(type(loaded), "table", label .. " must retain its module contract")
end

function T.field_mechanisms_have_exact_shallow_domain_inventory()
  local expected = expectedFiles()
  local unexpected = {}
  for _, path in ipairs(luaFilesUnder(HGSS_SOURCE_ROOT)) do
    if not expected[path] then
      unexpected[#unexpected + 1] = path
    end
  end
  for path in pairs(expected) do
    Assert.isTrue(pathExists(path), "HGSS mechanism is missing from its owner path: " .. path)
  end
  table.sort(unexpected)
  Assert.isTrue(
    #unexpected == 0,
    "unexpected HGSS mechanism files remain or nested domains were added:\n" .. table.concat(unexpected, "\n")
  )
end

function T.representative_mechanisms_load_from_owner_domains()
  requireFromNewPath("libs.hgss.src.field.FieldSession", "field coordination")
  requireFromNewPath("libs.hgss.src.actors.FieldActorManager", "actor mechanisms")
  requireFromNewPath("libs.hgss.src.world.FieldCoverage", "world mechanisms")
  requireFromNewPath("libs.hgss.src.interaction.FieldInteractionResolver", "interaction mechanisms")
  requireFromNewPath("libs.hgss.src.transition.FieldTransition", "transition mechanisms")
  requireFromNewPath("libs.hgss.src.presentation.BillboardTransform", "presentation mechanisms")

  for sibling, moduleName in pairs(EXISTING_SIBLINGS) do
    requireFromNewPath(moduleName, sibling .. " sibling mechanisms")
  end
end

function T.old_field_paths_and_generic_namespace_are_absent()
  local violations = {}
  local moved = movedModuleNames()
  for moduleName in pairs(moved) do
    local path = FIELD_SOURCE_ROOT .. "/" .. moduleName .. ".lua"
    if pathExists(path) then
      violations[#violations + 1] = path
    end
  end
  for _, path in ipairs(staleRequires()) do
    violations[#violations + 1] = path
  end
  Assert.isFalse(pathExists("libs/field"), "a generic libs/field package must not be introduced")
  table.sort(violations)
  Assert.isTrue(#violations == 0, "old field module files or requires remain:\n" .. table.concat(violations, "\n"))
end

return { tests = T }
