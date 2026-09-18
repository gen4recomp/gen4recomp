-- Stateless ordered directional candidate resolution over an explicit graph.

---@alias FocusDirection "up"|"down"|"left"|"right"
---@alias FocusNodeId string|integer
---@alias FocusGraphMap table<FocusNodeId, table<string, FocusNodeId[]>>

local FocusGraph = {}

---@param graph FocusGraphMap
---@param currentId FocusNodeId
---@param direction FocusDirection
---@return FocusNodeId
function FocusGraph.move(graph, currentId, direction)
  assert(type(graph) == "table", "the focus graph is required")
  local node = assert(graph[currentId], "current focus node is absent")
  local candidates = assert(node[direction], "unknown focus direction")
  assert(type(candidates) == "table", "the focus direction field must be an ordered candidate list")
  for _, candidateId in ipairs(candidates) do
    if graph[candidateId] ~= nil then
      return candidateId
    end
  end
  return currentId
end

return FocusGraph
