-- Oak hosts the Naming Screen at canonical logical size inside its own
-- already-resolved pixel surface: one integer physical scale, no nested fit,
-- and no crash when the dialogue-reserved scene region is small.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")

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

local function fakeNameEditController()
  local controller = {
    phase = "name_edit",
    started = 0,
    disposed = 0,
  }
  function controller:start()
    self.started = self.started + 1
  end
  function controller:tick() end
  function controller:view()
    return {
      phase = self.phase,
      genderCompositionProgress = 1,
      name = "A",
      nameInputEnabled = self.phase == "name_edit",
      genderFocus = 0,
      message = "generated.message",
      visual = "background",
      finalFadeAlpha = 0,
      namingScreen = {
        page = "upper",
        text = "A",
        cursor = { row = 1, column = 1 },
        grid = { {}, {}, {}, {}, {}, {} },
        subject = { kind = "player", gender = 0 },
      },
      confirmationChoice = nil,
    }
  end
  function controller:dispose()
    self.disposed = self.disposed + 1
  end
  return controller
end

local function nameEditState(width, height)
  local input = { calls = {} }
  function input:setTextInput(enabled)
    self.calls[#self.calls + 1] = enabled
  end
  local renderer = { draws = 0, disposed = 0 }
  function renderer:draw()
    self.draws = self.draws + 1
  end
  function renderer:dispose()
    self.disposed = self.disposed + 1
  end
  local state = OakIntroState.new({
    controller = fakeNameEditController(),
    manifest = layoutManifest(),
    textRenderer = {},
    choiceText = {},
    renderer = renderer,
    textInputHost = input,
    glyphs = {},
    width = width,
    height = height,
  })
  return state
end

function T.tests.oak_name_edit_hosts_canonical_naming_beside_the_parent_plan()
  for _, host in ipairs({ { 256, 192 }, { 512, 384 }, { 480, 360 } }) do
    local width, height = host[1], host[2]
    local layout = OakIntroLayout.compute(width, height, nameEditView(), {}, layoutManifest(), 1)
    Assert.isNil(layout.namingScreen, "scene composition no longer places the naming child")
    local canonical = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
    Assert.deepEqual({
      x = canonical.surface.x,
      y = canonical.surface.y,
      width = canonical.surface.width,
      height = canonical.surface.height,
    }, { x = 0, y = 0, width = 256, height = 192 }, "the child stays canonical instead of parent-centered")
    Assert.isNil(canonical.placement, "the Oak-hosted Naming Screen must not carry a child placement")
    local state = nameEditState(width, height)
    local view = state:view()
    local plan = assert(view.namingPresentation, "name editing publishes its parent-owned naming plan")
    local pane = assert(plan.panes[1], "the naming plan carries its content pane")
    Assert.equal(pane.placement.logicalWidth, 256)
    Assert.equal(pane.placement.logicalHeight, 192)
    local naming = assert(view.layout.namingScreen, "name editing must publish the Naming Screen")
    Assert.deepEqual(
      { x = naming.surface.x, y = naming.surface.y, width = naming.surface.width, height = naming.surface.height },
      { x = 0, y = 0, width = 256, height = 192 }
    )
    state:dispose()
  end
end

function T.tests.name_edit_publishes_a_parent_owned_canonical_naming_plan()
  local state = nameEditState(640, 480)
  local view = state:view()
  Assert.equal(view.phase, "name_edit")
  local plan = assert(view.namingPresentation, "Oak must own a naming presentation plan during name_edit")
  Assert.equal(#plan.panes, 1, "naming resolves to one logical pane")
  local pane = assert(plan.panes[1], "the naming plan carries its content pane")
  local placement = assert(pane.placement, "the naming pane carries its host placement")
  Assert.equal(placement.logicalWidth, 256, "the naming pane is canonically 256 logical wide")
  Assert.equal(placement.logicalHeight, 192, "the naming pane is canonically 192 logical tall")
  local naming = assert(view.layout.namingScreen, "name editing must publish the Naming Screen")
  Assert.deepEqual(
    { x = naming.surface.x, y = naming.surface.y, width = naming.surface.width, height = naming.surface.height },
    { x = 0, y = 0, width = 256, height = 192 },
    "the child stays canonical instead of parent-centered"
  )
  Assert.isNil(naming.placement, "the naming child must not own a placement")
  Assert.isNil(naming.scale, "the naming child must not own a scale")
  state:dispose()
end

function T.tests.name_edit_draws_without_application_frame_artwork()
  local state = nameEditState(1280, 720)
  local view = state:view()
  Assert.equal(view.phase, "name_edit")
  local plan = assert(view.namingPresentation, "Oak must own a naming presentation plan during name_edit")
  Assert.deepEqual(plan.frames, {}, "wide naming publishes no outer application frame")
  local fake = FakeGraphics.new({})
  local loaded = {}
  local borrowed = {}
  local renderer = NamingScreenRenderer.new({
    graphics = fake,
    text = {
      drawText = function(_, _, _, _) end,
      textWidth = function(_, _)
        return 8
      end,
    },
    drawSubject = function(_, _, _) end,
    manifest = FieldUiFixture.namingSemanticsManifest(),
    imageLoader = function(path)
      loaded[#loaded + 1] = path
      local image = { path = path }
      borrowed[#borrowed + 1] = image
      function image:release() end
      function image:setFilter() end
      return image
    end,
  })
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "blank" }
    end
  end
  local snapshot = {
    page = "upper",
    text = "A",
    maxLength = 7,
    cursor = { row = 3, column = 5 },
    grid = grid,
    subject = { kind = "player", gender = 0 },
    presentation = { subjectTick = 0, cursorTick = 0, glowAngle = 180 },
  }
  ApplicationPresentation.draw(fake, { graphics = fake, namingRenderer = renderer }, snapshot, plan)
  Assert.isTrue(#fake.draws > 0, "the naming screen actually draws its source visuals")
  for _, call in ipairs(fake.draws) do
    local image = assert(call.image, "every naming draw carries its source visual")
    Assert.isTrue(image.path ~= FieldUiFixture.STRIP_PATH, "no naming draw sources the dialogue frame strip")
    local known = false
    for _, own in ipairs(borrowed) do
      if own == image then
        known = true
        break
      end
    end
    Assert.isTrue(known, "every naming draw uses the borrowed naming visuals, never an outer frame atlas")
  end
  renderer:dispose()
  state:dispose()
end

function T.tests.tiny_host_keeps_canonical_naming_geometry_without_a_fit_error()
  local state = nameEditState(240, 180)
  local view = state:view()
  Assert.equal(view.phase, "name_edit")
  local plan = assert(view.namingPresentation, "Oak must own a naming presentation plan on a tiny host")
  local pane = assert(plan.panes[1], "the tiny-host naming plan carries its content pane")
  local placement = assert(pane.placement, "the tiny-host naming pane carries its host placement")
  Assert.equal(placement.logicalWidth, 256, "cropping never shrinks the canonical logical width")
  Assert.equal(placement.logicalHeight, 192, "cropping never shrinks the canonical logical height")
  local naming = assert(view.layout.namingScreen, "tiny hosts still publish the canonical Naming Screen")
  Assert.equal(naming.surface.width, 256)
  Assert.equal(naming.surface.height, 192)
  state:dispose()
end

return T
