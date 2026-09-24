-- Readiness, paths, and strict validation for the generated HGSS field-UI
-- class: one manifest (`ui.lua`) carrying the semantic surfaces and the
-- strict metadata sections, binary assets (PNG atlases) under the UI asset
-- root, and a completion marker written last with the ROM SHA-1 and producer
-- dependency hash. The manifest is the single mod-facing contract for
-- dialogue frames, signposts, the Start Menu, the Trainer Card, the normal
-- naming chrome, and the two-row choice prompt; it never
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

---@class FieldUiAssetCache.PromptVisual
---@field asset string
---@field rect { x: integer, y: integer, width: integer, height: integer }

---@class FieldUiAssetCache.PromptRow
---@field normal FieldUiAssetCache.PromptVisual
---@field selected FieldUiAssetCache.PromptVisual

---@class FieldUiAssetCache.PromptShape
---@field width integer
---@field height integer
---@field yes FieldUiAssetCache.PromptRow
---@field no FieldUiAssetCache.PromptRow

---@class FieldUiAssetCache.PromptSection
---@field shapes { compact: FieldUiAssetCache.PromptShape }

---@class FieldUiAssetCache.Manifest
---@field schema string
---@field assets table<string, FieldUiAssetCache.Asset>
---@field yesNoPrompt FieldUiAssetCache.PromptSection
---@field [string] table<string, unknown>

FieldUiAssetCache.FORMAT = Contract.fieldUi.cacheFormat
FieldUiAssetCache.SCHEMA = Contract.fieldUi.schema

-- The audited HGSS field-UI geometry is a generated-class invariant,
-- not a tunable: dialogue and signpost frame members carry 18 tiles (a
-- 144x8 strip) and every wayfinding member carries 24 tiles but is
-- persisted as a precomposed 48x32 final surface (6 columns x 4 rows).
-- The producer arranges the raw 24 tiles into that surface at build time;
-- runtime draws a single rect. The validator enforces the final 48x32
-- shape. The two-row choice prompt buttons are the same 6x4-tile compact
-- geometry: one 48x32 surface per button state. The producer and validator
-- consume these numbers from this one protocol owner.
FieldUiAssetCache.GEOMETRY = {
  FRAME_TILES = 18,
  WAYFINDING_TILES = 24,
  WAYFINDING_COLUMNS = 6,
  WAYFINDING_ROWS = 4,
  WAYFINDING_WIDTH = 48,
  WAYFINDING_HEIGHT = 32,
  PROMPT_BUTTON_WIDTH = 48,
  PROMPT_BUTTON_HEIGHT = 32,
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
  START_MENU_ICONS = "hgss.start_menu.icons",
  START_MENU_ICON_PALETTE = "hgss.start_menu.icon_palette",
  START_MENU_POKE_ICONS = "hgss.start_menu.poke_icons",
  START_MENU_CHROME_SUB = "hgss.start_menu.chrome_sub",
  TRAINER_CARD_FRONT = "hgss.trainer_card.front",
  NAMING_SCREEN_BASE = "hgss.naming_screen.base",
  NAMING_SCREEN_PAGE_UPPER = "hgss.naming_screen.page_upper",
  NAMING_SCREEN_PAGE_LOWER = "hgss.naming_screen.page_lower",
  NAMING_SCREEN_PAGE_SYMBOLS = "hgss.naming_screen.page_symbols",
  NAMING_SCREEN_CONTROL_UPPER = "hgss.naming_screen.control_upper",
  NAMING_SCREEN_CONTROL_LOWER = "hgss.naming_screen.control_lower",
  NAMING_SCREEN_CONTROL_SYMBOLS = "hgss.naming_screen.control_symbols",
  NAMING_SCREEN_CONTROL_BACK = "hgss.naming_screen.control_back",
  NAMING_SCREEN_CONTROL_OK = "hgss.naming_screen.control_ok",
  NAMING_SCREEN_CONTROL_BACKING = "hgss.naming_screen.control_backing",
  NAMING_SCREEN_CURSOR_KEYBOARD = "hgss.naming_screen.cursor_keyboard",
  NAMING_SCREEN_CURSOR_KEYBOARD_MASK = "hgss.naming_screen.cursor_keyboard_mask",
  NAMING_SCREEN_CURSOR_HOME_UPPER = "hgss.naming_screen.cursor_home_upper",
  NAMING_SCREEN_CURSOR_HOME_UPPER_MASK = "hgss.naming_screen.cursor_home_upper_mask",
  NAMING_SCREEN_CURSOR_HOME_LOWER = "hgss.naming_screen.cursor_home_lower",
  NAMING_SCREEN_CURSOR_HOME_LOWER_MASK = "hgss.naming_screen.cursor_home_lower_mask",
  NAMING_SCREEN_CURSOR_HOME_SYMBOLS = "hgss.naming_screen.cursor_home_symbols",
  NAMING_SCREEN_CURSOR_HOME_SYMBOLS_MASK = "hgss.naming_screen.cursor_home_symbols_mask",
  NAMING_SCREEN_CURSOR_HOME_BACK = "hgss.naming_screen.cursor_home_back",
  NAMING_SCREEN_CURSOR_HOME_BACK_MASK = "hgss.naming_screen.cursor_home_back_mask",
  NAMING_SCREEN_CURSOR_HOME_OK = "hgss.naming_screen.cursor_home_ok",
  NAMING_SCREEN_CURSOR_HOME_OK_MASK = "hgss.naming_screen.cursor_home_ok_mask",
  NAMING_SCREEN_SLOT_NORMAL = "hgss.naming_screen.slot_normal",
  NAMING_SCREEN_SLOT_SELECTED = "hgss.naming_screen.slot_selected",
  NAMING_SCREEN_SUBJECT_MALE = "hgss.naming_screen.subject_male",
  NAMING_SCREEN_SUBJECT_FEMALE = "hgss.naming_screen.subject_female",
  YES_NO_PROMPT_YES_NORMAL = "hgss.yes_no_prompt.yes_normal",
  YES_NO_PROMPT_YES_SELECTED = "hgss.yes_no_prompt.yes_selected",
  YES_NO_PROMPT_NO_NORMAL = "hgss.yes_no_prompt.no_normal",
  YES_NO_PROMPT_NO_SELECTED = "hgss.yes_no_prompt.no_selected",
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
    if type(s.palettes) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "dialogueFrames.palettes must be a table", {})
    end
    for frame = 0, s.count - 1 do
      local palette = s.palettes[frame]
      if type(palette) ~= "table" then
        return false,
          Errors.new(MANIFEST_INVALID, "dialogue frame " .. frame .. " palette must be a table", { frame = frame })
      end
      for slot = 0, 15 do
        local color = palette[slot]
        if type(color) ~= "table" then
          return false,
            Errors.new(
              MANIFEST_INVALID,
              "dialogue frame " .. frame .. " palette slot " .. slot .. " is missing",
              { frame = frame, slot = slot }
            )
        end
        for _, component in ipairs({ "r", "g", "b" }) do
          local value = color[component]
          if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 255 then
            return false,
              Errors.new(
                MANIFEST_INVALID,
                "dialogue frame " .. frame .. " palette slot " .. slot .. " must have byte RGB",
                { frame = frame, slot = slot, component = component }
              )
          end
        end
      end
      for slot in pairs(palette) do
        if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 15 then
          return false,
            Errors.new(MANIFEST_INVALID, "dialogue frame " .. frame .. " palette has an invalid slot", {
              frame = frame,
              slot = slot,
            })
        end
      end
    end
    -- The single dialogue strip is the only frame authority: the same
    -- row rectangles index the one atlas for ordinary windows and
    -- application decoration alike.
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
      for slot in pairs(typeEntry.palette) do
        if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 15 then
          return false,
            Errors.new(MANIFEST_INVALID, "signpost type " .. key .. " palette keys must be slots 0..15", {
              type = key,
              slot = slot,
            })
        end
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
    -- One composed sprite visual: an indexed atlas asset, a non-negative
    -- in-atlas rect, and the compositor's frame offset. The offset is a
    -- signed integral pair: a frame may extend left/up of its source anchor.
    local function spriteVisual(visual, what)
      if type(visual) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, what .. " must be a table", { what = what })
      end
      if type(visual.asset) ~= "string" or atlasSizes[visual.asset] == nil then
        return false, Errors.new(MANIFEST_INVALID, what .. " must reference an indexed asset", { what = what })
      end
      local rectOk, rectErr = rectInAtlas(visual.rect, visual.asset, what .. " rect")
      if not rectOk then
        return false, rectErr
      end
      if
        type(visual.offset) ~= "table"
        or type(visual.offset.x) ~= "number"
        or visual.offset.x % 1 ~= 0
        or type(visual.offset.y) ~= "number"
        or visual.offset.y % 1 ~= 0
      then
        return false, Errors.new(MANIFEST_INVALID, what .. " must carry an integral frame offset", { what = what })
      end
      return true
    end
    -- The retail icon-sprite contract: thirteen icon rows (Lua index =
    -- retail icon index + 1) with per-row art kind and label data, the
    -- shared icon atlas and palette record, seven context rows, the
    -- action-to-icon map, and chrome. Sprite rows carry source-composed
    -- normal/selected visuals (the Bag row carries the female pair as a
    -- first-class variant); text and poke-icon rows carry no art.
    if type(s.iconTable) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.iconTable must be a table", {})
    end
    local iconRowCount = 0
    for _ in pairs(s.iconTable) do
      iconRowCount = iconRowCount + 1
    end
    if iconRowCount ~= 13 then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.iconTable must carry all thirteen retail rows", {})
    end
    local validArts = { sprite = true, text = true, poke_icon = true }
    local validLabelKinds = { static = true, player_name = true }
    for index = 1, 13 do
      local row = s.iconTable[index]
      if type(row) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.iconTable row " .. index .. " must be a table", {})
      end
      if validArts[row.art] ~= true then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.iconTable row " .. index .. " art is invalid", {})
      end
      if row.art == "sprite" then
        for _, key in ipairs({ "normal", "selected" }) do
          local visual = type(row.visual) == "table" and row.visual[key] or nil
          local visualOk, visualErr = spriteVisual(visual, "start menu icon row " .. index .. " " .. key .. " visual")
          if not visualOk then
            return false, visualErr
          end
        end
      end
      if type(row.label) ~= "number" or row.label % 1 ~= 0 or row.label < 0 then
        return false,
          Errors.new(MANIFEST_INVALID, "startMenu.iconTable row " .. index .. " label must be a label-bank id", {})
      end
      if validLabelKinds[row.labelKind] ~= true then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.iconTable row " .. index .. " labelKind is invalid", {})
      end
      if row.variants ~= nil then
        if type(row.variants) ~= "table" then
          return false,
            Errors.new(MANIFEST_INVALID, "startMenu.iconTable row " .. index .. " variants must be a table", {})
        end
        local variantCount = 0
        for _ in pairs(row.variants) do
          variantCount = variantCount + 1
        end
        if variantCount ~= 1 or type(row.variants.female) ~= "table" then
          return false,
            Errors.new(MANIFEST_INVALID, "startMenu.iconTable row " .. index .. " carries only the female variant", {})
        end
        for _, key in ipairs({ "normal", "selected" }) do
          local variantOk, variantErr =
            spriteVisual(row.variants.female[key], "start menu icon row " .. index .. " female " .. key .. " visual")
          if not variantOk then
            return false, variantErr
          end
        end
      end
    end
    local palette = s.iconPalette
    if type(palette) ~= "table" or type(palette.asset) ~= "string" or atlasSizes[palette.asset] == nil then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.iconPalette must reference an indexed asset", {})
    end
    if
      type(palette.banks) ~= "number"
      or palette.banks % 1 ~= 0
      or palette.banks < 1
      or type(palette.selectionBank) ~= "number"
      or palette.selectionBank % 1 ~= 0
      or palette.selectionBank < 1
      or palette.selectionBank > palette.banks
    then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.iconPalette banks are invalid", {})
    end
    if s.pokeIcons ~= nil then
      if
        type(s.pokeIcons) ~= "table"
        or type(s.pokeIcons.asset) ~= "string"
        or atlasSizes[s.pokeIcons.asset] == nil
      then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.pokeIcons must reference an indexed asset", {})
      end
    end
    if type(s.contexts) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.contexts must be a table", {})
    end
    local contextCount = 0
    for _ in pairs(s.contexts) do
      contextCount = contextCount + 1
    end
    if contextCount ~= 7 then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.contexts must carry all seven retail rows", {})
    end
    for index = 1, 7 do
      local row = s.contexts[index]
      if type(row) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.contexts row " .. index .. " must be a table", {})
      end
      local entryCount = 0
      for _ in pairs(row) do
        entryCount = entryCount + 1
      end
      if entryCount ~= 7 then
        return false,
          Errors.new(MANIFEST_INVALID, "startMenu.contexts row " .. index .. " must map one icon per sprite slot", {})
      end
      for slot = 1, 7 do
        local icon = row[slot]
        if icon ~= false then
          if type(icon) ~= "number" or icon % 1 ~= 0 or icon < 0 or icon > 12 or s.iconTable[icon + 1] == nil then
            return false,
              Errors.new(MANIFEST_INVALID, "startMenu.contexts row " .. index .. " entry " .. slot .. " is invalid", {})
          end
        end
      end
    end
    if type(s.actionIcons) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.actionIcons must be a table", {})
    end
    for actionId, icon in pairs(s.actionIcons) do
      if type(actionId) ~= "string" then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.actionIcons keys must be action ids", {})
      end
      local row = type(icon) == "number" and s.iconTable[icon + 1] or nil
      if row == nil or row.art ~= "sprite" then
        return false,
          Errors.new(MANIFEST_INVALID, "startMenu.actionIcons " .. actionId .. " must map to a sprite icon row", {})
      end
    end
    -- The normal interactive selector: exactly the seven source positions
    -- 0..6, each carrying its action anchor, label window, touch hit
    -- rectangle, and four ordered three-candidate navigation lists, plus the
    -- cancel/header hit rectangle. Anchors are integral canonical points;
    -- label and hit rectangles stay inside the canonical 256x192 surface;
    -- every candidate names a normal position.
    local function canonicalRect(rect, what)
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
      if rect.x + rect.width > 256 or rect.y + rect.height > 192 then
        return false, Errors.new(MANIFEST_INVALID, what .. " must stay inside the 256x192 surface", { what = what })
      end
      return true
    end
    if type(s.interactive) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.interactive must be a table", {})
    end
    local cancelOk, cancelErr = canonicalRect(s.interactive.cancelHitRect, "start menu cancel hit rectangle")
    if not cancelOk then
      return false, cancelErr
    end
    if type(s.interactive.positions) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.interactive.positions must be a table", {})
    end
    local positionCount = 0
    for _ in pairs(s.interactive.positions) do
      positionCount = positionCount + 1
    end
    if positionCount ~= 7 then
      return false,
        Errors.new(MANIFEST_INVALID, "startMenu.interactive must carry exactly the seven normal positions", {})
    end
    for position = 0, 6 do
      local record = s.interactive.positions[position]
      if type(record) ~= "table" then
        return false,
          Errors.new(MANIFEST_INVALID, "startMenu.interactive position " .. position .. " must be a table", {})
      end
      if
        type(record.anchor) ~= "table"
        or type(record.anchor.x) ~= "number"
        or record.anchor.x % 1 ~= 0
        or type(record.anchor.y) ~= "number"
        or record.anchor.y % 1 ~= 0
      then
        return false,
          Errors.new(
            MANIFEST_INVALID,
            "startMenu.interactive position " .. position .. " anchor must be an integral point",
            {}
          )
      end
      local labelOk, labelErr = canonicalRect(record.labelWindow, "start menu position " .. position .. " label window")
      if not labelOk then
        return false, labelErr
      end
      local hitOk, hitErr = canonicalRect(record.hitRect, "start menu position " .. position .. " hit rectangle")
      if not hitOk then
        return false, hitErr
      end
      if type(record.navigation) ~= "table" then
        return false,
          Errors.new(
            MANIFEST_INVALID,
            "startMenu.interactive position " .. position .. " navigation must be a table",
            {}
          )
      end
      local directionCount = 0
      for _ in pairs(record.navigation) do
        directionCount = directionCount + 1
      end
      if directionCount ~= 4 then
        return false,
          Errors.new(
            MANIFEST_INVALID,
            "startMenu.interactive position " .. position .. " carries four navigation directions",
            {}
          )
      end
      for _, direction in ipairs({ "up", "down", "left", "right" }) do
        local candidates = record.navigation[direction]
        if type(candidates) ~= "table" or #candidates ~= 3 then
          return false,
            Errors.new(
              MANIFEST_INVALID,
              "startMenu.interactive position " .. position .. " " .. direction .. " must list three candidates",
              {}
            )
        end
        for _, candidate in ipairs(candidates) do
          if type(candidate) ~= "number" or candidate % 1 ~= 0 or candidate < 0 or candidate > 6 then
            return false,
              Errors.new(
                MANIFEST_INVALID,
                "startMenu.interactive position "
                  .. position
                  .. " "
                  .. direction
                  .. " candidates must name normal positions 0..6",
                {}
              )
          end
        end
      end
    end
    if type(s.chrome) ~= "table" or type(s.chrome.main) ~= "table" or type(s.chrome.sub) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.chrome must carry its main and sub sets", {})
    end
    for _, key in ipairs({ "main", "sub" }) do
      local set = s.chrome[key]
      if type(set.asset) ~= "string" or atlasSizes[set.asset] == nil then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.chrome." .. key .. " must reference an indexed asset", {})
      end
    end
    local aboveY = s.chrome.main.transparentAboveY
    if type(aboveY) ~= "number" or aboveY % 1 ~= 0 or aboveY < 1 then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.chrome.main must name its transparency boundary", {})
    end
    -- The Start Menu label palette is a required generated record: the
    -- source label-window roles as byte RGB with compositing alpha. Ink
    -- stays opaque while the background stays transparent, so glyph
    -- background-class pixels reveal the already-rendered chrome instead
    -- of repainting it.
    local labelPalette = s.labelPalette
    if type(labelPalette) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "startMenu.labelPalette must be a table", {})
    end
    local roleCount = 0
    for _ in pairs(labelPalette) do
      roleCount = roleCount + 1
    end
    if
      roleCount ~= 3
      or labelPalette.foreground == nil
      or labelPalette.shadow == nil
      or labelPalette.background == nil
    then
      return false,
        Errors.new(MANIFEST_INVALID, "startMenu.labelPalette must carry exactly foreground, shadow, and background", {})
    end
    local function labelRole(role, expectedAlpha)
      local color = labelPalette[role]
      if type(color) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, "startMenu.labelPalette." .. role .. " must be a table", {})
      end
      for _, component in ipairs({ "r", "g", "b" }) do
        local v = color[component]
        if type(v) ~= "number" or v % 1 ~= 0 or v < 0 or v > 255 then
          return false,
            Errors.new(
              MANIFEST_INVALID,
              "startMenu.labelPalette." .. role .. "." .. component .. " must be an integral byte 0..255",
              {}
            )
        end
      end
      if color.a ~= expectedAlpha then
        return false,
          Errors.new(
            MANIFEST_INVALID,
            "startMenu.labelPalette." .. role .. " alpha must be " .. expectedAlpha .. " for label compositing",
            {}
          )
      end
      return true
    end
    local labelForegroundOk, labelForegroundErr = labelRole("foreground", 1)
    if not labelForegroundOk then
      return false, labelForegroundErr
    end
    local labelShadowOk, labelShadowErr = labelRole("shadow", 1)
    if not labelShadowOk then
      return false, labelShadowErr
    end
    local labelBackgroundOk, labelBackgroundErr = labelRole("background", 0)
    if not labelBackgroundOk then
      return false, labelBackgroundErr
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
  -- source archive or member identities. The semantic layer adds the
  -- source-window text geometry (the entered-name origin plus the five
  -- thirteen-column keyboard text rows), the six OAM-composed controls with
  -- their canonical anchors, the stepping keyboard cursor with its five
  -- home-row variants, the stepping entry slots with normal/selected
  -- visuals, and the anchored male/female player subjects. Every sprite
  -- record draws at anchor plus the generated frame offset.
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
      or placement.x ~= 11
      or placement.y ~= 80
      or placement.width ~= 256
      or placement.height ~= 112
    then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.placement must be the x=11 y=80 overlay", {})
    end

    local function nonNegativeInt(value)
      return type(value) == "number" and value % 1 == 0 and value >= 0
    end

    local function canonicalPoint(point, what)
      if type(point) ~= "table" or not nonNegativeInt(point.x) or not nonNegativeInt(point.y) then
        return false, Errors.new(MANIFEST_INVALID, what .. " must be a canonical integer point", { what = what })
      end
      return true
    end

    -- One OAM-composed visual: a generated image drawn at its canonical
    -- anchor plus the compositor's frame offset. The asset must be indexed
    -- with matching dimensions; the offset may be negative (a cell whose
    -- objects start below the source origin shifts the frame).
    local function spriteRecord(record, what)
      if type(record) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, what .. " must be a table", { what = what })
      end
      local asset = atlasSizes[record.asset]
      if type(record.asset) ~= "string" or not asset then
        return false, Errors.new(MANIFEST_INVALID, what .. " must reference an indexed asset", { what = what })
      end
      if record.width ~= asset.width or record.height ~= asset.height then
        return false, Errors.new(MANIFEST_INVALID, what .. " dimensions must match its indexed asset", { what = what })
      end
      if record.width < 1 or record.height < 1 then
        return false, Errors.new(MANIFEST_INVALID, what .. " must be non-empty", { what = what })
      end
      local anchorOk, anchorErr = canonicalPoint(record.anchor, what .. " anchor")
      if not anchorOk then
        return false, anchorErr
      end
      if
        type(record.offset) ~= "table"
        or type(record.offset.x) ~= "number"
        or record.offset.x % 1 ~= 0
        or type(record.offset.y) ~= "number"
        or record.offset.y % 1 ~= 0
      then
        return false, Errors.new(MANIFEST_INVALID, what .. " must carry the generated frame offset", { what = what })
      end
      return true
    end

    local text = s.text
    if type(text) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.text must be a table", {})
    end
    if type(text.name) ~= "table" or text.name.x ~= 80 or text.name.y ~= 24 or text.name.advanceX ~= 12 then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.text.name must be the (80,24)+12px entry origin", {})
    end
    if type(text.keyboard) ~= "table" or type(text.keyboard.cells) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.text.keyboard.cells must be a table", {})
    end
    local textRowCount = 0
    for _ in pairs(text.keyboard.cells) do
      textRowCount = textRowCount + 1
    end
    if textRowCount ~= 5 then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.text.keyboard must carry five source rows", {})
    end
    for row = 1, 5 do
      local cells = text.keyboard.cells[row]
      if type(cells) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, "namingScreen.text.keyboard row " .. row .. " is missing", {})
      end
      local columnCount = 0
      for _ in pairs(cells) do
        columnCount = columnCount + 1
      end
      if columnCount ~= 13 then
        return false,
          Errors.new(MANIFEST_INVALID, "namingScreen.text.keyboard row " .. row .. " must carry thirteen cells", {})
      end
      for column = 1, 13 do
        local cell = cells[column]
        if
          type(cell) ~= "table"
          or not nonNegativeInt(cell.x)
          or not nonNegativeInt(cell.y)
          or cell.width ~= 16
          or cell.x + cell.width > 256
          or cell.y > 191
        then
          return false,
            Errors.new(
              MANIFEST_INVALID,
              "namingScreen.text.keyboard row " .. row .. " column " .. column .. " must be a 16px canonical cell",
              {}
            )
        end
      end
    end

    if type(s.controls) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.controls must be a table", {})
    end
    local controlAnchors = {
      upper = { x = 26, y = 68 },
      lower = { x = 58, y = 68 },
      symbols = { x = 90, y = 68 },
      back = { x = 158, y = 68 },
      ok = { x = 198, y = 68 },
      backing = { x = 22, y = 56 },
    }
    local controlCount = 0
    for _ in pairs(s.controls) do
      controlCount = controlCount + 1
    end
    if controlCount ~= 6 then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.controls must carry six source visuals", {})
    end
    for id, anchor in pairs(controlAnchors) do
      local recordOk, recordErr = spriteRecord(s.controls[id], "namingScreen.controls." .. id)
      if not recordOk then
        return false, recordErr
      end
      local recordAnchor = s.controls[id].anchor
      if recordAnchor.x ~= anchor.x or recordAnchor.y ~= anchor.y then
        return false, Errors.new(MANIFEST_INVALID, "namingScreen.controls." .. id .. " must keep its source anchor", {})
      end
    end

    local validPlayModes = { forward = true, forward_loop = true, reverse = true, reverse_loop = true }

    -- One generated animation record: decoded playback mode, zero-based
    -- loop start, and dense frames each naming an indexed atlas rect with
    -- the compositor offset and a positive duration. Cursor records
    -- additionally name their pulse-mask atlas and carry a same-size mask
    -- rect per frame; subject records carry no pulse fields.
    local function animationRecord(record, what, isCursor)
      if type(record) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, what .. " must be a table", { what = what })
      end
      if validPlayModes[record.playMode] ~= true then
        return false, Errors.new(MANIFEST_INVALID, what .. " carries an unsupported play mode", { what = what })
      end
      if type(record.frames) ~= "table" then
        return false, Errors.new(MANIFEST_INVALID, what .. " must carry animation frames", { what = what })
      end
      local frameCount = 0
      for _ in pairs(record.frames) do
        frameCount = frameCount + 1
      end
      if frameCount == 0 or frameCount ~= #record.frames then
        return false, Errors.new(MANIFEST_INVALID, what .. " frames must be a dense sequence", { what = what })
      end
      if
        type(record.loopStartFrameIdx) ~= "number"
        or record.loopStartFrameIdx % 1 ~= 0
        or record.loopStartFrameIdx < 0
        or record.loopStartFrameIdx >= frameCount
      then
        return false, Errors.new(MANIFEST_INVALID, what .. " loop start is outside its frames", { what = what })
      end
      local pulseAsset = nil
      if isCursor then
        pulseAsset = record.pulseAsset
        if type(pulseAsset) ~= "string" or atlasSizes[pulseAsset] == nil then
          return false,
            Errors.new(MANIFEST_INVALID, what .. " must reference its indexed pulse-mask atlas", { what = what })
        end
      elseif record.pulseAsset ~= nil then
        return false, Errors.new(MANIFEST_INVALID, what .. " carries no pulse-mask role", { what = what })
      end
      for index = 1, frameCount do
        local frame = record.frames[index]
        local frameWhat = what .. " frame " .. index
        if type(frame) ~= "table" then
          return false, Errors.new(MANIFEST_INVALID, frameWhat .. " must be a table", { what = frameWhat })
        end
        if type(frame.asset) ~= "string" or atlasSizes[frame.asset] == nil then
          return false,
            Errors.new(MANIFEST_INVALID, frameWhat .. " must reference an indexed atlas", { what = frameWhat })
        end
        local rectOk, rectErr = rectInAtlas(frame.rect, frame.asset, frameWhat .. " rect")
        if not rectOk then
          return false, rectErr
        end
        if
          type(frame.offset) ~= "table"
          or type(frame.offset.x) ~= "number"
          or frame.offset.x % 1 ~= 0
          or type(frame.offset.y) ~= "number"
          or frame.offset.y % 1 ~= 0
        then
          return false,
            Errors.new(MANIFEST_INVALID, frameWhat .. " must carry the generated frame offset", { what = frameWhat })
        end
        if type(frame.duration) ~= "number" or frame.duration % 1 ~= 0 or frame.duration < 1 then
          return false,
            Errors.new(MANIFEST_INVALID, frameWhat .. " duration must be a positive integer", { what = frameWhat })
        end
        if isCursor then
          local maskOk, maskErr = rectInAtlas(frame.pulseRect, pulseAsset, frameWhat .. " pulse rect")
          if not maskOk then
            return false, maskErr
          end
          if frame.pulseRect.width ~= frame.rect.width or frame.pulseRect.height ~= frame.rect.height then
            return false,
              Errors.new(MANIFEST_INVALID, frameWhat .. " pulse rect must match its frame size", { what = frameWhat })
          end
        elseif frame.pulseRect ~= nil then
          return false, Errors.new(MANIFEST_INVALID, frameWhat .. " carries no pulse-mask role", { what = frameWhat })
        end
      end
      return true
    end

    if type(s.cursor) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.cursor must be a table", {})
    end
    local keyboardCursor = s.cursor.keyboard
    local keyboardAnimOk, keyboardAnimErr = animationRecord(keyboardCursor, "namingScreen.cursor.keyboard", true)
    if not keyboardAnimOk then
      return false, keyboardAnimErr
    end
    if
      type(keyboardCursor.origin) ~= "table"
      or keyboardCursor.origin.x ~= 26
      or keyboardCursor.origin.y ~= 91
      or keyboardCursor.stepX ~= 16
      or keyboardCursor.stepY ~= 19
    then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.cursor.keyboard must step 16px by 19px from (26,91)", {})
    end
    if type(s.cursor.home) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.cursor.home must be a table", {})
    end
    local homeCount = 0
    for _ in pairs(s.cursor.home) do
      homeCount = homeCount + 1
    end
    if homeCount ~= 5 then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.cursor.home must carry five control variants", {})
    end
    for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
      local homeAnimOk, homeAnimErr = animationRecord(s.cursor.home[id], "namingScreen.cursor.home." .. id, true)
      if not homeAnimOk then
        return false, homeAnimErr
      end
      local homeAnchorOk, homeAnchorErr =
        canonicalPoint(s.cursor.home[id].anchor, "namingScreen.cursor.home." .. id .. " anchor")
      if not homeAnchorOk then
        return false, homeAnchorErr
      end
    end

    if type(s.entrySlots) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.entrySlots must be a table", {})
    end
    if
      type(s.entrySlots.origin) ~= "table"
      or s.entrySlots.origin.x ~= 80
      or s.entrySlots.origin.y ~= 39
      or s.entrySlots.stepX ~= 12
    then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.entrySlots must start at (80,39) stepping 12px", {})
    end
    for _, key in ipairs({ "normal", "selected" }) do
      local slotOk, slotErr = spriteRecord(s.entrySlots[key], "namingScreen.entrySlots." .. key)
      if not slotOk then
        return false, slotErr
      end
    end

    if type(s.playerSubjects) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.playerSubjects must be a table", {})
    end
    local subjectCount = 0
    for _ in pairs(s.playerSubjects) do
      subjectCount = subjectCount + 1
    end
    if subjectCount ~= 2 then
      return false, Errors.new(MANIFEST_INVALID, "namingScreen.playerSubjects must carry male and female", {})
    end
    for _, id in ipairs({ "male", "female" }) do
      local subjectAnimOk, subjectAnimErr =
        animationRecord(s.playerSubjects[id], "namingScreen.playerSubjects." .. id, false)
      if not subjectAnimOk then
        return false, subjectAnimErr
      end
      local subjectAnchor = s.playerSubjects[id].anchor
      if subjectAnchor.x ~= 24 or subjectAnchor.y ~= 8 then
        return false, Errors.new(MANIFEST_INVALID, "namingScreen.playerSubjects." .. id .. " must anchor at (24,8)", {})
      end
    end
    return true
  end)
  if not namingOk then
    return false, namingErr
  end

  -- The two-row choice prompt: exactly the compact shape, one 48x32 button
  -- per row with a normal and a selected visual each. Every visual resolves
  -- through the shared asset index by semantic id; the section carries no
  -- source archive, member, tile, palette, or background identities.
  local promptOk, promptErr = section("yesNoPrompt", function(s)
    if type(s.shapes) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "yesNoPrompt.shapes must be a table", {})
    end
    local shapeCount = 0
    for _ in pairs(s.shapes) do
      shapeCount = shapeCount + 1
    end
    if shapeCount ~= 1 or type(s.shapes.compact) ~= "table" then
      return false, Errors.new(MANIFEST_INVALID, "yesNoPrompt.shapes must carry exactly the compact shape", {})
    end
    local compact = s.shapes.compact
    if compact.width ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_WIDTH then
      return false, Errors.new(MANIFEST_INVALID, "the compact prompt width must be 48", {})
    end
    if compact.height ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_HEIGHT then
      return false, Errors.new(MANIFEST_INVALID, "the compact prompt height must be 32", {})
    end
    for _, row in ipairs({ "yes", "no" }) do
      local states = compact[row]
      if type(states) ~= "table" then
        return false,
          Errors.new(MANIFEST_INVALID, "the compact prompt " .. row .. " row must be a table", { row = row })
      end
      for _, state in ipairs({ "normal", "selected" }) do
        local visual = states[state]
        if type(visual) ~= "table" then
          return false,
            Errors.new(
              MANIFEST_INVALID,
              "the compact prompt " .. row .. " row must carry its " .. state .. " visual",
              { row = row, state = state }
            )
        end
        if type(visual.asset) ~= "string" or atlasSizes[visual.asset] == nil then
          return false,
            Errors.new(
              MANIFEST_INVALID,
              "the compact prompt " .. row .. " " .. state .. " visual must reference an indexed asset",
              { row = row, state = state }
            )
        end
        local rectOk, rectErr =
          rectInAtlas(visual.rect, visual.asset, "the compact prompt " .. row .. " " .. state .. " rect")
        if not rectOk then
          return false, rectErr
        end
        if
          visual.rect.width ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_WIDTH
          or visual.rect.height ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_HEIGHT
        then
          return false,
            Errors.new(
              MANIFEST_INVALID,
              "the compact prompt " .. row .. " " .. state .. " rect must be the 48x32 button surface",
              { row = row, state = state }
            )
        end
      end
    end
    local forbidden = {
      member = true,
      memberId = true,
      narc = true,
      narcId = true,
      alias = true,
      fileId = true,
      bgId = true,
      tileStart = true,
      plttSlot = true,
      paletteSlot = true,
      sourcePath = true,
    }
    local function scan(value)
      if type(value) ~= "table" then
        return nil
      end
      for key, nested in pairs(value) do
        if type(key) == "string" and forbidden[key] then
          return key
        end
        local leaked = scan(nested)
        if leaked ~= nil then
          return leaked
        end
      end
      return nil
    end
    local leaked = scan(s)
    if leaked ~= nil then
      return false, Errors.new(MANIFEST_INVALID, "the two-row prompt manifest leaks source detail", { field = leaked })
    end
    return true
  end)
  if not promptOk then
    return false, promptErr
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
