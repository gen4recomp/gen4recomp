-- Ordinary window configuration. The ordinary boot path must seed the reference
-- size before applying independent environment overrides, and invalid
-- overrides must fail with the offending variable named.

local Assert = require("tests.support.Assert")
local WindowConfig = require("game.src.WindowConfig")

local T = {}

local function withOrdinaryConf(env, fn)
  local savedArg = arg
  local savedGetenv = os.getenv
  local savedConf = love.conf
  arg = {}
  os.getenv = function(name)
    local v = env[name]
    if v ~= nil then
      return v
    end
    return nil
  end
  local t = { window = {}, modules = {} }
  local ok, err = pcall(function()
    love.conf(t)
    fn(t)
  end)
  arg = savedArg
  os.getenv = savedGetenv
  love.conf = savedConf
  if not ok then
    error(err, 0)
  end
end

local function assertInvalid(env, expectedVar)
  local savedArg = arg
  local savedGetenv = os.getenv
  local savedConf = love.conf
  arg = {}
  os.getenv = function(name)
    local v = env[name]
    if v ~= nil then
      return v
    end
    return nil
  end
  local t = { window = {}, modules = {} }
  local ok, err = pcall(function()
    love.conf(t)
  end)
  arg = savedArg
  os.getenv = savedGetenv
  love.conf = savedConf
  Assert.isFalse(ok, "invalid environment must raise")
  Assert.notNil(err, "error must name " .. expectedVar)
  local message = err --[[@as string]]
  Assert.notNil(message:find(expectedVar, 1, true), "error must name " .. expectedVar)
end

function T.ordinary_configuration_defaults_to_reference_size()
  withOrdinaryConf({}, function(t)
    Assert.equal(t.window.width, WindowConfig.REFERENCE_WIDTH)
    Assert.equal(t.window.height, WindowConfig.REFERENCE_HEIGHT)
    Assert.equal(t.window.title, "g4recomp")
    Assert.isTrue(t.window.resizable)
    Assert.equal(t.window.vsync, 1)
  end)
end

function T.width_override_replaces_only_width()
  withOrdinaryConf({ G4RECOMP_WINDOW_WIDTH = "800" }, function(t)
    Assert.equal(t.window.width, 800)
    Assert.equal(t.window.height, WindowConfig.REFERENCE_HEIGHT)
  end)
end

function T.height_override_replaces_only_height()
  withOrdinaryConf({ G4RECOMP_WINDOW_HEIGHT = "600" }, function(t)
    Assert.equal(t.window.width, WindowConfig.REFERENCE_WIDTH)
    Assert.equal(t.window.height, 600)
  end)
end

function T.both_dimensions_override_together()
  withOrdinaryConf({ G4RECOMP_WINDOW_WIDTH = "800", G4RECOMP_WINDOW_HEIGHT = "600" }, function(t)
    Assert.equal(t.window.width, 800)
    Assert.equal(t.window.height, 600)
  end)
end

function T.invalid_width_is_rejected()
  assertInvalid({ G4RECOMP_WINDOW_WIDTH = "0" }, "G4RECOMP_WINDOW_WIDTH")
end

function T.invalid_height_is_rejected()
  assertInvalid({ G4RECOMP_WINDOW_HEIGHT = "garbage" }, "G4RECOMP_WINDOW_HEIGHT")
end

return { tests = T }
