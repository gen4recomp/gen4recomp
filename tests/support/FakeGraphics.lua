-- Shared fake LÖVE graphics namespace for the renderer unit suites. Tracks
-- created images and their release calls, records every draw (with its quad,
-- position, and the color at draw time), the transform stack (translate/
-- scale) and primitive calls (rectangle/polygon/print) as separate lists (plus
-- a detailed `rectangles` record for callers that need the exact mode/rect/
-- color), created shaders (with every `send` call recorded), tracks the
-- transform-stack depth, and holds a full settable state the renderers must
-- restore exactly. failOnQuadCall/failOnDrawCall/failOnImageCall/
-- failOnShaderCall make the Nth construction/draw/image/shader call raise;
-- imageSizes supplies the created image dimensions in creation order. The
-- suites assert exactly the record shapes this helper produces; the real
-- love.graphics object is never touched.

---@class FakeGraphics: love.Graphics
---@field images table[]
---@field draws table[]
---@field transforms table[]
---@field primitives string[]
---@field rectangles table[]
---@field shaders table[]
---@field canvases table[]
---@field blendModes table[]
---@field pushDepth fun(): integer
---@field newImage fun(data?: table): table
---@field getLineWidth fun(): number
---@field setLineWidth fun(width: number)
local FakeGraphics = {}

-- opts.canvas/shader/blendMode/... seed the settable state so tests can
-- verify exact restoration after a draw. The returned table is structurally
-- a love.Graphics subset plus the recording fields; call sites pass it as
-- the renderers' injectable graphics namespace.
---@param opts? { canvas?: any, shader?: any, blendMode?: any, blendAlpha?: any, depthMode?: any, depthWrite?: boolean, wireframe?: boolean, cullMode?: any, color?: number[], scissor?: number[], lineWidth?: number, imageSizes?: table[], failOnCanvasCall?: integer, failOnQuadCall?: integer, failOnDrawCall?: integer, failOnImageCall?: integer, failOnShaderCall?: integer, shaderReturnsNil?: boolean }
---@return FakeGraphics
function FakeGraphics.new(opts)
  opts = opts or {}
  local images = {}
  local canvases = {}
  local shaders = {}
  local blendModes = {}
  local canvasCalls, imageCalls, quadCalls, drawCalls, shaderCalls = 0, 0, 0, 0, 0
  local pushDepth = 0
  local draws = {}
  local transforms = {}
  local primitives = {}
  local rectangles = {}
  local state = {
    canvas = opts.canvas,
    shader = opts.shader,
    blendMode = opts.blendMode,
    blendAlpha = opts.blendAlpha,
    depthMode = opts.depthMode,
    depthWrite = opts.depthWrite,
    wireframe = opts.wireframe,
    cullMode = opts.cullMode,
    color = opts.color or { 1, 1, 1, 1 },
    scissor = opts.scissor,
    lineWidth = opts.lineWidth or 1,
  }
  return {
    images = images,
    canvases = canvases,
    shaders = shaders,
    draws = draws,
    blendModes = blendModes,
    transforms = transforms,
    primitives = primitives,
    rectangles = rectangles,
    pushDepth = function()
      return pushDepth
    end,
    newShader = function(source)
      shaderCalls = shaderCalls + 1
      if opts.failOnShaderCall == shaderCalls then
        error("injected newShader failure")
      end
      if opts.shaderReturnsNil then
        return nil
      end
      local shader = { source = source, released = false, sends = {} }
      shader.send = function(_, name, value)
        shader.sends[#shader.sends + 1] = { name = name, value = value }
      end
      shader.release = function()
        shader.released = true
      end
      shaders[#shaders + 1] = shader
      return shader
    end,
    newCanvas = function(width, height)
      canvasCalls = canvasCalls + 1
      if opts.failOnCanvasCall == canvasCalls then
        error("injected newCanvas failure")
      end
      local canvas = {
        width = width,
        height = height,
        releaseCount = 0,
        setFilter = function() end,
      }
      function canvas:release()
        self.releaseCount = self.releaseCount + 1
      end
      canvases[#canvases + 1] = canvas
      return canvas
    end,
    newImage = function()
      imageCalls = imageCalls + 1
      if opts.failOnImageCall == imageCalls then
        error("injected newImage failure")
      end
      local size = opts.imageSizes and opts.imageSizes[#images + 1] or { 16, 16 }
      local image
      image = {
        released = false,
        releaseCount = 0,
        filters = {},
        setFilter = function(_, min, mag)
          image.filters[#image.filters + 1] = { min = min, mag = mag }
        end,
        getWidth = function()
          return size[1]
        end,
        getHeight = function()
          return size[2]
        end,
      }
      image.release = function()
        image.released = true
        image.releaseCount = image.releaseCount + 1
      end
      images[#images + 1] = image
      return image
    end,
    newQuad = function(x, y, w, h, imgW, imgH)
      quadCalls = quadCalls + 1
      if opts.failOnQuadCall == quadCalls then
        error("injected newQuad failure")
      end
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
    push = function()
      pushDepth = pushDepth + 1
    end,
    pop = function()
      pushDepth = pushDepth - 1
    end,
    translate = function(x, y)
      transforms[#transforms + 1] = { "translate", x, y }
    end,
    scale = function(x, y)
      transforms[#transforms + 1] = { "scale", x, y }
    end,
    setColor = function(r, g, b, a)
      state.color = { r, g, b, a }
    end,
    clear = function() end,
    getColor = function()
      return state.color[1], state.color[2], state.color[3], state.color[4]
    end,
    draw = function(image, quad, x, y, rotation, sx, sy)
      drawCalls = drawCalls + 1
      draws[#draws + 1] = {
        kind = "draw",
        image = image,
        quad = quad,
        x = x,
        y = y,
        rotation = rotation,
        sx = sx,
        sy = sy,
        color = state.color,
      }
      if opts.failOnDrawCall == drawCalls then
        error("injected draw failure")
      end
    end,
    rectangle = function(mode, x, y, w, h, rx, ry)
      primitives[#primitives + 1] = "rectangle"
      rectangles[#rectangles + 1] = {
        mode = mode,
        x = x,
        y = y,
        w = w,
        h = h,
        rx = rx,
        ry = ry,
        color = { state.color[1], state.color[2], state.color[3], state.color[4] },
        lineWidth = state.lineWidth,
      }
    end,
    getLineWidth = function()
      return state.lineWidth
    end,
    setLineWidth = function(width)
      state.lineWidth = width
    end,
    polygon = function()
      primitives[#primitives + 1] = "polygon"
    end,
    print = function()
      primitives[#primitives + 1] = "print"
    end,
    getCanvas = function()
      return state.canvas
    end,
    setCanvas = function(canvas)
      state.canvas = canvas
    end,
    getShader = function()
      return state.shader
    end,
    setShader = function(shader)
      state.shader = shader
    end,
    getBlendMode = function()
      return state.blendMode, state.blendAlpha
    end,
    setBlendMode = function(mode, alpha)
      state.blendMode, state.blendAlpha = mode, alpha
      blendModes[#blendModes + 1] = { mode, alpha }
    end,
    getDepthMode = function()
      return state.depthMode, state.depthWrite
    end,
    setDepthMode = function(mode, write)
      state.depthMode, state.depthWrite = mode, write
    end,
    isWireframe = function()
      return state.wireframe
    end,
    setWireframe = function(wireframe)
      state.wireframe = wireframe
    end,
    getMeshCullMode = function()
      return state.cullMode
    end,
    setMeshCullMode = function(mode)
      state.cullMode = mode
    end,
    getScissor = function()
      if not state.scissor then
        return nil
      end
      return state.scissor[1], state.scissor[2], state.scissor[3], state.scissor[4]
    end,
    setScissor = function(x, y, w, h)
      if x == nil then
        state.scissor = nil
      else
        state.scissor = { x, y, w, h }
      end
    end,
  }
end

return FakeGraphics
