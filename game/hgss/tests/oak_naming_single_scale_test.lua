-- Oak hosts the Naming Screen at canonical logical size inside its own
-- already-resolved pixel surface: one integer physical scale, no nested fit,
-- and no crash when the dialogue-reserved scene region is small.

local Assert = require("tests.support.Assert")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")

local T = { tests = {} }

local function widget(width, height, anchor, sourceBounds)
  return {
    width = width,
    height = height,
    anchor = anchor,
    sourceBounds = sourceBounds,
    frames = {
      { width = width, height = height, duration = 1, anchor = anchor },
    },
  }
end

local function layoutManifest()
  return {
    sourceReference = { width = 256, height = 192 },
    background = { width = 256, height = 192, sampling = "linear" },
    genderSelector = {
      defaultTone = { r = 100, g = 101, b = 102 },
      buttons = {
        male = { bounds = { x = 18, y = 25, width = 93, height = 148 } },
        female = { bounds = { x = 144, y = 25, width = 95, height = 148 } },
      },
    },
    widgets = {
      oak = widget(80, 100, { x = 20, y = 100 }, { x = 20, y = 30, width = 80, height = 100 }),
      gender_male = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
      gender_female = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
      ball_open = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
      marill = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
    },
  }
end

local function nameEditView()
  return {
    phase = "name_edit",
    visual = "background",
    primaryWidget = nil,
    revealWidget = nil,
    oakBgScrollX = 0,
    genderFocus = 0,
    genderCompositionProgress = 1,
    nameCompositionProgress = 0,
    focusBlinkDelta = 0,
    messageKey = nil,
  }
end

local function assertIntegerRect(rect, label)
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    Assert.equal(rect[field], math.floor(rect[field]), label .. "." .. field .. " must be an integer")
  end
end

function T.tests.naming_layout_is_canonical_logical_geometry_without_a_child_scale()
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 512, height = 384 })
  Assert.deepEqual(layout.surface, { x = 128, y = 96, width = 256, height = 192 })
  Assert.isNil(layout.placement, "the naming child must not own a placement")
  Assert.isNil(layout.scale, "the naming child must not own a scale")
  assertIntegerRect(layout.surface, "surface")
  assertIntegerRect(layout.nameSlots, "nameSlots")
  assertIntegerRect(layout.subject, "subject")
  for row = 1, 6 do
    for column = 1, 13 do
      assertIntegerRect(layout.cells[row][column], "cells[" .. row .. "][" .. column .. "]")
    end
  end
  for id, region in pairs(layout.controls) do
    assertIntegerRect(region, "controls." .. id)
  end
  Assert.throws(function()
    NamingScreenLayout.compute({ x = 0, y = 0, width = 200, height = 150 })
  end, "a viewport smaller than the canonical surface is a host programming error")
end

function T.tests.oak_name_edit_renders_from_the_full_viewport_at_supported_hosts()
  for _, host in ipairs({ { 256, 192 }, { 512, 384 }, { 480, 360 } }) do
    local width, height = host[1], host[2]
    local layout = OakIntroLayout.compute(width, height, nameEditView(), {}, layoutManifest(), 1)
    local naming = assert(layout.namingScreen, "name editing must publish the Naming Screen")
    Assert.deepEqual(
      { x = naming.surface.x, y = naming.surface.y, width = naming.surface.width, height = naming.surface.height },
      {
        x = math.floor((width - 256) / 2),
        y = math.floor((height - 192) / 2),
        width = 256,
        height = 192,
      }
    )
    Assert.isNil(naming.placement, "the Oak-hosted Naming Screen must not carry a child placement")
  end
end

return T
