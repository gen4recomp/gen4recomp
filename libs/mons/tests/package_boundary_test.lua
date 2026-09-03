-- Package boundary: the mon domain package exists with its prescribed
-- modules, exposes no facade, and depends only on the narrow foundation
-- set. Any wider require or presentation-engine use fails here before it
-- can entangle the domain with story, field, script, or host code.

local Assert = require("tests.support.Assert")

local T = {}

local EXPECTED_MODULES = {
  "libs/mons/src/MonCatalog.lua",
  "libs/mons/src/Mon.lua",
  "libs/mons/src/Party.lua",
  "libs/mons/src/MonsSave.lua",
  "libs/mons/src/errors.lua",
  "libs/mons/src/gen4/Lcrng.lua",
  "libs/mons/src/gen4/Personality.lua",
  "libs/mons/src/gen4/Experience.lua",
  "libs/mons/src/gen4/Stats.lua",
  "libs/mons/src/gen4/Moves.lua",
  "libs/mons/src/gen4/MonFactory.lua",
  "libs/mons/src/gen4/NativeLegality.lua",
  "libs/mons/src/gen4/BoxCodec.lua",
}

local FORBIDDEN_MODULES = {
  "libs/mons/src/Mons.lua",
  "libs/mons/src/gen4/mons.lua",
}

local ALLOWED_PACKAGES = {
  mons = true,
  assets = true,
  codec = true,
  errors = true,
  math = true,
}

local PACKAGE_PREFIXES = {
  { prefix = "libs.mons.src.", packageName = "mons" },
  { prefix = "libs.assets.src.", packageName = "assets" },
  { prefix = "libs.codec.src.", packageName = "codec" },
  { prefix = "libs.errors.src.", packageName = "errors" },
  { prefix = "libs.math.src.", packageName = "math" },
  { prefix = "libs.storage.src.", packageName = "storage" },
  { prefix = "libs.nds.src.", packageName = "nds" },
  { prefix = "libs.script.src.", packageName = "script" },
  { prefix = "libs.hgss.src.", packageName = "hgss" },
  { prefix = "libs.ui.src.", packageName = "ui" },
  { prefix = "game.src.", packageName = "game" },
  { prefix = "game.hgss.src.", packageName = "game_hgss" },
  { prefix = "romdump.src.", packageName = "romdump" },
  { prefix = "app.src.", packageName = "app" },
}

local function targetPackage(module)
  for _, entry in ipairs(PACKAGE_PREFIXES) do
    if module:sub(1, #entry.prefix) == entry.prefix then
      return entry.packageName
    end
  end
  for _, prefix in ipairs({ "libs.", "app.", "game.", "romdump." }) do
    if module:sub(1, #prefix) == prefix then
      return "unknown"
    end
  end
  return nil
end

-- The runner executes under `love app/`, whose presentation filesystem is
-- rooted at the app directory, so repo-relative paths are read through the
-- real source base directory instead (the same approach the shared
-- architecture test uses). Every assertion below keeps its original
-- contract: the same expected and forbidden modules, the same allowed
-- packages, and the same presentation-engine scan.
local BASE = love.filesystem.getSourceBaseDirectory()

local function fileExists(path)
  local handle = io.open(BASE .. "/" .. path, "r")
  if handle == nil then
    return false
  end
  handle:close()
  return true
end

local function readFile(path)
  local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
  local content = handle:read("*a")
  handle:close()
  return content
end

local function collectSources(dir, out)
  local command = "find '" .. BASE .. "/" .. dir .. "' -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. dir .. ": io.popen unavailable")
  local prefix = BASE .. "/"
  for line in pipe:lines() do
    assert(line:sub(1, #prefix) == prefix, "unexpected path outside the repository: " .. line)
    out[#out + 1] = line:sub(#prefix + 1)
  end
  pipe:close()
  table.sort(out)
  return out
end

function T.package_keeps_narrow_boundary_without_facade()
  Assert.isTrue(fileExists("libs/mons/AGENTS.md"), "the domain package owns its guidance")
  for _, path in ipairs(EXPECTED_MODULES) do
    Assert.isTrue(fileExists(path), "missing domain module " .. path)
  end
  for _, path in ipairs(FORBIDDEN_MODULES) do
    Assert.isFalse(fileExists(path), "forbidden facade " .. path)
  end

  local sources = collectSources("libs/mons/src", {})
  Assert.isTrue(#sources > 0, "the domain package carries no scanned sources")
  local violations = {}
  for _, path in ipairs(sources) do
    local content = readFile(path)
    for module in content:gmatch('require%s*%(%s*"([^"]+)"%s*%)') do
      local target = targetPackage(module)
      if target ~= nil and ALLOWED_PACKAGES[target] ~= true then
        violations[#violations + 1] = path .. " requires " .. module
      end
    end
    for module in content:gmatch('require%s*"([^"]+)"') do
      local target = targetPackage(module)
      if target ~= nil and ALLOWED_PACKAGES[target] ~= true then
        violations[#violations + 1] = path .. " requires " .. module
      end
    end
    if content:find("love%.") ~= nil then
      violations[#violations + 1] = path .. " reaches the presentation engine"
    end
  end
  table.sort(violations)
  Assert.isTrue(#violations == 0, table.concat(violations, "\n"))
end

return { tests = T }
