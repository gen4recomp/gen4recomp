-- Recovers the host path passed to the test command's `--rom-source <path>`
-- flag for suites that must open a canonical ROM directly through
-- RomSource/NdsRom rather than through the imported derived cache. LOVE
-- preserves the raw process invocation in the global `arg` table, so this
-- reads the exact path the test runner's own Cli.parse already validated,
-- without re-deriving or duplicating that parsing.

local RomSourcePath = {}

---@return string|nil
function RomSourcePath.find()
  local raw = _G.arg
  if type(raw) ~= "table" then
    return nil
  end
  for i = 1, #raw do
    if raw[i] == "--rom-source" then
      return raw[i + 1]
    end
  end
  return nil
end

return RomSourcePath
