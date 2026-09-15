-- Real generated-asset LÖVE smoke for the field Bag presentation: the
-- production BagRenderer, the borrowed production BagHeroRenderer, the
-- production item-icon provider, and the production field text renderer draw
-- the real compiled Bag cache through the real BagLayout placements into a
-- real canvas. Pixel evidence (never draw-did-not-throw) proves the hero
-- model path is active, the full hero stage carries lit chromatic source
-- material instead of a near-black silhouette, female joint stages preserve
-- the base silhouette instead of exploding across the target, the generated action/quantity/confirmation states
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
  Assert.equal(manifest.schema, "g4-bag-assets-v7", versionId .. " renders the v7 bag manifest")
  return cacheFs, manifest
end

-- The realized browse background for one pocket and visible occupied count:
-- seven count variants where index `occupiedCount + 1` covers counts 0..6.
local function browseVariant(manifest, pocket, occupiedCount, versionId)
  local browse = assert(manifest.interactive.backgrounds.browse, versionId .. " carries its browse backgrounds")
  local variants = assert(browse[pocket], versionId .. " carries the " .. pocket .. " browse variants")
  Assert.equal(#variants, 7, versionId .. " carries seven count variants for " .. pocket)
  return assert(variants[occupiedCount + 1], versionId .. " carries count " .. occupiedCount .. " for " .. pocket)
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
local function heroStatusAt(manifest, pocket, ticks, gender)
  local presenter = BagHeroPresenter.new({ manifest = manifest, gender = gender or "male" })
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

local function imageDataDigest(data)
  local hash = 2166136261
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      for _, channel in ipairs({ red, green, blue, alpha }) do
        hash = (hash * 16777619 + math.floor(channel * 255 + 0.5)) % 4294967296
      end
    end
  end
  return hash
end

local function occupiedPixels(data)
  local occupied = {}
  for y = 0, data:getHeight() - 1 do
    occupied[y] = {}
    for x = 0, data:getWidth() - 1 do
      local _, _, _, alpha = data:getPixel(x, y)
      local present = alpha > 0
      occupied[y][x] = present
    end
  end
  return occupied
end

local function bounds(data, requireMaterial)
  local left, top, right, bottom
  local count = 0
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if alpha > 0 and (not requireMaterial or red + green + blue > 0) then
        left = left and math.min(left, x) or x
        top = top and math.min(top, y) or y
        right = right and math.max(right, x) or x
        bottom = bottom and math.max(bottom, y) or y
        count = count + 1
      end
    end
  end
  return { left = left, top = top, right = right, bottom = bottom, count = count }
end

local function assertCanonicalBounds(region, description)
  Assert.isTrue(region.count > 0, description .. " is nonempty")
  local left = assert(region.left, description .. " has a left bound")
  local top = assert(region.top, description .. " has a top bound")
  local right = assert(region.right, description .. " has a right bound")
  local bottom = assert(region.bottom, description .. " has a bottom bound")
  Assert.isTrue(
    left >= 0 and top >= 0 and right < 256 and bottom < 192,
    description .. " stays inside the canonical 256x192 target"
  )
  Assert.isTrue(right > left and bottom > top, description .. " has positive extent")
end

local function drawRealizedStage(scope, heroRenderer, gender, stage, pocket)
  heroRenderer:_ensureGender(gender)
  local realized = assert(heroRenderer._realized[gender], "the real hero model is realized")
  local material = heroRenderer._manifest.hero.animations.material[gender]
  local status = heroStatusAt(heroRenderer._manifest, pocket or "items", 0)
  local clips = {
    joint = status.pose,
    pattern = status.pattern,
    material = material,
  }
  local function play(name)
    realized.instance:play(clips[name], { loopMode = "loop" })
  end
  if stage == "material" then
    play("material")
  elseif stage == "joint" then
    play("joint")
  elseif stage == "joint_pattern" then
    play("joint")
    play("pattern")
  elseif stage == "full" then
    play("joint")
    play("pattern")
    play("material")
  else
    Assert.equal(stage, "base", "the diagnostic stage name is valid")
  end
  realized.instance:evaluatePose()

  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  local renderer = assert(heroRenderer._renderer, "the real hero owns its field renderer")
  local view = heroRenderer._view
  local projection = heroRenderer._projection
  renderer:draw(
    heroRenderer._sceneRuntime,
    {
      far = heroRenderer._cameraFar,
      zoom = 1,
      view = function()
        return view
      end,
      projection = function()
        return projection
      end,
      billboardProjection = function()
        return projection
      end,
    },
    { realized.instance:drawItems(realized.renderMeshes) },
    nil,
    {
      worldViewport = { x = 0, y = 0, width = 256, height = 192 },
      referenceFrame = { x = 0, y = 0, width = 256, height = 192 },
    },
    1
  )
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

-- Occupancy and material-color census of one staged hero capture: pixels
-- with substantial coverage contribute bounds and extent, while the lit and
-- chromatic populations measure clearly-lit surface (brightest channel at or
-- above 0.30) and real texture hue (channel spread above 0.05) instead of
-- near-black or flat-gray silhouette pixels.
local function stageMaterialStats(data)
  local left, top, right, bottom, count = nil, nil, nil, nil, 0
  local lit, chromatic = 0, 0
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if alpha > 0.5 then
        left = left and math.min(left, x) or x
        top = top and math.min(top, y) or y
        right = right and math.max(right, x) or x
        bottom = bottom and math.max(bottom, y) or y
        count = count + 1
        local brightest = math.max(red, green, blue)
        if brightest >= 0.30 then
          lit = lit + 1
        end
        if brightest - math.min(red, green, blue) > 0.05 then
          chromatic = chromatic + 1
        end
      end
    end
  end
  return {
    left = left,
    top = top,
    right = right,
    bottom = bottom,
    count = count,
    lit = lit,
    chromatic = chromatic,
  }
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

-- The realized destination of one tab visual: its tab anchor (the rect
-- center) plus the generated offset, which already positions the image.
local function visualRect(rect, visual)
  local offset = visual.offset or { x = 0, y = 0 }
  local x = rect.x + rect.width / 2 + offset.x
  local y = rect.y + rect.height / 2 + offset.y
  return { x = x, y = y, width = visual.width, height = visual.height }
end

local function rectanglesDoNotOverlap(first, second)
  return first.x + first.width <= second.x
    or second.x + second.width <= first.x
    or first.y + first.height <= second.y
    or second.y + second.height <= first.y
end

local function hasOccupiedPixel(data)
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local _, _, _, alpha = data:getPixel(x, y)
      if alpha > 0 then
        return true
      end
    end
  end
  return false
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

    local femaleStatus = heroStatusAt(manifest, pocketA, 40, "female")
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

-- Each pocket keeps its normal tab artwork and tab focus is the generated
-- source visual at the focused pocket's target: focusing pocket A while
-- pocket B stays the baseline changes pixels inside A's focus footprint but
-- never inside another pocket's normal footprint. Normals prove themselves
-- against the decoded browse background. No fixed tab position, color, or
-- occupancy threshold is needed beyond the generated footprints.
function T.all_pocket_tabs_render_the_source_focus_visual_at_their_targets(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local interactive = assert(manifest.interactive, versionId .. " carries the interactive pane")
    local tabs = assert(interactive.pocketTabs, versionId .. " carries the pocket tabs")
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")
    for index, visual in ipairs(tabs.normal) do
      Assert.isTrue(type(visual.image) == "string", versionId .. " tab " .. index .. " is a static source visual")
      Assert.isNil(visual.frames, versionId .. " tab " .. index .. " has no runtime frame timeline")
      local normal = decodeImage(scope, cacheFs, visual.image, versionId .. " normal tab " .. index)
      Assert.isTrue(hasOccupiedPixel(normal), versionId .. " normal tab " .. index .. " has source occupancy")
    end
    Assert.isNil(tabs.highlight, versionId .. " carries no retired tab highlight")
    Assert.isNil(tabs.selected, versionId .. " carries no retired selected tab visual")
    local focus = assert(interactive.focus, versionId .. " carries its generated focus")
    local tabFocus = assert(focus.tabs, versionId .. " carries its tab focus")
    Assert.isTrue(type(tabFocus.visual.image) == "string", versionId .. " tab focus is a static source visual")
    Assert.isNil(tabFocus.visual.frames, versionId .. " tab focus has no runtime frame timeline")
    local sourceFocus = decodeImage(scope, cacheFs, tabFocus.visual.image, versionId .. " tab focus")
    Assert.isTrue(hasOccupiedPixel(sourceFocus), versionId .. " tab focus has source occupancy")
    Assert.equal(#tabFocus.targets, 8, versionId .. " targets one tab focus per pocket")
    local pocketRecords = pockets()
    for index, pocket in ipairs(pocketRecords) do
      local status = heroStatusAt(manifest, pocket.pocket, 0)
      local focused = render(scope, owned, presentation(firstIcon, secondIcon, status, { focus = "tabs" }), layout)
      local unfocused = render(scope, owned, presentation(firstIcon, secondIcon, status, { focus = "items" }), layout)
      local offset = tabFocus.visual.offset or { x = 0, y = 0 }
      local target = assert(tabFocus.targets[index], versionId .. " targets tab " .. index)
      local footprint = {
        x = interactiveFrame.x + target.x + offset.x,
        y = interactiveFrame.y + target.y + offset.y,
        width = tabFocus.visual.width,
        height = tabFocus.visual.height,
      }
      Assert.isTrue(
        regionDistance(focused, unfocused, footprint, 1) > 0,
        versionId .. " tab focus paints inside the " .. pocket.pocket .. " footprint"
      )
      local browse = browseVariant(manifest, pocket.pocket, 2, versionId)
      local backdrop = decodeImage(scope, cacheFs, browse.image, versionId .. " browse background")
      local normalRect = visualRect(tabs.rects[index], tabs.normal[index])
      local normalRegion = {
        x = interactiveFrame.x + normalRect.x,
        y = interactiveFrame.y + normalRect.y,
        width = normalRect.width,
        height = normalRect.height,
      }
      local backdropOffset = browse.offset or { x = 0, y = 0 }
      local normalChanged = 0
      for y = 0, normalRegion.height - 1 do
        for x = 0, normalRegion.width - 1 do
          local bx, by =
            normalRegion.x - interactiveFrame.x - backdropOffset.x + x,
            normalRegion.y - interactiveFrame.y - backdropOffset.y + y
          if bx >= 0 and by >= 0 and bx < backdrop:getWidth() and by < backdrop:getHeight() then
            local r1, g1, b1, a1 = unfocused:getPixel(normalRegion.x + x, normalRegion.y + y)
            local r2, g2, b2, a2 = backdrop:getPixel(bx, by)
            if
              quantize(r1) ~= quantize(r2)
              or quantize(g1) ~= quantize(g2)
              or quantize(b1) ~= quantize(b2)
              or quantize(a1) ~= quantize(a2)
            then
              normalChanged = normalChanged + 1
            end
          end
        end
      end
      Assert.isTrue(normalChanged > 0, versionId .. " normal tab " .. index .. " paints over the browse background")
    end
  end
end

local function rectanglesOverlap(first, second)
  return not rectanglesDoNotOverlap(first, second)
end

local function assertNoOverlap(rect, others, label)
  for _, other in ipairs(others) do
    Assert.isFalse(
      rectanglesOverlap(rect, other.rect),
      label .. " must not overlap " .. other.label .. " or the chrome check is confounded"
    )
  end
end

-- The browse lower pane composites source-derived chrome over the generated
-- browse background: empty item cells preserve the background
-- pixel-for-pixel, the generated item focus occupies its source-derived
-- destination over the selected cell, and the generated Cancel label paints
-- inside the Cancel rectangle with its own focus treatment. Every rectangle
-- and visual comes from the generated manifest; the selected background is
-- the anchor. Overlaps between sampled regions and other draws fail loudly
-- instead of silently weakening the comparison.
function T.browse_lower_pane_composites_source_derived_chrome(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local interactive = assert(manifest.interactive, versionId .. " carries the interactive pane")
    local pocket = twoPockets(manifest, versionId)
    local heroStatus = heroStatusAt(manifest, pocket, 6)
    local record = presentation(firstIcon, secondIcon, heroStatus)
    local composed = render(scope, owned, record, layout)
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")

    local browse = browseVariant(manifest, record.pocket, 2, versionId)
    local backdrop = decodeImage(scope, cacheFs, browse.image, versionId .. " browse background")
    local backdropOffset = browse.offset or { x = 0, y = 0 }
    local function backdropPixel(hostX, hostY)
      local bx = hostX - interactiveFrame.x - backdropOffset.x
      local by = hostY - interactiveFrame.y - backdropOffset.y
      if bx < 0 or by < 0 or bx >= backdrop:getWidth() or by >= backdrop:getHeight() then
        return nil
      end
      local red, green, blue, alpha = backdrop:getPixel(bx, by)
      return { quantize(red), quantize(green), quantize(blue), quantize(alpha) }
    end
    local function composedPixel(hostX, hostY)
      local red, green, blue, alpha = composed:getPixel(hostX, hostY)
      return { quantize(red), quantize(green), quantize(blue), quantize(alpha) }
    end
    local function assertMatchesBackdrop(hostX, hostY, label)
      local expected = backdropPixel(hostX, hostY)
      Assert.notNil(expected, label .. " maps inside the generated background at " .. hostX .. "," .. hostY)
      local actual = composedPixel(hostX, hostY)
      Assert.deepEqual(actual, assert(expected), label .. " preserves the background at " .. hostX .. "," .. hostY)
    end

    local tabs = assert(interactive.pocketTabs, versionId .. " carries the pocket tabs")
    local tabFootprints = {}
    for index, rect in ipairs(assert(tabs.rects, versionId .. " carries tab rectangles")) do
      tabFootprints[#tabFootprints + 1] = {
        rect = visualRect(rect, assert(tabs.normal[index], versionId .. " carries normal tab " .. index)),
        label = "normal tab " .. index,
      }
    end
    local pocketRecords = pockets()
    local selectedTabIndex = nil
    for index, entry in ipairs(pocketRecords) do
      if entry.pocket == record.pocket then
        selectedTabIndex = index
      end
    end
    Assert.notNil(selectedTabIndex, versionId .. " resolves the selected tab for " .. tostring(record.pocket))
    local slots = assert(interactive.itemSlots.slots, versionId .. " carries item slot rectangles")
    local focus = assert(interactive.focus, versionId .. " carries its generated focus")
    local itemFocus = assert(focus.items, versionId .. " carries its item focus")
    Assert.equal(#itemFocus.targets, 6, versionId .. " targets one item focus per visible cell")
    local itemOffset = itemFocus.visual.offset or { x = 0, y = 0 }
    local firstTarget = assert(itemFocus.targets[1], versionId .. " targets its first item cell")
    local focusFootprint = {
      x = firstTarget.x + itemOffset.x,
      y = firstTarget.y + itemOffset.y,
      width = itemFocus.visual.width,
      height = itemFocus.visual.height,
      label = "selection focus",
    }
    local cancelGeometry = assert(interactive.cancel, versionId .. " carries its cancel geometry")
    local cancelRect = assert(cancelGeometry.rect, versionId .. " carries its cancel control rectangle")
    local cancelTextRect = assert(cancelGeometry.textRect, versionId .. " carries its cancel text window")
    local pageRect = assert(interactive.pageIndicator.rect, versionId .. " carries its page rectangle")
    local drawnRegions = {}
    for _, footprint in ipairs(tabFootprints) do
      drawnRegions[#drawnRegions + 1] = footprint
    end
    -- The selection focus footprint is excluded here: it may legitimately
    -- extend over neighboring empty cells, and the pixel loop below skips
    -- its pixels explicitly.
    drawnRegions[#drawnRegions + 1] = { rect = cancelRect, label = "cancel" }
    drawnRegions[#drawnRegions + 1] = { rect = pageRect, label = "page" }

    -- Empty cells preserve the generated background pixel-for-pixel: no
    -- icon, name, quantity, or chrome paints over them. Pixels inside the
    -- selected cell's focus footprint are the focus proof below, not
    -- background evidence here.
    local function inFocusFootprint(x, y)
      return x >= focusFootprint.x
        and y >= focusFootprint.y
        and x < focusFootprint.x + focusFootprint.width
        and y < focusFootprint.y + focusFootprint.height
    end
    local emptyChecked = 0
    for index = 3, 6 do
      local rect = assert(slots[index].rect, versionId .. " carries cell rectangle " .. index)
      assertNoOverlap(rect, drawnRegions, versionId .. " empty cell " .. index)
      for y = rect.y, rect.y + rect.height - 1 do
        for x = rect.x, rect.x + rect.width - 1 do
          if not inFocusFootprint(x, y) then
            assertMatchesBackdrop(interactiveFrame.x + x, interactiveFrame.y + y, versionId .. " empty cell " .. index)
            emptyChecked = emptyChecked + 1
          end
        end
      end
    end
    Assert.isTrue(emptyChecked > 0, versionId .. " samples empty-cell background pixels")

    -- Item focus is the generated source visual at the selected target: a
    -- second render with item focus off differs inside that footprint and
    -- matches exactly in a disjoint cell, so the visual paints and never
    -- bleeds.
    local unfocusedRecord = presentation(firstIcon, secondIcon, heroStatus, { focus = "cancel" })
    local unfocused = render(scope, owned, unfocusedRecord, layout)
    local focusRegion = {
      x = interactiveFrame.x + focusFootprint.x,
      y = interactiveFrame.y + focusFootprint.y,
      width = focusFootprint.width,
      height = focusFootprint.height,
    }
    Assert.isTrue(
      regionDistance(composed, unfocused, focusRegion, 1) > 0,
      versionId .. " item focus paints inside its generated footprint"
    )
    local distantRect = nil
    for index = 3, 6 do
      local rect = assert(slots[index].rect, versionId .. " carries cell rectangle " .. index)
      if rectanglesDoNotOverlap(rect, focusFootprint) then
        distantRect = rect
        break
      end
    end
    local distant = assert(distantRect, versionId .. " resolves an empty cell disjoint from the focus footprint")
    Assert.equal(
      regionDistance(composed, unfocused, {
        x = interactiveFrame.x + distant.x,
        y = interactiveFrame.y + distant.y,
        width = distant.width,
        height = distant.height,
      }, 1),
      0,
      versionId .. " item focus never paints outside its footprint"
    )

    -- The generated Cancel label paints inside the Cancel text window: the
    -- region differs from the bare background there.
    local cancelLabel = assert(
      interactive.text and interactive.text.actions and interactive.text.actions.cancel,
      versionId .. " carries its generated cancel label"
    )
    Assert.isTrue(type(cancelLabel) == "string" and cancelLabel ~= "", versionId .. " labels Cancel from source")
    local cancelChanged = 0
    for y = cancelTextRect.y, cancelTextRect.y + cancelTextRect.height - 1 do
      for x = cancelTextRect.x, cancelTextRect.x + cancelTextRect.width - 1 do
        local expected = backdropPixel(interactiveFrame.x + x, interactiveFrame.y + y)
        if expected ~= nil then
          local actual = composedPixel(interactiveFrame.x + x, interactiveFrame.y + y)
          if actual[1] ~= expected[1] or actual[2] ~= expected[2] or actual[3] ~= expected[3] then
            cancelChanged = cancelChanged + 1
          end
        end
      end
    end
    Assert.isTrue(cancelChanged > 0, versionId .. " paints the generated Cancel label in its rectangle")

    -- Cancel focus is the generated source visual at its target: the
    -- Cancel-focused render differs from the item-focused render inside
    -- that footprint.
    local cancelFocus = assert(focus.cancel, versionId .. " carries its cancel focus")
    local cancelTarget = assert(cancelFocus.target, versionId .. " targets its cancel control")
    local cancelOffset = cancelFocus.visual.offset or { x = 0, y = 0 }
    Assert.isTrue(regionDistance(composed, unfocused, {
      x = interactiveFrame.x + cancelTarget.x + cancelOffset.x,
      y = interactiveFrame.y + cancelTarget.y + cancelOffset.y,
      width = cancelFocus.visual.width,
      height = cancelFocus.visual.height,
    }, 1) > 0, versionId .. " cancel focus paints inside its generated footprint")
  end
end

-- A partially filled page exposes the dashed empty chrome of its own count
-- variant: trailing empty cells match the decoded count-3 background
-- pixel-for-pixel, while a full page paints populated chrome over the same
-- region. Every background comes from the generated manifest.
function T.mixed_occupancy_uses_its_own_count_chrome(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local interactive = assert(manifest.interactive, versionId .. " carries the interactive pane")
    local pocket = twoPockets(manifest, versionId)
    local heroStatus = heroStatusAt(manifest, pocket, 6)
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")
    local slots = assert(interactive.itemSlots.slots, versionId .. " carries item slot rectangles")
    local focus = assert(interactive.focus, versionId .. " carries its generated focus")
    local itemFocus = assert(focus.items, versionId .. " carries its item focus")
    local itemOffset = itemFocus.visual.offset or { x = 0, y = 0 }
    local firstTarget = assert(itemFocus.targets[1], versionId .. " targets its first item cell")
    local focusFootprint = {
      x = firstTarget.x + itemOffset.x,
      y = firstTarget.y + itemOffset.y,
      width = itemFocus.visual.width,
      height = itemFocus.visual.height,
    }
    local function inFocusFootprint(x, y)
      return x >= focusFootprint.x
        and y >= focusFootprint.y
        and x < focusFootprint.x + focusFootprint.width
        and y < focusFootprint.y + focusFootprint.height
    end

    local partial = {
      makeSlot("SMOKE_ITEM_A", "Smoke A", firstIcon, 5, nil),
      makeSlot("SMOKE_ITEM_B", "Smoke B", secondIcon, 3, nil),
      makeSlot("SMOKE_ITEM_C", "Smoke C", firstIcon, 1, nil),
      emptyCell(4),
      emptyCell(5),
      emptyCell(6),
    }
    local partialRecord =
      presentation(firstIcon, secondIcon, heroStatus, { visibleSlots = partial, selected = partial[1] })
    local partialRender = render(scope, owned, partialRecord, layout)
    local variant = browseVariant(manifest, partialRecord.pocket, 3, versionId)
    local backdrop = decodeImage(scope, cacheFs, variant.image, versionId .. " count-3 browse background")
    local backdropOffset = variant.offset or { x = 0, y = 0 }
    local matched = 0
    for index = 4, 6 do
      local rect = assert(slots[index].rect, versionId .. " carries cell rectangle " .. index)
      for y = rect.y, rect.y + rect.height - 1 do
        for x = rect.x, rect.x + rect.width - 1 do
          if not inFocusFootprint(x, y) then
            local bx, by = x - backdropOffset.x, y - backdropOffset.y
            if bx >= 0 and by >= 0 and bx < backdrop:getWidth() and by < backdrop:getHeight() then
              local r1, g1, b1, a1 = partialRender:getPixel(interactiveFrame.x + x, interactiveFrame.y + y)
              local r2, g2, b2, a2 = backdrop:getPixel(bx, by)
              Assert.equal(quantize(r1), quantize(r2), versionId .. " partial cell keeps the count-3 red")
              Assert.equal(quantize(g1), quantize(g2), versionId .. " partial cell keeps the count-3 green")
              Assert.equal(quantize(b1), quantize(b2), versionId .. " partial cell keeps the count-3 blue")
              Assert.equal(quantize(a1), quantize(a2), versionId .. " partial cell keeps the count-3 alpha")
              matched = matched + 1
            end
          end
        end
      end
    end
    Assert.isTrue(matched > 0, versionId .. " samples dashed empty-cell background pixels")

    local full = {
      makeSlot("SMOKE_ITEM_A", "Smoke A", firstIcon, 5, nil),
      makeSlot("SMOKE_ITEM_B", "Smoke B", secondIcon, 3, nil),
      makeSlot("SMOKE_ITEM_C", "Smoke C", firstIcon, 1, nil),
      makeSlot("SMOKE_ITEM_D", "Smoke D", secondIcon, 2, nil),
      makeSlot("SMOKE_ITEM_E", "Smoke E", firstIcon, 4, nil),
      makeSlot("SMOKE_ITEM_F", "Smoke F", secondIcon, 1, nil),
    }
    local fullRecord = presentation(firstIcon, secondIcon, heroStatus, { visibleSlots = full, selected = full[1] })
    local fullRender = render(scope, owned, fullRecord, layout)
    local left, top, right, bottom = nil, nil, nil, nil
    for index = 4, 6 do
      local rect = assert(slots[index].rect, versionId .. " carries cell rectangle " .. index)
      left = left and math.min(left, rect.x) or rect.x
      top = top and math.min(top, rect.y) or rect.y
      right = right and math.max(right, rect.x + rect.width) or rect.x + rect.width
      bottom = bottom and math.max(bottom, rect.y + rect.height) or rect.y + rect.height
    end
    Assert.isTrue(regionDistance(partialRender, fullRender, {
      x = interactiveFrame.x + left,
      y = interactiveFrame.y + top,
      width = right - left,
      height = bottom - top,
    }, 1) > 0, versionId .. " the full page paints populated chrome over the dashed cells")
  end
end

-- Tab focus never covers normal tab icon pixels: every opaque pixel of the
-- decoded normal artwork is identical between the focused and unfocused
-- renders for all eight pockets.
function T.focused_tabs_keep_their_icons_above_the_fill(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local interactive = assert(manifest.interactive, versionId .. " carries the interactive pane")
    local tabs = assert(interactive.pocketTabs, versionId .. " carries the pocket tabs")
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")
    for index, pocket in ipairs(pockets()) do
      local status = heroStatusAt(manifest, pocket.pocket, 0)
      local focused = render(scope, owned, presentation(firstIcon, secondIcon, status, { focus = "tabs" }), layout)
      local unfocused = render(scope, owned, presentation(firstIcon, secondIcon, status, { focus = "items" }), layout)
      local normalRect = visualRect(tabs.rects[index], tabs.normal[index])
      local normal = decodeImage(scope, cacheFs, tabs.normal[index].image, versionId .. " normal tab " .. index)
      local compared = 0
      for y = 0, normalRect.height - 1 do
        for x = 0, normalRect.width - 1 do
          if x < normal:getWidth() and y < normal:getHeight() then
            local _, _, _, alpha = normal:getPixel(x, y)
            if alpha > 0.5 then
              local hostX = interactiveFrame.x + math.floor(normalRect.x + x)
              local hostY = interactiveFrame.y + math.floor(normalRect.y + y)
              local r1, g1, b1, a1 = focused:getPixel(hostX, hostY)
              local r2, g2, b2, a2 = unfocused:getPixel(hostX, hostY)
              Assert.equal(quantize(r1), quantize(r2), versionId .. " tab " .. index .. " keeps its icon red")
              Assert.equal(quantize(g1), quantize(g2), versionId .. " tab " .. index .. " keeps its icon green")
              Assert.equal(quantize(b1), quantize(b2), versionId .. " tab " .. index .. " keeps its icon blue")
              Assert.equal(quantize(a1), quantize(a2), versionId .. " tab " .. index .. " keeps its icon alpha")
              compared = compared + 1
            end
          end
        end
      end
      Assert.isTrue(compared > 0, versionId .. " normal tab " .. index .. " carries opaque icon pixels")
    end
  end
end

-- The Cancel label paints centered on its source label area: the label area
-- centers on X=224, the label inks inside the measured advance box at the
-- source text-window top, and the label actually paints.
function T.cancel_label_paints_centered_on_its_source_label_area(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local interactive = assert(manifest.interactive, versionId .. " carries the interactive pane")
    local pocket = twoPockets(manifest, versionId)
    local heroStatus = heroStatusAt(manifest, pocket, 6)
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")
    local cancelGeometry = assert(interactive.cancel, versionId .. " carries its cancel geometry")
    local labelRect = assert(cancelGeometry.labelRect, versionId .. " carries its cancel label area")
    Assert.equal(labelRect.x * 2 + labelRect.width, 448, versionId .. " centers its Cancel label area on X=224")
    local label = assert(
      interactive.text and interactive.text.actions and interactive.text.actions.cancel,
      versionId .. " carries its generated cancel label"
    )
    local content = label:gsub("{[^}]*}", "")
    local width = owned.text:textWidth(content)
    local penX = labelRect.x + (labelRect.width - width) / 2
    local record = presentation(firstIcon, secondIcon, heroStatus)
    local composed = render(scope, owned, record, layout)
    local variant = browseVariant(manifest, record.pocket, 2, versionId)
    local backdrop = decodeImage(scope, cacheFs, variant.image, versionId .. " count-2 browse background")
    local backdropOffset = variant.offset or { x = 0, y = 0 }
    local cancelRect = assert(cancelGeometry.rect, versionId .. " carries its cancel control rectangle")
    local left, top, right, bottom, changed = nil, nil, nil, nil, 0
    for y = cancelRect.y, cancelRect.y + cancelRect.height - 1 do
      for x = cancelRect.x, cancelRect.x + cancelRect.width - 1 do
        local bx, by = x - backdropOffset.x, y - backdropOffset.y
        if bx >= 0 and by >= 0 and bx < backdrop:getWidth() and by < backdrop:getHeight() then
          local r1, g1, b1 = composed:getPixel(interactiveFrame.x + x, interactiveFrame.y + y)
          local r2, g2, b2 = backdrop:getPixel(bx, by)
          if quantize(r1) ~= quantize(r2) or quantize(g1) ~= quantize(g2) or quantize(b1) ~= quantize(b2) then
            left = left and math.min(left, x) or x
            top = top and math.min(top, y) or y
            right = right and math.max(right, x) or x
            bottom = bottom and math.max(bottom, y) or y
            changed = changed + 1
          end
        end
      end
    end
    Assert.isTrue(changed > 0, versionId .. " paints the Cancel label inside its control")
    Assert.isTrue(
      assert(left, versionId .. " finds the label ink") >= math.floor(penX) - 1,
      versionId .. " starts the label ink at its measured advance"
    )
    Assert.isTrue(
      assert(right, versionId .. " finds the label ink") <= math.ceil(penX + width) + 1,
      versionId .. " ends the label ink at its measured advance"
    )
    Assert.isTrue(
      assert(top, versionId .. " finds the label ink") >= labelRect.y,
      versionId .. " keeps the label ink below the source text-window top"
    )
    Assert.isTrue(
      assert(bottom, versionId .. " finds the label ink") < labelRect.y + labelRect.height,
      versionId .. " keeps the label ink inside the source label area"
    )
  end
end

-- The action menu carries the generated action focus at the selected
-- target: two renders differing only in the selected action differ inside
-- both affected footprints.
function T.action_focus_follows_the_selected_action(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local interactive = assert(manifest.interactive, versionId .. " carries the interactive pane")
    local focus = assert(interactive.focus, versionId .. " carries its generated focus")
    local actionFocus = assert(focus.actions, versionId .. " carries its action focus")
    Assert.equal(#actionFocus.targets, 4, versionId .. " targets one action focus per button")
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")
    local pocket = twoPockets(manifest, versionId)
    local heroStatus = heroStatusAt(manifest, pocket, 6)
    local first = render(
      scope,
      owned,
      presentation(firstIcon, secondIcon, heroStatus, {
        state = "action_menu",
        actions = { { id = "toss" }, { id = "move" }, { id = "cancel" } },
        selectedAction = 0,
      }),
      layout
    )
    local third = render(
      scope,
      owned,
      presentation(firstIcon, secondIcon, heroStatus, {
        state = "action_menu",
        actions = { { id = "toss" }, { id = "move" }, { id = "cancel" } },
        selectedAction = 2,
      }),
      layout
    )
    local offset = actionFocus.visual.offset or { x = 0, y = 0 }
    for _, index in ipairs({ 1, 3 }) do
      local target = assert(actionFocus.targets[index], versionId .. " targets action " .. index)
      Assert.isTrue(regionDistance(first, third, {
        x = interactiveFrame.x + target.x + offset.x,
        y = interactiveFrame.y + target.y + offset.y,
        width = actionFocus.visual.width,
        height = actionFocus.visual.height,
      }, 1) > 0, versionId .. " moving the selection changes action footprint " .. index)
    end
  end
end

-- The occupied item row paints its icon and its name inside their own
-- generated geometry: emptying the row restores both regions, so neither
-- the icon nor the label borrows the other's window.
function T.item_row_paints_icon_and_name_inside_their_own_geometry(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the bag smoke needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = manifestFor(versionId)
    local layout = twoPaneLayout(manifest)
    local firstIcon, secondIcon = iconKeys(cacheFs, versionId)
    local owned = owners(cacheFs, manifest, scope)
    local interactive = assert(manifest.interactive, versionId .. " carries the interactive pane")
    local interactiveFrame = assert(layout.interactive.frame, versionId .. " places the interactive pane")
    local pocket = twoPockets(manifest, versionId)
    local heroStatus = heroStatusAt(manifest, pocket, 6)
    local occupied = render(scope, owned, presentation(firstIcon, secondIcon, heroStatus), layout)
    local cleared = presentation(firstIcon, secondIcon, heroStatus)
    cleared.visibleSlots = { emptyCell(1), emptyCell(2), emptyCell(3), emptyCell(4), emptyCell(5), emptyCell(6) }
    cleared.selected = nil
    local vacant = render(scope, owned, cleared, layout)
    local slot = assert(
      assert(interactive.itemSlots.slots, versionId .. " carries item slot rectangles")[1],
      versionId .. " carries its first item cell"
    )
    local center = assert(slot.iconCenter, versionId .. " carries its first icon center")
    local textRect = assert(slot.textRect, versionId .. " carries its first text window")
    local nameAt = assert(slot.nameAt, versionId .. " carries its first name anchor")
    Assert.isTrue(regionDistance(occupied, vacant, {
      x = interactiveFrame.x + math.floor(center.x - 16),
      y = interactiveFrame.y + math.floor(center.y - 16),
      width = 32,
      height = 32,
    }, 1) > 0, versionId .. " the icon paints inside its generated center")
    Assert.isTrue(regionDistance(occupied, vacant, {
      x = interactiveFrame.x + textRect.x + nameAt.x,
      y = interactiveFrame.y + textRect.y + nameAt.y,
      width = 48,
      height = 16,
    }, 1) > 0, versionId .. " the name paints inside its generated text window")
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

local function soulSilverCache(context)
  local versions = readyVersions()
  local found = false
  for _, versionId in ipairs(versions) do
    found = found or versionId == "soulsilver"
  end
  if not found then
    context:skip("the hero smoke needs the warmed SoulSilver derived cache")
  end
  return manifestFor("soulsilver")
end

local function canonicalHeroPlacement()
  return {
    frame = { x = 0, y = 0, width = 256, height = 192 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
  }
end

local function drawSolid(scope, red, green, blue)
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(red, green, blue, 1)
  love.graphics.setCanvas()
  return canvas
end

function T.real_model_stages_use_real_culling_and_preserve_geometry_occupancy(scope, context)
  local cacheFs, manifest = soulSilverCache(context)
  local stages = { "base", "material", "joint", "joint_pattern", "full" }
  local captures = {}
  for _, stage in ipairs(stages) do
    local heroRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
    captures[stage] = drawRealizedStage(scope, heroRenderer, "male", stage)
  end

  local baseMask = occupiedPixels(captures.base)
  assertCanonicalBounds(bounds(captures.base, false), "the base hero alpha coverage")

  for _, stage in ipairs({ "material", "joint", "joint_pattern", "full" }) do
    local stageMask = occupiedPixels(captures[stage])
    for y = 0, 191 do
      for x = 0, 255 do
        Assert.equal(
          stageMask[y][x],
          baseMask[y][x],
          stage .. " preserves the base hero alpha mask at " .. x .. "," .. y
        )
      end
    end
  end

  assertCanonicalBounds(bounds(captures.full, false), "the full hero alpha coverage")
  assertCanonicalBounds(bounds(captures.full, true), "the full hero material coverage")
end

-- The full hero stage carries lit source material color instead of a
-- near-black silhouette. The retail reference shows the hero's skin,
-- garments, and bag as brightly lit surfaces across most of the
-- silhouette, so a correct full-stage capture carries thousands of
-- clearly-lit pixels with real chroma from the source textures, while the
-- current dark capture carries only a few hundred dim highlights. The
-- floors below are source-observation margins (a retail-lit silhouette
-- against the current few hundred dim pixels), not values fitted to any
-- one capture. Both the opening pocket and a second pocket state must be
-- lit, and a repeated realization of the same pocket state is identical.
function T.full_hero_stage_carries_lit_source_material_pixels(scope, context)
  local cacheFs, manifest = soulSilverCache(context)
  local firstPocket, secondPocket = twoPockets(manifest, "soulsilver")
  for _, pocket in ipairs({ firstPocket, secondPocket }) do
    local firstRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
    local first = drawRealizedStage(scope, firstRenderer, "male", "full", pocket)
    assertCanonicalBounds(bounds(first, false), "the male " .. pocket .. " full-stage alpha coverage")
    local material = stageMaterialStats(first)
    Assert.isTrue(
      material.lit >= 2000,
      "the male " .. pocket .. " hero carries lit source material, got " .. material.lit
    )
    Assert.isTrue(
      material.chromatic >= 800,
      "the male " .. pocket .. " hero carries chromatic source material, got " .. material.chromatic
    )
    local secondRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
    local second = drawRealizedStage(scope, secondRenderer, "male", "full", pocket)
    Assert.equal(
      imageDataDigest(second),
      imageDataDigest(first),
      "the male " .. pocket .. " full stage realizes deterministically"
    )
  end
end

-- Female joint and pattern clips must not explode the silhouette: every
-- animated stage stays within a bounded growth of the base silhouette
-- inside the canonical target. The current female joint clip smears one
-- texture across the whole 256x192 target (full-canvas coverage against a
-- few-thousand-pixel base). Un-exploding must not leave the female hero
-- dark either: she shares the male lighting and materials, so her full
-- stage carries the same lit-population floor.
function T.female_joint_stages_preserve_the_base_silhouette(scope, context)
  local cacheFs, manifest = soulSilverCache(context)
  local baseRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local base = drawRealizedStage(scope, baseRenderer, "female", "base")
  local baseRegion = bounds(base, false)
  assertCanonicalBounds(baseRegion, "the female base alpha coverage")
  for _, stage in ipairs({ "joint", "joint_pattern", "full" }) do
    local renderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
    local capture = drawRealizedStage(scope, renderer, "female", stage)
    local region = bounds(capture, false)
    assertCanonicalBounds(region, "the female " .. stage .. " alpha coverage")
    Assert.isTrue(
      region.count <= baseRegion.count * 2,
      "the female "
        .. stage
        .. " stage does not explode the silhouette, got "
        .. region.count
        .. " over base "
        .. baseRegion.count
    )
  end
  local fullRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local fullMaterial = stageMaterialStats(drawRealizedStage(scope, fullRenderer, "female", "full"))
  Assert.isTrue(fullMaterial.lit >= 2000, "the female full stage carries lit source material, got " .. fullMaterial.lit)
end

-- Male and female full stages realize their own distinct descriptors: the
-- two gender renders differ across the canonical target.
function T.male_and_female_full_stages_render_distinct_descriptors(scope, context)
  local cacheFs, manifest = soulSilverCache(context)
  local maleRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local male = drawRealizedStage(scope, maleRenderer, "male", "full")
  local femaleRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local female = drawRealizedStage(scope, femaleRenderer, "female", "full")
  Assert.isTrue(
    regionDistance(male, female, { x = 0, y = 0, width = 256, height = 192 }, 2) > 100,
    "the male and female full stages render distinct descriptors"
  )
end

function T.transparent_model_pixels_preserve_a_prepainted_sentinel(scope, context)
  local cacheFs, manifest = soulSilverCache(context)
  local heroRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local layerCanvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(layerCanvas)
  love.graphics.clear(0, 0, 0, 0)
  heroRenderer:draw("male", heroStatusAt(manifest, "items", 0), canonicalHeroPlacement())
  love.graphics.setCanvas()
  local layer = scope:own(layerCanvas:newImageData())
  local baselineCanvas = drawSolid(scope, 0.17, 0.29, 0.61)
  local baseline = scope:own(baselineCanvas:newImageData())

  local composedCanvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(composedCanvas)
  love.graphics.clear(0.17, 0.29, 0.61, 1)
  heroRenderer:draw("male", heroStatusAt(manifest, "items", 0), canonicalHeroPlacement())
  love.graphics.setCanvas()
  local composed = scope:own(composedCanvas:newImageData())

  for y = 0, 191 do
    for x = 0, 255 do
      local _, _, _, alpha = layer:getPixel(x, y)
      if alpha == 0 then
        local br, bg, bb, ba = baseline:getPixel(x, y)
        local cr, cg, cb, ca = composed:getPixel(x, y)
        Assert.equal(
          math.floor(cr * 255 + 0.5),
          math.floor(br * 255 + 0.5),
          "the red sentinel survives at every transparent model pixel"
        )
        Assert.equal(
          math.floor(cg * 255 + 0.5),
          math.floor(bg * 255 + 0.5),
          "the green sentinel survives at every transparent model pixel"
        )
        Assert.equal(
          math.floor(cb * 255 + 0.5),
          math.floor(bb * 255 + 0.5),
          "the blue sentinel survives at every transparent model pixel"
        )
        Assert.equal(
          math.floor(ca * 255 + 0.5),
          math.floor(ba * 255 + 0.5),
          "the alpha sentinel survives at every transparent model pixel"
        )
      end
    end
  end
end

-- The integrated Bag composition keeps the generated gender backdrop visible
-- wherever the transparent hero model contributes no pixel. The description
-- frame is a separate generated foreground and is excluded wherever its
-- decoded pixels are nontransparent; every other model-free pixel is an exact
-- source-derived check.
function T.integrated_hero_preserves_generated_backdrop_in_model_free_pixels(scope, context)
  local cacheFs, manifest = soulSilverCache(context)
  local layout = twoPaneLayout(manifest)
  local firstIcon, secondIcon = iconKeys(cacheFs, "soulsilver")
  local owned = owners(cacheFs, manifest, scope)
  local pocket = twoPockets(manifest, "soulsilver")
  local status = heroStatusAt(manifest, pocket, 0)
  local placement = canonicalHeroPlacement()
  local layerCanvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(layerCanvas)
  love.graphics.clear(0, 0, 0, 0)
  owned.heroRenderer:draw("male", status, placement)
  love.graphics.setCanvas()
  local layer = scope:own(layerCanvas:newImageData())
  local composed = render(scope, owned, presentation(firstIcon, secondIcon, status), layout)
  local backdrop = decodeImage(scope, cacheFs, manifest.hero.background.male.image, "male backdrop")
  local foreground = decodeImage(scope, cacheFs, manifest.hero.description.frame.image, "description frame foreground")
  local modelFree = 0

  for y = 0, 191 do
    for x = 0, 255 do
      local _, _, _, modelAlpha = layer:getPixel(x, y)
      local _, _, _, foregroundAlpha = foreground:getPixel(x, y)
      if modelAlpha == 0 and foregroundAlpha == 0 then
        modelFree = modelFree + 1
        local cr, cg, cb, ca = composed:getPixel(x, y)
        local br, bg, bb, ba = backdrop:getPixel(x, y)
        Assert.equal(quantize(cr), quantize(br), "the integrated hero preserves the generated backdrop red channel")
        Assert.equal(quantize(cg), quantize(bg), "the integrated hero preserves the generated backdrop green channel")
        Assert.equal(quantize(cb), quantize(bb), "the integrated hero preserves the generated backdrop blue channel")
        Assert.equal(quantize(ca), quantize(ba), "the integrated hero preserves the generated backdrop alpha channel")
      end
    end
  end
  Assert.isTrue(modelFree > 0, "the generated hero has model-free pixels outside its foreground")
end

function T.real_hero_rendering_has_a_repeatable_nonempty_digest(scope, context)
  local cacheFs, manifest = soulSilverCache(context)
  local firstRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local secondRenderer = scope:own(BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest }))
  local first = drawRealizedStage(scope, firstRenderer, "male", "full")
  local second = drawRealizedStage(scope, secondRenderer, "male", "full")
  local firstDigest = imageDataDigest(first)
  local secondDigest = imageDataDigest(second)
  Assert.isTrue(firstDigest ~= 0, "the real hero digest is nonempty")
  Assert.equal(secondDigest, firstDigest, "the same real-cache hero frame has a stable digest")
end

function T.graphics_rejects_fake_non_four_light_manifests(_, context)
  local cacheFs, manifest = soulSilverCache(context)
  for _, count in ipairs({ 3, 5 }) do
    local original = manifest.hero.presentation.lights.count
    manifest.hero.presentation.lights.count = count
    Assert.throws(function()
      BagHeroRenderer.new({ cacheFs = cacheFs, manifest = manifest })
    end, "the real graphics path rejects fake light count " .. count)
    manifest.hero.presentation.lights.count = original
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
