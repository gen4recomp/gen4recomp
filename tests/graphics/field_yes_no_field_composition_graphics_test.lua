-- Production FieldState composition for adapted field Yes/No presentation.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldState = require("game.hgss.src.field.FieldState")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PixelScale = require("libs.ui.src.PixelScale")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function freshGame(versionId)
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = { mapSymbol = "MAP_NEW_BARK", fieldX = 10, fieldZ = 10, facing = "south" },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "fastest", textFrame = 1 },
    },
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(versionId),
    bag = require("libs.hgss.src.save.BagSave").empty(),
  }
end

local function readyVersion()
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      return versionId
    end
  end
  error("a ready game dump and derived cache are required")
end

local function topology(width, height, safeRect)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    safeRect = safeRect,
    role = "world",
    touch = false,
  })
end

local function openScriptDialogueAndChoice(state)
  local host = assert(state.runtime.scripts.dialogueHost)
  host:startPrint("msg.hgss.0542.00034", {}, {})
  for _ = 1, 600 do
    if host:printProgress().done then
      break
    end
    host:advance({})
  end
  Assert.isTrue(host:printProgress().done, "the script-owned message printer must finish")
  Assert.isTrue(state.runtime.dialogue:isModal(), "the script-owned dialogue must remain open")
  host:askYesNo()
  Assert.notNil(host:yesNoPresentation(), "the script-owned choice must be active")
end

local function render(scope, state, width, height)
  local graphics = love.graphics
  local canvas = scope:own(graphics.newCanvas(width, height))
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  state:draw()
  graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function pixelEnvelope(image, comparison)
  local left, top, right, bottom
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local red, green, blue, alpha = image:getPixel(x, y)
      local otherRed, otherGreen, otherBlue, otherAlpha = comparison:getPixel(x, y)
      if red ~= otherRed or green ~= otherGreen or blue ~= otherBlue or alpha ~= otherAlpha then
        left = left and math.min(left, x) or x
        top = top and math.min(top, y) or y
        right = right and math.max(right, x) or x
        bottom = bottom and math.max(bottom, y) or y
      end
    end
  end
  Assert.notNil(left, "the choice must change final canvas pixels")
  return { x = left, y = top, width = right - left + 1, height = bottom - top + 1 }
end

local function assertMenuComposition(scope, width, height, safeRect)
  local originalGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return width, height
  end)
  local state
  local resolvedYesNoLayout
  local resolvedYesNoInputs
  local resolvedDialoguePresentation
  local ok, err = xpcall(function()
    state = FieldState.new(freshGame(readyVersion()), {
      topologyProvider = function()
        return topology(width, height, safeRect)
      end,
    })
    scope:own({
      release = function()
        state:dispose()
      end,
    })

    local yesNoRenderer = assert(state.presentationResources and state.presentationResources.yesNoRenderer)
    local layout = yesNoRenderer.layout
    yesNoRenderer.layout = function(self, status, screenTopology, dialogueBox, adaptedHost)
      resolvedYesNoInputs = { dialogueBox = dialogueBox, adaptedHost = adaptedHost }
      resolvedYesNoLayout = layout(self, status, screenTopology, dialogueBox, adaptedHost)
      return resolvedYesNoLayout
    end
    local dialogueRenderer = assert(state.presentationResources.dialogueRenderer)
    local drawDialogue = dialogueRenderer.draw
    dialogueRenderer.draw = function(self, dialogue, presentation)
      resolvedDialoguePresentation = presentation
      return drawDialogue(self, dialogue, presentation)
    end

    local runtime = assert(state.runtime)
    for _ = 1, 120 do
      if runtime.session.mapEntryStage == nil then
        break
      end
      state:draw()
      state:update(1 / 60)
    end
    Assert.isNil(runtime.session.mapEntryStage, "the production field entry must settle before drawing")

    local dialogueHost = assert(runtime.scripts.dialogueHost)
    dialogueHost:askYesNo()
    Assert.isFalse(runtime.dialogue:isModal(), "standalone choice must not require ordinary dialogue")
    Assert.notNil(dialogueHost:yesNoPresentation(), "the script-owned standalone choice must be active")

    local standaloneChoice = render(scope, state, width, height)
    Assert.notNil(resolvedYesNoLayout, "active standalone choice must reach the field Yes/No renderer")
    dialogueHost:closeYesNo()
    local standaloneField = render(scope, state, width, height)
    local standalonePixels = pixelEnvelope(standaloneChoice, standaloneField)

    local bounds = assert(runtime.viewport.worldViewport)
    local standaloneLayout = assert(resolvedYesNoLayout)
    local standaloneInputs = assert(resolvedYesNoInputs)
    Assert.isNil(standaloneInputs.dialogueBox, "standalone choice layout has no dialogue anchor")
    Assert.equal(
      standaloneInputs.adaptedHost.preferredScale,
      runtime.fieldPixelScale:resolvedScale(),
      "standalone choice layout uses the resolved field scale"
    )
    local standaloneFrame = assert(standaloneLayout.placement).frame
    Assert.isTrue(standaloneFrame.x >= bounds.x, "complete standalone frame stays inside field UI bounds")
    Assert.isTrue(standaloneFrame.y >= bounds.y, "complete standalone frame stays inside field UI bounds")
    Assert.isTrue(
      standaloneFrame.x + standaloneFrame.width <= bounds.x + bounds.width,
      "complete standalone frame stays inside field UI bounds"
    )
    Assert.isTrue(
      standaloneFrame.y + standaloneFrame.height <= bounds.y + bounds.height,
      "complete standalone frame stays inside field UI bounds"
    )
    Assert.isTrue(standalonePixels.x >= bounds.x, "standalone choice pixels stay inside field UI bounds")
    Assert.isTrue(standalonePixels.y >= bounds.y, "standalone choice pixels stay inside field UI bounds")
    Assert.isTrue(
      standalonePixels.x + standalonePixels.width <= bounds.x + bounds.width,
      "standalone choice pixels stay inside field UI bounds"
    )
    Assert.isTrue(
      standalonePixels.y + standalonePixels.height <= bounds.y + bounds.height,
      "standalone choice pixels stay inside field UI bounds"
    )

    openScriptDialogueAndChoice(state)

    local withChoice = render(scope, state, width, height)
    runtime.scripts.dialogueHost:closeYesNo()
    local dialogueOnly = render(scope, state, width, height)
    local menuPixels = pixelEnvelope(withChoice, dialogueOnly)
    runtime.scripts.dialogueHost:close(true)
    local fieldOnly = render(scope, state, width, height)
    local dialoguePixels = pixelEnvelope(dialogueOnly, fieldOnly)

    local frame = assert(assert(resolvedYesNoLayout).placement).frame
    local dialogueBox = assert(assert(resolvedYesNoInputs).dialogueBox)
    local dialogueOuterRect = assert(assert(resolvedDialoguePresentation).outerRect)
    Assert.equal(dialogueBox.x, dialogueOuterRect.x, "dialogue-attached choice keeps the dialogue horizontal anchor")
    Assert.equal(dialogueBox.y, dialogueOuterRect.y, "dialogue-attached choice keeps the dialogue vertical anchor")
    Assert.equal(dialogueBox.width, dialogueOuterRect.width, "dialogue-attached choice keeps dialogue width")
    Assert.equal(dialogueBox.height, dialogueOuterRect.height, "dialogue-attached choice keeps dialogue height")
    Assert.near(
      frame.x + frame.width,
      bounds.x + bounds.width,
      1e-9,
      "the production layout anchors its complete exterior frame to field UI bounds"
    )
    local resolvedScale = runtime.fieldPixelScale:resolvedScale()
    local dialogueScale = PixelScale.fitPreferred(bounds, 256, 48, resolvedScale)
    Assert.equal(
      assert(resolvedYesNoInputs).adaptedHost.preferredScale,
      dialogueScale,
      "dialogue-attached choice keeps the dialogue scale"
    )
    local expectedScale = math.min(dialogueScale, math.floor(math.min(bounds.width / 88, bounds.height / 48)))
    Assert.isTrue(expectedScale >= 1, "the composed host must fit the complete menu at integer scale")
    Assert.isTrue(menuPixels.x >= bounds.x, "every changed menu pixel stays inside field UI bounds")
    Assert.isTrue(menuPixels.y >= bounds.y, "every changed menu pixel stays inside field UI bounds")
    Assert.isTrue(menuPixels.x + menuPixels.width <= bounds.x + bounds.width, "menu pixels stay inside field UI bounds")
    Assert.isTrue(
      menuPixels.y + menuPixels.height <= bounds.y + bounds.height,
      "menu pixels stay inside field UI bounds"
    )
    Assert.isTrue(
      menuPixels.width >= 84 * expectedScale - 1,
      string.format(
        "the complete menu follows the field's resolved presentation scale (pixels=%d, expectedScale=%d, dialogueScale=%d, resolvedScale=%s)",
        menuPixels.width,
        expectedScale,
        dialogueScale,
        tostring(resolvedScale)
      )
    )
    Assert.isTrue(
      menuPixels.x + menuPixels.width <= dialoguePixels.x
        or menuPixels.x >= dialoguePixels.x + dialoguePixels.width
        or menuPixels.y + menuPixels.height <= dialoguePixels.y
        or menuPixels.y >= dialoguePixels.y + dialoguePixels.height,
      "choice pixels are spatially distinct from visible dialogue pixels"
    )
  end, debug.traceback)
  rawset(love.graphics, "getDimensions", originalGetDimensions)
  if not ok then
    error(err, 0)
  end
end

function T.four_three_standalone_choice_and_attached_dialogue_keep_their_layouts(scope)
  assertMenuComposition(scope, 640, 480)
end

function T.tall_standalone_choice_stays_complete_inside_the_attached_viewport(scope)
  assertMenuComposition(scope, 390, 844, { x = 12, y = 24, width = 366, height = 796 })
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
