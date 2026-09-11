-- Field presentation tests: HGSS scene policy is translated into a plain
-- frame and the queue is built once before the NDS renderer is called.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function lightingRecord(startHalfSeconds, diffuseRgb555)
  return {
    startHalfSeconds = startHalfSeconds,
    lights = {
      { enabled = true, colorRgb555 = diffuseRgb555, vectorFx12 = { 0, 0, -4096 } },
      { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
      { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
      { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
    },
    diffuseRgb555 = diffuseRgb555,
    ambientRgb555 = 0,
    specularRgb555 = 0,
    emissionRgb555 = 0,
  }
end

-- Builds the fixed camera/scene inputs shared by the identity/frame tests
-- below: a distinguishable world projection, a distinguishable billboard
-- projection, and a two-record lighting table so time-of-day selection is
-- independently observable from the draw-record identity assertions.
local function fixtureDraw(gxRenderer)
  local fieldRenderer = FieldRenderer.new({ gxRenderer = gxRenderer })
  local view = Matrix4.identity()
  local worldProjection = Matrix4.identity()
  worldProjection[1] = 2
  local billboardProjection = Matrix4.identity()
  billboardProjection[1] = 3
  local camera = {
    zoom = 1,
    far = 400,
    view = function()
      return view
    end,
    projection = function()
      return worldProjection
    end,
    billboardProjection = function()
      return billboardProjection
    end,
  }
  local ordinaryItem = {
    alphaClass = "opaque",
    center = { 0, 0, 0 },
    transform = view,
  }
  local fieldEffectItem = {
    alphaClass = "opaque",
    center = { 0, 0, 0 },
    transform = view,
    fieldEffect = "tall_grass",
  }
  local spriteItem = {
    alphaClass = "opaque",
    center = { 0, 0, 0 },
    transform = view,
  }
  local morning = lightingRecord(0, 1)
  local evening = lightingRecord(10, 2)
  local sceneRuntime = {
    lighting = { records = { morning, evening } },
    fieldTimeSeconds = 20,
    edgeColors = { [0] = 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = {} },
  }
  fieldRenderer:draw(
    sceneRuntime,
    camera,
    { { ordinaryItem, fieldEffectItem } },
    { spriteItem },
    { worldViewport = { x = 0, y = 0, width = 1, height = 1 } },
    0
  )
  return {
    fieldRenderer = fieldRenderer,
    worldProjection = worldProjection,
    billboardProjection = billboardProjection,
    ordinaryItem = ordinaryItem,
    fieldEffectItem = fieldEffectItem,
    spriteItem = spriteItem,
    evening = evening,
    sceneRuntime = sceneRuntime,
    camera = camera,
  }
end

function T.forwards_original_queue_and_sprite_records_to_the_gx_backend()
  local captured
  local fakeRenderer = {
    stats = {},
    draw = function(_, frame)
      captured = frame
    end,
    release = function() end,
  }
  local fixture = fixtureDraw(fakeRenderer)

  Assert.equal(captured.lighting, fixture.evening, "HGSS time-of-day selection happens above the NDS renderer")
  Assert.isTrue(captured.queue.opaque[1] == fixture.ordinaryItem, "the ordinary item reaches GX by identity")
  Assert.isTrue(captured.queue.opaque[2] == fixture.fieldEffectItem, "the field-effect item reaches GX by identity")
  Assert.isTrue(captured.spriteItems[1] == fixture.spriteItem, "the sprite record reaches GX by identity")
  Assert.equal(captured.worldProjection, fixture.worldProjection, "the world projection is a frame-level field")
  Assert.equal(
    captured.billboardProjection,
    fixture.billboardProjection,
    "the billboard projection is a frame-level field"
  )
  Assert.isNil(captured.sceneRuntime, "the frame does not leak the HGSS scene runtime")
  Assert.isNil(captured.camera, "the frame does not leak the camera object")
end

function T.repeated_draws_reuse_the_same_queue_pass_array_identities()
  local frames = {}
  local fakeRenderer = {
    stats = {},
    draw = function(_, frame)
      frames[#frames + 1] = frame
    end,
    release = function() end,
  }
  local fixture = fixtureDraw(fakeRenderer)
  local firstQueue = frames[1].queue
  local firstOpaque = firstQueue.opaque

  fixture.fieldRenderer:draw(
    fixture.sceneRuntime,
    fixture.camera,
    { { fixture.ordinaryItem, fixture.fieldEffectItem } },
    { fixture.spriteItem },
    { worldViewport = { x = 0, y = 0, width = 1, height = 1 } },
    0
  )

  Assert.equal(frames[2].queue, firstQueue, "the renderer-owned queue scratch is reused across draws")
  Assert.equal(frames[2].queue.opaque, firstOpaque, "the opaque pass array identity is reused across draws")
end

function T.blended_entries_stay_the_render_queues_own_wrapper_around_the_original_item()
  local captured
  local fakeRenderer = {
    stats = {},
    draw = function(_, frame)
      captured = frame
    end,
    release = function() end,
  }
  local fieldRenderer = FieldRenderer.new({ gxRenderer = fakeRenderer })
  local view = Matrix4.identity()
  local camera = {
    zoom = 1,
    far = 400,
    view = function()
      return view
    end,
    projection = function()
      return view
    end,
    billboardProjection = function()
      return view
    end,
  }
  local translucentItem = {
    alphaClass = "translucent",
    center = { 0, 0, -1 },
    transform = view,
  }
  local sceneRuntime = {
    edgeColors = { [0] = 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = {} },
  }
  fieldRenderer:draw(
    sceneRuntime,
    camera,
    { { translucentItem } },
    nil,
    { worldViewport = { x = 0, y = 0, width = 1, height = 1 } },
    0
  )

  Assert.isTrue(
    captured.queue.blended[1].item == translucentItem,
    "the blended entry's item is the original translucent record, not a further copy"
  )
  Assert.equal(
    captured.queue.blended[1],
    fieldRenderer._queueScratch.blended[1],
    "FieldRenderer allocates no second wrapper around the RenderQueue-owned blended entry"
  )
end

-- The wrapper's own clear color is a frame-level input to GX, so two
-- FieldRenderer instances sharing one GX backend can each request their own
-- clear color without mutating shared backend state.
function T.frame_clear_color_is_wrapper_local_when_sharing_one_backend()
  local frames = {}
  local sharedBackend = {
    stats = {},
    draw = function(_, frame)
      frames[#frames + 1] = frame
    end,
    release = function() end,
  }
  local firstColor = { 1, 0, 0, 1 }
  local secondColor = { 0, 1, 0, 1 }
  local first = FieldRenderer.new({ gxRenderer = sharedBackend, clearColor = firstColor })
  local second = FieldRenderer.new({ gxRenderer = sharedBackend, clearColor = secondColor })
  local view = Matrix4.identity()
  local camera = {
    zoom = 1,
    far = 400,
    view = function()
      return view
    end,
    projection = function()
      return view
    end,
    billboardProjection = function()
      return view
    end,
  }
  local sceneRuntime = {
    edgeColors = { [0] = 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = {} },
  }
  local viewport = { worldViewport = { x = 0, y = 0, width = 1, height = 1 } }

  first:draw(sceneRuntime, camera, nil, nil, viewport, 0)
  second:draw(sceneRuntime, camera, nil, nil, viewport, 0)

  Assert.equal(frames[1].clearColor, firstColor, "the first wrapper submits its own clear color on its frame")
  Assert.equal(frames[2].clearColor, secondColor, "the second wrapper submits its own clear color on its frame")

  second:release()
  first:draw(sceneRuntime, camera, nil, nil, viewport, 0)
  Assert.equal(
    frames[3].clearColor,
    firstColor,
    "the shared backend remains usable and still receives the first wrapper's clear color"
  )
end

-- Releasing a wrapper that borrowed its GX backend must never release that
-- backend; only the wrapper that constructed the backend owns it.
function T.borrowed_wrapper_release_never_releases_the_shared_backend()
  local releaseCalls = 0
  local sharedBackend = {
    stats = {},
    draw = function() end,
    release = function()
      releaseCalls = releaseCalls + 1
    end,
  }
  local borrower = FieldRenderer.new({ gxRenderer = sharedBackend })
  borrower:release()
  Assert.equal(releaseCalls, 0, "a borrowed backend is never released by the borrowing wrapper")
end

-- A wrapper that constructs its own backend (no gxRenderer supplied) owns it
-- and releases it exactly once.
---@class FieldRendererCountedShader : GxRenderer.Shader
---@field releaseCount integer
function T.owning_wrapper_releases_its_constructed_backend_exactly_once()
  local owner = FieldRenderer.new({
    graphics = {
      newShader = function(source)
        return {
          source = source,
          releaseCount = 0,
          release = function(self)
            self.releaseCount = self.releaseCount + 1
          end,
        }
      end,
    },
    readSource = function()
      return "source"
    end,
  })
  local backend = owner.gxRenderer
  local shader, edgeShader, worldShader = backend.shader, backend.edgeShader, backend.worldShader
  ---@cast shader FieldRendererCountedShader
  ---@cast edgeShader FieldRendererCountedShader
  ---@cast worldShader FieldRendererCountedShader
  owner:release()
  Assert.equal(shader.releaseCount, 1, "the owning wrapper releases the shader it constructed exactly once")
  Assert.equal(edgeShader.releaseCount, 1, "the owning wrapper releases the edge shader it constructed")
  Assert.equal(worldShader.releaseCount, 1, "the owning wrapper releases the world shader it constructed")
end

function T.rejects_a_missing_or_non_positive_camera_far_plane()
  local draws = 0
  local fieldRenderer = FieldRenderer.new({
    gxRenderer = {
      stats = {},
      draw = function()
        draws = draws + 1
      end,
      release = function() end,
    },
  })
  local identity = Matrix4.identity()
  local camera = {
    zoom = 1,
    far = nil,
    view = function()
      return identity
    end,
    projection = function()
      return identity
    end,
    billboardProjection = function()
      return identity
    end,
  }
  local sceneRuntime = {
    edgeColors = { [0] = 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = {} },
  }
  local viewport = { worldViewport = { x = 0, y = 0, width = 1, height = 1 } }

  Assert.throws(function()
    fieldRenderer:draw(sceneRuntime, camera, nil, nil, viewport, 0)
  end)
  camera.far = 0
  Assert.throws(function()
    fieldRenderer:draw(sceneRuntime, camera, nil, nil, viewport, 0)
  end)
  camera.far = -10
  Assert.throws(function()
    fieldRenderer:draw(sceneRuntime, camera, nil, nil, viewport, 0)
  end)
  Assert.equal(draws, 0, "invalid camera configuration never reaches the GX renderer")
end

return { tests = T }
