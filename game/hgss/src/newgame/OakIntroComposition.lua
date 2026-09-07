-- Production composition for the Oak/profile introduction. It validates and
-- reads generated assets, captures generated message templates, and transfers
-- audio and presentation ownership to the constructed Oak state.

local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local DialogueLayout = require("libs.hgss.src.ui.DialogueLayout")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local LocalClock = require("game.src.LocalClock")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroMessages = require("game.hgss.src.newgame.OakIntroMessages")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")
local GameAudio = require("game.hgss.src.audio.GameAudio")

local OakIntroComposition = {}

local MESSAGE_IDS = {
  ["greeting.morning"] = 1,
  ["greeting.day"] = 2,
  ["greeting.evening"] = 3,
  ["greeting.night"] = 4,
  ["greeting.midnight"] = 5,
  ["oak.welcome"] = 6,
  ["oak.world_inhabited"] = 34,
  ["oak.live_alongside"] = 35,
  ["oak.tell_about_yourself"] = 36,
  ["profile.gender_question"] = 37,
  ["profile.gender_confirm.male"] = 38,
  ["profile.gender_confirm.female"] = 39,
  ["profile.name_prompt"] = 40,
  ["profile.name_confirm.male"] = 41,
  ["profile.name_confirm.female"] = 42,
  ["profile.final"] = 43,
  ["choice.yes"] = 47,
  ["choice.no"] = 48,
}

local function mapMessages(getMessage, includeChoices)
  local messages = {}
  for key, messageId in pairs(MESSAGE_IDS) do
    if includeChoices or key ~= "choice.yes" and key ~= "choice.no" then
      local message = assert(getMessage(messageId))
      messages[key] = message
    end
  end
  return messages
end

function OakIntroComposition.messageKeys(messages)
  return mapMessages(function(messageId)
    return messages[messageId]
  end)
end

function OakIntroComposition.randomU32(mathHost)
  mathHost = mathHost or love.math
  assert(type(mathHost.random) == "function", "Oak intro requires love.math.random")
  local function randomValue()
    local high = mathHost.random(0, 0xFFFF)
    local low = mathHost.random(0, 0xFFFF)
    return high * 0x10000 + low
  end
  return randomValue
end

local function virtualGlyphs(charmap)
  local glyphs = {}
  local pages = {
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "abcdefghijklmnopqrstuvwxyz",
    "0123456789 -.'",
  }
  for _, page in ipairs(pages) do
    for glyph in page:gmatch(".") do
      if charmap[glyph] ~= nil then
        glyphs[#glyphs + 1] = glyph
      end
    end
  end
  local upper, lower = false, false
  for _, glyph in ipairs(glyphs) do
    upper = upper or glyph:match("^[A-Z]$") ~= nil
    lower = lower or glyph:match("^[a-z]$") ~= nil
  end
  assert(upper and lower, "generated field font lacks an uppercase or lowercase name-key page")
  return glyphs
end

local function generatedImageLoader(cacheFs, graphics)
  local function loadImage(path)
    local bytes = assert(cacheFs:read(path), "missing generated Oak image " .. path)
    local fileData = love.filesystem.newFileData(bytes, path)
    return graphics.newImage(fileData, { linear = false, mipmaps = false })
  end
  return loadImage
end

local function validManifest(manifest, validate, name)
  local valid, err = validate(manifest)
  if not valid then
    error(err or (name .. " manifest is invalid"), 0)
  end
  return manifest
end

---@param options table<string, unknown>
---@return OakIntroState
function OakIntroComposition.compose(options)
  assert(type(options) == "table", "Oak intro composition requires options")
  assert(type(options.candidate) == "table", "Oak intro composition requires a candidate")
  assert(type(options.versionId) == "string", "Oak intro composition requires a version")

  local cacheFs = CacheFs.forVersion(options.versionId)
  local introManifest =
    validManifest(assert(cacheFs:loadLua(IntroAssetCache.manifestPath())), IntroAssetCache.validateManifest, "intro")
  local uiManifest = validManifest(
    assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath())),
    FieldUiAssetCache.validateManifest,
    "field UI"
  )
  local fontDef = FieldFontLoader.load(cacheFs)
  local frameIndexes = {}
  for frame = 0, uiManifest.dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  local playerDataContext = { charmap = fontDef.charmap, frameIndexes = frameIndexes }

  local provider = FieldMessageProvider.new(cacheFs)
  local bankAcquired = false
  local audio
  local audioLifetime
  local textRenderer
  local choiceText
  local dialogueRenderer
  local ok, state = pcall(function()
    assert(provider:acquireBank(219))
    bankAcquired = true
    local messages = mapMessages(function(messageId)
      return assert(provider:get(219, messageId))
    end, true)
    provider:releaseBank(219)
    bankAcquired = false
    local messageFormatter = OakIntroMessages.new({ templates = messages, fontDef = fontDef })

    audio = GameAudio.compose({
      cacheFs = cacheFs,
      outputRate = 32768,
      outputHost = options.audioOutput,
    })
    local function disposeAudio(self)
      if self.disposed then
        return
      end
      self.disposed = true
      if audio.sink then
        audio.sink:release()
      end
    end
    audioLifetime = {
      dispose = disposeAudio,
    }

    local graphics = options.graphics or love.graphics
    ---@cast graphics love.Graphics|love.graphics
    textRenderer = FieldTextRenderer.new({ cacheFs = cacheFs, graphics = graphics })
    choiceText = FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 4, graphics = graphics })
    dialogueRenderer = FieldDialogueRenderer.new({
      cacheFs = cacheFs,
      manifest = uiManifest,
      text = textRenderer,
      graphics = graphics,
      drawFocusIndicator = false,
    })
    local function layoutDialogue(formatted)
      return DialogueLayout.layout(
        formatted.tokens,
        FieldDialogueTheme.fontMetrics(fontDef),
        { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
      )
    end
    local dialogueController = FieldDialogueController.new({
      layout = layoutDialogue,
      continueCursor = uiManifest.dialogueFrames.continueCursor,
    })
    local controller = OakIntroController.new({
      candidate = options.candidate,
      clock = options.clock or LocalClock.system(),
      audio = audio.sound,
      messages = messages,
      assets = introManifest,
      playerDataContext = playerDataContext,
      randomU32 = options.randomU32 or OakIntroComposition.randomU32(),
      virtualGlyphs = virtualGlyphs(fontDef.charmap),
    })
    return OakIntroState.new({
      controller = controller --[[@as unknown]],
      manifest = introManifest,
      textRenderer = textRenderer,
      choiceText = choiceText,
      graphics = graphics,
      imageLoader = options.imageLoader or generatedImageLoader(cacheFs, graphics),
      textInputHost = options.textInputHost,
      width = options.width,
      height = options.height,
      onComplete = options.onComplete,
      audioSink = audio.sink --[[@as OakIntroStateAudioSink?]],
      audioLifetime = audioLifetime,
      dialogueController = dialogueController,
      dialogueRenderer = dialogueRenderer,
      dialogueText = textRenderer,
      dialogueFormatter = messageFormatter,
      dialogueCursorPlacement = uiManifest.dialogueFrames.continueCursor.placement,
      screenTopology = options.screenTopology,
    })
  end)
  if not ok then
    if bankAcquired then
      pcall(provider.releaseBank, provider, 219)
    end
    if audioLifetime then
      audioLifetime:dispose()
    elseif audio and audio.sink then
      audio.sink:release()
    end
    if dialogueRenderer then
      pcall(dialogueRenderer.release, dialogueRenderer)
    end
    if textRenderer then
      pcall(textRenderer.release, textRenderer)
    end
    if choiceText then
      pcall(choiceText.release, choiceText)
    end
    error(state, 0)
  end
  return state
end

return OakIntroComposition
