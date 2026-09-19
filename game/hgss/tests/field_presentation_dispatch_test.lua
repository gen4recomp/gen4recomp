-- Application presentation dispatch: the production-built per-instance
-- presenter map routes each presentable application id to its concrete
-- renderer, faults on an unknown id instead of falling back to another
-- surface, and releases owned resources exactly once. Pokemon, Trainer
-- Card, and Bag are all explicitly mapped through the real
-- FieldPresentationResources composition; draws borrow the composed
-- resources and never acquire them.

local Assert = require("tests.support.Assert")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")

local T = {}

local TARGET_MODULE = "game.hgss.src.field.FieldPresentationResources"

local CONSTRUCTOR_MODULES = {
  "libs.assets.src.BagCache",
  "libs.hgss.src.presentation.BagHeroRenderer",
  "libs.hgss.src.ui.BagRenderer",
  "libs.hgss.src.ui.FieldDialogueRenderer",
  "libs.hgss.src.ui.FieldMenuRenderer",
  "libs.hgss.src.ui.FieldSignpostRenderer",
  "libs.hgss.src.ui.FieldTextRenderer",
  "libs.hgss.src.presentation.FieldStaticEffectRenderer",
  "libs.hgss.src.presentation.FieldActorEmoteRenderer",
  "libs.hgss.src.presentation.FieldTerrainEffectRenderer",
  "libs.hgss.src.presentation.GpuAssetPool",
  "libs.hgss.src.presentation.FieldRenderer",
  "libs.hgss.src.ui.StartMenuRenderer",
  "libs.hgss.src.ui.TrainerCardRenderer",
  "libs.hgss.src.ui.PartyScreenRenderer",
  "libs.hgss.src.presentation.MonIconAssetProvider",
  "libs.hgss.src.presentation.ItemIconAssetProvider",
  "libs.hgss.src.presentation.FollowingMonTransitionRenderer",
}

local function releasable(calls, name)
  return {
    release = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function disposable(calls, name)
  return {
    dispose = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function drawOnly(label, sink)
  return {
    draw = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
  }
end

local function drawReleaser(label, sink, calls, name)
  return {
    draw = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
    release = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function buildDoubles(sink, calls)
  local party = drawOnly("party", sink)
  local card = drawReleaser("card", sink, calls, "card")
  local bag = drawReleaser("bag", sink, calls, "bag")
  return {
    ["libs.assets.src.BagCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
    ["libs.hgss.src.presentation.BagHeroRenderer"] = {
      new = function(_)
        return releasable(calls, "hero")
      end,
    },
    ["libs.hgss.src.ui.BagRenderer"] = {
      new = function(_)
        return bag
      end,
    },
    ["libs.hgss.src.ui.FieldDialogueRenderer"] = {
      new = function(_)
        return releasable(calls, "dialogue")
      end,
    },
    ["libs.hgss.src.ui.FieldMenuRenderer"] = {
      new = function(_)
        return {}
      end,
    },
    ["libs.hgss.src.ui.FieldSignpostRenderer"] = {
      new = function(_)
        return releasable(calls, "signpost")
      end,
    },
    ["libs.hgss.src.ui.FieldTextRenderer"] = {
      new = function(_)
        return releasable(calls, "text")
      end,
    },
    ["libs.hgss.src.presentation.FieldStaticEffectRenderer"] = {
      new = function(_)
        return disposable(calls, "staticEffect")
      end,
    },
    ["libs.hgss.src.presentation.FieldActorEmoteRenderer"] = {
      new = function(_)
        return disposable(calls, "emote")
      end,
    },
    ["libs.hgss.src.presentation.FieldTerrainEffectRenderer"] = {
      new = function(_)
        return disposable(calls, "terrain")
      end,
    },
    ["libs.hgss.src.presentation.GpuAssetPool"] = {
      new = function(_)
        return releasable(calls, "pool")
      end,
    },
    ["libs.hgss.src.presentation.FieldRenderer"] = {
      new = function(_)
        return releasable(calls, "renderer")
      end,
    },
    ["libs.hgss.src.ui.StartMenuRenderer"] = {
      new = function(_)
        return releasable(calls, "menu")
      end,
    },
    ["libs.hgss.src.ui.TrainerCardRenderer"] = {
      new = function(_)
        return card
      end,
    },
    ["libs.hgss.src.ui.PartyScreenRenderer"] = {
      new = function(_)
        return party
      end,
    },
    ["libs.hgss.src.presentation.MonIconAssetProvider"] = {
      new = function(_)
        return releasable(calls, "icons")
      end,
    },
    ["libs.hgss.src.presentation.ItemIconAssetProvider"] = {
      new = function(_)
        return releasable(calls, "itemIcons")
      end,
    },
    ["libs.hgss.src.presentation.FollowingMonTransitionRenderer"] = {
      new = function(_)
        return disposable(calls, "transition")
      end,
    },
  }
end

-- The minimal production-shaped runtime the real presentation constructor
-- reads. Follower-transition composition stays disabled by leaving its
-- definition and controller nil, the same as a definition-less composition.
local function compositionRuntime()
  return {
    cacheFs = {},
    uiManifest = {},
    windowStyles = {},
    fieldEntranceIndicatorAsset = {
      model = {},
      effects = {
        surf_attachment = {
          presentation = {},
          model = {},
        },
      },
    },
    fieldEmoteModels = {},
    fieldEffectAssets = {},
    fieldTerrainEffectController = {
      setModelFactory = function(_, _) end,
    },
  }
end

---@param viewport table?
---@return table
local function drawRuntime(viewport)
  return {
    viewport = viewport,
    fieldPixelScale = {
      resolvedScale = function(_)
        return 1
      end,
    },
  }
end

-- Installs recording constructor doubles, requires the real presentation
-- composition fresh, builds it through FieldPresentationResources.new, and
-- runs the callback against the production-built presenter map. Every
-- replaced module entry is restored even when the callback fails.
local function withProductionComposition(sink, calls, runtime, callback)
  local doubles = buildDoubles(sink, calls)
  local saved = {}
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = doubles[name]
  end
  package.loaded[TARGET_MODULE] = nil
  local ok, err = pcall(function()
    local FieldPresentationResources = require(TARGET_MODULE)
    local resources = FieldPresentationResources.new(runtime)
    callback(resources)
  end)
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[TARGET_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

function T.pokemon_routes_only_to_the_party_presenter()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    local presentation = { layout = { frame = { x = 0, y = 0, width = 640, height = 480 } } }
    resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
    Assert.equal(#sink, 1, "exactly one presenter draws")
    Assert.equal(sink[1][1], "party", "the Pokemon application draws through the party renderer")
    Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
    Assert.equal(sink[1][3], presentation.layout, "the party presenter draws through the application layout")
    Assert.equal(sink[1][4], resources.monIconProvider, "the party presenter borrows the shared icon provider")
    Assert.isNil(calls.icons, "drawing never releases the borrowed icon provider")
    resources:dispose()
  end)
end

function T.trainer_card_routes_only_to_the_card_presenter()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    local presentation = { name = "GOLD" }
    local viewport = { referenceFrame = { x = 0, y = 0, width = 256, height = 192 } }
    local runtime = drawRuntime(viewport)
    resources:drawApplication(FieldApplicationIds.TRAINER_CARD, presentation, runtime)
    Assert.equal(#sink, 1, "exactly one presenter draws")
    Assert.equal(sink[1][1], "card", "the Trainer Card application draws through the card renderer")
    Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
    Assert.equal(sink[1][3], runtime.viewport, "the card presenter draws into the runtime viewport")
    resources:dispose()
  end)
end

function T.bag_routes_only_to_the_bag_presenter()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "bag",
          render = function(borrowed, view, plan)
            assert(borrowed.bagRenderer, "the bag render borrows its renderer"):draw(view, plan, {
              icons = borrowed.icons,
            })
          end,
          mapInput = function()
            return nil
          end,
          coverage = {},
          backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
        },
      }
      resources:drawApplication(FieldApplicationIds.BAG, presentation, drawRuntime())
      Assert.equal(#sink, 1, "exactly one presenter draws")
      Assert.equal(sink[1][1], "bag", "the Bag application draws through the bag renderer")
      Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
      Assert.equal(sink[1][3], presentation.presentation, "the bag presenter draws through the application plan")
      Assert.equal(
        sink[1][4].icons,
        resources.itemIconProvider,
        "the bag presenter borrows the shared item icon provider"
      )
      Assert.isNil(calls.itemIcons, "drawing never releases the borrowed item icon provider")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.unknown_application_ids_fault_without_drawing()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    Assert.throws(function()
      resources:drawApplication("not-an-application", {}, drawRuntime())
    end)
    Assert.equal(#sink, 0, "a faulting dispatch must not fall through to any renderer")
    resources:dispose()
  end)
end

function T.draw_reuses_presenters_without_acquiring_resources()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    local presentation = { layout = { frame = { x = 0, y = 0, width = 10, height = 10 } } }
    resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
    local map = assert(resources.presenters, "dispatch owns one per-instance presenter map")
    resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
    Assert.equal(resources.presenters, map, "repeated draws must not rebuild the presenter map")
    Assert.equal(type(map[FieldApplicationIds.POKEMON]), "function", "the Pokemon presenter is explicitly mapped")
    Assert.equal(
      type(map[FieldApplicationIds.TRAINER_CARD]),
      "function",
      "the Trainer Card presenter is explicitly mapped"
    )
    Assert.equal(type(map[FieldApplicationIds.BAG]), "function", "the Bag presenter is explicitly mapped")
    Assert.equal(#sink, 2, "both draws reach the same borrowed renderer")
    Assert.isNil(calls.icons, "drawing never releases the borrowed icon provider")
    resources:dispose()
  end)
end

function T.dispose_releases_owned_resources_exactly_once()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    resources:drawApplication(FieldApplicationIds.POKEMON, { layout = {} }, drawRuntime())
    resources:dispose()
    resources:dispose()
    Assert.equal(calls.menu, 1, "repeat disposal never releases a renderer twice")
    Assert.equal(calls.card, 1, "repeat disposal never releases the card renderer twice")
    Assert.equal(calls.icons, 1, "repeat disposal never releases the icon provider twice")
    Assert.equal(calls.bag, 1, "repeat disposal never releases the bag renderer twice")
    Assert.equal(calls.itemIcons, 1, "repeat disposal never releases the item icon provider twice")
    Assert.equal(calls.hero, 1, "repeat disposal never releases the hero model renderer twice")
    Assert.equal(calls.dialogue, 1, "repeat disposal never releases the dialogue renderer twice")
    Assert.equal(calls.signpost, 1, "repeat disposal never releases the signpost renderer twice")
    Assert.equal(calls.text, 1, "repeat disposal never releases the text renderer twice")
    Assert.equal(calls.renderer, 1, "repeat disposal never releases the field renderer twice")
    Assert.equal(calls.staticEffect, 2, "repeat disposal releases each static effect renderer once")
    Assert.equal(calls.terrain, 1, "repeat disposal never releases the terrain effect renderer twice")
    Assert.equal(calls.emote, 1, "repeat disposal never releases the emote renderer twice")
    Assert.equal(calls.pool, 2, "repeat disposal releases each asset pool once")
  end)
end

function T.dispose_releases_the_borrowed_hero_model_renderer_exactly_once()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    resources:dispose()
    resources:dispose()
    Assert.equal(calls.hero, 1, "repeat disposal never releases the hero model renderer twice")
  end)
end

function T.bag_draw_borrows_shared_resources_without_releasing_them()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "bag",
          render = function(borrowed, view, plan)
            assert(borrowed.bagRenderer, "the bag render borrows its renderer"):draw(view, plan, {
              icons = borrowed.icons,
            })
          end,
          mapInput = function()
            return nil
          end,
          coverage = {},
          backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
        },
      }
      resources:drawApplication(FieldApplicationIds.BAG, presentation, drawRuntime())
      Assert.equal(#sink, 1, "exactly one presenter draws")
      Assert.isNil(calls.hero, "drawing never releases the borrowed hero model renderer")
      Assert.isNil(calls.bag, "drawing never releases the borrowed bag renderer")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- The Start Menu dispatch executes the resolved plan's render callback with
-- the borrowed renderer and never releases it: the plan owns geometry,
-- the resources own the GPU objects.
function T.start_menu_draw_executes_the_resolved_plan_with_borrowed_resources()
  local sink, calls = {}, {}
  local doubles = buildDoubles(sink, calls)
  doubles["libs.hgss.src.ui.StartMenuRenderer"] = {
    new = function(_)
      return {
        draw = function(_, presentation, placement)
          sink[#sink + 1] = { "menu", presentation, placement }
        end,
        release = function(_)
          calls.menu = (calls.menu or 0) + 1
        end,
      }
    end,
  }
  local saved = {}
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = doubles[name]
  end
  package.loaded[TARGET_MODULE] = nil
  local PixelScale = require("libs.ui.src.PixelScale")
  local FakeGraphics = require("tests.support.FakeGraphics").new
  local ok, err = pcall(function()
    local FieldPresentationResources = require(TARGET_MODULE)
    local resources = FieldPresentationResources.new(compositionRuntime())
    local body = assert(
      PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
      "the dispatch test host fits the canonical body"
    )
    local status = { selectedPosition = 0, actions = {} }
    status.presentation = {
      panes = { { id = "content", placement = body, interactive = true } },
      content = {},
      inputKey = "start-menu",
      render = function(borrowed, view, plan)
        assert(borrowed.startMenuRenderer, "the menu render borrows its renderer"):draw(
          view,
          assert(plan.panes[1], "the menu plan needs its body pane").placement
        )
      end,
      mapInput = function()
        return nil
      end,
      coverage = { { x = 0, y = 0, width = 640, height = 480 } },
      backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
    }
    local graphics = FakeGraphics({})
    resources:drawStartMenu(status, graphics)
    Assert.equal(#sink, 1, "exactly the chosen render callback draws")
    Assert.equal(sink[1][1], "menu", "the menu draws through the owned renderer")
    Assert.equal(sink[1][2], status, "the renderer receives the wrapper snapshot")
    Assert.deepEqual(sink[1][3], body, "the renderer draws at the plan body placement")
    Assert.isNil(calls.menu, "drawing never releases the borrowed renderer")
    Assert.throws(function()
      resources:drawStartMenu({ selectedPosition = 0 })
    end, "drawing without a published plan fails instead of drawing stale content")
    resources:dispose()
  end)
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[TARGET_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
