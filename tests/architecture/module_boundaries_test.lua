-- Static architecture guard: enforces the application package DAG by scanning
-- literal require("...") strings across production package roots. Literal
-- scanning is sufficient because the repository requires modules by full
-- repo-relative path; this is deliberately not a general-purpose dependency
-- analyzer.

local Assert = require("tests.support.Assert")

local T = {}

local BASE = love.filesystem.getSourceBaseDirectory()

local PACKAGE_ROOTS = {
  "libs/assets",
  "libs/codec",
  "libs/errors",
  "libs/storage",
  "libs/math",
  "libs/mons",
  "libs/nds",
  "libs/script",
  "libs/hgss",
  "libs/ui",
  "app",
  "game",
  "romdump",
}

local scanned = nil

local function luaFilesUnder(root)
  -- stderr is discarded so the assertion below reports the missing root.
  local command = "find '" .. BASE .. "/" .. root .. "' -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. root .. ": io.popen unavailable")
  local prefix = BASE .. "/"
  local out = {}
  for line in pipe:lines() do
    assert(line:sub(1, #prefix) == prefix, "unexpected path outside the repository: " .. line)
    out[#out + 1] = line:sub(#prefix + 1)
  end
  pipe:close()
  assert(#out > 0, "package root indexed no Lua files: " .. root)
  return out
end

local function readFile(path)
  local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
  local content = handle:read("*a")
  handle:close()
  return content
end

local function pathExists(path)
  local handle = io.open(BASE .. "/" .. path, "r")
  if handle == nil then
    return false
  end
  handle:close()
  return true
end

-- The two spellings the repository uses; anything else is a load error before
-- this test could run.
local REQUIRE_PAREN = 'require%s*%(%s*"([^"]+)"%s*%)'
local REQUIRE_BARE = 'require%s*"([^"]+)"'

local function requiredModules(content)
  local modules = {}
  for module in content:gmatch(REQUIRE_PAREN) do
    modules[#modules + 1] = module
  end
  for module in content:gmatch(REQUIRE_BARE) do
    modules[#modules + 1] = module
  end
  return modules
end

-- repo-relative file path -> list of required module names
local function scannedFiles()
  if scanned == nil then
    scanned = {}
    for _, root in ipairs(PACKAGE_ROOTS) do
      for _, file in ipairs(luaFilesUnder(root)) do
        scanned[file] = requiredModules(readFile(file))
      end
    end
  end
  return scanned
end

-- nil when there is nothing to report, so the assertion message stays
-- optional; Assert.isTrue accepts a nil message.
local function violationMessage(heading, violations)
  if #violations == 0 then
    return nil
  end
  return heading .. table.concat(violations, "\n")
end

local GOVERNED_PACKAGES = {
  "assets",
  "codec",
  "errors",
  "math",
  "mons",
  "storage",
  "nds",
  "script",
  "hgss",
  "ui",
  "game_hgss",
  "game",
  "romdump",
  "app",
}

local REPRESENTATIVE_MODULES = {
  assets = "libs.assets.src.field.FieldMessageCache",
  codec = "libs.codec.src.BinaryReader",
  errors = "libs.errors.src.Errors",
  math = "libs.math.src.FixedPoint",
  mons = "libs.mons.src.Mon",
  storage = "libs.storage.src.SaveFs",
  nds = "libs.nds.src.gx.DsPolygonAttr",
  script = "libs.script.src.Runtime",
  hgss = "libs.hgss.src.field.FieldSession",
  ui = "libs.ui.src.Button",
  game = "game.src.Game",
  game_hgss = "game.hgss.src.HgssGame",
  romdump = "romdump.src.source.GameVersion",
  app = "app.src.App",
}

local PACKAGE_RULES = {
  assets = {
    sourcePrefix = "libs/assets/src/",
    scanRoot = "libs/assets",
    allowed = { assets = true, codec = true, errors = true, math = true },
  },
  codec = {
    sourcePrefix = "libs/codec/src/",
    scanRoot = "libs/codec",
    allowed = { codec = true, errors = true, math = true },
  },
  errors = { sourcePrefix = "libs/errors/src/", scanRoot = "libs/errors", allowed = { errors = true } },
  math = { sourcePrefix = "libs/math/src/", scanRoot = "libs/math", allowed = { math = true } },
  mons = {
    sourcePrefix = "libs/mons/src/",
    scanRoot = "libs/mons",
    allowed = { mons = true, assets = true, codec = true, errors = true, math = true },
  },
  storage = {
    sourcePrefix = "libs/storage/src/",
    scanRoot = "libs/storage",
    allowed = { storage = true, codec = true, errors = true, math = true },
  },
  nds = {
    sourcePrefix = "libs/nds/src/",
    scanRoot = "libs/nds",
    allowed = { nds = true, codec = true, errors = true, math = true },
  },
  script = {
    sourcePrefix = "libs/script/src/",
    scanRoot = "libs/script",
    allowed = { script = true, assets = true, codec = true, errors = true, math = true, storage = true },
  },
  hgss = {
    sourcePrefix = "libs/hgss/src/",
    scanRoot = "libs/hgss",
    allowed = {
      hgss = true,
      nds = true,
      script = true,
      assets = true,
      codec = true,
      errors = true,
      math = true,
      storage = true,
    },
  },
  ui = {
    sourcePrefix = "libs/ui/src/",
    scanRoot = "libs/ui",
    allowed = { ui = true },
  },
  game = {
    sourcePrefix = "game/src/",
    scanRoot = "game",
    allowed = { game = true, codec = true, errors = true, math = true, storage = true },
  },
  game_hgss = {
    sourcePrefix = "game/hgss/src/",
    scanRoot = "game",
    allowed = {
      game_hgss = true,
      game = true,
      hgss = true,
      ui = true,
      assets = true,
      script = true,
      storage = true,
      codec = true,
      errors = true,
      math = true,
    },
  },
  romdump = {
    sourcePrefix = "romdump/src/",
    scanRoot = "romdump",
    allowed = {
      romdump = true,
      nds = true,
      assets = true,
      script = true,
      storage = true,
      codec = true,
      errors = true,
      math = true,
    },
  },
  app = {
    sourcePrefix = "app/src/",
    scanRoot = "app",
    allowed = { app = true, game = true, game_hgss = true, romdump = true, errors = true },
  },
}

local TARGET_PACKAGE_PREFIXES = {
  { prefix = "game.hgss.src.", packageName = "game_hgss" },
  { prefix = "libs.assets.src.", packageName = "assets" },
  { prefix = "libs.codec.src.", packageName = "codec" },
  { prefix = "libs.errors.src.", packageName = "errors" },
  { prefix = "libs.math.src.", packageName = "math" },
  { prefix = "libs.mons.src.", packageName = "mons" },
  { prefix = "libs.storage.src.", packageName = "storage" },
  { prefix = "libs.nds.src.", packageName = "nds" },
  { prefix = "libs.script.src.", packageName = "script" },
  { prefix = "libs.hgss.src.", packageName = "hgss" },
  { prefix = "libs.ui.src.", packageName = "ui" },
  { prefix = "game.src.", packageName = "game" },
  { prefix = "romdump.src.", packageName = "romdump" },
  { prefix = "app.src.", packageName = "app" },
}

local GOVERNED_TARGET_PREFIXES = { "libs.", "app.", "game.", "romdump." }

local APP_HGSS_IMPORTS = { ["game.hgss.src.HgssGame"] = true }
local APP_ROMDUMP_IMPORTS = {
  ["romdump.src.source.GameVersion"] = true,
  ["romdump.src.source.RomImporter"] = true,
}

local ROOT_FILE_PACKAGES = {
  ["app/main.lua"] = "app",
  ["app/conf.lua"] = "app",
  ["romdump/main.lua"] = "romdump",
  ["romdump/conf.lua"] = "romdump",
}

local function sourcePackageFor(file)
  local rootPackage = ROOT_FILE_PACKAGES[file]
  if rootPackage ~= nil then
    return rootPackage
  end
  for _, packageName in ipairs(GOVERNED_PACKAGES) do
    local rule = PACKAGE_RULES[packageName]
    if file:sub(1, #rule.sourcePrefix) == rule.sourcePrefix then
      return packageName
    end
  end
  return nil
end

local function targetPackageFor(module)
  for _, entry in ipairs(TARGET_PACKAGE_PREFIXES) do
    if module:sub(1, #entry.prefix) == entry.prefix then
      return entry.packageName
    end
  end
  for _, prefix in ipairs(GOVERNED_TARGET_PREFIXES) do
    if module:sub(1, #prefix) == prefix then
      return nil, "unknown first-party package"
    end
  end
  return nil
end

local function sortedFiles(files)
  local names = {}
  for file in pairs(files) do
    names[#names + 1] = file
  end
  table.sort(names)
  return names
end

local function appSeamViolation(module, targetPackage)
  if targetPackage == "game_hgss" and not APP_HGSS_IMPORTS[module] then
    return "app -> non-seam game_hgss import"
  end
  if targetPackage == "romdump" and not APP_ROMDUMP_IMPORTS[module] then
    return "app -> non-seam romdump import"
  end
  return nil
end

local function packageViolationsFor(files, packageName)
  local rule = assert(PACKAGE_RULES[packageName], "unknown package rule " .. packageName)
  local violations = {}
  for _, file in ipairs(sortedFiles(files)) do
    if sourcePackageFor(file) == packageName then
      for _, module in ipairs(files[file]) do
        local targetPackage, reason = targetPackageFor(module)
        if reason ~= nil then
          violations[#violations + 1] = file .. " requires " .. module .. " (" .. packageName .. " -> " .. reason .. ")"
        elseif targetPackage ~= nil and rule.allowed[targetPackage] ~= true then
          violations[#violations + 1] = file
            .. " requires "
            .. module
            .. " ("
            .. packageName
            .. " -> "
            .. targetPackage
            .. ")"
        elseif packageName == "app" then
          local seamViolation = appSeamViolation(module, targetPackage)
          if seamViolation ~= nil then
            violations[#violations + 1] = file .. " requires " .. module .. " (" .. seamViolation .. ")"
          end
        end
      end
    end
  end
  return violations
end

local function fixtureViolations(packageName, dependency)
  local rule = PACKAGE_RULES[packageName]
  if rule == nil then
    return { "missing package rule for " .. packageName }
  end
  return packageViolationsFor({
    [rule.sourcePrefix .. "Fixture.lua"] = { dependency },
  }, packageName)
end

function T.app_is_the_interactive_root()
  Assert.isTrue(pathExists("app/main.lua"), "the interactive LÖVE root must provide app/main.lua")
  Assert.isTrue(pathExists("app/conf.lua"), "the interactive LÖVE root must provide app/conf.lua")
  Assert.isTrue(pathExists("app/src/App.lua"), "the app shell must provide app/src/App.lua")
end

function T.nds_love_renderer_has_a_concrete_owner_without_upward_imports()
  Assert.isTrue(
    pathExists("libs/nds/src/love/GxRenderer.lua"),
    "the concrete DS LÖVE renderer must be owned under libs/nds/src/love"
  )
end

function T.package_policy_matches_every_governed_pair()
  local mismatches = {}
  for _, sourcePackage in ipairs(GOVERNED_PACKAGES) do
    for _, targetPackage in ipairs(GOVERNED_PACKAGES) do
      local expectedAllowed = PACKAGE_RULES[sourcePackage].allowed[targetPackage] == true
      local actualAllowed = #fixtureViolations(sourcePackage, REPRESENTATIVE_MODULES[targetPackage]) == 0
      if actualAllowed ~= expectedAllowed then
        mismatches[#mismatches + 1] = sourcePackage
          .. " -> "
          .. targetPackage
          .. " expected "
          .. tostring(expectedAllowed)
      end
    end
  end
  Assert.isTrue(#mismatches == 0, violationMessage("package policy mismatches:\n", mismatches))
end

function T.unknown_first_party_targets_are_rejected_without_rejecting_external_modules()
  local unknownModules = {
    "libs.future.src.Experiment",
    "app.future.Experiment",
    "game.future.src.Experiment",
    "romdump.future.Experiment",
  }
  local mismatches = {}
  for _, module in ipairs(unknownModules) do
    if #fixtureViolations("assets", module) == 0 then
      mismatches[#mismatches + 1] = "unknown target was accepted: " .. module
    end
  end
  Assert.equal(
    #fixtureViolations("assets", "vendor.utility.Module"),
    0,
    "an unmanaged external module must remain outside the package DAG"
  )
  Assert.isTrue(
    #mismatches == 0,
    violationMessage("unknown first-party targets bypassed the package policy:\n", mismatches)
  )
end

function T.app_cross_package_imports_match_exact_semantic_seams()
  local fixtures = {
    { module = "game.hgss.src.HgssGame", allowed = true },
    { module = "romdump.src.source.GameVersion", allowed = true },
    { module = "romdump.src.source.RomImporter", allowed = true },
    { module = "game.hgss.src.field.FieldRuntime", allowed = false },
    { module = "game.hgss.src.field.FieldState", allowed = false },
    { module = "romdump.src.digest.model.ModelAssetCompiler", allowed = false },
    { module = "romdump.src.source.RomSource", allowed = false },
  }
  local mismatches = {}
  for _, fixture in ipairs(fixtures) do
    local actualAllowed = #fixtureViolations("app", fixture.module) == 0
    if actualAllowed ~= fixture.allowed then
      mismatches[#mismatches + 1] = fixture.module .. " expected allowed=" .. tostring(fixture.allowed)
    end
  end
  Assert.isTrue(#mismatches == 0, violationMessage("app seam policy mismatches:\n", mismatches))
end

function T.runnable_roots_are_classified_and_reject_forbidden_dependencies()
  local fixtures = {
    { file = "app/main.lua", packageName = "app", dependency = "libs.hgss.src.field.FieldSession" },
    { file = "app/conf.lua", packageName = "app", dependency = "libs.hgss.src.field.FieldSession" },
    { file = "romdump/main.lua", packageName = "romdump", dependency = "game.hgss.src.HgssGame" },
    { file = "romdump/conf.lua", packageName = "romdump", dependency = "game.hgss.src.HgssGame" },
  }
  local failures = {}
  for _, fixture in ipairs(fixtures) do
    if sourcePackageFor(fixture.file) ~= fixture.packageName then
      failures[#failures + 1] = fixture.file .. " was not classified as " .. fixture.packageName
    end
    local violations = packageViolationsFor({ [fixture.file] = { fixture.dependency } }, fixture.packageName)
    if #violations == 0 then
      failures[#failures + 1] = fixture.file .. " accepted forbidden dependency " .. fixture.dependency
    end
  end
  Assert.isTrue(#failures == 0, violationMessage("runnable-root policy failures:\n", failures))
end

function T.test_paths_remain_unclassified_when_scanner_roots_are_broadened()
  local testPaths = {
    "app/tests/example.lua",
    "romdump/tests/example.lua",
  }
  for _, file in ipairs(testPaths) do
    Assert.equal(nil, sourcePackageFor(file), file .. " must remain outside production package classification")
  end
end

function T.package_policy_matches_actual_production_graph()
  local violations = {}
  for _, packageName in ipairs(GOVERNED_PACKAGES) do
    for _, violation in ipairs(packageViolationsFor(scannedFiles(), packageName)) do
      violations[#violations + 1] = violation
    end
  end
  table.sort(violations)
  Assert.isTrue(#violations == 0, violationMessage("production package policy violations:\n", violations))
end

function T.scanner_configuration_covers_runtime_package_roots()
  local indexed = {}
  for _, root in ipairs(PACKAGE_ROOTS) do
    indexed[root] = true
  end
  for _, packageName in ipairs(GOVERNED_PACKAGES) do
    Assert.isTrue(
      indexed[PACKAGE_RULES[packageName].scanRoot],
      "architecture scanner omits " .. packageName .. " source root"
    )
  end
end

return { tests = T }
