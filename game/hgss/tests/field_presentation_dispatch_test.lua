-- Application presentation dispatch: the per-instance presenter map routes
-- each presentable application id to its concrete renderer, faults on an
-- unknown id instead of falling back to another surface, and releases owned
-- resources exactly once. Pokemon, Trainer Card, and Bag are all explicitly
-- mapped; draws borrow the composed resources and never acquire them.

local Assert = require("tests.support.Assert")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")

local T = {}

local function recordingRenderer(label, sink)
  return {
    draw = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
  }
end

local function fakeRenderer(label, sink, calls)
  return {
    draw = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
    release = function(_)
      calls[label] = (calls[label] or 0) + 1
    end,
  }
end

local function fakeReleasable(calls, name)
  return {
    release = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function dispatchResources(sink, calls)
  local resources = setmetatable({
    partyScreenRenderer = recordingRenderer("party", sink),
    trainerCardRenderer = fakeRenderer("card", sink, calls),
    bagRenderer = fakeRenderer("bag", sink, calls),
    heroRenderer = fakeReleasable(calls, "hero"),
    monIconProvider = fakeReleasable(calls, "icons"),
    itemIconProvider = fakeReleasable(calls, "itemIcons"),
    startMenuRenderer = fakeReleasable(calls, "menu"),
  }, FieldPresentationResources)
  -- The explicit test seam: the per-instance presenter map is composed
  -- alongside the resources it borrows, mirroring production ownership.
  -- Dispatch never builds it; a missing map faults at the boundary.
  resources.presenters = {
    [FieldApplicationIds.POKEMON] = function(presentation, _)
      resources.partyScreenRenderer:draw(presentation, presentation.layout, resources.monIconProvider)
    end,
    [FieldApplicationIds.TRAINER_CARD] = function(presentation, runtime)
      resources.trainerCardRenderer:draw(presentation, runtime.viewport)
    end,
    [FieldApplicationIds.BAG] = function(presentation, _)
      resources.bagRenderer:draw(presentation, presentation.layout, { icons = resources.itemIconProvider })
    end,
  }
  return resources
end

---@param viewport table?
---@return FieldRuntime
local function fakeRuntime(viewport)
  local runtime = { viewport = viewport }
  return runtime --[[@as FieldRuntime]]
end

function T.pokemon_routes_only_to_the_party_presenter()
  local sink, calls = {}, {}
  local resources = dispatchResources(sink, calls)
  local presentation = { layout = { frame = { x = 0, y = 0, width = 640, height = 480 } } }
  resources:drawApplication(FieldApplicationIds.POKEMON, presentation, fakeRuntime())
  Assert.equal(#sink, 1, "exactly one presenter draws")
  Assert.equal(sink[1][1], "party", "the Pokemon application draws through the party renderer")
  Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
  Assert.equal(sink[1][3], presentation.layout, "the party presenter draws through the application layout")
  Assert.equal(sink[1][4], resources.monIconProvider, "the party presenter borrows the shared icon provider")
end

function T.trainer_card_routes_only_to_the_card_presenter()
  local sink, calls = {}, {}
  local resources = dispatchResources(sink, calls)
  local presentation = { name = "GOLD" }
  local viewport = { referenceFrame = { x = 0, y = 0, width = 256, height = 192 } }
  local runtime = fakeRuntime(viewport)
  resources:drawApplication(FieldApplicationIds.TRAINER_CARD, presentation, runtime)
  Assert.equal(#sink, 1, "exactly one presenter draws")
  Assert.equal(sink[1][1], "card", "the Trainer Card application draws through the card renderer")
  Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
  Assert.equal(sink[1][3], runtime.viewport, "the card presenter draws into the runtime viewport")
end

function T.bag_routes_only_to_the_bag_presenter()
  local sink, calls = {}, {}
  local resources = dispatchResources(sink, calls)
  local presentation = { layout = { frame = { x = 0, y = 0, width = 512, height = 384 } } }
  resources:drawApplication(FieldApplicationIds.BAG, presentation, fakeRuntime())
  Assert.equal(#sink, 1, "exactly one presenter draws")
  Assert.equal(sink[1][1], "bag", "the Bag application draws through the bag renderer")
  Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
  Assert.equal(sink[1][3], presentation.layout, "the bag presenter draws through the application layout")
  Assert.equal(sink[1][4].icons, resources.itemIconProvider, "the bag presenter borrows the shared item icon provider")
end

function T.unknown_application_ids_fault_without_drawing()
  local sink, calls = {}, {}
  local resources = dispatchResources(sink, calls)
  Assert.throws(function()
    resources:drawApplication("not-an-application", {}, fakeRuntime())
  end)
  Assert.equal(#sink, 0, "a faulting dispatch must not fall through to any renderer")
end

function T.draw_reuses_presenters_without_acquiring_resources()
  local sink, calls = {}, {}
  local resources = dispatchResources(sink, calls)
  local presentation = { layout = { frame = { x = 0, y = 0, width = 10, height = 10 } } }
  resources:drawApplication(FieldApplicationIds.POKEMON, presentation, fakeRuntime())
  local map = assert(resources.presenters, "dispatch owns one per-instance presenter map")
  resources:drawApplication(FieldApplicationIds.POKEMON, presentation, fakeRuntime())
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
end

function T.dispose_releases_owned_resources_exactly_once()
  local sink, calls = {}, {}
  local resources = dispatchResources(sink, calls)
  resources:drawApplication(FieldApplicationIds.POKEMON, { layout = {} }, fakeRuntime())
  resources:dispose()
  resources:dispose()
  Assert.equal(calls.menu, 1, "repeat disposal never releases a renderer twice")
  Assert.equal(calls.card, 1, "repeat disposal never releases the card renderer twice")
  Assert.equal(calls.icons, 1, "repeat disposal never releases the icon provider twice")
  Assert.equal(calls.bag, 1, "repeat disposal never releases the bag renderer twice")
  Assert.equal(calls.itemIcons, 1, "repeat disposal never releases the item icon provider twice")
end

function T.dispose_releases_the_borrowed_hero_model_renderer_exactly_once()
  local sink, calls = {}, {}
  local resources = dispatchResources(sink, calls)
  resources:dispose()
  resources:dispose()
  Assert.equal(calls.hero, 1, "repeat disposal never releases the hero model renderer twice")
end

function T.bag_draw_borrows_shared_resources_without_releasing_them()
  local sink, calls = {}, {}
  local resources = dispatchResources(sink, calls)
  local presentation = { layout = { frame = { x = 0, y = 0, width = 512, height = 384 } } }
  resources:drawApplication(FieldApplicationIds.BAG, presentation, fakeRuntime())
  Assert.equal(#sink, 1, "exactly one presenter draws")
  Assert.isNil(calls.hero, "drawing never releases the borrowed hero model renderer")
  Assert.isNil(calls.bag, "drawing never releases the borrowed bag renderer")
end

return { tests = T }
