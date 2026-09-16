-- Oak hosts the reusable Naming Screen without taking over its geometry:
-- composition threads the already-validated field-UI manifest and the
-- generated image loader through to naming construction, the naming child
-- keeps its canonical 256x192 surface with no child placement, and subject
-- art stays host-owned.

local Assert = require("tests.support.Assert")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")

local T = {}

local function stubTextRenderer()
  return {
    drawText = function() end,
    textWidth = function(_, value)
      return #value * 8
    end,
  }
end

local function stubController()
  return {
    start = function() end,
    dispose = function() end,
  }
end

local function spyOnRendererConstruction(captured)
  local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
  local original = OakIntroRenderer.new
  rawset(OakIntroRenderer, "new", function(options)
    captured.options = options
    return {
      dispose = function() end,
    }
  end)
  return function()
    rawset(OakIntroRenderer, "new", original)
  end
end

local function namingManifest()
  return {
    namingScreen = {
      base = { asset = "hgss.naming_screen.base", image = "assets/generated/field/ui/naming-screen-base.png" },
      pages = {
        upper = { asset = "hgss.naming_screen.page_upper", image = "assets/generated/field/ui/page-upper.png" },
        lower = { asset = "hgss.naming_screen.page_lower", image = "assets/generated/field/ui/page-lower.png" },
        symbols = { asset = "hgss.naming_screen.page_symbols", image = "assets/generated/field/ui/page-symbols.png" },
      },
      placement = { x = 0, y = 80, width = 256, height = 112 },
    },
  }
end

function T.oak_threads_the_validated_naming_contract_to_its_renderer()
  local captured = {}
  local restore = spyOnRendererConstruction(captured)
  local uiManifest = namingManifest()
  local function imageLoader(_)
    return nil
  end
  local state
  local ok, err = pcall(function()
    state = OakIntroState.new({
      controller = stubController(),
      manifest = {},
      textRenderer = stubTextRenderer(),
      choiceText = stubTextRenderer(),
      graphics = {},
      uiManifest = uiManifest,
      imageLoader = imageLoader,
      textInputHost = { setTextInput = function() end },
      width = 256,
      height = 192,
    })
  end)
  restore()
  Assert.isTrue(ok, "Oak state construction with the naming contract must succeed: " .. tostring(err))
  Assert.notNil(captured.options, "Oak state must construct its renderer through the spied entry")
  Assert.deepEqual(captured.options.uiManifest, uiManifest, "the validated field-UI manifest reaches the renderer")
  Assert.equal(captured.options.imageLoader, imageLoader, "the generated image loader reaches the renderer")
  assert(state):dispose()
end

function T.oak_naming_keeps_one_canonical_surface_without_a_child_placement()
  local computed = NamingScreenLayout.compute({ x = 0, y = 0, width = 512, height = 384 })
  Assert.deepEqual(computed.surface, { x = 128, y = 96, width = 256, height = 192 })
  Assert.isNil(computed.placement, "the naming child must not own a placement")
  Assert.isNil(computed.scale, "the naming child must not own a scale")
end

return { tests = T }
