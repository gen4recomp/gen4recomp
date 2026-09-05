-- Script lowering handlers for sound, music, and screen fade operations.
local Operands = require("romdump.src.digest.script.lowering.Operands")

local function playSound(ins)
  -- PlaySE reads its operand through ScriptGetVar (scrcmd_sound.c).
  return { op = "play_sound", sound = Operands.varRef(ins.operands[1]) }
end

local function stopSound(ins)
  return { op = "stop_sound", sound = Operands.varRef(ins.operands[1]) }
end

local function waitSound(ins)
  return { op = "wait_sound", sound = Operands.varRef(ins.operands[1]) }
end

local function playCry(ins)
  -- PlayCryEx reads both operands through ScriptGetVar (scrcmd_sound.c); its
  -- second script operand is the cry pattern, not a mon form.
  return { op = "play_cry", species = Operands.varRef(ins.operands[1]), pattern = Operands.varRef(ins.operands[2]) }
end

local function waitCry()
  return { op = "wait_cry" }
end

local function playFanfare(ins)
  return { op = "play_fanfare", fanfare = Operands.varRef(ins.operands[1]) }
end

local function waitFanfare()
  return { op = "wait_fanfare" }
end

local function playMusic(ins)
  return { op = "play_music", music = Operands.operandValue(ins.operands[1]) }
end

local function stopMusic()
  -- The pinned ScrCmd_StopBGM ignores its operand entirely (it stops the
  -- currently playing BGM), so the operand is a documented erasure.
  return { op = "stop_music" }
end

local function resetMusic()
  return { op = "reset_music" }
end

local function fadeMusicOut(ins)
  return {
    op = "fade_music_out",
    target = Operands.operandValue(ins.operands[1]),
    durationTicks = Operands.operandValue(ins.operands[2]),
  }
end

local function fadeMusicIn(ins)
  return { op = "fade_music_in", durationTicks = Operands.operandValue(ins.operands[1]) }
end

local function temporaryMusic(ins)
  return { op = "temporary_music", music = Operands.operandValue(ins.operands[1]) }
end

local function fadeScreen(ins)
  local rawDirection = Operands.operandValue(ins.operands[3])
  local direction
  if rawDirection == 0 then
    direction = "out"
  elseif rawDirection == 1 then
    direction = "in"
  else
    error("unknown fade type " .. tostring(rawDirection))
  end
  local rawColor = Operands.operandValue(ins.operands[4])
  local color
  if rawColor == 0 then
    color = "black"
  elseif rawColor == 0x7FFF or rawColor == 32767 then
    color = "white"
  else
    error("unknown fade color " .. tostring(rawColor))
  end
  return {
    op = "fade_screen",
    duration = Operands.operandValue(ins.operands[1]),
    speed = Operands.operandValue(ins.operands[2]),
    direction = direction,
    color = color,
  }
end

local function waitFade()
  return { op = "wait_fade" }
end

return {
  [73] = playSound,
  [74] = stopSound,
  [75] = waitSound,
  [76] = playCry,
  [77] = waitCry,
  [78] = playFanfare,
  [79] = waitFanfare,
  [80] = playMusic,
  [81] = stopMusic,
  [82] = resetMusic,
  [84] = fadeMusicOut,
  [85] = fadeMusicIn,
  [87] = temporaryMusic,
  [174] = fadeScreen,
  [175] = waitFade,
}
