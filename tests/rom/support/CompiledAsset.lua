-- Reads finalized compiler assets through their production love.Data contract.

local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")

local CompiledAsset = {}

function CompiledAsset.bytes(data)
  assert(type(data) == "userdata" and type(data.getString) == "function", "compiled asset must be love.Data")
  return data:getString()
end

function CompiledAsset.mesh(data)
  return SceneMesh.decode(CompiledAsset.bytes(data))
end

return CompiledAsset
