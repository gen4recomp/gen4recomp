-- Real generated-asset LÖVE smoke for the field Bag presentation: the
-- production BagRenderer, the borrowed production BagHeroRenderer, the
-- production item-icon provider, and the production field text renderer draw
-- the real compiled Bag cache through the real BagLayout placements into a
-- real canvas. Pixel evidence (never draw-did-not-throw) proves the hero
-- model path is active, the generated action/quantity/confirmation states
-- are distinct, the two registration markers are distinct, repeated draws at
-- one semantic frame are identical, and teardown releases exactly once.

local Assert = require("tests.support.Assert")
local BagCache = require("libs.assets.src.BagCache")
local BagHeroPresenter = require("libs.hgss.src.presentation.BagHeroPresenter")
local BagHeroRenderer = require("libs.hgss.src.presentation.BagHeroRenderer")
local BagLayout = require("libs.hgss.src.ui.BagLayout")
local BagRenderer = require("libs.hgss.src.ui.BagRenderer")
local BagSave = require("libs.hgss.src.save.BagSave")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local CANVAS_WIDTH = 512
local CANVAS_HEIGHT = 192

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(BagCache.markerPath())
      if
        marker ~= nil
        and BagCache.isReady(cacheFs, marker)
        and cacheFs:read(ItemCache.iconManifestPath()) ~= nil
        and cacheFs:read(ItemCache.iconImagePath()) ~= nil
        and cacheFs:read(FieldFontCache.atlasPath(0)) ~= nil
      then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function manifestFor(versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = BagCache.loadManifest(cacheFs)
  Assert.equal(manifest.schema, "g4-bag-assets-v3", versionId .. " renders the v3 bag manifest")
  return cacheFs, manifest
end

-- The single-surface horizontal composition: two 256x192 panes side by side
-- at unit scale, so canonical pane coordinates map 1:1 into host pixels
-- offset by the placement frame.
local function twoPaneLayout(manifest)
  local layout = BagLayout.resolve({
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = CANVAS_WIDTH, height = CANVAS_HEIGHT },
      touch = false,
      role = "world",
    }),
    manifest = manifest,
  })
  Assert.equal(layout.mode, "horizontal", "the 512x192 surface composes both panes side by side")
  Assert.equal(layout.hero.scale, 1, "the smoke canvas keeps canonical coordinates")
  Assert.equal(layout.interactive.scale, 1, "the smoke canvas keeps canonical coordinates")
  return layout
end

local function iconKeys(cacheFs, versionId)
  local manifest = assert(cacheFs:loadLua(ItemCache.iconManifestPath()), versionId .. " loads its item icon manifest")
  local keys = {}
  for key in pairs(assert(manifest.entries, versionId .. " carries icon entries")) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  Assert.isTrue(#keys >= 2, versionId .. " carries two item icons")
  return keys[1], keys[2]
end

local function pockets()
  local tabs = {}
  for index, key in ipairs(BagSave.POCKET_ORDER) do
    tabs[index] = { pocket = key, nativeId = index - 1, name = key }
  end
  return tabs
end

local function makeSlot(item, name, icon, quantity, registrationSlot)
  return {
    item = item,
    nativeId = 1,
    name = name,
    quantity = quantity,
    description = name .. " restores vigor",
    icon = icon,
    registrationSlot = registrationSlot,
  }
end

local function emptyCell(index)
  return { empty = true, visibleIndex = index - 1 }
end

-- Six visible cells with two occupied entries; the caller selects the
-- registration identity of the first cell and the hero/pocket facts.
local function presentation(firstIcon, secondIcon, heroStatus, overrides)
  local cells = {
    makeSlot("SMOKE_ITEM_A", "Smoke A", firstIcon, 5, overrides and overrides.registrationSlot or nil),
    makeSlot("SMOKE_ITEM_B", "Smoke B", secondIcon, 3, nil),
    emptyCell(3),
    emptyCell(4),
    emptyCell(5),
    emptyCell(6),
  }
  local record = {
    open = true,
    state = "browsing",
    focus = "items",
    revision = 1,
    pocket = heroStatus.pocket,
    pockets = pockets(),
    selectedAbsoluteIndex = 0,
    visibleStart = 0,
    visibleSlots = cells,
    page = { current = 1, count = 1 },
    selected = cells[1],
    heroGender = (overrides and overrides.heroGender) or "male",
    hero = heroStatus,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      if key ~= "registrationSlot" and key ~= "heroGender" then
        record[key] = value
      end
    end
  end
  return record
end

-- One BagHeroPresenter per pocket path, advanced a fixed number of semantic
-- ticks: the status records carry production pocket/pose/pattern/frame facts.
local function heroStatusAt(manifest, pocket, ticks)
  local presenter = BagHeroPresenter.new({ manifest = manifest })
  presenter:selectPocket(pocket)
  for _ = 1, ticks do
    presenter:updateFixed()
  end
  return presenter:status()
end

local function twoPockets(manifest, versionId)
  local states = assert(manifest.hero.animations.states, versionId .. " carries hero pocket states")
  Assert.isTrue(#states >= 2, versionId .. " carries two hero pocket states")
  local first, second = states[1].pocket, states[2].pocket
  Assert.isTrue(type(first) == "string" and first ~= "", versionId .. " names its first hero pocket")
  Assert.isTrue(
    type(second) == "string" and second ~= "" and second ~= first,
    versionId .. " names a second hero pocket"
  )
  return first, second
end

local function owners(cacheFs, manifest, scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
  local icons = scope:own(ItemIconAssetProvider.new(cacheFs))
  local heroRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local renderer = scope:own(BagRenderer.new({
    cacheFs = cacheFs,
    manifest = manifest,
    text = text,
    heroRenderer = heroRenderer,
  }))
  return { text = text, icons = icons, heroRenderer = heroRenderer, renderer = renderer }
end

local function render(scope, owned, presentationRecord, layout)
  local canvas = scope:own(love.graphics.newCanvas(CANVAS_WIDTH, CANVAS_HEIGHT))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  owned.renderer:draw(presentationRecord, layout, { icons = owned.icons })
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function decodeImage(scope, cacheFs, path, what)
  local bytes = assert(cacheFs:read(path), "the cache carries " .. what)
  return scope:own(love.image.newImageData(love.filesystem.newFileData(bytes, path)))
end

local function quantize(channel)
  return math.floor(channel * 255 + 0.5)
end

-- Counts pixels in a host rectangle whose quantized color differs between
-- two captures; every differing pixel fails loudly only through the
-- caller's threshold.
local function regionDistance(first, second, rect, stride)
  Assert.equal(first:getWidth(), second:getWidth(), "captures share their width")
  Assert.equal(first:getHeight(), second:getHeight(), "captures share their height")
  local changed = 0
  for y = rect.y, rect.y + rect.height - 1, stride do
    for x = rect.x, rect.x + rect.width - 1, stride do
      local r1, g1, b1, a1 = first:getPixel(x, y)
      local r2, g2, b2, a2 = second:getPixel(x, y)
      if
        quantize(r1) ~= quantize(r2)
        or quantize(g1) ~= quantize(g2)
        or quantize(b1) ~= quantize(b2)
        or quantize(a1) ~= quantize(a2)
      then
        changed = changed + 1
      end
    end
  end
  return changed
end

-- Counts hero-region pixels (outside the description text rectangle, where
-- only the 3D model varies between same-text renders) whose color differs
-- from the decoded gender backdrop mapped 1:1 into canonical coordinates.
local function modelPixelsOverBackdrop(composed, backdrop, heroFrame, textRect, stride)
  local changed = 0
  for hostY = heroFrame.y, heroFrame.y + heroFrame.height - 1, stride do
    for hostX = heroFrame.x, heroFrame.x + heroFrame.width - 1, stride do
      local cx, cy = hostX - heroFrame.x, hostY - heroFrame.y
      if
        cx >= textRect.x - 2
        and cx < textRect.x + textRect.width + 2
        and cy >= textRect.y - 2
        and cy < textRect.y + textRect.height + 2
      then
        -- The contextual description is identical across the compared
        -- renders; only model pixels prove the 3D path.
      elseif cx >= 0 and cy >= 0 and cx < backdrop:getWidth() and cy < backdrop:getHeight() then
        local r1, g1, b1, a1 = composed:getPixel(hostX, hostY)
        local r2, g2, b2, a2 = backdrop:getPixel(cx, cy)
        if a1 > 0.5 and a2 > 0.5 and math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.03 then
          changed = changed + 1
        end
      end
    end
  end
  return changed
end

-- Counts hero-region pixels outside the description text rectangle that
-- differ between two renders sharing gender, backdrop, and description
-- text: only the realized model can move those pixels.
local function modelRegionDistance(first, second, heroFrame, textRect, stride)
  local changed = 0
  for hostY = heroFrame.y, heroFrame.y + heroFrame.height - 1, stride do
    for hostX = heroFrame.x, heroFrame.x + heroFrame.width - 1, stride do
      local cx, cy = hostX - heroFrame.x, hostY - heroFrame.y
      if
        cx >= textRect.x - 2
        and cx < textRect.x + textRect.width + 2
        and cy >= textRect.y - 2
        and cy < textRect.y + textRect.height + 2
      then
        -- Same description text on both renders; skip it.
      else
        local r1, g1, b1 = first:getPixel(hostX, hostY)
        local r2, g2, b2 = second:getPixel(hostX, hostY)
        if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.03 then
          changed = changed + 1
        end
      end
    end
  end
  return changed
end

-- The hero pane draws the model over the gender backdrop, and changing only
-- the hero pocket (same gender, same backdrop, same description) moves
-- pixels outside the description text: the compiled model/clip path is
-- active rather than a static 2D pane. Both genders render their matching
-- descriptors without fallback.
function T.hero_pane_renders_the_model_and_tracks_the_pocket(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local pocketA, pocketB = twoPockets(manifest, versionId)
    local textRect = assert(manifest.hero.description.textRect, versionId .. " carries its description text rectangle")
    local heroFrame = assert(layout.hero.frame, versionId .. " places the hero pane")

    local maleStatus = heroStatusAt(manifest, pocketA, 40)
    local male = render(scope, owned, presentation(firstIcon, secondIcon, maleStatus), layout)
    local maleBackdrop = decodeImage(scope, cacheFs, manifest.hero.background.male.image, versionId .. " male backdrop")
    Assert.isTrue(
      modelPixelsOverBackdrop(male, maleBackdrop, heroFrame, textRect, 2) > 40,
      versionId .. " the male hero pane carries model content over its backdrop"
    )

    local otherStatus = heroStatusAt(manifest, pocketB, 40)
    local other = render(scope, owned, presentation(firstIcon, secondIcon, otherStatus), layout)

    -- Pocket variants are small per-pocket accessories over a shared idle pose,
    -- so the deterministic pocket delta is a couple of pixels, stable across
    -- runs, renderers, and animation frames. Full-stride sampling aliases it
    -- away, so compare every pixel: any change proves the compiled per-pocket
    -- path reaches the hero region rather than only tabs changing.
    Assert.isTrue(
      modelRegionDistance(male, other, heroFrame, textRect, 1) > 0,
      versionId .. " switching pockets moves hero-model pixels outside the description"
    )

    local femaleStatus = heroStatusAt(manifest, pocketA, 40)
    local female =
      render(scope, owned, presentation(firstIcon, secondIcon, femaleStatus, { heroGender = "female" }), layout)

    local femaleBackdrop =
      decodeImage(scope, cacheFs, manifest.hero.background.female.image, versionId .. " female backdrop")
    Assert.isTrue(
      modelPixelsOverBackdrop(female, femaleBackdrop, heroFrame, textRect, 2) > 40,
      versionId .. " the female hero pane carries model content over its backdrop"
    )
  end
end

-- The generated lower-pane states are visually distinct: the action menu
-- rests on its action background with generated labels, the quantity picker
-- on its quantity layer stack and digit geometry, and the toss confirmation
-- on its distinct confirmation screen.
function T.action_quantity_and_confirmation_render_distinct_states(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local pocket = twoPockets(manifest, versionId)
    local heroStatus = heroStatusAt(manifest, pocket, 6)
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")

    local labels = assert(
      manifest.interactive.text and manifest.interactive.text.actions,
      versionId .. " carries generated action labels"
    )
    Assert.isTrue(type(labels.toss) == "string" and labels.toss ~= "", versionId .. " labels the toss action")
    Assert.isTrue(type(labels.cancel) == "string" and labels.cancel ~= "", versionId .. " labels the cancel action")

    local menu = render(
      scope,
      owned,
      presentation(firstIcon, secondIcon, heroStatus, {
        state = "action_menu",
        actions = { { id = "toss" }, { id = "cancel" } },
        selectedAction = 0,
      }),
      layout
    )
    local quantity = render(
      scope,
      owned,
      presentation(firstIcon, secondIcon, heroStatus, {
        state = "toss_quantity",
        quantity = 2,
        quantityMax = 5,
      }),
      layout
    )
    local confirm = render(
      scope,
      owned,
      presentation(firstIcon, secondIcon, heroStatus, {
        state = "toss_confirm",
        quantity = 2,
      }),
      layout
    )
    Assert.isTrue(
      regionDistance(menu, quantity, interactiveFrame, 2) > 100,
      versionId .. " the action menu and the quantity picker are distinct surfaces"
    )
    Assert.isTrue(
      regionDistance(quantity, confirm, interactiveFrame, 2) > 100,
      versionId .. " the quantity picker and the confirmation are distinct surfaces"
    )
    Assert.isTrue(
      regionDistance(menu, confirm, interactiveFrame, 2) > 100,
      versionId .. " the action menu and the confirmation are distinct surfaces"
    )
  end
end

-- Registration slot 1 and slot 2 draw their distinct source markers: two
-- otherwise-equal item cells differ inside the generated 40x16 marker cell,
-- and the compiled marker images differ from each other.
function T.registration_slots_render_distinct_markers(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local pocket = twoPockets(manifest, versionId)
    local heroStatus = heroStatusAt(manifest, pocket, 6)

    local registration =
      assert(manifest.interactive.itemSlots.registration, versionId .. " carries its registration markers")
    Assert.equal(registration.slot1.width, 40, versionId .. " sizes the first marker from source")
    Assert.equal(registration.slot1.height, 16, versionId .. " sizes the first marker from source")
    Assert.equal(registration.slot2.width, 40, versionId .. " sizes the second marker from source")
    Assert.equal(registration.slot2.height, 16, versionId .. " sizes the second marker from source")
    local marker1 = decodeImage(scope, cacheFs, registration.slot1.image, versionId .. " first marker")
    local marker2 = decodeImage(scope, cacheFs, registration.slot2.image, versionId .. " second marker")
    Assert.isTrue(
      regionDistance(marker1, marker2, { x = 0, y = 0, width = 40, height = 16 }, 1) > 10,
      versionId .. " the compiled slot markers are distinct images"
    )

    local slot1 =
      render(scope, owned, presentation(firstIcon, secondIcon, heroStatus, { registrationSlot = 1 }), layout)
    local slot2 =
      render(scope, owned, presentation(firstIcon, secondIcon, heroStatus, { registrationSlot = 2 }), layout)
    local cell =
      assert(manifest.interactive.itemSlots.slots[1].rect, versionId .. " carries its first item-cell rectangle")
    local offset = assert(registration.offset, versionId .. " carries its marker offset")
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")
    local markerRegion = {
      x = interactiveFrame.x + cell.x + offset.x,
      y = interactiveFrame.y + cell.y + offset.y,
      width = 40,
      height = 16,
    }
    Assert.isTrue(
      regionDistance(slot1, slot2, markerRegion, 1) > 10,
      versionId .. " slot 1 and slot 2 draw distinct marker pixels"
    )
  end
end

-- Repeated draws at the same hero semantic frame are observationally
-- identical: render frequency never advances Bag semantic time.
function T.repeated_draw_at_one_semantic_frame_is_identical(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local pocket = twoPockets(manifest, versionId)
    local heroStatus = heroStatusAt(manifest, pocket, 6)
    local record = presentation(firstIcon, secondIcon, heroStatus)
    local first = render(scope, owned, record, layout)
    local second = render(scope, owned, record, layout)
    Assert.equal(
      regionDistance(first, second, { x = 0, y = 0, width = CANVAS_WIDTH, height = CANVAS_HEIGHT }, 1),
      0,
      versionId .. " repeated draws at one semantic frame match exactly"
    )
  end
end

-- Release is exactly-once across the production collaborators: an explicit
-- release of every owned renderer/provider succeeds, and a second release
-- stays a safe no-op without double-release errors.
function T.release_teardown_is_idempotent(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local pocket = twoPockets(manifest, versionId)

    local text = FieldTextRenderer.new({ cacheFs = cacheFs })
    local icons = ItemIconAssetProvider.new(cacheFs)
    local heroRenderer = BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest })
    local renderer = BagRenderer.new({
      cacheFs = cacheFs,
      manifest = manifest,
      text = text,
      heroRenderer = heroRenderer,
    })
    local owned = { text = text, icons = icons, heroRenderer = heroRenderer, renderer = renderer }
    local heroStatus = heroStatusAt(manifest, pocket, 6)
    scope:own(render(scope, owned, presentation(firstIcon, secondIcon, heroStatus), layout))

    renderer:release()
    heroRenderer:release()
    icons:release()
    text:release()
    Assert.isTrue(next(renderer._images) == nil, versionId .. " releasing frees the pane images")

    renderer:release()
    heroRenderer:release()
    icons:release()
    text:release()
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
