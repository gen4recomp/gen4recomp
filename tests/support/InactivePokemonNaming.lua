-- Inactive field-test owner for the required Pokemon naming runtime contract.
local InactivePokemonNaming = {}

function InactivePokemonNaming.new()
  return {
    isActive = function()
      return false
    end,
    cancelPointerCapture = function() end,
  }
end

return InactivePokemonNaming
