-- Behavior: wayfinding manifest rects are final 48x32 surfaces, not 192x8 strips.
-- This file covers the manifest validator contract for final surfaces.

local Assert = require("tests.support.Assert")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {}

local function validPalette()
  local palette = {}
  for slot = 0, 15 do
    palette[slot] = { r = slot * 16, g = slot * 16, b = slot * 16 }
  end
  return palette
end

local function baseManifest()
  local frameTiles = {}
  for frame = 0, 19 do
    frameTiles[frame] = { x = 0, y = 0, width = 144, height = 8 }
  end
  local manifest = {
    schema = DerivedAssetContract.fieldUi.schema,
    reference = { width = 256, height = 192 },
    assets = {
      ["hgss.dialogue_frame.tiles"] = {
        image = "assets/generated/field/ui/dialogue-frame-tiles.png",
        width = 144,
        height = 168,
      },
      ["hgss.dialogue_continue_cursor"] = {
        image = "assets/generated/field/ui/dialogue-continue-cursor.png",
        width = 48,
        height = 320,
      },
      ["hgss.signpost.tiles"] = { image = "assets/generated/field/ui/signpost-tiles.png", width = 288, height = 16 },
      ["hgss.signpost.wayfinding"] = {
        image = "assets/generated/field/ui/wayfinding-tiles.png",
        width = 192,
        height = 64,
      },
      ["hgss.start_menu.background"] = { image = "assets/generated/field/ui/start-menu.png", width = 256, height = 192 },
      ["hgss.start_menu.cursor"] = {
        image = "assets/generated/field/ui/start-menu-cursor.png",
        width = 32,
        height = 32,
      },
      ["hgss.start_menu.icons"] = {
        image = "assets/generated/field/ui/start-menu-icons.png",
        width = 352,
        height = 80,
      },
      ["hgss.start_menu.icon_palette"] = {
        image = "assets/generated/field/ui/start-menu-icon-palette.png",
        width = 16,
        height = 2,
      },
      ["hgss.start_menu.chrome_sub"] = {
        image = "assets/generated/field/ui/start-menu-chrome-sub.png",
        width = 256,
        height = 256,
      },
      ["hgss.trainer_card.front"] = { image = "assets/generated/field/ui/trainer-card.png", width = 256, height = 192 },
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
      ["hgss.yes_no_prompt.yes_normal"] = {
        image = "assets/generated/field/ui/yes-no-prompt-yes-normal.png",
        width = 48,
        height = 32,
      },
      ["hgss.yes_no_prompt.yes_selected"] = {
        image = "assets/generated/field/ui/yes-no-prompt-yes-selected.png",
        width = 48,
        height = 32,
      },
      ["hgss.yes_no_prompt.no_normal"] = {
        image = "assets/generated/field/ui/yes-no-prompt-no-normal.png",
        width = 48,
        height = 32,
      },
      ["hgss.yes_no_prompt.no_selected"] = {
        image = "assets/generated/field/ui/yes-no-prompt-no-selected.png",
        width = 48,
        height = 32,
      },
    },
    dialogueFrames = {
      count = 20,
      frameTiles = frameTiles,
      standardFrame = {
        frameTiles = { x = 0, y = 160, width = 72, height = 8 },
        palette = validPalette(),
      },
      palettes = (function()
        local palettes = {}
        for frame = 0, 19 do
          palettes[frame] = validPalette()
        end
        return palettes
      end)(),
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
      interactive = FieldUiFixture.startMenuInteractive(),
      iconTable = (function()
        local rows = {}
        local cell = 0
        for icon = 0, 12 do
          if icon == 8 or icon == 9 then
            rows[icon + 1] = { art = "text", label = 32, labelKind = "static" }
          elseif icon == 10 then
            rows[icon + 1] = { art = "poke_icon", label = 32, labelKind = "static" }
          else
            rows[icon + 1] = {
              art = "sprite",
              visual = {
                normal = {
                  asset = "hgss.start_menu.icons",
                  rect = { x = cell * 32, y = 0, width = 32, height = 40 },
                  offset = { x = 0, y = 0 },
                },
                selected = {
                  asset = "hgss.start_menu.icons",
                  rect = { x = cell * 32, y = 40, width = 32, height = 40 },
                  offset = { x = 0, y = 0 },
                },
              },
              label = icon,
              labelKind = "static",
            }
            cell = cell + 1
          end
        end
        return rows
      end)(),
      iconPalette = { asset = "hgss.start_menu.icon_palette", banks = 2, selectionBank = 2 },
      contexts = {
        { 0, 1, 2, 3, 4, 5, 6 },
        { 7, 0, 1, 2, 3, 4, 6 },
        { 7, 0, 1, 3, 4, 6, 10 },
        { 7, 0, 1, 3, 4, 6, 9 },
        { 11, 0, 1, 2, 12, 4, 6 },
        { 1, 2, 4, 6, false, false, false },
        { 1, 4, 6, false, false, false, false },
      },
      actionIcons = {
        ["vanilla.pokedex"] = 0,
        ["vanilla.pokemon"] = 1,
        ["vanilla.bag"] = 2,
        ["vanilla.pokegear"] = 3,
        ["vanilla.trainer_card"] = 4,
        ["vanilla.save"] = 5,
        ["vanilla.options"] = 6,
      },
      chrome = {
        main = { asset = "hgss.start_menu.background", transparentAboveY = 136 },
        sub = { asset = "hgss.start_menu.chrome_sub" },
      },
      labelPalette = FieldUiFixture.startMenuLabelPalette(),
    },
    trainerCard = { front = { x = 0, y = 0, width = 256, height = 192 } },
    yesNoPrompt = {
      shapes = {
        compact = {
          width = 48,
          height = 32,
          yes = {
            normal = {
              asset = "hgss.yes_no_prompt.yes_normal",
              rect = { x = 0, y = 0, width = 48, height = 32 },
            },
            selected = {
              asset = "hgss.yes_no_prompt.yes_selected",
              rect = { x = 0, y = 0, width = 48, height = 32 },
            },
          },
          no = {
            normal = {
              asset = "hgss.yes_no_prompt.no_normal",
              rect = { x = 0, y = 0, width = 48, height = 32 },
            },
            selected = {
              asset = "hgss.yes_no_prompt.no_selected",
              rect = { x = 0, y = 0, width = 48, height = 32 },
            },
          },
        },
      },
    },
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
  return FieldUiFixture.addNamingSemantics(manifest)
end

function T.final_surface_48x32_is_accepted_under_the_current_schema()
  local manifest = baseManifest()
  -- The expected final contract is 48x32 per wayfinding entry.
  manifest.schema = DerivedAssetContract.fieldUi.schema
  manifest.assets["hgss.signpost.wayfinding"] =
    { image = "assets/generated/field/ui/wayfinding-tiles.png", width = 48, height = 32 }
  manifest.signposts.types[0].wayfinding[0] = { x = 0, y = 0, width = 48, height = 32 }
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isTrue(ok, "48x32 final surface under the current schema should be accepted")
  Assert.isNil(err)
end

function T.old_strip_192x8_is_rejected_under_final_surface_contract()
  local manifest = baseManifest()
  manifest.schema = DerivedAssetContract.fieldUi.schema
  manifest.assets["hgss.signpost.wayfinding"] =
    { image = "assets/generated/field/ui/wayfinding-tiles.png", width = 192, height = 32 }
  manifest.signposts.types[0].wayfinding[0] = { x = 0, y = 0, width = 192, height = 8 }
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok, "old 192x8 strip must be rejected under final surface contract")
  Assert.isTrue(err ~= nil)
  Assert.equal(err and err.code, "FIELD_UI_MANIFEST_INVALID")
end

function T.stale_v5_schema_is_rejected()
  local manifest = baseManifest()
  manifest.schema = "g4-field-ui-v5"
  manifest.signposts.types[0].wayfinding[0] = { x = 0, y = 0, width = 48, height = 32 }
  -- Even if rect is 48x32, old schema must be rejected
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok, "v5 schema must be rejected as stale")
  Assert.isTrue(err ~= nil)
  Assert.equal(err and err.code, "FIELD_UI_MANIFEST_INVALID")
end

function T.final_surface_must_be_inside_atlas_bounds()
  local manifest = baseManifest()
  manifest.schema = DerivedAssetContract.fieldUi.schema
  manifest.assets["hgss.signpost.wayfinding"] =
    { image = "assets/generated/field/ui/wayfinding-tiles.png", width = 48, height = 32 }
  manifest.signposts.types[0].wayfinding[0] = { x = 10, y = 10, width = 48, height = 32 }
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok, "wayfinding rect escaping atlas must be rejected")
  Assert.isTrue(err ~= nil)
  Assert.equal(err and err.code, "FIELD_UI_MANIFEST_INVALID")
end

function T.final_surface_must_be_exactly_48x32()
  local manifest = baseManifest()
  manifest.schema = DerivedAssetContract.fieldUi.schema
  manifest.assets["hgss.signpost.wayfinding"] =
    { image = "assets/generated/field/ui/wayfinding-tiles.png", width = 48, height = 32 }
  manifest.signposts.types[0].wayfinding[0] = { x = 0, y = 0, width = 47, height = 32 }
  local ok, _ = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok, "47x32 must be rejected - exactly 48x32 required")
  local manifest2 = baseManifest()
  manifest2.schema = DerivedAssetContract.fieldUi.schema
  manifest2.assets["hgss.signpost.wayfinding"] =
    { image = "assets/generated/field/ui/wayfinding-tiles.png", width = 48, height = 32 }
  manifest2.signposts.types[0].wayfinding[0] = { x = 0, y = 0, width = 48, height = 31 }
  local ok2, _ = FieldUiAssetCache.validateManifest(manifest2)
  Assert.isFalse(ok2, "48x31 must be rejected")
end

function T.missing_wayfinding_map_is_rejected()
  local manifest = baseManifest()
  manifest.schema = DerivedAssetContract.fieldUi.schema
  manifest.assets["hgss.signpost.wayfinding"] =
    { image = "assets/generated/field/ui/wayfinding-tiles.png", width = 48, height = 32 }
  manifest.signposts.types[0].wayfinding = {}
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok)
  Assert.isTrue(err ~= nil)
  Assert.equal(err and err.code, "FIELD_UI_MANIFEST_INVALID")
end

return { tests = T }
