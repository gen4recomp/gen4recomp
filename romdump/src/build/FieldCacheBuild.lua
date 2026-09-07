-- Builds field, mon, global, and physical-cell derived assets for one version.

local Errors = require("libs.errors.src.Errors")
local FieldCameraCompiler = require("romdump.src.digest.field.FieldCameraCompiler")
local FieldCameraCacheWriter = require("romdump.src.digest.field.FieldCameraCacheWriter")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local FieldActorCacheWriter = require("romdump.src.digest.actor.FieldActorCacheWriter")
local FollowingMonVisualCompiler = require("romdump.src.digest.FollowingMonVisualCompiler")
local MonCatalogCompiler = require("romdump.src.digest.MonCatalogCompiler")
local MonCacheWriter = require("romdump.src.digest.MonCacheWriter")
local FieldFontCompiler = require("romdump.src.digest.ui.FieldFontCompiler")
local FieldFontCacheWriter = require("romdump.src.digest.ui.FieldFontCacheWriter")
local FieldUiCompiler = require("romdump.src.digest.ui.FieldUiCompiler")
local FieldUiCacheWriter = require("romdump.src.digest.ui.FieldUiCacheWriter")
local IntroAssetCompiler = require("romdump.src.digest.newgame.IntroAssetCompiler")
local IntroAssetCacheWriter = require("romdump.src.digest.newgame.IntroAssetCacheWriter")
local StarterChoiceAssetCompiler = require("romdump.src.digest.StarterChoiceAssetCompiler")
local StarterChoiceAssetCacheWriter = require("romdump.src.digest.StarterChoiceAssetCacheWriter")
local FieldWeatherCompiler = require("romdump.src.digest.field.FieldWeatherCompiler")
local FieldWeatherCacheWriter = require("romdump.src.digest.field.FieldWeatherCacheWriter")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local FieldEntranceIndicatorCacheWriter = require("romdump.src.digest.field.FieldEntranceIndicatorCacheWriter")
local FieldActorEmoteCompiler = require("romdump.src.digest.actor.FieldActorEmoteCompiler")
local FieldActorEmoteCacheWriter = require("romdump.src.digest.actor.FieldActorEmoteCacheWriter")
local NewGameInitCompiler = require("romdump.src.digest.newgame.NewGameInitCompiler")
local NewGameInitCacheWriter = require("romdump.src.digest.newgame.NewGameInitCacheWriter")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")

local FieldCacheBuild = {}

---@param context VersionBuildContext
---@param bundle table<string, unknown>
---@param writer table<string, function>
---@param ready function
---@param label string
---@param detail fun(bundle: table<string, unknown>): string
local function writeIfStale(context, bundle, writer, ready, label, detail)
  if context.forced or not ready(context.cacheFs, bundle.marker) then
    writer.write(context.cacheFs, bundle)
    context.log(string.format("build-cache: %s %s compiled%s", context.version, label, detail(bundle)))
  else
    context.log(string.format("build-cache: %s %s current", context.version, label))
  end
end

---@param bundle table<string, unknown>|nil
---@param err Errors.Error|string|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
local function requireBundle(bundle, err)
  if bundle then
    return bundle
  end
  assert(Errors.is(err), "field cache stage failure must be a structured error")
  return nil, err
end

---@param context VersionBuildContext
---@return true|nil, Errors.Error|string|nil
local function buildLateFieldAssets(context)
  local bundle, err = FieldWeatherCompiler.compile(context.romFs)
  local weather = requireBundle(bundle, err)
  if not weather then
    return nil, err
  end
  bundle, err = FieldEntranceIndicatorCompiler.compile(context.romFs)
  local effect = requireBundle(bundle, err)
  if not effect then
    return nil, err
  end
  writeIfStale(
    context,
    effect,
    FieldEntranceIndicatorCacheWriter,
    FieldEffectAssetCache.isReady,
    "warp entrance field effect",
    function()
      return ""
    end
  )

  bundle, err = FieldActorEmoteCompiler.compile(context.romFs)
  local emote = requireBundle(bundle, err)
  if not emote then
    return nil, err
  end
  writeIfStale(
    context,
    emote,
    FieldActorEmoteCacheWriter,
    FieldEmoteAssetCache.isReady,
    "field emote indicator",
    function()
      return ""
    end
  )
  writeIfStale(context, weather, FieldWeatherCacheWriter, FieldWeatherCacheWriter.isReady, "field weather", function()
    return ""
  end)

  bundle, err = NewGameInitCompiler.compileFromRom(context.romFs)
  local newGameInit = requireBundle(bundle, err)
  if not newGameInit then
    return nil, err
  end
  writeIfStale(
    context,
    newGameInit,
    NewGameInitCacheWriter,
    NewGameInitCacheWriter.isReady,
    "fresh-game startup initializer",
    function()
      return ""
    end
  )

  bundle, err = FieldMessageCompiler.compile(context.romFs)
  local message = requireBundle(bundle, err)
  if not message then
    return nil, err
  end
  writeIfStale(
    context,
    message,
    FieldMessageCacheWriter,
    FieldMessageCacheWriter.isReady,
    "field messages",
    function(value)
      return string.format(" (%d banks)", #value.index.bankIds)
    end
  )

  return true
end

---@param context VersionBuildContext
---@return true|nil, Errors.Error|string|nil
function FieldCacheBuild.build(context)
  local bundle, err = FieldCameraCompiler.compile(context.romFs)
  local camera = requireBundle(bundle, err)
  if not camera then
    return nil, err
  end
  writeIfStale(context, camera, FieldCameraCacheWriter, FieldCameraCacheWriter.isReady, "field cameras", function()
    return ""
  end)

  bundle, err = FieldActorCompiler.compile(context.romFs)
  local actor = requireBundle(bundle, err)
  if not actor then
    return nil, err
  end
  -- Follower visuals extend the actor sprite index, so they must merge before
  -- the actor class is published; the mon catalog below validates its
  -- follower references against this merged index.
  local followerBundle, followerErr = FollowingMonVisualCompiler.compile(context.romFs)
  local follower = requireBundle(followerBundle, followerErr)
  if not follower then
    return nil, followerErr
  end
  FollowingMonVisualCompiler.mergeIntoActorBundle(actor, follower)
  writeIfStale(context, actor, FieldActorCacheWriter, FieldActorCacheWriter.isReady, "field actors", function(value)
    return string.format(" (%d sprites)", #value.index.spriteIds)
  end)

  local monBundle, monErr = MonCatalogCompiler.compileAll(context.romFs)
  local mons = requireBundle(monBundle, monErr)
  if not mons then
    return nil, monErr
  end
  local actorSpriteIds = {}
  for _, spriteId in ipairs(actor.index.spriteIds) do
    actorSpriteIds[spriteId] = true
  end
  local monSpecies = 0
  for speciesKey, species in pairs(mons.catalog.species) do
    monSpecies = monSpecies + 1
    for formId, form in pairs(species.forms) do
      if form.follower ~= nil then
        local followerRefs = { form.follower.visualId }
        if form.follower.female ~= nil then
          followerRefs[#followerRefs + 1] = form.follower.female.visualId
        end
        for _, visualId in ipairs(followerRefs) do
          if not actorSpriteIds[visualId] then
            return nil,
              Errors.new(
                "MON_CATALOG_FOLLOWER_UNRESOLVED",
                "catalog follower visual is absent from the actor index",
                { species = speciesKey, form = formId, visualId = visualId }
              )
          end
        end
      end
    end
  end
  writeIfStale(context, mons, MonCacheWriter, MonCacheWriter.isReady, "mons", function()
    return string.format(" (%d species)", monSpecies)
  end)

  local fieldBundles
  fieldBundles, err = FieldMapDataCompiler.compileAll(context.romFs)
  if not fieldBundles then
    return nil, err
  end
  for _, fieldBundle in ipairs(fieldBundles) do
    writeIfStale(
      context,
      fieldBundle,
      FieldMapDataCacheWriter,
      FieldMapDataCache.isReady,
      string.format("map %d field data", fieldBundle.mapId),
      function()
        return ""
      end
    )
  end

  bundle, err = FieldFontCompiler.compile(context.romFs)
  local font = requireBundle(bundle, err)
  if not font then
    return nil, err
  end
  writeIfStale(context, font, FieldFontCacheWriter, FieldFontCacheWriter.isReady, "field font", function()
    return ""
  end)

  bundle, err = FieldUiCompiler.compile(context.romFs)
  local ui = requireBundle(bundle, err)
  if not ui then
    return nil, err
  end
  writeIfStale(context, ui, FieldUiCacheWriter, FieldUiCacheWriter.isReady, "field ui", function()
    return ""
  end)

  bundle, err = IntroAssetCompiler.compile(context.romFs)
  local intro = requireBundle(bundle, err)
  if not intro then
    return nil, err
  end
  writeIfStale(context, intro, IntroAssetCacheWriter, IntroAssetCacheWriter.isReady, "intro assets", function()
    return ""
  end)

  bundle, err = StarterChoiceAssetCompiler.compile(context.romFs)
  local starterChoice = requireBundle(bundle, err)
  if not starterChoice then
    return nil, err
  end
  writeIfStale(
    context,
    starterChoice,
    StarterChoiceAssetCacheWriter,
    StarterChoiceAssetCacheWriter.isReady,
    "starter choice assets",
    function()
      return ""
    end
  )

  return buildLateFieldAssets(context)
end

return FieldCacheBuild
