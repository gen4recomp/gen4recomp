-- Production Oak composition tests cover generated semantic inputs and the
-- host-owned randomness boundary without embedding generated dialogue.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameAudio = require("game.hgss.src.audio.GameAudio")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroMessages = require("game.hgss.src.newgame.OakIntroMessages")

local T = { tests = {} }

function T.tests.message_ids_have_one_semantic_mapping()
  local messages = OakIntroComposition.messageKeys({
    [1] = { text = "morning" },
    [2] = { text = "day" },
    [3] = { text = "evening" },
    [4] = { text = "night" },
    [5] = { text = "midnight" },
    [6] = { text = "welcome" },
    [34] = { text = "inhabited" },
    [35] = { text = "alongside" },
    [36] = { text = "yourself" },
    [37] = { text = "gender" },
    [38] = { text = "male" },
    [39] = { text = "female" },
    [40] = { text = "name" },
    [41] = { text = "male-name" },
    [42] = { text = "female-name" },
    [43] = { text = "final" },
  })

  Assert.equal(messages["greeting.morning"].text, "morning")
  Assert.equal(messages["greeting.day"].text, "day")
  Assert.equal(messages["greeting.evening"].text, "evening")
  Assert.equal(messages["greeting.night"].text, "night")
  Assert.equal(messages["greeting.midnight"].text, "midnight")
  Assert.equal(messages["oak.welcome"].text, "welcome")
  Assert.equal(messages["oak.world_inhabited"].text, "inhabited")
  Assert.equal(messages["oak.live_alongside"].text, "alongside")
  Assert.equal(messages["oak.tell_about_yourself"].text, "yourself")
  Assert.equal(messages["profile.gender_question"].text, "gender")
  Assert.equal(messages["profile.gender_confirm.male"].text, "male")
  Assert.equal(messages["profile.gender_confirm.female"].text, "female")
  Assert.equal(messages["profile.name_prompt"].text, "name")
  Assert.equal(messages["profile.name_confirm.male"].text, "male-name")
  Assert.equal(messages["profile.name_confirm.female"].text, "female-name")
  Assert.equal(messages["profile.final"].text, "final")
end

function T.tests.random_u32_provider_returns_nonconstant_uint32_values()
  local draws = { 0x1234, 0x5678 }
  local random = OakIntroComposition.randomU32({
    random = function()
      return table.remove(draws, 1)
    end,
  })
  local value = random()
  Assert.equal(value, 0x12345678)
  Assert.isTrue(value >= 0 and value <= 0xFFFFFFFF)
end

function T.tests.composition_releases_font_zero_when_font_four_acquisition_fails()
  local modules = {
    cache = CacheFs.forVersion,
    introValidate = require("libs.assets.src.newgame.IntroAssetCache").validateManifest,
    fieldUiValidate = require("libs.assets.src.field.FieldUiAssetCache").validateManifest,
    fontLoad = FieldFontLoader.load,
    providerNew = FieldMessageProvider.new,
    audioCompose = GameAudio.compose,
    textNew = FieldTextRenderer.new,
    dialogueRendererNew = FieldDialogueRenderer.new,
    dialogueControllerNew = FieldDialogueController.new,
    controllerNew = OakIntroController.new,
    messagesNew = OakIntroMessages.new,
  }
  local introCache = require("libs.assets.src.newgame.IntroAssetCache")
  local fieldUiCache = require("libs.assets.src.field.FieldUiAssetCache")
  local calls = {}
  local fontZero = { releases = 0 }
  function fontZero:release()
    self.releases = self.releases + 1
  end
  local fakeCache = {
    loadLua = function(_, path)
      if path == introCache.manifestPath() then
        return {}
      end
      if path == fieldUiCache.manifestPath() then
        return {
          schema = fieldUiCache.SCHEMA,
          dialogueFrames = { count = 0, continueCursor = { placement = {} } },
        }
      end
      error("unexpected cache path " .. path)
    end,
  }
  local provider = {
    acquireBank = function()
      return true
    end,
    get = function()
      return {}
    end,
    releaseBank = function() end,
  }
  local sink = { releases = 0 }
  function sink:release()
    self.releases = self.releases + 1
  end

  rawset(CacheFs, "forVersion", function()
    return fakeCache
  end)
  rawset(introCache, "validateManifest", function()
    return true
  end)
  rawset(fieldUiCache, "validateManifest", function()
    return true
  end)
  rawset(FieldFontLoader, "load", function()
    return { charmap = {}, fontId = 0 }
  end)
  rawset(FieldMessageProvider, "new", function()
    return provider
  end)
  rawset(GameAudio, "compose", function()
    return { sound = {}, sink = sink }
  end)
  rawset(FieldTextRenderer, "new", function(options)
    calls[#calls + 1] = options.fontId or 0
    if options.fontId == 4 then
      error("font 4 construction failed")
    end
    return fontZero
  end)
  rawset(OakIntroMessages, "new", function()
    return {}
  end)

  local ok, failure = pcall(function()
    OakIntroComposition.compose({ candidate = {}, versionId = "heartgold" })
  end)

  rawset(CacheFs, "forVersion", modules.cache)
  rawset(introCache, "validateManifest", modules.introValidate)
  rawset(fieldUiCache, "validateManifest", modules.fieldUiValidate)
  rawset(FieldFontLoader, "load", modules.fontLoad)
  rawset(FieldMessageProvider, "new", modules.providerNew)
  rawset(GameAudio, "compose", modules.audioCompose)
  rawset(FieldTextRenderer, "new", modules.textNew)
  rawset(FieldDialogueRenderer, "new", modules.dialogueRendererNew)
  rawset(FieldDialogueController, "new", modules.dialogueControllerNew)
  rawset(OakIntroController, "new", modules.controllerNew)
  rawset(OakIntroMessages, "new", modules.messagesNew)

  Assert.isFalse(ok)
  Assert.isTrue(tostring(failure):find("font 4 construction failed", 1, true) ~= nil)
  Assert.deepEqual(calls, { 0, 4 })
  Assert.equal(fontZero.releases, 1, "font 0 is released after font 4 construction fails")
  Assert.equal(sink.releases, 1, "audio is released after partial Oak composition failure")
end

return T
