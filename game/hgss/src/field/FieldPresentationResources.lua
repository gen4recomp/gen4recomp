-- Owns the concrete GPU, UI, and field-effect resources used by FieldState.

local Errors = require("libs.errors.src.Errors")
local BagCache = require("libs.assets.src.BagCache")
local BagHeroRenderer = require("libs.hgss.src.presentation.BagHeroRenderer")
local BagRenderer = require("libs.hgss.src.ui.BagRenderer")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldPresentationConfig = require("game.hgss.src.field.FieldPresentationConfig")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldMenuRenderer = require("libs.hgss.src.ui.FieldMenuRenderer")
local FieldSignpostRenderer = require("libs.hgss.src.ui.FieldSignpostRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldStaticEffectRenderer = require("libs.hgss.src.presentation.FieldStaticEffectRenderer")
local FieldActorEmoteRenderer = require("libs.hgss.src.presentation.FieldActorEmoteRenderer")
local FieldTerrainEffectRenderer = require("libs.hgss.src.presentation.FieldTerrainEffectRenderer")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local StartMenuRenderer = require("libs.hgss.src.ui.StartMenuRenderer")
local TrainerCardRenderer = require("libs.hgss.src.ui.TrainerCardRenderer")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local FollowingMonTransitionRenderer = require("libs.hgss.src.presentation.FollowingMonTransitionRenderer")

---@class FieldPresentationResourcesRuntime
---@field cacheFs CacheFs
---@field uiManifest table<string, unknown>
---@field windowStyles FieldWindowStyles
---@field fieldEntranceIndicatorAsset table<string, unknown>
---@field fieldEmoteModels table<string, table<string, unknown>>
---@field fieldEffectAssets table<string, unknown>
---@field fieldTerrainEffectController FieldTerrainEffectController
---@field followerTransitionDefinition table<string, unknown>?
---@field followingMonTransition FollowingMonTransitionController?

---@class FieldPresentationResources
---@field renderer FieldRenderer?
---@field dialogueRenderer FieldDialogueRenderer?
---@field menuRenderer FieldMenuRenderer
---@field signpostRenderer FieldSignpostRenderer?
---@field startMenuRenderer StartMenuRenderer?
---@field trainerCardRenderer TrainerCardRenderer?
---@field partyScreenRenderer PartyScreenRenderer?
---@field monIconProvider MonIconAssetProvider? the one shared party-icon atlas for the state lifetime
---@field itemIconProvider ItemIconAssetProvider the one shared bag item-icon atlas
---@field heroRenderer BagHeroRenderer the one bag hero model renderer borrowed by the bag renderer
---@field bagRenderer BagRenderer the one field-bag pane renderer
---@field followingMonTransitionRenderer FollowingMonTransitionRenderer? transient follower-transition presentation (nil without the generated definition)
---@field textRenderer FieldTextRenderer?
---@field fieldEntranceIndicatorPool GpuAssetPool?
---@field fieldEntranceIndicatorRenderer FieldStaticEffectRenderer?
---@field fieldSurfRenderer FieldStaticEffectRenderer?
---@field surfPresentation table<string, unknown>
---@field fieldEmotePool GpuAssetPool?
---@field fieldEmoteRenderer FieldActorEmoteRenderer?
---@field fieldTerrainEffectRenderer FieldTerrainEffectRenderer?
---@field presenters table<string, FieldPresentationApplicationPresenter>? the per-instance application presenter map
local FieldPresentationResources = {}
FieldPresentationResources.__index = FieldPresentationResources

---@alias FieldPresentationApplicationPresenter fun(presentation: table<string, unknown>?, runtime: FieldRuntime?)

-- The explicit per-instance application presenter map: every presentable
-- application id resolves to the concrete renderer draw over resources this
-- owner holds. Presenters borrow those resources; they never acquire or
-- release them. An id without a presenter is a composition error, never a
-- fallback to another application surface.
---@param owner FieldPresentationResources
---@return table<string, FieldPresentationApplicationPresenter>
local function buildPresenters(owner)
  local function drawPokemon(presentation, _)
    assert(owner.partyScreenRenderer, "party screen renderer is unavailable"):draw(
      presentation,
      assert(presentation and presentation.layout, "the party application presents its layout"),
      assert(owner.monIconProvider, "party icon provider is unavailable")
    )
  end
  local function drawTrainerCard(presentation, runtime)
    assert(owner.trainerCardRenderer, "trainer card renderer is unavailable"):draw(
      presentation,
      assert(runtime and runtime.viewport, "the card application requires the runtime viewport")
    )
  end
  local function drawBag(presentation, _)
    assert(owner.bagRenderer, "bag renderer is unavailable"):draw(
      presentation,
      assert(presentation and presentation.layout, "the bag application presents its layout"),
      { icons = assert(owner.itemIconProvider, "bag icon provider is unavailable") }
    )
  end
  return {
    [FieldApplicationIds.POKEMON] = drawPokemon,
    [FieldApplicationIds.TRAINER_CARD] = drawTrainerCard,
    [FieldApplicationIds.BAG] = drawBag,
  }
end

---@param runtime FieldPresentationResourcesRuntime
---@return FieldPresentationResources
function FieldPresentationResources.new(runtime)
  local self = setmetatable({}, FieldPresentationResources)
  local ok, err = pcall(function()
    self.renderer = FieldRenderer.new({
      clearColor = { 0, 0, 0, 1 },
      worldRasterScale = FieldPresentationConfig.WORLD_3D_RASTER_SCALE,
    })
    local textRenderer = FieldTextRenderer.new({ cacheFs = runtime.cacheFs })
    self.textRenderer = textRenderer
    self.dialogueRenderer = FieldDialogueRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
    })
    self.menuRenderer = FieldMenuRenderer.new()
    self.signpostRenderer = FieldSignpostRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
      windowStyles = runtime.windowStyles,
    })
    self.startMenuRenderer = StartMenuRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
    })
    self.trainerCardRenderer = TrainerCardRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
    })
    self.partyScreenRenderer = PartyScreenRenderer.new()
    self.monIconProvider = MonIconAssetProvider.new(runtime.cacheFs)
    -- Bag presentation resolves eagerly beside the party icons: field entry
    -- boots only when the compiled item/bag caches are present, and the
    -- launch-time capability gate in the FieldRuntime bag factory still
    -- fails fast on missing service/cursor/catalog/assets when Bag opens.
    self.itemIconProvider = ItemIconAssetProvider.new(runtime.cacheFs)
    -- The bag manifest loads once: the 2D pane renderer and the borrowed
    -- hero model renderer share the same validated table.
    local bagManifest = BagCache.loadManifest(runtime.cacheFs)
    self.heroRenderer = BagHeroRenderer.new({ cacheFs = runtime.cacheFs, manifest = bagManifest })
    self.bagRenderer = BagRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = bagManifest,
      text = textRenderer,
      heroRenderer = self.heroRenderer,
    })
    local entrancePool = GpuAssetPool.new(runtime.cacheFs)
    self.fieldEntranceIndicatorPool = entrancePool
    self.fieldEntranceIndicatorRenderer =
      FieldStaticEffectRenderer.new(runtime.fieldEntranceIndicatorAsset.model, entrancePool)
    -- The transient follower-transition presentation shares the field effect
    -- pool. Its renderer-backed part instances replace the runtime's
    -- headless factory, so script-started transitions render through the
    -- exact generated resources while keeping controller timing.
    -- Definition-less compositions leave the renderer nil; the draw
    -- short-circuit below and the nil-guarded dispose keep them inert.
    if runtime.followerTransitionDefinition ~= nil and runtime.followingMonTransition ~= nil then
      local transitionRenderer =
        FollowingMonTransitionRenderer.new({ transition = runtime.followerTransitionDefinition }, entrancePool)
      self.followingMonTransitionRenderer = transitionRenderer
      local function transitionModelFactory(part)
        return transitionRenderer:newInstance(part)
      end
      runtime.followingMonTransition:setModelFactory(transitionModelFactory)
    else
      self.followingMonTransitionRenderer = nil
    end
    local surfEffects = runtime.fieldEntranceIndicatorAsset.effects
    local surfAttachment =
      assert(surfEffects and surfEffects.surf_attachment, "field-effect cache is missing surf_attachment")
    self.surfPresentation = assert(surfAttachment.presentation, "field-effect cache is missing surf presentation")
    self.fieldSurfRenderer = FieldStaticEffectRenderer.new(surfAttachment.model, entrancePool)
    local emotePool = GpuAssetPool.new(runtime.cacheFs)
    self.fieldEmotePool = emotePool
    self.fieldEmoteRenderer = FieldActorEmoteRenderer.new(runtime.fieldEmoteModels, emotePool)
    local fieldEffectAssets = assert(runtime.fieldEffectAssets, "field terrain-effect assets are unavailable")
    local terrainEffectRenderer = FieldTerrainEffectRenderer.new(fieldEffectAssets, entrancePool)
    self.fieldTerrainEffectRenderer = terrainEffectRenderer
    local function terrainModelFactory(kind)
      return terrainEffectRenderer:newInstance(kind)
    end
    local fieldTerrainEffectController =
      assert(runtime.fieldTerrainEffectController, "field terrain-effect controller is unavailable")
    fieldTerrainEffectController:setModelFactory(terrainModelFactory)
    self.presenters = buildPresenters(self)
  end)
  if not ok then
    self:dispose()
    error(err, 0)
  end
  return self
end

-- Draws the current application through its registered presenter. The map is
-- built once per instance alongside the renderers it borrows; a draw never
-- acquires resources. An application id without a presenter is a composition
-- error, never a fallback surface.
---@param applicationId string
---@param presentation table<string, unknown>?
---@param runtime FieldRuntime?
function FieldPresentationResources:drawApplication(applicationId, presentation, runtime)
  local map = assert(self.presenters, "the application presenter map is unavailable")
  local presenter = map[applicationId]
  if presenter == nil then
    Errors.raise(
      FieldErrors.FIELD_PRESENTATION_UNKNOWN_APPLICATION,
      "no presenter is registered for application " .. tostring(applicationId),
      { applicationId = applicationId }
    )
  end
  local draw = assert(presenter, "the application presenter is unavailable")
  draw(presentation, runtime)
end

function FieldPresentationResources:dispose()
  self.presenters = nil
  if self.dialogueRenderer then
    self.dialogueRenderer:release()
    self.dialogueRenderer = nil
  end
  if self.signpostRenderer then
    self.signpostRenderer:release()
    self.signpostRenderer = nil
  end
  if self.startMenuRenderer then
    self.startMenuRenderer:release()
    self.startMenuRenderer = nil
  end
  if self.trainerCardRenderer then
    self.trainerCardRenderer:release()
    self.trainerCardRenderer = nil
  end
  if self.monIconProvider then
    self.monIconProvider:release()
    self.monIconProvider = nil
  end
  if self.itemIconProvider then
    self.itemIconProvider:release()
    self.itemIconProvider = nil
  end
  if self.bagRenderer then
    self.bagRenderer:release()
    self.bagRenderer = nil
  end
  if self.heroRenderer then
    self.heroRenderer:release()
    self.heroRenderer = nil
  end
  self.partyScreenRenderer = nil
  if self.followingMonTransitionRenderer then
    self.followingMonTransitionRenderer:dispose()
    self.followingMonTransitionRenderer = nil
  end
  if self.textRenderer then
    self.textRenderer:release()
    self.textRenderer = nil
  end
  if self.fieldEntranceIndicatorRenderer then
    self.fieldEntranceIndicatorRenderer:dispose()
    self.fieldEntranceIndicatorRenderer = nil
  end
  if self.fieldSurfRenderer then
    self.fieldSurfRenderer:dispose()
    self.fieldSurfRenderer = nil
  end
  if self.fieldTerrainEffectRenderer then
    self.fieldTerrainEffectRenderer:dispose()
    self.fieldTerrainEffectRenderer = nil
  end
  if self.fieldEntranceIndicatorPool then
    self.fieldEntranceIndicatorPool:release()
    self.fieldEntranceIndicatorPool = nil
  end
  if self.fieldEmoteRenderer then
    self.fieldEmoteRenderer:dispose()
    self.fieldEmoteRenderer = nil
  end
  if self.fieldEmotePool then
    self.fieldEmotePool:release()
    self.fieldEmotePool = nil
  end
  if self.renderer then
    self.renderer:release()
    self.renderer = nil
  end
end

return FieldPresentationResources
