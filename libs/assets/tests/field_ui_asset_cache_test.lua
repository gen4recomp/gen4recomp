-- FieldUiAssetCache contract: strict paths, the FORMAT:romSha1:depHash
-- marker written last, isReady semantics (marker + manifest + every indexed
-- file), and strict rejection of malformed generated metadata (missing
-- arrays, unknown values, non-finite/negative/out-of-atlas rectangles).

local Assert = require("tests.support.Assert")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

-- A valid manifest models the audited HGSS geometry: every dialogue frame
-- strip and the signpost frame are 18 tiles (144x8), every wayfinding
-- surface is 24 tiles precomposed as a 48x32 final rect. v6 schema
-- includes per-type signpost palettes and per-type frame geometry.
local function validManifest()
  local frameTiles = {}
  for frame = 0, 19 do
    frameTiles[frame] = { x = 0, y = 0, width = 144, height = 8 }
  end
  local slots = {}
  for id = 1, 10 do
    slots[id] = { x = (id % 2 == 1 and 0 or 128), y = math.floor((id - 1) / 2) * 38, width = 128, height = 38 }
  end

  local function validPalette()
    local palette = {}
    for slot = 0, 15 do
      palette[slot] = { r = slot * 16, g = slot * 16, b = slot * 16 }
    end
    return palette
  end

  return {
    schema = FieldUiAssetCache.SCHEMA,
    reference = { width = 256, height = 192 },
    assets = {
      ["hgss.dialogue_frame.tiles"] = {
        image = "assets/generated/field/ui/dialogue-frame-tiles.png",
        width = 144,
        height = 160,
      },
      ["hgss.signpost.tiles"] = { image = "assets/generated/field/ui/signpost-tiles.png", width = 288, height = 16 },
      ["hgss.signpost.wayfinding"] = {
        image = "assets/generated/field/ui/wayfinding-tiles.png",
        width = 48,
        height = 64,
      },
      ["hgss.start_menu.background"] = { image = "assets/generated/field/ui/start-menu.png", width = 256, height = 192 },
      ["hgss.start_menu.cursor"] = {
        image = "assets/generated/field/ui/start-menu-cursor.png",
        width = 32,
        height = 32,
      },
      ["hgss.trainer_card.front"] = { image = "assets/generated/field/ui/trainer-card.png", width = 256, height = 192 },
      ["hgss.dialogue_continue_cursor"] = {
        image = "assets/generated/field/ui/dialogue-continue-cursor.png",
        width = 48,
        height = 320,
      },
      ["hgss.naming_screen.base"] = {
        image = "assets/generated/field/ui/naming-screen-base.png",
        width = 256,
        height = 192,
      },
      ["hgss.naming_screen.page_upper"] = {
        image = "assets/generated/field/ui/naming-screen-page-upper.png",
        width = 256,
        height = 112,
      },
      ["hgss.naming_screen.page_lower"] = {
        image = "assets/generated/field/ui/naming-screen-page-lower.png",
        width = 256,
        height = 112,
      },
      ["hgss.naming_screen.page_symbols"] = {
        image = "assets/generated/field/ui/naming-screen-page-symbols.png",
        width = 256,
        height = 112,
      },
    },
    dialogueFrames = {
      count = 20,
      frameTiles = frameTiles,
      continueCursor = {
        asset = "hgss.dialogue_continue_cursor",
        cycle = { 0, 1, 2, 1 },
        framePrinterTicks = 9,
        placement = { x = 240, y = 168, width = 16, height = 16 },
        styles = (function()
          local styles = {}
          for style = 0, 19 do
            styles[style] = {
              phases = {
                [0] = { x = 0, y = style * 16, width = 16, height = 16 },
                [1] = { x = 16, y = style * 16, width = 16, height = 16 },
                [2] = { x = 32, y = style * 16, width = 16, height = 16 },
              },
            }
          end
          return styles
        end)(),
      },
    },
    signposts = {
      textColors = { foreground = 2, shadow = 10, background = 15 },
      types = {
        [0] = {
          sourceType = 0,
          palette = validPalette(),
          frameTiles = { x = 0, y = 0, width = 144, height = 8 },
          wayfinding = {
            [0] = { x = 0, y = 0, width = 48, height = 32 },
            [1] = { x = 0, y = 32, width = 48, height = 32 },
          },
        },
        [2] = {
          sourceType = 2,
          palette = validPalette(),
          frameTiles = { x = 144, y = 0, width = 144, height = 8 },
        },
      },
    },
    startMenu = {
      background = { x = 0, y = 0, width = 256, height = 192 },
      cursor = { frames = { { x = 0, y = 0, width = 32, height = 32, duration = 3 } } },
      slots = slots,
      actionSurfaces = {
        ["vanilla.trainer_card"] = slots[6],
        ["vanilla.save"] = slots[7],
        ["vanilla.options"] = slots[8],
      },
    },
    trainerCard = { front = { x = 0, y = 0, width = 256, height = 192 } },
    namingScreen = {
      base = { asset = "hgss.naming_screen.base", width = 256, height = 192 },
      pages = {
        upper = { asset = "hgss.naming_screen.page_upper", width = 256, height = 112 },
        lower = { asset = "hgss.naming_screen.page_lower", width = 256, height = 112 },
        symbols = { asset = "hgss.naming_screen.page_symbols", width = 256, height = 112 },
      },
      placement = { x = 0, y = 80, width = 256, height = 112 },
    },
  }
end

local function publishedCache(manifest)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest or validManifest())
  cache:write(FieldUiAssetCache.markerPath(), FieldUiAssetCache.marker("rom-sha", "dep-hash"))
  for _, entry in pairs((manifest or validManifest()).assets) do
    cache:write(entry.image, "png")
  end
  return cache
end

function T.contract_constants_flow_from_the_contract_owner()
  Assert.equal(FieldUiAssetCache.FORMAT, DerivedAssetContract.fieldUi.cacheFormat)
  Assert.equal(FieldUiAssetCache.SCHEMA, DerivedAssetContract.fieldUi.schema)
  Assert.equal(FieldUiAssetCache.marker("abc", "def"), "field-ui-cache-v1:abc:def")
end

function T.ready_requires_marker_manifest_and_every_indexed_file()
  local cache = publishedCache()
  Assert.isTrue(FieldUiAssetCache.isReady(cache, FieldUiAssetCache.marker("rom-sha", "dep-hash")))
  Assert.isFalse(
    FieldUiAssetCache.isReady(cache, FieldUiAssetCache.marker("rom-sha", "stale")),
    "marker must match exactly"
  )
  cache:remove(FieldUiAssetCache.markerPath())
  Assert.isFalse(FieldUiAssetCache.isReady(cache, FieldUiAssetCache.marker("rom-sha", "dep-hash")))
  local cache2 = publishedCache()
  cache2:remove("assets/generated/field/ui/start-menu.png")
  Assert.isFalse(
    FieldUiAssetCache.isReady(cache2, FieldUiAssetCache.marker("rom-sha", "dep-hash")),
    "a missing indexed file is not ready"
  )
end

local function reject(mutate, code)
  local manifest = validManifest()
  mutate(manifest)
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok)
  Assert.equal(assert(err).code, code)
end

function T.missing_or_unknown_schema_and_reference_are_rejected()
  reject(function(m)
    m.schema = "g4-field-ui-v0"
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.reference = { width = 320, height = 240 }
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.assets_must_be_non_empty_with_dimensions()
  reject(function(m)
    m.assets = {}
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.assets["hgss.start_menu.background"].width = -1
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.rectangles_outside_their_atlas_are_rejected()
  reject(function(m)
    m.startMenu.background = { x = 0, y = 0, width = 257, height = 192 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.background.x = 1.5
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[2] = { sourceType = "two" }
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.missing_sections_are_rejected()
  reject(function(m)
    m.dialogueFrames = nil
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu = nil
  end, "FIELD_UI_MANIFEST_INVALID")
end

-- The start menu surface contract: at least one cursor frame, the dense
-- 1..10 slot grid (the touch surface the producer hard-codes), and every
-- slot rect inside the background atlas.
function T.start_menu_surface_validation_is_strict()
  reject(function(m)
    m.startMenu.cursor.frames = {}
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots[1] = nil
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots[3] = nil
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots[11] = { x = 0, y = 0, width = 128, height = 38 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots[5] = { x = 200, y = 0, width = 128, height = 38 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.startMenu.slots = { [0] = { x = 0, y = 0, width = 128, height = 38 } }
  end, "FIELD_UI_MANIFEST_INVALID")
end

-- Signpost type entries must be keyed by their own sourceType, and every
-- map-specific wayfinding record is a validated atlas rectangle.
function T.signpost_type_and_wayfinding_validation_is_strict()
  reject(function(m)
    m.signposts.types[2].sourceType = 3
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[7] = {}
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[2].wayfinding = {}
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].wayfinding[-1] = { x = 0, y = 0, width = 48, height = 32 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].wayfinding[1] = { x = 0, y = 0, width = 49, height = 32 }
  end, "FIELD_UI_MANIFEST_INVALID")
end

-- The generated class is pinned to the audited HGSS geometry — every
-- dialogue frame strip and the signpost frame are the 18-tile 144x8 row,
-- every wayfinding surface is the 24-tile 48x32 final rect. A corrupted
-- dimension must be rejected by manifest validation before any renderer
-- draw, even when the wrong rect still fits inside its atlas.
function T.ui_row_geometry_must_match_the_hgss_strip_contract()
  reject(function(m)
    m.dialogueFrames.frameTiles[0].width = 136
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.dialogueFrames.frameTiles[1].height = 16
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].frameTiles.width = 136
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].wayfinding[0].width = 47
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].wayfinding[0].height = 31
  end, "FIELD_UI_MANIFEST_INVALID")
end

-- A complete cursor contract passes, while each independently malformed
-- cursor field is rejected before runtime can consume the generated class.
function T.continuation_cursor_contract_rejects_incomplete_manifests()
  local complete = validManifest()
  Assert.isTrue(FieldUiAssetCache.validateManifest(complete))

  local mutations = {
    function(m)
      m.assets["hgss.dialogue_continue_cursor"] = nil
    end,
    function(m)
      m.dialogueFrames.continueCursor.styles[19] = nil
    end,
    function(m)
      m.dialogueFrames.continueCursor.styles[0].phases[2] = nil
    end,
    function(m)
      m.dialogueFrames.continueCursor.styles[0].phases[0].width = 15
    end,
    function(m)
      m.dialogueFrames.continueCursor.styles[0].phases[0].x = 40
    end,
    function(m)
      m.dialogueFrames.continueCursor.cycle = { 0, 1, 0, 1 }
    end,
    function(m)
      m.dialogueFrames.continueCursor.placement.x = 239
    end,
    function(m)
      m.dialogueFrames.continueCursor.framePrinterTicks = 8
    end,
  }
  for index, mutate in ipairs(mutations) do
    local manifest = validManifest()
    mutate(manifest)
    local ok, err = FieldUiAssetCache.validateManifest(manifest)
    Assert.isFalse(ok, "cursor mutation " .. index .. " must be rejected: " .. tostring(err))
  end
end

-- v5 schema: signposts section requires textColors and per-type palettes.
-- v4 manifests without these new required fields must be rejected.
function T.v5_rejects_v4_manifest_missing_text_colors()
  reject(function(m)
    m.signposts.textColors = nil
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_wrong_text_color_foreground()
  reject(function(m)
    m.signposts.textColors.foreground = 1
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_wrong_text_color_shadow()
  reject(function(m)
    m.signposts.textColors.shadow = 9
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_wrong_text_color_background()
  reject(function(m)
    m.signposts.textColors.background = 14
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_non_integral_text_color_slot()
  reject(function(m)
    m.signposts.textColors.foreground = 2.5
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_text_color_out_of_range()
  reject(function(m)
    m.signposts.textColors.foreground = 16
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.textColors.shadow = -1
  end, "FIELD_UI_MANIFEST_INVALID")
end

-- Per-type palette validation: must have exactly 16 entries (0..15), each
-- with r/g/b components as integers in 0..255.
function T.v5_rejects_type_missing_palette()
  reject(function(m)
    m.signposts.types[0].palette = nil
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_palette_with_fewer_than_16_entries()
  reject(function(m)
    m.signposts.types[0].palette[15] = nil
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_palette_with_more_than_16_entries()
  reject(function(m)
    m.signposts.types[0].palette[16] = { r = 0, g = 0, b = 0 }
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_palette_color_missing_components()
  reject(function(m)
    m.signposts.types[0].palette[0] = { r = 0, g = 0 }
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_palette_color_non_integral_component()
  reject(function(m)
    m.signposts.types[0].palette[0] = { r = 0.5, g = 0, b = 0 }
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_palette_color_out_of_range()
  reject(function(m)
    m.signposts.types[0].palette[0] = { r = 256, g = 0, b = 0 }
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].palette[5].b = -1
  end, "FIELD_UI_MANIFEST_INVALID")
end

-- Per-type frameTiles validation: must exist, be exactly 144x8, and fit in
-- the signpost tiles atlas.
function T.v5_rejects_type_missing_frame_tiles()
  reject(function(m)
    m.signposts.types[0].frameTiles = nil
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_frame_tiles_wrong_dimensions()
  reject(function(m)
    m.signposts.types[0].frameTiles.width = 136
  end, "FIELD_UI_MANIFEST_INVALID")
  reject(function(m)
    m.signposts.types[0].frameTiles.height = 16
  end, "FIELD_UI_MANIFEST_INVALID")
end

function T.v5_rejects_frame_tiles_outside_atlas()
  reject(function(m)
    m.signposts.types[0].frameTiles = { x = 200, y = 0, width = 144, height = 8 }
  end, "FIELD_UI_MANIFEST_INVALID")
end

return { tests = T }
