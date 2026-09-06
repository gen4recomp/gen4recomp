-- Production-cache coverage for the integrated mon flow: follower-variant
-- portrait/icon selectors against the real atlases, and a real
-- party-application frame cycle through the production menu.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonCache = require("libs.assets.src.MonCache")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

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
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
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

  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
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
          local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
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
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
