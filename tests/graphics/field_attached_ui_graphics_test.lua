-- Graphics smoke for field-attached dialogue/signpost: proves the single
-- translate+scale transform matches the bottom-centered layout.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldSignpostRenderer = require("libs.hgss.src.ui.FieldSignpostRenderer")
local FieldSignpostFixture = require("tests.support.FieldSignpostFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}

local function fakeGraphicsFromSupport()
  return require("tests.support.FakeGraphics").new({
    imageSizes = {
      { 16, 16 },
      { 16, 16 },
      { 96, 32 },
      { 144, 16 },
      { 144, 8 },
      { 192, 32 },
    },
  })
end

local CURSOR_PLACEMENT = FieldUiFixture.manifest().dialogueFrames.continueCursor.placement

function T.dialogue_uses_bottom_centered_translate_and_single_scale(_)
  local lg = fakeGraphicsFromSupport()
  local text = FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
  local manifest = FieldUiFixture.manifest()
  local renderer = FieldDialogueRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    text = text,
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local viewport = FieldViewport.new(768, 576, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local ref = viewport.referenceFrame
  local expectedScale = fieldScale
  local expectedX = ref.x + (ref.width - 256 * expectedScale) / 2
  local expectedY = ref.y + ref.height - 48 * expectedScale
  renderer:draw(
    controller,
    DialoguePresentationLayout.compute(ref, {
      maxScale = fieldScale,
      cursorPlacement = CURSOR_PLACEMENT,
    })
  )
  Assert.equal(#lg.transforms, 2, "exactly one translate and one scale")
  Assert.equal(lg.transforms[1][1], "translate")
  Assert.near(lg.transforms[1][2], expectedX, 1e-6)
  Assert.near(lg.transforms[1][3], expectedY, 1e-6)
  Assert.equal(lg.transforms[2][1], "scale")
  Assert.near(lg.transforms[2][2], expectedScale, 1e-6)
  Assert.near(lg.transforms[2][3], expectedScale, 1e-6)
  renderer:release()
  text:release()
end

function T.dialogue_shrinks_from_bottom_center_at_reduced_zoom(_)
  local lg = fakeGraphicsFromSupport()
  local text = FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
  local manifest = FieldUiFixture.manifest()
  local renderer = FieldDialogueRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    text = text,
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local viewport = FieldViewport.new(768, 576, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(0.5)
  local ref = viewport.referenceFrame
  local expectedX = ref.x + (ref.width - 256 * fieldScale) / 2
  local expectedY = ref.y + ref.height - 48 * fieldScale
  renderer:draw(
    controller,
    DialoguePresentationLayout.compute(ref, {
      maxScale = fieldScale,
      cursorPlacement = CURSOR_PLACEMENT,
    })
  )
  Assert.equal(#lg.transforms, 2, "exactly one translate and one scale")
  Assert.near(lg.transforms[1][2], expectedX, 1e-6, "bottom-centered X at 0.5x")
  Assert.near(lg.transforms[1][3], expectedY, 1e-6, "bottom-anchored Y at 0.5x")
  Assert.near(lg.transforms[2][2], fieldScale, 1e-6, "scale follows zoom at 0.5x")
  renderer:release()
  text:release()
end

function T.signpost_uses_same_bottom_centered_transform(_)
  local lg = fakeGraphicsFromSupport()
  local text = FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
  local manifest = FieldUiFixture.manifest()
  local renderer = FieldSignpostRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    text = text,
    graphics = lg,
    windowStyles = FieldSignpostFixture.styles(),
  })
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 })
  local viewport = FieldViewport.new(768, 576, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local ref = viewport.referenceFrame
  local expectedX = ref.x + (ref.width - 256 * fieldScale) / 2
  local expectedY = ref.y + ref.height - 192 * fieldScale
  renderer:draw(controller, viewport, 1, fieldScale)
  Assert.equal(#lg.transforms, 2)
  Assert.near(lg.transforms[1][2], expectedX, 1e-6)
  Assert.near(lg.transforms[1][3], expectedY, 1e-6)
  Assert.near(lg.transforms[2][2], fieldScale, 1e-6)
  renderer:release()
  text:release()
end

function T.signpost_shrinks_from_bottom_center_at_reduced_zoom(_)
  local lg = fakeGraphicsFromSupport()
  local text = FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
  local manifest = FieldUiFixture.manifest()
  local renderer = FieldSignpostRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    text = text,
    graphics = lg,
    windowStyles = FieldSignpostFixture.styles(),
  })
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 })
  local viewport = FieldViewport.new(768, 576, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(0.5)
  local ref = viewport.referenceFrame
  local expectedX = ref.x + (ref.width - 256 * fieldScale) / 2
  local expectedY = ref.y + ref.height - 192 * fieldScale
  renderer:draw(controller, viewport, 1, fieldScale)
  Assert.near(lg.transforms[1][2], expectedX, 1e-6)
  Assert.near(lg.transforms[1][3], expectedY, 1e-6)
  Assert.near(lg.transforms[2][2], fieldScale, 1e-6)
  renderer:release()
  text:release()
end

return GraphicsSmoke.suite(T)
