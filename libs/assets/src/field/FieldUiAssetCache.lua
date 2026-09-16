-- Readiness, paths, and strict validation for the generated HGSS field-UI
-- class: one manifest (`ui.lua`) carrying the semantic surfaces and the
-- strict metadata sections, binary assets (PNG atlases) under the UI asset
-- root, and a completion marker written last with the ROM SHA-1 and producer
-- dependency hash. The manifest is the single mod-facing contract for
-- dialogue frames, signposts, the Start Menu, the Trainer Card, and the
-- normal naming chrome; it never
-- carries NARC/member ids. A UI class is ready only when the marker matches
-- exactly and every indexed file exists. Paths are cache-relative; all IO
-- goes through a CacheFs.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

local FieldUiAssetCache = {}

---@class FieldUiAssetCache.Asset
---@field image string
---@field width integer
---@field height integer

---@class FieldUiAssetCache.Manifest
---@field schema string
---@field assets table<string, FieldUiAssetCache.Asset>
---@field [string] table<string, unknown>

FieldUiAssetCache.FORMAT = Contract.fieldUi.cacheFormat
FieldUiAssetCache.SCHEMA = Contract.fieldUi.schema

-- The audited HGSS field-UI geometry is a generated-class invariant,
-- not a tunable: dialogue and signpost frame members carry 18 tiles (a
-- 144x8 strip) and every wayfinding member carries 24 tiles but is
-- persisted as a precomposed 48x32 final surface (6 columns x 4 rows).
-- The producer arranges the raw 24 tiles into that surface at build time;
-- runtime draws a single rect. The validator enforces the final 48x32
-- shape. The producer and validator consume these numbers from this one
-- protocol owner.
FieldUiAssetCache.GEOMETRY = {
  FRAME_TILES = 18,
  WAYFINDING_TILES = 24,
  WAYFINDING_COLUMNS = 6,
  WAYFINDING_ROWS = 4,
  WAYFINDING_WIDTH = 48,
  WAYFINDING_HEIGHT = 32,
}

-- The generated field-UI asset protocol ids: one constant table so the
-- producer, the cache validation, and the renderers never repeat the raw
-- strings.
FieldUiAssetCache.ASSET = {
  DIALOGUE_FRAME_TILES = "hgss.dialogue_frame.tiles",
  DIALOGUE_CONTINUE_CURSOR = "hgss.dialogue_continue_cursor",
  SIGNPOST_TILES = "hgss.signpost.tiles",
  SIGNPOST_WAYFINDING = "hgss.signpost.wayfinding",
  START_MENU_BACKGROUND = "hgss.start_menu.background",
  START_MENU_CURSOR = "hgss.start_menu.cursor",
  TRAINER_CARD_FRONT = "hgss.trainer_card.front",
  NAMING_SCREEN_BASE = "hgss.naming_screen.base",
  NAMING_SCREEN_PAGE_UPPER = "hgss.naming_screen.page_upper",
  NAMING_SCREEN_PAGE_LOWER = "hgss.naming_screen.page_lower",
  NAMING_SCREEN_PAGE_SYMBOLS = "hgss.naming_screen.page_symbols",
}

-- One error code for every malformed generated class: the manifest is the
-- single strict structural boundary, so all violations share the code while
-- the message names the exact broken field.
local MANIFEST_INVALID = "FIELD_UI_MANIFEST_INVALID"

local DATA_DIR = "data/generated/field/ui"
local ASSET_DIR = "assets/generated/field/ui"

function FieldUiAssetCache.dir()
  return DATA_DIR
end
function FieldUiAssetCache.assetDir()
  return ASSET_DIR
end
function FieldUiAssetCache.manifestPath()
  return DATA_DIR .. "/ui.lua"
end
function FieldUiAssetCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function FieldUiAssetCache.markerPath()
  return DATA_DIR .. "/complete"
end

function FieldUiAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldUiAssetCache.FORMAT, romSha1, depHash)
end

-- Strict manifest validation: required arrays, strict enums, and every
-- rectangle/size/index finite, integral, non-negative, and inside its
-- atlas. Returns nil, err on the first violation.

---@param manifest table<string, unknown>
---@return boolean, Errors.Error?
function FieldUiAssetCache.validateManifest(manifest)
  if type(manifest) ~= "table" then
    return false, Errors.new(MANIFEST_INVALID, "manifest is not a table", {})
  end
  if manifest.schema ~= FieldUiAssetCache.SCHEMA then
    return false,
      Errors.new(MANIFEST_INVALID, "manifest schema mismatch", {
        schema = manifest.schema,
        expected = FieldUiAssetCache.SCHEMA,
      })
  end
  if type(manifest.reference) ~= "table" or manifest.reference.width ~= 256 or manifest.reference.height ~= 192 then
    return false,
      Errors.new(MANIFEST_INVALID, "manifest reference must be the 256x192 field screen", {
        reference = manifest.reference,
      })
  end
  if type(manifest.assets) ~= "table" or next(manifest.assets) == nil then
    return false, Errors.new(MANIFEST_INVALID, "manifest assets must be a non-empty table", {})
  end
  local atlasSizes = {}
  for key, entry in pairs(manifest.assets) do
    if type(key) ~= "string" or key == "" then
      return false, Errors.new(MANIFEST_INVALID, "asset key must be a non-empty string", {})
    end
    if type(entry) ~= "table" or type(entry.image) ~= "string" or entry.image == "" then
      return false, Errors.new(MANIFEST_INVALID, "asset " .. key .. " must name an image path", { key = key })
    end
    local function sizeField(field)
      local v = entry[field]
      return type(v) == "number" and v % 1 == 0 and v >= 1
    end
    if not sizeField("width") or not sizeField("height") then
      return false,
        Errors.new(MANIFEST_INVALID, "asset " .. key .. " needs positive integral dimensions", {
          key = key,
        })
    end
    atlasSizes[key] = { width = entry.width, height = entry.height }
  end

  local function rectInAtlas(rect, atlasKey, what)
    if type(rect) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, what .. " must be a rectangle", { what = what })
    end
    for _, field in ipairs({ "x", "y", "width", "height" }) do
      local v = rect[field]
      if type(v) ~= "number" or v % 1 ~= 0 or v < 0 then
        return false,
          Errors.new(MANIFEST_INVALID, what .. " " .. field .. " must be a non-negative integer", {
            what = what,
            field = field,
          })
      end
    end
    if rect.width == 0 or rect.height == 0 then
      return false, Errors.new(MANIFEST_INVALID, what .. " must be non-empty", { what = what })
    end
    local atlas = atlasSizes[atlasKey]
    if not atlas or rect.x + rect.width > atlas.width or rect.y + rect.height > atlas.height then
      return false,
        Errors.new(MANIFEST_INVALID, what .. " escapes its atlas " .. atlasKey, {
          what = what,
          atlas = atlasKey,
        })
    end
    return true
  end

  -- A rect must be an exact HGSS strip (`width` x 8) inside its atlas.
  -- Dialogue/signpost frames are the 18-tile 144x8 row; wayfinding rects
  -- are validated separately as 48x32 final surfaces. The atlas-bound check
  -- additionally proves the rect is addressable in its PNG.
  local function stripInAtlas(rect, atlasKey, what, width)
    local ok, err = rectInAtlas(rect, atlasKey, what)
    if not ok then
      return false, err
    end
    if rect.width ~= width or rect.height ~= 8 then
      return false,
        Errors.new(MANIFEST_INVALID, what .. " must be the " .. width .. "x8 HGSS strip", {
          what = what,
          width = rect.width,
          height = rect.height,
        })
    end
    return true
  end

  local function section(name, checker)
    if type(manifest[name]) ~= "table" then
      return false,
        Errors.new(MANIFEST_INVALID, "manifest section " .. name .. " must be a table", {
          section = name,
        })
    end
    return checker(manifest[name])
  end

  local ok, err = section("dialogueFrames", function(s)
    if type(s.count) ~= "number" or s.count % 1 ~= 0 or s.count < 1 then
      return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.count must be a positive integer", {})
    end
    if type(s.frameTiles) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.frameTiles must be a table", {})
    end
    for frame = 0, s.count - 1 do
      local ok, err = stripInAtlas(
        s.frameTiles[frame],
        FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES,
        "frame " .. frame .. " tiles",
        FieldUiAssetCache.GEOMETRY.FRAME_TILES * 8
      )
      if not ok then
        return false, err
      end
    end
    local cursor = s.continueCursor
    if type(cursor) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.continueCursor must be a table", {})
    end
    local cursorAsset = cursor.asset
    local asset = atlasSizes[cursorAsset]
    if cursorAsset ~= FieldUiAssetCache.ASSET.DIALOGUE_CONTINUE_CURSOR or not asset then
      return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.continueCursor.asset is invalid", {})
    end
    if asset.width ~= 48 or asset.height ~= s.count * 16 then
      return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor atlas has invalid dimensions", {})
    end
    if type(cursor.cycle) ~= "table" or #cursor.cycle ~= 4 then
      return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor cycle is invalid", {})
    end
    for index, phase in ipairs({ 0, 1, 2, 1 }) do
      if cursor.cycle[index] ~= phase then
        return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor cycle is not source-faithful", {})
      end
    end
    if cursor.framePrinterTicks ~= 9 then
      return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor timing is invalid", {})
    end
    local placement = cursor.placement
    if
      type(placement) ~= "table"
      or placement.x ~= 240
      or placement.y ~= 168
      or placement.width ~= 16
      or placement.height ~= 16
    then
      return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor placement is invalid", {})
    end
    if type(cursor.styles) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor styles are missing", {})
    end
    for style = 0, s.count - 1 do
      local styleEntry = cursor.styles[style]
      if type(styleEntry) ~= "table" or type(styleEntry.phases) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, "dialogue continuation cursor style is missing", { style = style })
      end
      for phase = 0, 2 do
        local rect = styleEntry.phases[phase]
        local expected = { x = phase * 16, y = style * 16, width = 16, height = 16 }
        if
          type(rect) ~= "table"
          or rect.x ~= expected.x
          or rect.y ~= expected.y
          or rect.width ~= expected.width
          or rect.height ~= expected.height
        then
          return false,
            Errors.new(MANIFEST_INVALID, "dialogue continuation cursor phase is invalid", {
              style = style,
              phase = phase,
            })
        end
        local phaseOk, phaseErr = rectInAtlas(rect, cursorAsset, "dialogue continuation cursor phase")
        if not phaseOk then
          return false, phaseErr
        end
      end
    end
    return true
  end)
  if not ok then
    return false, err
  end

  local signpostsOk, signpostsErr = section("signposts", function(s)
    -- v5 schema requires textColors: the source palette slot assignments.
    if type(s.textColors) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "signposts.textColors must be a table", {})
    end
    local function validateSlot(slot, name)
      if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 15 then
        return false,
          Errors.new(MANIFEST_INVALID, "signposts.textColors." .. name .. " must be an integral slot 0..15", {
            name = name,
            value = slot,
          })
      end
      return true
    end
    local foregroundOk, foregroundErr = validateSlot(s.textColors.foreground, "foreground")
    if not foregroundOk then
      return false, foregroundErr
    end
    if s.textColors.foreground ~= 2 then
      return false,
        Errors.new(MANIFEST_INVALID, "signposts.textColors.foreground must be slot 2 (HGSS contract)", {
          value = s.textColors.foreground,
        })
    end
    local shadowOk, shadowErr = validateSlot(s.textColors.shadow, "shadow")
    if not shadowOk then
      return false, shadowErr
    end
    if s.textColors.shadow ~= 10 then
      return false,
        Errors.new(MANIFEST_INVALID, "signposts.textColors.shadow must be slot 10 (HGSS contract)", {
          value = s.textColors.shadow,
        })
    end
    local backgroundOk, backgroundErr = validateSlot(s.textColors.background, "background")
    if not backgroundOk then
      return false, backgroundErr
    end
    if s.textColors.background ~= 15 then
      return false,
        Errors.new(MANIFEST_INVALID, "signposts.textColors.background must be slot 15 (HGSS contract)", {
          value = s.textColors.background,
        })
    end

    if type(s.types) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "signposts.types must be a table", {})
    end
    for key, typeEntry in pairs(s.types) do
      if type(key) ~= "number" or key % 1 ~= 0 or key < 0 then
        return false, Errors.new(MANIFEST_INVALID, "signpost type keys must be non-negative integers", { key = key })
      end
      if type(typeEntry) ~= "table" or typeEntry.sourceType ~= key then
        return false,
          Errors.new(MANIFEST_INVALID, "signpost type entries must be keyed by their own sourceType", {
            key = key,
          })
      end

      -- v5: per-type palette (16 colors, 0..15, each with r/g/b 0..255).
      if type(typeEntry.palette) ~= "table" then
        return false,
          Errors.new(MANIFEST_INVALID, "signpost type " .. key .. " palette must be a table", {
            type = key,
          })
      end
      local function isValidComponent(val)
        return type(val) == "number" and val % 1 == 0 and val >= 0 and val <= 255
      end
      for slot = 0, 15 do
        local color = typeEntry.palette[slot]
        if color == nil then
          return false,
            Errors.new(MANIFEST_INVALID, "signpost type " .. key .. " palette slot " .. slot .. " is missing", {
              type = key,
              slot = slot,
            })
        end
        if
          type(color) ~= "table"
          or not isValidComponent(color.r)
          or not isValidComponent(color.g)
          or not isValidComponent(color.b)
        then
          return false,
            Errors.new(
              MANIFEST_INVALID,
              "signpost type " .. key .. " palette slot " .. slot .. " must have integral r/g/b 0..255",
              {
                type = key,
                slot = slot,
              }
            )
        end
      end
      -- Every slot 0..15 was checked above; any other key means the table
      -- carries more than the exact 16-entry palette the schema requires.
      local paletteKeyCount = 0
      for _ in pairs(typeEntry.palette) do
        paletteKeyCount = paletteKeyCount + 1
      end
      if paletteKeyCount ~= 16 then
        return false,
          Errors.new(MANIFEST_INVALID, "signpost type " .. key .. " palette must have exactly 16 entries (0..15)", {
            type = key,
            count = paletteKeyCount,
          })
      end

      -- v5: per-type frameTiles (must be exactly 144x8 in the tiles atlas).
      if type(typeEntry.frameTiles) ~= "table" then
        return false,
          Errors.new(MANIFEST_INVALID, "signpost type " .. key .. " frameTiles must be a table", {
            type = key,
          })
      end
      local frameTilesOk, frameTilesErr = stripInAtlas(
        typeEntry.frameTiles,
        FieldUiAssetCache.ASSET.SIGNPOST_TILES,
        "signpost type " .. key .. " frameTiles",
        FieldUiAssetCache.GEOMETRY.FRAME_TILES * 8
      )
      if not frameTilesOk then
        return false, frameTilesErr
      end

      if typeEntry.wayfinding ~= nil then
        -- A type either has per-map wayfinding or none: the producer omits
        -- the field for types without a map graphic, so an empty table is a
        -- producer bug, not a plausible contract state. Each wayfinding rect
        -- is a precomposed final 48x32 surface, not the old 192x8 strip.
        if type(typeEntry.wayfinding) ~= "table" or next(typeEntry.wayfinding) == nil then
          return false, Errors.new(MANIFEST_INVALID, "signpost wayfinding must be a non-empty per-map table", {})
        end
        for map, rect in pairs(typeEntry.wayfinding) do
          if type(map) ~= "number" or map % 1 ~= 0 or map < 0 then
            return false,
              Errors.new(MANIFEST_INVALID, "signpost wayfinding map keys must be non-negative integers", {
                map = map,
              })
          end
          local wayfindingOk, wayfindingErr =
            rectInAtlas(rect, FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING, "signpost wayfinding map " .. map)
          if not wayfindingOk then
            return false, wayfindingErr
          end
          if
            rect.width ~= FieldUiAssetCache.GEOMETRY.WAYFINDING_WIDTH
            or rect.height ~= FieldUiAssetCache.GEOMETRY.WAYFINDING_HEIGHT
          then
            return false,
              Errors.new(MANIFEST_INVALID, "signpost wayfinding map " .. map .. " must be the 48x32 final surface", {
                what = "signpost wayfinding map " .. map,
                width = rect.width,
                height = rect.height,
              })
          end
        end
      end
    end
    return true
  end)
  if not signpostsOk then
    return false, signpostsErr
  end

  local startMenuOk, startMenuErr = section("startMenu", function(s)
    local backgroundOk, backgroundErr =
      rectInAtlas(s.background, FieldUiAssetCache.ASSET.START_MENU_BACKGROUND, "start menu background")
    if not backgroundOk then
      return false, backgroundErr
    end
    if type(s.cursor) ~= "table" or type(s.cursor.frames) ~= "table" or #s.cursor.frames < 1 then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.cursor must carry at least one frame", {})
    end
    for _, frameEntry in ipairs(s.cursor.frames) do
      local cursorOk, cursorErr =
        rectInAtlas(frameEntry, FieldUiAssetCache.ASSET.START_MENU_CURSOR, "start menu cursor frame")
      if not cursorOk then
        return false, cursorErr
      end
      if type(frameEntry.duration) ~= "number" or frameEntry.duration % 1 ~= 0 or frameEntry.duration < 1 then
        return false, Errors.new(MANIFEST_INVALID, "cursor frame duration must be a positive integer", {})
      end
    end
    -- The producer compiles the HGSS touch surface: ten slots in a complete
    -- 1..10 grid (the touch handler maps touch ids 1..10). The manifest pins
    -- the dense grid so the controller never rediscovers slot assumptions.
    if type(s.slots) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.slots must be a table", {})
    end
    local slotCount = 0
    for _ in pairs(s.slots) do
      slotCount = slotCount + 1
    end
    if slotCount ~= 10 then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.slots must be exactly the ten-slot grid", {})
    end
    for id = 1, 10 do
      local slot = s.slots[id]
      if slot == nil then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.slots must be the dense 1..10 grid", {})
      end
      local slotOk, slotErr = rectInAtlas(slot, FieldUiAssetCache.ASSET.START_MENU_BACKGROUND, "start menu slot " .. id)
      if not slotOk then
        return false, slotErr
      end
    end
    if type(s.actionSurfaces) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.actionSurfaces must be a table", {})
    end
    for actionId, surface in pairs(s.actionSurfaces) do
      if type(actionId) ~= "string" or type(surface) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, "start menu action surfaces are malformed", {})
      end
      local actionOk, actionErr =
        rectInAtlas(surface, FieldUiAssetCache.ASSET.START_MENU_BACKGROUND, "start menu action " .. actionId)
      if not actionOk then
        return false, actionErr
      end
    end
    return true
  end)
  if not startMenuOk then
    return false, startMenuErr
  end

  local trainerCardOk, trainerCardErr = section("trainerCard", function(s)
    local frontOk, frontErr = rectInAtlas(s.front, FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT, "trainer card front")
    if not frontOk then
      return false, frontErr
    end
    return true
  end)
  if not trainerCardOk then
    return false, trainerCardErr
  end

  -- Normal naming chrome: one opaque 256x192 base plus exactly the three
  -- normal page overlays (upper, lower, symbols), each 256x112, drawn at the
  -- canonical y=80 placement over the base. Every entry references its image
  -- through the shared asset index by semantic id; the manifest carries no
  -- source archive or member identities.
  local namingOk, namingErr = section("namingScreen", function(s)
    if type(s.base) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.base must be a table", {})
    end
    local baseAsset = atlasSizes[s.base.asset]
    if type(s.base.asset) ~= "string" or not baseAsset then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.base must reference an indexed asset", {})
    end
    if s.base.width ~= 256 or s.base.height ~= 192 or baseAsset.width ~= 256 or baseAsset.height ~= 192 then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.base must be the opaque 256x192 surface", {})
    end
    if type(s.pages) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.pages must be a table", {})
    end
    local pageKeys = { "upper", "lower", "symbols" }
    local pageCount = 0
    for _ in pairs(s.pages) do
      pageCount = pageCount + 1
    end
    if pageCount ~= #pageKeys then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.pages must carry exactly upper, lower, and symbols", {})
    end
    for _, key in ipairs(pageKeys) do
      local page = s.pages[key]
      if type(page) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, "namingScreen.pages." .. key .. " must be a table", {})
      end
      local pageAsset = atlasSizes[page.asset]
      if type(page.asset) ~= "string" or not pageAsset then
        return false,
          Errors.new(MANIFEST_INVALID, "namingScreen.pages." .. key .. " must reference an indexed asset", {})
      end
      if page.width ~= 256 or page.height ~= 112 or pageAsset.width ~= 256 or pageAsset.height ~= 112 then
        return false, Errors.new(MANIFEST_INVALID, "namingScreen.pages." .. key .. " must be the 256x112 overlay", {})
      end
    end
    local placement = s.placement
    if
      type(placement) ~= "table"
      or placement.x ~= 0
      or placement.y ~= 80
      or placement.width ~= 256
      or placement.height ~= 112
    then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.placement must be the canonical y=80 overlay", {})
    end
    return true
  end)
  if not namingOk then
    return false, namingErr
  end

  return true
end

-- Every generated file the manifest indexes must exist for the class to be
-- ready. The marker must also match exactly; the manifest itself must be
-- present and valid.
function FieldUiAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldUiAssetCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if type(manifest) ~= "table" then
    return false
  end
  local ok = FieldUiAssetCache.validateManifest(manifest)
  if not ok then
    return false
  end
  for _, entry in pairs(manifest.assets) do
    if not cacheFs:exists(entry.image, "file") then
      return false
    end
  end
  return true
end

return FieldUiAssetCache
