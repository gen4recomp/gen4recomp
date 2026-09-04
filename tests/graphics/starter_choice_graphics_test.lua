-- Starter choice presentation smoke: the responsive candidate geometry
-- draws a framed, highlighted choice at compact, wide, and portrait sizes
-- through the real offscreen context, in both selection and confirmation
-- modes. Text rasterization stays outside these assertions; they pin that
-- the draw path executes and candidate regions never overlap or clip.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local CONTROLLER_MODULE = "libs.hgss.src.ui.StarterChoiceController"
local LAYOUT_MODULE = "libs.hgss.src.ui.StarterChoiceLayout"
local RENDERER_MODULE = "libs.hgss.src.ui.StarterChoiceRenderer"

local NAMES = { "Chikorita", "Cyndaquil", "Totodile" }

local function requireModule(name, role)
  local ok, module = pcall(require, name)
  Assert.isTrue(ok, role)
  return assert(module)
end

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function disjoint(a, b)
  return a.x + a.width <= b.x or b.x + b.width <= a.x or a.y + a.height <= b.y or b.y + b.height <= a.y
end

local function opaquePixels(image, width, height)
  local found = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local _, _, _, a = image:getPixel(x, y)
      if a > 0.5 then
        found = found + 1
      end
    end
  end
  return found
end

function T.starter_choice_draws_disjoint_candidates_in_both_modes(scope)
  local StarterChoiceController = requireModule(CONTROLLER_MODULE, "the starter controller owns the drawn cursor")
  local StarterChoiceLayout = requireModule(LAYOUT_MODULE, "the starter layout owns the drawn regions")
  local StarterChoiceRenderer =
    requireModule(RENDERER_MODULE, "the starter renderer paints candidates through offscreen graphics")

  local renderer = StarterChoiceRenderer.new()
  for _, case in ipairs({
    { width = 256, height = 192 },
    { width = 1280, height = 720 },
    { width = 390, height = 844 },
  }) do
    local layout = StarterChoiceLayout.resolve({ topology = topology(case.width, case.height), scale = 1 })
    Assert.equal(#layout.candidates, 3, "three candidates draw at every supported size")
    for left = 1, 3 do
      for right = left + 1, 3 do
        Assert.isTrue(disjoint(layout.candidates[left], layout.candidates[right]), "drawn candidates never overlap")
      end
      local rect = layout.candidates[left]
      Assert.isTrue(rect.x >= 0 and rect.y >= 0, "drawn candidates stay on screen")
      Assert.isTrue(rect.x + rect.width <= case.width, "drawn candidates stay within the viewport width")
      Assert.isTrue(rect.y + rect.height <= case.height, "drawn candidates stay within the viewport height")
    end

    local selecting = StarterChoiceController.new({ candidates = NAMES, initialCursor = 1 })
    local canvas = scope:own(love.graphics.newCanvas(case.width, case.height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw({ status = selecting:status(), layout = layout, names = NAMES })
    love.graphics.setCanvas()
    local selectingImage = scope:own(canvas:newImageData())
    Assert.isTrue(opaquePixels(selectingImage, case.width, case.height) > 0, "selection draws visible candidate frames")

    local confirming = StarterChoiceController.new({ candidates = NAMES })
    confirming:confirm()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw({ status = confirming:status(), layout = layout, names = NAMES })
    love.graphics.setCanvas()
    local confirmingImage = scope:own(canvas:newImageData())
    Assert.isTrue(
      opaquePixels(confirmingImage, case.width, case.height) > 0,
      "confirmation draws visible candidate and prompt frames"
    )
  end
end

return GraphicsSmoke.suite(T)
