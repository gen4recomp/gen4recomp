-- Script dependency boundary: the generic script package never imports
-- mon or HGSS mechanics, while HGSS script composition receives the live
-- mon service through its established injection seam.

local Assert = require("tests.support.Assert")
local Bindings = require("libs.hgss.src.script.Bindings")

local T = {}

local BASE = love.filesystem.getSourceBaseDirectory()

local function luaFilesUnder(root)
  local command = "find '" .. BASE .. "/" .. root .. "' -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. root)
  local out = {}
  for line in pipe:lines() do
    out[#out + 1] = line
  end
  pipe:close()
  return out
end

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local content = handle:read("*a")
  handle:close()
  return content
end

function T.generic_script_package_imports_no_mon_or_hgss_mechanics()
  local violations = {}
  for _, path in ipairs(luaFilesUnder("libs/script/src")) do
    local content = readFile(path)
    for module in content:gmatch('require%s*%(%s*"([^"]+)"%s*%)') do
      if module:find("libs.mons", 1, true) == 1 or module:find("libs.hgss", 1, true) == 1 then
        violations[#violations + 1] = path .. " requires " .. module
      end
    end
    for module in content:gmatch('require%s*"([^"]+)"') do
      if module:find("libs.mons", 1, true) == 1 or module:find("libs.hgss", 1, true) == 1 then
        violations[#violations + 1] = path .. " requires " .. module
      end
    end
  end
  Assert.equal(#violations, 0, "generic script code stays mon-agnostic: " .. table.concat(violations, ", "))
end

function T.hgss_bindings_receive_the_live_mon_service()
  -- A stand-in service object: the boundary contract only needs an injected
  -- value to flow through without the script package importing the mon domain.
  local mons = { marker = "live-mon-service" }
  local bindings = Bindings.new({
    mons = mons --[[@as HgssMonService]],
  })
  Assert.equal(bindings.mons, mons, "composition injects the mon service instead of importing it")
end

return { tests = T }
