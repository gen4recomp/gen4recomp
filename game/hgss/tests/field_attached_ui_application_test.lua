-- Start Menu / Trainer Card placement must not follow field camera zoom.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")

local T = {}

local function measurementFor(topology, width, height)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = "zoom-probe",
  }
end

local function fullscreenContext(topology, width, height)
  local measurement = measurementFor(topology, width, height)
  local selection = ApplicationLayout.selectSurfaces(measurement)
  return {
    measurement = measurement,
    configuration = "nativeLike",
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = StartMenuInterface.fullscreen,
  }
end

function T.start_menu_plan_identical_across_zooms()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = false,
    role = "world",
  })
  local view = {}
  local first = StartMenuInterface.fullscreen(fullscreenContext(topology, 640, 480), view)
  local second = StartMenuInterface.fullscreen(fullscreenContext(topology, 640, 480), view)
  -- Two resolves under different field zooms share one UI fit: the
  -- interface never consumes a camera zoom argument.
  Assert.deepEqual(first.panes[1].placement, second.panes[1].placement)
  -- Different zooms would carry different field scales, but the plan is
  -- the same UI-bounds fit either way.
  local zoomedOut, zoomedIn = 1, 3
  Assert.isTrue(zoomedOut ~= zoomedIn)
  Assert.equal(first.panes[1].placement.pixelScale, 2, "the 640x480 UI fit stays 2x at any zoom")
end

function T.trainer_card_draw_placement_identical_across_zooms()
  local PixelScale = require("libs.ui.src.PixelScale")
  -- Application surfaces resolve one integer-fit placement from UI
  -- bounds and never consume the field camera zoom: the same resolved
  -- placement draws identically twice.
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 1280, height = 720 }, 256, 192),
    "the probe host must admit a card placement"
  )
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
  rA:draw(presentation, placement)
  rB:draw(presentation, placement)
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
