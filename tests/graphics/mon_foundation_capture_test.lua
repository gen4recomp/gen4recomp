-- Focused captures for the integrated mon flow: a synthetic mixed six-slot
-- party, follower-variant portrait/icon selectors against the real atlases,
-- and a real party-application frame cycle. Starter selecting/confirmation
-- geometry is owned by the starter capture suite; representative
-- icon/portrait pixels by the manifest suite; this file covers what those
-- do not: full-party layout cases, variant distinctness, and the modal
-- frame replacing (not overlaying) field-attached surfaces.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PngWriter = require("libs.assets.src.PngWriter")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local function iconCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    image = MonCache.iconImagePath(),
    entries = {
      ["MON0/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
      },
    },
    representative = { "MON0/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(200, 40, 40, 255)
  end
  cache:write(MonCache.iconImagePath(), PngWriter.encode(64, 64, table.concat(pixels)))
  return cache
end

---@param slot0 integer
---@param overrides table<string, any>
---@return table<string, any>
local function occupiedSlot(slot0, overrides)
  local record = {
    slot = slot0,
    occupied = true,
    eligible = true,
    iconKey = "MON0/f0",
    displayName = "MON" .. slot0,
    level = 5,
    gender = "male",
    status = "ok",
    currentHp = 20,
    maxHp = 20,
    hpFraction = 1,
  }
  for key, value in pairs(overrides) do
    record[key] = value
  end
  return record
end

local function sixSlotView(cursorNode)
  return {
    open = true,
    mode = "view",
    action = "browsing",
    cursorNode = cursorNode,
    switchSource = nil,
    actionSelection = nil,
    view = {
      revision = 7,
      slots = {
        occupiedSlot(0, {}),
        occupiedSlot(1, { gender = "female", status = "poison", currentHp = 4, maxHp = 20, hpFraction = 0.2 }),
        occupiedSlot(2, { status = "burn", currentHp = 10, maxHp = 20, hpFraction = 0.5 }),
        occupiedSlot(3, { gender = "genderless", status = "sleep", currentHp = 20, maxHp = 20, hpFraction = 1 }),
        occupiedSlot(4, { status = "paralysis", currentHp = 1, maxHp = 20, hpFraction = 0.05 }),
        occupiedSlot(5, { status = "faint", currentHp = 0, maxHp = 20, hpFraction = 0 }),
      },
    },
    cancellable = true,
  }
end

local function opaqueCount(image, width, height)
  local found = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local _, _, _, a = image:getPixel(x, y)
      if a > 0.5 then
        found = found + 1
      end
    end
  end
  return found
end

function T.mixed_six_slot_party_paints_every_slot(scope)
  for _, size in ipairs({ { width = 320, height = 240 }, { width = 640, height = 480 } }) do
    local layout = PartyScreenLayout.resolve({ width = size.width, height = size.height, cancellable = true })
    Assert.equal(#layout.slotRects, 6, "all six slots resolve")
    for left = 1, 6 do
      for right = left + 1, 6 do
        local a, b = layout.slotRects[left], layout.slotRects[right]
        Assert.isTrue(
          a.x + a.width <= b.x or b.x + b.width <= a.x or a.y + a.height <= b.y or b.y + b.height <= a.y,
          "party slots never overlap"
        )
      end
    end
    local provider = MonIconAssetProvider.new(iconCache())
    local renderer = PartyScreenRenderer.new()
    local canvas = scope:own(love.graphics.newCanvas(size.width, size.height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(sixSlotView(5), layout, provider)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    Assert.isTrue(
      opaqueCount(image, size.width, size.height) > 0,
      "the full party paints visible surfaces at " .. size.width .. "x" .. size.height
    )
    -- The healthy lead keeps its slot surface; the damaged second slot
    -- keeps a red HP bar segment; the fainted last slot paints under the
    -- cursor without failing.
    local lead = layout.slotRects[1]
    local r, g, b, a = image:getPixel(math.floor(lead.x + 2), math.floor(lead.y + 2))
    Assert.near(r, 0.2, 0.06, "the lead slot surface paints")
    Assert.near(g, 0.2, 0.06)
    Assert.near(b, 0.28, 0.06)
    Assert.near(a, 1, 0.01)
    local ir, ig = image:getPixel(math.floor(lead.x + 6 + 4), math.floor(lead.y + lead.height / 2))
    Assert.near(ir, 200 / 255, 0.06, "the icon quad draws inside the lead slot")
    Assert.near(ig, 40 / 255, 0.06)
    local second = layout.slotRects[2]
    local hr, hg = image:getPixel(math.floor(second.x + 6 + 32 + 8 + 4), math.floor(second.y + second.height - 10 + 3))
    Assert.isTrue(hr > 0.7 and hg < 0.5, "low HP paints the red zone")
    provider:release()
  end

  -- Selection mode dims the ineligible slot while keeping its icon under
  -- dimmed chrome: a separate layout case the view capture cannot show.
  local size = { width = 640, height = 480 }
  local layout = PartyScreenLayout.resolve({ width = size.width, height = size.height, cancellable = true })
  local status = sixSlotView(0)
  status.mode = "select"
  status.view.slots[2].eligible = false
  local provider = MonIconAssetProvider.new(iconCache())
  local renderer = PartyScreenRenderer.new()
  local canvas = scope:own(love.graphics.newCanvas(size.width, size.height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(status, layout, provider)
  love.graphics.setCanvas()
  local image = scope:own(canvas:newImageData())
  Assert.isTrue(opaqueCount(image, size.width, size.height) > 0, "selection paints with dimmed chrome")
  provider:release()
end

local function atlasData(cache, manifestPath)
  local manifest = assert(cache:loadLua(manifestPath), "manifest must load: " .. manifestPath)
  local imageBytes = assert(cache:read(manifest.image), "atlas must be present: " .. tostring(manifest.image))
  local data = love.image.newImageData(love.filesystem.newFileData(imageBytes, manifest.image))
  return manifest, data
end

local function visiblePixels(data, rect)
  local count = 0
  for row = rect.y, rect.y + rect.height - 1 do
    for col = rect.x, rect.x + rect.width - 1 do
      local _, _, _, alpha = data:getPixel(col, row)
      if alpha > 0 then
        count = count + 1
      end
    end
  end
  return count
end

local function frameRect(entry)
  local frame = assert(entry.frames and entry.frames[1], "entries carry at least one frame")
  return { x = frame.x, y = frame.y, width = frame.width, height = frame.height }
end

-- Gender, shiny, and form variants of the journey species must address
-- distinct rendered frames: aliasing a variant to the wrong frame would
-- show the wrong mon in the starter and party screens. The representative
-- suite pins that frames exist; this pins that variants differ.
function T.follower_variant_selectors_address_distinct_rendered_pixels(_, _)
  local ready = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready = ready + 1
      local cache = CacheFs.forVersion(versionId)
      local portraits, portraitData = atlasData(cache, MonCache.portraitManifestPath())
      local function portraitRect(selector)
        local entry = assert(portraits.entries[selector], versionId .. " portrait resolves: " .. selector)
        return frameRect(entry)
      end
      for _, pair in ipairs({
        { "CHIKORITA/f0/male/plain", "CHIKORITA/f0/female/plain" },
        { "TOTODILE/f0/male/plain", "TOTODILE/f0/male/shiny" },
        { "UNOWN/f0/male/plain", "UNOWN/f5/male/plain" },
      }) do
        local first, second = portraitRect(pair[1]), portraitRect(pair[2])
        Assert.isTrue(
          first.x ~= second.x or first.y ~= second.y,
          versionId .. " " .. pair[1] .. " and " .. pair[2] .. " address distinct frames"
        )
        Assert.isTrue(visiblePixels(portraitData, first) > 0, versionId .. " " .. pair[1] .. " paints pixels")
        Assert.isTrue(visiblePixels(portraitData, second) > 0, versionId .. " " .. pair[2] .. " paints pixels")
      end
      portraitData:release()
      local icons, iconData = atlasData(cache, MonCache.iconManifestPath())
      local function iconRect(selector)
        local entry = assert(icons.entries[selector], versionId .. " icon resolves: " .. selector)
        return frameRect(entry)
      end
      local unownPlain, unownVariant = iconRect("UNOWN/f0"), iconRect("UNOWN/f1")
      Assert.isTrue(
        unownPlain.x ~= unownVariant.x or unownPlain.y ~= unownVariant.y,
        versionId .. " form icons address distinct frames"
      )
      Assert.isTrue(visiblePixels(iconData, unownPlain) > 0, versionId .. " UNOWN/f0 paints pixels")
      Assert.isTrue(visiblePixels(iconData, unownVariant) > 0, versionId .. " UNOWN/f1 paints pixels")
      iconData:release()
    end
  end
  Assert.isTrue(ready > 0, "derived-cache capability promised a ready game version")
end

-- A real presentation boot opens the party application through the
-- production menu, draws one settled modal frame, and closes it: the modal
-- surface replaces field-attached UI (production never draws both), and
-- closing leaves no stale modal behind. Pixels prove the frame; host status
-- proves the layering contract underneath it.
function T.party_application_frame_cycle_leaves_no_stale_modal(scope)
  local FieldState = require("game.hgss.src.field.FieldState")
  local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
  local FieldEventState = require("libs.hgss.src.field.FieldEventState")
  local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local MonsSave = require("libs.mons.src.MonsSave")
  local PlayTime = require("libs.hgss.src.save.PlayTime")

  local ready = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready = ready + 1
      local cacheFs = CacheFs.forVersion(versionId)
      local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
      local fontDef = FieldFontLoader.load(cacheFs)
      local service = HgssMonService.new({
        catalog = catalog,
        bucket = MonsSave.empty(catalog:fingerprint(), 7),
        profile = { name = "GOLD", gender = 0, trainerId = 1 },
        game = versionId,
        language = MonCache.loadCatalog(cacheFs).version.language,
        charmap = assert(fontDef.charmap, "production font carries the charmap"),
        -- Write-only interim met metadata (no summary/legality/script
        -- consumer reads it): the town map below carries id 60 in the
        -- generated world.
        mapSection = function()
          return 60
        end,
        date = { year = 2000, month = 1, day = 1 },
      })
      Assert.isTrue(
        service:giveMon({ species = "CHIKORITA", level = 5, location = 60 }),
        "the frame-cycle gift enters through the production service"
      )
      local game = {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = "MAP_NEW_BARK", fieldX = 10, fieldZ = 10, facing = "south" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = service:capture(),
      }
      local state = assert(FieldState.new(game, {}))
      local ok, err = xpcall(function()
        local runtime = assert(state.runtime)
        local function step()
          state:update(1 / 30)
        end
        local function waitFor(label, predicate, bound)
          for _ = 1, bound do
            if predicate() then
              return
            end
            step()
          end
          error("timed out waiting for " .. label, 0)
        end
        waitFor("field entry", function()
          -- Map entry completes only once presentation acknowledges it,
          -- which happens inside draw: pump both until the stage clears.
          state:draw()
          return runtime.session.mapEntryStage == nil
        end, 240)
        local function hostStatus()
          return runtime.applicationHost:status()
        end
        -- Source policy gates the party route on starter progression; the
        -- owned mon alone is not enough.
        do
          local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
          runtime.scripts.worldState:setFlag(FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER)
        end
        runtime:pressMenu()
        step()
        runtime:releaseMenu()
        waitFor("start menu", function()
          return hostStatus().phase == FieldApplicationHost.PHASES.menu
        end, 120)
        local function menuStatus()
          local status = hostStatus()
          Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the menu owns the tick")
          return assert(status.menu, "the menu phase exposes its controller")
        end
        local function cursorActionId(status)
          local position = assert(status.cursorSlotId, "menu status exposes the cursor") - 2
          for _, action in ipairs(assert(status.actions, "menu status lists actions")) do
            if action.position == position then
              return action.id
            end
          end
          error("menu cursor resolves to no visible action", 0)
        end
        for _ = 1, #menuStatus().actions + 1 do
          if cursorActionId(menuStatus()) == "vanilla.pokemon" then
            break
          end
          state:keypressed("s")
          step()
          state:keyreleased("s")
        end
        Assert.equal(cursorActionId(menuStatus()), "vanilla.pokemon", "an owned party offers its route")
        runtime.input:pressAction("key:return")
        step()
        runtime.input:releaseAction("key:return")
        waitFor("party application", function()
          return hostStatus().phase == FieldApplicationHost.PHASES.application
        end, 180)
        local shown = hostStatus()
        Assert.equal(shown.applicationId, "pokemon", "confirming the route launches the party screen")
        Assert.isNil(shown.menu, "the modal application owns the frame, not the menu")
        local width, height = love.graphics.getDimensions()
        local canvas = scope:own(love.graphics.newCanvas(width, height))
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 0)
        state:draw()
        love.graphics.setCanvas()
        local image = scope:own(canvas:newImageData())
        local settle = hostStatus()
        -- The host fade completes before the destination constructs: the
        -- application phase holds full cover over the world viewport, so
        -- the modal surface replaces the field frame with no abrupt cut
        -- and no stale world/UI underneath it.
        Assert.equal(settle.fadeAlpha, 1, "the application frame holds full fade cover")
        local rect = assert(settle.application.layout, "the party application presents its layout").slotRects[1]
        local r, g, b = image:getPixel(math.floor(rect.x + 2), math.floor(rect.y + 2))
        Assert.near(r, 0.2, 0.08, "the modal lead slot paints over the field frame")
        Assert.near(g, 0.2, 0.08)
        Assert.near(b, 0.28, 0.08)
        runtime:pressCancel()
        step()
        runtime:releaseCancel()
        waitFor("party close", function()
          local phase = hostStatus().phase
          return phase == FieldApplicationHost.PHASES.menu or phase == FieldApplicationHost.PHASES.closed
        end, 120)
        if hostStatus().phase == FieldApplicationHost.PHASES.menu then
          runtime:pressMenu()
          step()
          runtime:releaseMenu()
          waitFor("menu close", function()
            return hostStatus().phase == FieldApplicationHost.PHASES.closed
          end, 120)
        end
        local closed = hostStatus()
        Assert.equal(closed.phase, FieldApplicationHost.PHASES.closed, "closing returns to the field")
        Assert.isNil(closed.menu, "no menu survives the close")
        Assert.isNil(closed.application, "no application survives the close")
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 0)
        state:draw()
        love.graphics.setCanvas()
      end, debug.traceback)
      state:dispose()
      if not ok then
        error(err, 0)
      end
    end
  end
  Assert.isTrue(ready > 0, "derived-cache capability promised a ready game version")
end

return GraphicsSmoke.suite(T)
