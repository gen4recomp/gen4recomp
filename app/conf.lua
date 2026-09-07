-- LÖVE configuration for the game app. The test command (--test) gets a real
-- but offscreen graphics context: the explicit graphics layer compiles shaders
-- and allocates canvases, meshes, and images for real, so a windowless run would
-- report work it never did. The window is hidden, unfocused, and vsync-free so
-- the suite neither steals the desktop nor paces itself against a monitor; the
-- host modules no test needs (audio, sound, joystick, touch) stay off. An
-- ordinary boot gets a normal resizable window. Test detection is a plain scan
-- of `arg` because LÖVE modules are not up yet.

-- Requires the shared window reference. love.conf runs before main.lua, so the
-- repo-root package.path it installs is not available yet; the module resolves
-- through the launch working directory instead.
local WindowConfig = require("game.src.WindowConfig")

local function isTest()
  for _, a in ipairs(arg or {}) do
    if a == "--test" then
      return true
    end
  end
  return false
end

function love.conf(t)
  t.identity = "g4recomp"
  t.version = "11.5"
  t.modules.physics = false

  if isTest() then
    t.modules.audio = false
    t.modules.sound = false
    t.modules.joystick = false
    t.modules.touch = false

    t.window.title = "g4recomp tests"
    t.window.width = WindowConfig.REFERENCE_WIDTH
    t.window.height = WindowConfig.REFERENCE_HEIGHT
    t.window.resizable = false
    t.window.visible = false
    t.window.vsync = 0
    t.window.depth = 24 -- the render-target smoke tests need a depth buffer
    t.window.stencil = 8
  else
    t.window.title = "g4recomp"
    t.window.width = WindowConfig.REFERENCE_WIDTH
    t.window.height = WindowConfig.REFERENCE_HEIGHT
    t.window.resizable = true
    t.window.vsync = 1
    t.window.depth = 24 -- 3D map rendering needs a depth buffer
    t.window.stencil = 8
    -- Environment-provided dimensions must be positive integers; an invalid
    -- value is a configuration fault that refuses to boot rather than silently
    -- opening at a different size.
    local width, widthError =
      WindowConfig.parseEnvDimension(os.getenv("G4RECOMP_WINDOW_WIDTH"), "G4RECOMP_WINDOW_WIDTH")
    if widthError then
      error(widthError, 0)
    end
    local height, heightError =
      WindowConfig.parseEnvDimension(os.getenv("G4RECOMP_WINDOW_HEIGHT"), "G4RECOMP_WINDOW_HEIGHT")
    if heightError then
      error(heightError, 0)
    end
    if width then
      t.window.width = width
    end
    if height then
      t.window.height = height
    end
  end
end
