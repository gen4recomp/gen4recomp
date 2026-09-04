-- Responsive single-window geometry for the three-candidate starter
-- screen: three disjoint candidate controls plus a two-button confirmation
-- bar that never covers a candidate. Pure rectangles, button-compatible by
-- construction; the controller test pins compatibility through the shared
-- button primitive. No input, no state, no love dependency.

local StarterChoiceLayout = {}

local CANDIDATE_COUNT = 3
local MARGIN = 8
local GAP = 8
local MAX_CONFIRM_BUTTON_WIDTH = 192

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@param rect ScreenTopology.Rectangle
---@return ScreenTopology.Rectangle copy
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

---@class StarterChoiceLayout.Resolved
---@field frame ScreenTopology.Rectangle viewport rectangle the geometry was resolved against
---@field candidates ScreenTopology.Rectangle[] three candidate rectangles in display order
---@field confirm ScreenTopology.Rectangle[] yes/no rectangles in answer order

---@class StarterChoiceLayout.Spec
---@field topology ScreenTopology
---@field scale number?

---@param spec StarterChoiceLayout.Spec
---@return StarterChoiceLayout.Resolved
function StarterChoiceLayout.resolve(spec)
  assert(type(spec) == "table", "starter layout requires a specification")
  local topology = assert(spec.topology, "starter layout requires the display topology")
  assert(type(topology.surfaces) == "table" and #topology.surfaces > 0, "starter layout requires a display surface")
  local surface = assert(topology.surfaces[1], "starter layout requires the main display surface")
  local frame = surface.safeRect or surface.rect
  assert(type(frame) == "table", "starter layout requires the display frame")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(frame[field]), "starter layout frame must be finite")
  end
  assert(frame.width > 0 and frame.height > 0, "starter layout frame must be positive")
  local scale = spec.scale
  if scale == nil then
    scale = 1
  end
  assert(finite(scale) and scale > 0, "starter layout scale must be positive")

  local margin = MARGIN * scale
  local gap = GAP * scale
  assert(frame.width > margin * 4 + gap * 3, "starter layout viewport is too narrow")
  assert(frame.height > margin * 4, "starter layout viewport is too short")

  -- The confirmation bar takes a bounded bottom strip; the candidates own
  -- everything above it with a margin gap so the two regions never overlap.
  local confirmHeight = frame.height * 0.2
  if confirmHeight < 28 then
    confirmHeight = 28
  elseif confirmHeight > 64 then
    confirmHeight = 64
  end
  local candidatesHeight = frame.height - margin * 3 - confirmHeight
  assert(candidatesHeight > 0, "starter layout viewport leaves no candidate room")
  local candidateWidth = (frame.width - margin * 2 - gap * 2) / CANDIDATE_COUNT

  local candidates = {}
  for index = 1, CANDIDATE_COUNT do
    candidates[index] = {
      x = frame.x + margin + (index - 1) * (candidateWidth + gap),
      y = frame.y + margin,
      width = candidateWidth,
      height = candidatesHeight,
    }
  end

  local buttonHeight = confirmHeight - margin
  local buttonWidth = (frame.width - margin * 2 - gap) / 2
  if buttonWidth > MAX_CONFIRM_BUTTON_WIDTH * scale then
    buttonWidth = MAX_CONFIRM_BUTTON_WIDTH * scale
  end
  local confirmY = frame.y + frame.height - margin - buttonHeight
  local confirmX = frame.x + (frame.width - (buttonWidth * 2 + gap)) / 2
  local confirm = {
    { x = confirmX, y = confirmY, width = buttonWidth, height = buttonHeight },
    { x = confirmX + buttonWidth + gap, y = confirmY, width = buttonWidth, height = buttonHeight },
  }

  return { frame = copyRect(frame), candidates = candidates, confirm = confirm }
end

---@param rect ScreenTopology.Rectangle
---@param x number
---@param y number
---@return boolean
local function contains(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

---@class StarterChoiceLayout.Hit
---@field kind "candidate"|"confirm"
---@field index integer
---@param layout StarterChoiceLayout.Resolved
---@param x number
---@param y number
---@return StarterChoiceLayout.Hit|nil
function StarterChoiceLayout.hitTest(layout, x, y)
  assert(type(layout) == "table", "starter hit testing requires the resolved layout")
  assert(finite(x) and finite(y), "starter hit point must be finite")
  assert(type(layout.candidates) == "table", "starter layout carries its candidate regions")
  assert(type(layout.confirm) == "table", "starter layout carries its confirmation regions")
  for index, rect in ipairs(layout.candidates) do
    if contains(rect, x, y) then
      return { kind = "candidate", index = index - 1 }
    end
  end
  for index, rect in ipairs(layout.confirm) do
    if contains(rect, x, y) then
      return { kind = "confirm", index = index - 1 }
    end
  end
  return nil
end

return StarterChoiceLayout
