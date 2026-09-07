-- LÖVE configuration for the romdump CLI. It is always windowless and runs
-- without GPU/audio: every command is headless, prints machine-readable output,
-- and exits with a status code.

function love.conf(t)
  t.identity = "g4recomp"
  t.version = "11.5"
  t.modules.physics = false
  t.modules.window = false
  t.modules.graphics = false
  t.modules.audio = false
  t.modules.sound = false
  t.modules.joystick = false
  t.modules.touch = false
end
