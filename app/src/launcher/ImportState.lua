-- Interactive import screen. Presentational only: it renders an
-- importer's status snapshot and forwards drops; App owns the importer and pumps
-- it. Shows the drop instruction and the save-directory path where the private
-- cache lands, plus live stage/progress and structured error text on failure.

local Errors = require("libs.errors.src.Errors")
local RomImporter = require("romdump.src.source.RomImporter")

local ImportState = {}
ImportState.__index = ImportState

function ImportState.new(importer, saveDir)
  return setmetatable({ importer = importer, saveDir = saveDir }, ImportState)
end

function ImportState:update(_) end

function ImportState:filedropped(file)
  self.importer:filedropped(file)
end

---@param key string
function ImportState:keypressed(key, _, _)
  if key == "escape" then
    love.event.quit(0)
  end
end

function ImportState:draw()
  ImportState.render(self.importer:status(), self.saveDir)
end

-- Stateless renderer driven by an importer status snapshot. `saveDir` may be nil.
function ImportState.render(status, saveDir)
  local lg = love.graphics
  local x, y = 24, 24
  lg.setColor(1, 1, 1)
  lg.print("portemon — HeartGold / SoulSilver ROM import", x, y)
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Drop a .nds file onto this window to import it.", x, y + 28)
  if saveDir then
    lg.print("Private cache is written under:", x, y + 52)
    lg.print(saveDir, x, y + 72)
  end

  y = y + 116
  lg.setColor(0.85, 0.9, 0.95)
  lg.print("State:  " .. status.state, x, y)
  if status.sourceName then
    lg.print("File:   " .. status.sourceName, x, y + 20)
  end
  if status.displayName then
    lg.print("Target: " .. status.displayName, x, y + 40)
  end

  local s = RomImporter.STATES
  if status.state == s.EXTRACTING or status.state == s.COMPLETE then
    lg.print((status.stageLabel or "Working") .. (status.detail and ("  " .. status.detail) or ""), x, y + 68)
    local w, h = 360, 14
    lg.setColor(0.2, 0.22, 0.28)
    lg.rectangle("fill", x, y + 92, w, h)
    lg.setColor(0.35, 0.75, 0.55)
    lg.rectangle("fill", x, y + 92, w * (status.progress or 0), h)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print(string.format("%d%%", math.floor((status.progress or 0) * 100 + 0.5)), x + w + 12, y + 90)
  end

  if status.state == s.COMPLETE then
    lg.setColor(0.6, 0.9, 0.6)
    lg.print("Import complete.", x, y + 120)
  elseif status.state == s.ERROR then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Import failed [" .. tostring(status.errorCode or "ERROR") .. "]:", x, y + 120)
    lg.print(Errors.format(status.error), x, y + 140)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print("Drop a valid .nds ROM to retry.", x, y + 168)
  end
end

return ImportState
