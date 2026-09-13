-- Shared scaffolding for the graphics smoke suites. LÖVE's graphics state is
-- process-global and its objects are GPU memory, so a failing smoke test must
-- leave neither behind for the next one. `GraphicsSmoke.suite` declares the
-- graphics capability once (the graphics layer comes from the discovery root
-- the suite lives under) and wraps every body so that the resources the body
-- took ownership of through `scope:own` are released, and every captured
-- global state is restored, on the failure path as well as the success path. A
-- body that asserts release behavior itself keeps its own explicit `release()`
-- call and does not hand the object to the scope.

local GraphicsSmoke = {}

---@class GraphicsScope
---@field _owned table[]
local Scope = {}
Scope.__index = Scope

-- Hands a freshly created graphics resource to the test scope. Returns it, so
-- `local canvas = scope:own(love.graphics.newCanvas(64, 64))` reads as one step.
---@generic T
---@param resource T
---@return T
function Scope:own(resource)
  self._owned[#self._owned + 1] = resource
  return resource
end

---@param lg love.graphics
---@return table
local function capture(lg)
  local red, green, blue, alpha = lg.getColor()
  local blendMode, alphaMode = lg.getBlendMode()
  local depthMode, depthWrite = lg.getDepthMode()
  local sx, sy, sw, sh = lg.getScissor()
  return {
    canvas = lg.getCanvas(),
    shader = lg.getShader(),
    color = { red, green, blue, alpha },
    blend = { blendMode, alphaMode },
    depth = { depthMode, depthWrite },
    wireframe = lg.isWireframe(),
    cullMode = lg.getMeshCullMode(),
    scissor = sx and { sx, sy, sw, sh } or nil,
  }
end

---@param lg love.graphics
---@param state table
local function restore(lg, state)
  lg.setCanvas(state.canvas)
  lg.setShader(state.shader)
  lg.setColor(state.color[1], state.color[2], state.color[3], state.color[4])
  lg.setBlendMode(state.blend[1], state.blend[2])
  lg.setDepthMode(state.depth[1], state.depth[2])
  lg.setWireframe(state.wireframe)
  lg.setMeshCullMode(state.cullMode)
  if state.scissor then
    lg.setScissor(state.scissor[1], state.scissor[2], state.scissor[3], state.scissor[4])
  else
    lg.setScissor()
  end
end

---@param body fun(scope: GraphicsScope, context: table?)
---@return fun(context: table?)
local function wrap(body)
  return function(context)
    local lg = love.graphics
    ---@cast lg love.graphics
    local before = capture(lg)
    local scope = setmetatable({ _owned = {} }, Scope)

    local ok, err = xpcall(body, debug.traceback, scope, context)

    local cleanupError
    for index = #scope._owned, 1, -1 do
      local released, releaseError = pcall(scope._owned[index].release, scope._owned[index])
      if not released and cleanupError == nil then
        cleanupError = releaseError
      end
    end
    local restored, restoreError = pcall(restore, lg, before)

    if not ok then
      error(err, 0)
    end
    if not restored then
      error(restoreError, 0)
    end
    if cleanupError ~= nil then
      error(cleanupError, 0)
    end
  end
end

-- Builds the explicit suite shape a graphics module returns. Every body takes
-- the scope (and, for tests that need it, the runner context for explicit
-- `context:skip`); these suites need no capability probing of their own,
-- because the declared capability already gates them.
---@param tests table<string, fun(scope: GraphicsScope, context: table?)>
---@return table suite
function GraphicsSmoke.suite(tests)
  local wrapped = {}
  for name, body in pairs(tests) do
    wrapped[name] = wrap(body)
  end
  return {
    metadata = { capabilities = { "graphics" } },
    tests = wrapped,
  }
end

return GraphicsSmoke
