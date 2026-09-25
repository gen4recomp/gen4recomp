-- ROM-backed standard cry contract. The test opens the generated audio cache
-- for every ready game version and stops at the semantic audio/output boundary.

local Assert = require("tests.support.Assert")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "bootstrap" },
    tags = { "audio", "cry", "rom" },
  },
  tests = {},
}

local contexts

local function loadCore()
  local ok, core = pcall(require, "game.hgss.src.audio.GameAudio")
  Assert.isTrue(ok, "ROM-backed cry cannot reach a reusable core audio composition")
  Assert.isTrue(type(core) == "table" and type(core.compose) == "function", "audio core must expose compose")
  return core
end

function T.beforeAll()
  contexts = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local index = cacheFs:loadLua(AudioCache.indexPath())
      Assert.notNil(index, versionId .. " must have a generated audio index")
      contexts[#contexts + 1] = { versionId = versionId, cacheFs = cacheFs, index = index }
    end
  end
end

function T.afterAll()
  contexts = nil
end

function T.tests.marill_form_zero_uses_generated_audio_samples()
  for _, context in ipairs(assert(contexts, "ROM audio contexts were not prepared")) do
    Assert.notNil(context.index.sequences[2], context.versionId .. " must contain generic cry sequence 2")
    Assert.notNil(context.index.banks[183], context.versionId .. " must contain Marill bank 183")

    local bank = assert(context.cacheFs:loadLua(AudioCache.bankPath(183)))
    local sampleKeys = AudioBank.sampleKeys(bank)
    Assert.isTrue(sampleKeys ~= nil and #sampleKeys > 0, context.versionId .. " Marill bank must reference samples")

    local output = FakeAudioOutput.new()
    local core
    local ok, err = xpcall(function()
      local GameAudio = loadCore()
      core = GameAudio.compose({
        cacheFs = context.cacheFs,
        outputRate = 32768,
        outputHost = { audio = output.audio, sound = output.sound },
      })
      core.sound:playCry(183, 0)
      for _ = 1, 240 do
        core.sound:updateSoundFrame()
        core.sink:update()
        if output:anyNonSilent() then
          break
        end
      end
      Assert.isTrue(output:anyNonSilent(), context.versionId .. " Marill cry must produce non-silent PCM")
    end, debug.traceback)
    if core and core.sink then
      core.sink:release()
    end
    if not ok then
      error(context.versionId .. ": " .. tostring(err), 0)
    end
  end
end

return T
