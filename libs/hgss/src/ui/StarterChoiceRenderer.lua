-- Stateless starter-choice painter. It draws the three candidate frames
-- with one highlighted selection, plus a yes/no confirmation panel while
-- the controller is confirming, through the global graphics namespace and
-- plain layered rectangles in the current button visual language.
-- Hit-testing and cursor ownership stay in the layout and controller; this
-- module never mutates them and loads no images during draw. Optional
-- per-candidate portraits ({ image, quad } entries) and an optional text
-- provider ({ drawText }) enrich the plates; both stay optional so
-- offscreen smoke can pin geometry alone. Pure presentation module: no
-- love require, the namespace resolves at construction like the other
-- field UI renderers.

local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

---@class StarterChoiceRenderer
---@field _graphics love.Graphics|love.graphics the graphics namespace draws resolve through
local StarterChoiceRenderer = {}
StarterChoiceRenderer.__index = StarterChoiceRenderer

local CORNER_RADIUS = 4
local CONTENT_PAD_X = 8
local CONTENT_PAD_Y = 6

local PALETTE = {
  dim = { 0, 0, 0, 0.78 },
  border = { 0.88, 0.88, 0.94, 1 },
  rim = { 0.1, 0.12, 0.18, 1 },
  face = { 0.16, 0.18, 0.24, 1 },
  faceSelected = { 0.26, 0.34, 0.52, 1 },
  faceTop = { 1, 1, 1, 0.08 },
  placeholder = { 0.32, 0.36, 0.46, 1 },
  plate = { 0.06, 0.07, 0.11, 1 },
}

---@class StarterChoiceRenderer.Options
---@field graphics unknown? injectable graphics namespace for tests

---@param opts StarterChoiceRenderer.Options?
---@return StarterChoiceRenderer
function StarterChoiceRenderer.new(opts)
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(
    graphics and type(graphics.rectangle) == "function" and type(graphics.setColor) == "function",
    "StarterChoiceRenderer requires the graphics namespace"
  )
  ---@cast graphics love.Graphics|love.graphics
  return setmetatable({ _graphics = graphics }, StarterChoiceRenderer)
end

---@param lg love.Graphics|love.graphics
---@param rect ScreenTopology.Rectangle
---@param faceColor number[]
local function drawFrame(lg, rect, faceColor)
  lg.setColor(PALETTE.border[1], PALETTE.border[2], PALETTE.border[3], PALETTE.border[4])
  lg.rectangle("fill", rect.x, rect.y, rect.width, rect.height, CORNER_RADIUS, CORNER_RADIUS)
  local rim = 2
  lg.setColor(PALETTE.rim[1], PALETTE.rim[2], PALETTE.rim[3], PALETTE.rim[4])
  lg.rectangle(
    "fill",
    rect.x + rim,
    rect.y + rim,
    rect.width - rim * 2,
    rect.height - rim * 2,
    CORNER_RADIUS,
    CORNER_RADIUS
  )
  local faceInset = rim * 2
  lg.setColor(faceColor[1], faceColor[2], faceColor[3], faceColor[4])
  lg.rectangle(
    "fill",
    rect.x + faceInset,
    rect.y + faceInset,
    rect.width - faceInset * 2,
    rect.height - faceInset * 2,
    CORNER_RADIUS,
    CORNER_RADIUS
  )
end

---@class StarterChoiceRenderer.View
---@field status StarterChoiceController.Status controller status ({ state, mode, candidateIndex, confirmIndex? })
---@field layout StarterChoiceLayout.Resolved resolved layout ({ frame, candidates[3], confirm[2] })
---@field names string[] three candidate display names
---@field portraits { image: unknown, quad: unknown? }[]? per-candidate portrait entries, holes allowed
---@field text table<string, unknown>? text provider ({ drawText })

---@param view StarterChoiceRenderer.View
function StarterChoiceRenderer:draw(view)
  assert(type(view) == "table", "starter presentation requires a view")
  local status = assert(view.status, "starter presentation requires the controller status")
  local layout = assert(view.layout, "starter presentation requires the resolved layout")
  local names = assert(view.names, "starter presentation requires the candidate names")
  assert(type(names) == "table" and #names == 3, "starter presentation requires three candidate names")
  assert(type(layout.candidates) == "table" and #layout.candidates == 3, "starter layout carries three candidates")
  assert(type(layout.confirm) == "table" and #layout.confirm == 2, "starter layout carries the confirmation pair")
  assert(
    status.candidateIndex ~= nil and status.candidateIndex >= 0 and status.candidateIndex < 3,
    "starter status names the highlighted candidate"
  )
  local lg = assert(self._graphics, "starter renderer has no graphics namespace")
  local portraits = view.portraits
  local text = view.text
  if text ~= nil then
    assert(type(text.drawText) == "function", "starter text provider draws lines")
  end
  FieldDrawState.protectedDraw(lg, function()
    local frame = layout.frame or layout.candidates[1]
    if layout.frame ~= nil then
      lg.setColor(PALETTE.dim[1], PALETTE.dim[2], PALETTE.dim[3], PALETTE.dim[4])
      lg.rectangle("fill", frame.x, frame.y, frame.width, frame.height)
    end
    for index, rect in ipairs(layout.candidates) do
      local selected = (index - 1) == status.candidateIndex
      drawFrame(lg, rect, selected and PALETTE.faceSelected or PALETTE.face)
      local content = {
        x = rect.x + CONTENT_PAD_X,
        y = rect.y + CONTENT_PAD_Y,
        width = rect.width - CONTENT_PAD_X * 2,
        height = rect.height - CONTENT_PAD_Y * 2,
      }
      local portrait = portraits ~= nil and portraits[index] or nil
      if portrait ~= nil then
        assert(portrait.image ~= nil, "starter portrait entry carries its image")
        if portrait.quad ~= nil then
          local _, _, quadWidth, quadHeight = portrait.quad:getViewport()
          local scale = math.min(content.width / quadWidth, content.height / quadHeight)
          local drawWidth, drawHeight = quadWidth * scale, quadHeight * scale
          lg.setColor(1, 1, 1, 1)
          lg.draw(
            portrait.image,
            portrait.quad,
            content.x + (content.width - drawWidth) / 2,
            content.y + (content.height - drawHeight) / 2,
            0,
            scale,
            scale
          )
        else
          lg.setColor(1, 1, 1, 1)
          lg.draw(portrait.image, content.x, content.y)
        end
      else
        lg.setColor(PALETTE.placeholder[1], PALETTE.placeholder[2], PALETTE.placeholder[3], PALETTE.placeholder[4])
        lg.rectangle("fill", content.x, content.y, content.width, content.height, CORNER_RADIUS, CORNER_RADIUS)
      end
      local plateHeight = 20
      lg.setColor(PALETTE.plate[1], PALETTE.plate[2], PALETTE.plate[3], PALETTE.plate[4])
      lg.rectangle(
        "fill",
        rect.x + CONTENT_PAD_X,
        rect.y + rect.height - CONTENT_PAD_Y - plateHeight,
        rect.width - CONTENT_PAD_X * 2,
        plateHeight,
        CORNER_RADIUS,
        CORNER_RADIUS
      )
      if text ~= nil then
        lg.setColor(1, 1, 1, 1)
        text:drawText(names[index], rect.x + CONTENT_PAD_X + 2, rect.y + rect.height - CONTENT_PAD_Y - plateHeight + 3)
      end
      if selected then
        lg.setColor(PALETTE.faceTop[1], PALETTE.faceTop[2], PALETTE.faceTop[3], PALETTE.faceTop[4])
        lg.rectangle("fill", rect.x + 4, rect.y + 4, rect.width - 8, (rect.height - 8) * 0.4)
      end
    end
    if status.mode == "confirming" then
      local labels = { "Yes", "No" }
      for index, rect in ipairs(layout.confirm) do
        local selected = status.confirmIndex ~= nil and (index - 1) == status.confirmIndex or index == 1
        drawFrame(lg, rect, selected and PALETTE.faceSelected or PALETTE.face)
        if text ~= nil then
          lg.setColor(1, 1, 1, 1)
          text:drawText(labels[index], rect.x + CONTENT_PAD_X, rect.y + CONTENT_PAD_Y)
        end
      end
    end
    lg.setColor(1, 1, 1, 1)
  end)
end

return StarterChoiceRenderer
