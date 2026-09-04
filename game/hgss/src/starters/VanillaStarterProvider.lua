-- Default starter roster for Elm's Lab. HGSS story policy: exactly three
-- native species keys in source creation order. Creation level, generator
-- draws, met context, presentation, and party publication live in the
-- starter task and the mon service; this module only selects species.
-- Hand-editing the table below is sufficient to substitute other native
-- species while preserving legal creation. Field composition injects this
-- module; starter code consumes the injected provider shape, never this
-- concrete module directly.

local VanillaStarterProvider = {}

local SPECIES = { "CHIKORITA", "CYNDAQUIL", "TOTODILE" }

---@return string[] exactly three native species keys in source order
function VanillaStarterProvider:resolve()
  return { SPECIES[1], SPECIES[2], SPECIES[3] }
end

return VanillaStarterProvider
