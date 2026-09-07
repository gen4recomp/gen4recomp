-- Process callback forwarding. The real LÖVE entrypoint wires host
-- callbacks directly into App; this test keeps that thin seam from silently
-- dropping or reordering arguments.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")

local T = {}

---@class CapturedCallbackArguments
---@field [integer] unknown
---@field n integer

function T.input_callbacks_forward_complete_argument_tuples()
  local savedLoveLoad = love.load
  local savedLoveKeypressed = love.keypressed
  local savedLoveTextinput = love.textinput
  local savedLoveGamepadaxis = love.gamepadaxis
  local savedLoveMousepressed = love.mousepressed
  local savedLoveTouchpressed = love.touchpressed

  local savedAppLoad = App.load
  local savedAppKeypressed = App.keypressed
  local savedAppTextinput = App.textinput
  local savedAppGamepadaxis = App.gamepadaxis
  local savedAppMousepressed = App.mousepressed
  local savedAppTouchpressed = App.touchpressed

  local ok, err = pcall(function()
    App.load = function() end
    local entrypoint = assert(loadfile(love.filesystem.getSourceBaseDirectory() .. "/app/main.lua"))
    entrypoint()
    love.load({})
    App.load = savedAppLoad

    local calls = {}

    App.keypressed = function(...)
      local t = { n = select("#", ...), ... } ---@type CapturedCallbackArguments
      calls.keypressed = t
    end
    App.textinput = function(...)
      local t = { n = select("#", ...), ... } ---@type CapturedCallbackArguments
      calls.textinput = t
    end
    App.gamepadaxis = function(...)
      local t = { n = select("#", ...), ... } ---@type CapturedCallbackArguments
      calls.gamepadaxis = t
    end
    App.mousepressed = function(...)
      local t = { n = select("#", ...), ... } ---@type CapturedCallbackArguments
      calls.mousepressed = t
    end
    App.touchpressed = function(...)
      local t = { n = select("#", ...), ... } ---@type CapturedCallbackArguments
      calls.touchpressed = t
    end

    local joystick = {}

    Assert.equal(type(love.keypressed), "function", "love.keypressed must be registered by the entrypoint")
    Assert.equal(type(love.textinput), "function", "love.textinput must be registered by the entrypoint")
    Assert.equal(type(love.gamepadaxis), "function", "love.gamepadaxis must be registered by the entrypoint")
    Assert.equal(type(love.mousepressed), "function", "love.mousepressed must be registered by the entrypoint")
    Assert.equal(type(love.touchpressed), "function", "love.touchpressed must be registered by the entrypoint")

    local keypressedArgs = { "a", "a", true }
    ---@diagnostic disable-next-line: param-type-mismatch -- Deliberately forward the complete LÖVE keypressed vararg payload.
    love.keypressed(unpack(keypressedArgs))
    local actual = assert(calls.keypressed, "love.keypressed must reach App.keypressed")
    Assert.equal(actual.n, #keypressedArgs, "love.keypressed must preserve every LÖVE argument")
    for i, v in ipairs(keypressedArgs) do
      Assert.equal(actual[i], v, "love.keypressed argument " .. i .. " changed")
    end

    local textinputArgs = { "é" }
    love.textinput(unpack(textinputArgs))
    actual = assert(calls.textinput, "love.textinput must reach App.textinput")
    Assert.equal(actual.n, #textinputArgs, "love.textinput must preserve every LÖVE argument")
    for i, v in ipairs(textinputArgs) do
      Assert.equal(actual[i], v, "love.textinput argument " .. i .. " changed")
    end

    local gamepadaxisArgs = { joystick, "leftx", 0.75 }
    love.gamepadaxis(unpack(gamepadaxisArgs))
    actual = assert(calls.gamepadaxis, "love.gamepadaxis must reach App.gamepadaxis")
    Assert.equal(actual.n, #gamepadaxisArgs, "love.gamepadaxis must preserve every LÖVE argument")
    for i, v in ipairs(gamepadaxisArgs) do
      Assert.equal(actual[i], v, "love.gamepadaxis argument " .. i .. " changed")
    end
    Assert.equal(actual[1], joystick, "love.gamepadaxis joystick identity must be preserved")

    local mousepressedArgs = { 12, 34, 1, false, 2 }
    love.mousepressed(unpack(mousepressedArgs))
    actual = assert(calls.mousepressed, "love.mousepressed must reach App.mousepressed")
    Assert.equal(actual.n, #mousepressedArgs, "love.mousepressed must preserve every LÖVE argument")
    for i, v in ipairs(mousepressedArgs) do
      Assert.equal(actual[i], v, "love.mousepressed argument " .. i .. " changed")
    end

    local touchId = "touch-1"
    local touchpressedArgs = { touchId, 3, 4, 0.5, 0.25, 0.8 }
    love.touchpressed(unpack(touchpressedArgs))
    actual = assert(calls.touchpressed, "love.touchpressed must reach App.touchpressed")
    Assert.equal(actual.n, #touchpressedArgs, "love.touchpressed must preserve every LÖVE argument")
    for i, v in ipairs(touchpressedArgs) do
      Assert.equal(actual[i], v, "love.touchpressed argument " .. i .. " changed")
    end
    Assert.equal(actual[1], touchId, "love.touchpressed identifier identity must be preserved")
  end)

  App.load = savedAppLoad
  App.keypressed = savedAppKeypressed
  App.textinput = savedAppTextinput
  App.gamepadaxis = savedAppGamepadaxis
  App.mousepressed = savedAppMousepressed
  App.touchpressed = savedAppTouchpressed
  love.load = savedLoveLoad
  love.keypressed = savedLoveKeypressed
  love.textinput = savedLoveTextinput
  love.gamepadaxis = savedLoveGamepadaxis
  love.mousepressed = savedLoveMousepressed
  love.touchpressed = savedLoveTouchpressed

  if not ok then
    error(err, 0)
  end
end

return { tests = T }
