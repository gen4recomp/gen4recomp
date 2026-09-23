-- Minimal two-version selector. Shown only when both
-- HeartGold and SoulSilver dumps are ready and no version was requested. Number
-- keys pick a version; onPick(versionId) hands control back to App.

local GameVersion = require("romdump.src.source.GameVersion")

local VersionSelectState = {}
VersionSelectState.__index = VersionSelectState

function VersionSelectState.new(readyVersions, onPick)
  return setmetatable({ ready = readyVersions, onPick = onPick }, VersionSelectState)
end

function VersionSelectState:update(_) end

---@param key string
function VersionSelectState:keypressed(key, _, _)
  local n = tonumber(key)
  if n and self.ready[n] then
    self.onPick(self.ready[n])
  elseif key == "escape" then
    love.event.quit(0)
  end
end

function VersionSelectState:draw()
  local lg = love.graphics
  local x, y = 24, 24
  lg.setColor(1, 1, 1)
  lg.print("portemon — select a version", x, y)
  lg.setColor(0.85, 0.9, 0.95)
  for i, id in ipairs(self.ready) do
    lg.print(i .. ") " .. GameVersion.info(id).displayName, x, y + 12 + i * 22)
  end
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Press the number to start or resume its field session.", x, y + 24 + (#self.ready + 1) * 22)
end

return VersionSelectState
