-- App entry point. This app is its own LÖVE root (`love app/`); the repo root
-- (the source base directory) is added to package.path first so `require`
-- resolves libs and sibling apps by their full repo-relative path (libs.*,
-- game.src.*, data.*) independent of the working directory. Flags: --test runs
-- the recursively discovered, layer-selectable test suite and exits; --dev enables
-- the playtest HUD and the F1/F2 developer binds; without
-- it the app runs in product mode; otherwise App drives the normal
-- boot/import/Main Menu flow. Options.parse owns strictness: unknown options and
-- stray arguments are rejected with a message on
-- stderr and exit status 2, and everything after the exact --test token is
-- left to the test command.
local ROOT = love.filesystem.getSourceBaseDirectory()
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

local Options = require("app.src.Options")

local App

function love.load(argv)
  local opts, message = Options.parse(argv)
  if opts == nil then
    -- A raise from love.load would hang headless on the error screen; reject
    -- with the usage status instead. "app: " mirrors the test command's
    -- "test: " prefix.
    io.stderr:write("app: " .. message .. "\n")
    love.event.quit(Options.EXIT_USAGE)
    return
  end

  if opts.test then
    -- The test command owns its own argument parsing and exit status.
    love.event.quit(require("tests.run").main(argv))
    return
  end

  App = require("app.src.App")
  App.load(opts)
end

function love.update(dt)
  if App then
    App.update(dt)
  end
end

function love.draw()
  if App then
    App.draw()
  end
end

function love.resize(width, height)
  if App then
    App.resize(width, height)
  end
end

function love.filedropped(file)
  if App then
    App.filedropped(file)
  end
end

function love.keypressed(key, scancode, isrepeat)
  if App then
    App.keypressed(key, scancode, isrepeat)
  end
end

function love.textinput(text)
  if App then
    App.textinput(text)
  end
end

function love.keyreleased(key, scancode)
  if App then
    App.keyreleased(key, scancode)
  end
end

function love.gamepadpressed(joystick, button)
  if App then
    App.gamepadpressed(joystick, button)
  end
end

function love.gamepadreleased(joystick, button)
  if App then
    App.gamepadreleased(joystick, button)
  end
end

function love.gamepadaxis(joystick, axis, value)
  if App then
    App.gamepadaxis(joystick, axis, value)
  end
end

function love.mousepressed(x, y, button, istouch, presses)
  if App then
    App.mousepressed(x, y, button, istouch, presses)
  end
end

function love.mousemoved(x, y, dx, dy, istouch)
  if App then
    App.mousemoved(x, y, dx, dy, istouch)
  end
end

function love.mousereleased(x, y, button, istouch, presses)
  if App then
    App.mousereleased(x, y, button, istouch, presses)
  end
end

function love.wheelmoved(x, y)
  if App then
    App.wheelmoved(x, y)
  end
end

function love.touchpressed(id, x, y, dx, dy, pressure)
  if App then
    App.touchpressed(id, x, y, dx, dy, pressure)
  end
end

function love.touchmoved(id, x, y, dx, dy, pressure)
  if App then
    App.touchmoved(id, x, y, dx, dy, pressure)
  end
end

function love.touchreleased(id, x, y, dx, dy, pressure)
  if App then
    App.touchreleased(id, x, y, dx, dy, pressure)
  end
end

function love.focus(focused)
  if App then
    App.focus(focused)
  end
end

function love.quit()
  if App then
    App.quit()
  end
end
