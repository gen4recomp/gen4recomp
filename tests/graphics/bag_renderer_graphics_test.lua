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

local function visualRect(rect, visual)
  local offset = visual.offset or { x = 0, y = 0 }
  local x = rect.x + rect.width / 2 + offset.x - visual.width / 2
  local y = rect.y + rect.height / 2 + offset.y - visual.height / 2
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

-- Each selected pocket overlays its generated selected visual over the normal
-- visual in that pocket's generated rectangle. Compare the exact source-pixel
-- difference with the exact difference between two real BagRenderer captures;
-- the baseline selection is chosen from a generated visual footprint that does
-- not overlap the target rectangle, so no fixed tab position, color, or
-- occupancy threshold is needed.
function T.all_pocket_tabs_render_the_source_selected_visual_in_their_rects(scope, context)
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
    Assert.isTrue(type(tabs.selected.image) == "string", versionId .. " selected tab is a static source visual")
    Assert.isNil(tabs.selected.frames, versionId .. " selected tab has no runtime frame timeline")
    local sourceSelected = decodeImage(scope, cacheFs, tabs.selected.image, versionId .. " selected tab")
    Assert.isTrue(hasOccupiedPixel(sourceSelected), versionId .. " selected tab has source occupancy")
    local pocketRecords = pockets()
    local captures = {}
    for index, pocket in ipairs(pocketRecords) do
      local status = heroStatusAt(manifest, pocket.pocket, 0)
      captures[index] = render(scope, owned, presentation(firstIcon, secondIcon, status), layout)
    end
    for index, pocket in ipairs(pocketRecords) do
      local baselineIndex
      for candidate = 1, #pocketRecords do
        if
          candidate ~= index
          and rectanglesDoNotOverlap(tabs.rects[index], visualRect(tabs.rects[candidate], tabs.selected))
        then
          baselineIndex = candidate
          break
        end
      end
      Assert.notNil(baselineIndex, versionId .. " has a non-overlapping generated baseline for tab " .. index)
      Assert.isTrue(regionDistance(captures[index], captures[assert(baselineIndex)], {
        x = interactiveFrame.x + tabs.rects[index].x,
        y = interactiveFrame.y + tabs.rects[index].y,
        width = tabs.rects[index].width,
        height = tabs.rects[index].height,
      }, 1) > 0, versionId .. " selected " .. pocket.pocket .. " changes pixels in its generated tab rect")
    end
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

function T.graphics_rejects_fake_non_four_light_manifests(scope, context)
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
