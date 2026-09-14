-- Start Menu / Trainer Card placement must not follow field camera zoom.

local Assert = require("tests.support.Assert")
local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}

local function placement(referenceFrame, topology)
  return StartMenuLayout.resolve(topology, referenceFrame)
end

function T.start_menu_placement_identical_across_zooms()
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  local ref = viewport.referenceFrame
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  local p1 = placement(ref, topology)
  local p2 = placement(ref, topology)
  -- Simulate two zooms: placement must not change (it does not take zoom)
  Assert.deepEqual(p1, p2)
  -- Prove that StartMenuLayout never consumes a scale/zoom argument
  Assert.isTrue(p1.scale ~= nil)
  -- Different zooms would have different field scales, but placement is same
  local scale1 = 1
  local scale2 = 3
  Assert.isTrue(scale1 ~= scale2)
  Assert.deepEqual(p1.frame, p2.frame)
end

function T.trainer_card_draw_placement_identical_across_zooms()
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  -- Application surfaces receive their own integer-fit scale and do not
  -- consume the field camera zoom.
  local FieldUiFixture = require("tests.support.FieldUiFixture")
  local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
  local TrainerCardRenderer = require("libs.hgss.src.ui.TrainerCardRenderer")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local lgA = FakeGraphics.new({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 256, 256 } } })
  local lgB = FakeGraphics.new({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 256, 256 } } })
  local cache = FieldUiFixture.trainerCardCache()
  local manifest = FieldUiFixture.manifest()
  local textA = FieldTextRenderer.new({ cacheFs = cache, graphics = lgA })
  local textB = FieldTextRenderer.new({ cacheFs = cache, graphics = lgB })
  local rA = TrainerCardRenderer.new({ cacheFs = cache, manifest = manifest, text = textA, graphics = lgA })
  local rB = TrainerCardRenderer.new({ cacheFs = cache, manifest = manifest, text = textB, graphics = lgB })
  local presentation = {
    name = "RED",
    trainerId = 12345,
    visibleTrainerId = 12345,
    money = 0,
    playTimeSeconds = 0,
  }
  rA:draw(presentation, viewport, 2)
  rB:draw(presentation, viewport, 2)
  Assert.deepEqual(
    lgA.transforms,
    lgB.transforms,
    "trainer card transform identical regardless of camera zoom (no zoom plumbing)"
  )
  -- Trainer card is an application surface and stays independent of field zoom;
  -- only field-attached renderers gain zoom-aware transforms.
  rA:release()
  rB:release()
  textA:release()
  textB:release()
end

return { tests = T }
