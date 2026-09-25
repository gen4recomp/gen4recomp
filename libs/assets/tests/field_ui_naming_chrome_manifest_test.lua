-- The generated field-UI class carries the reusable normal naming chrome as
-- strict source-independent data: one opaque 256x192 base, exactly the three
-- normal pages (upper, lower, symbols) as 256x112 overlays, and the canonical
-- page placement at y=80. Manifests missing that section or carrying
-- malformed naming dimensions, page keys, placement, or asset references must
-- fail validation before any renderer can consume them.

local Assert = require("tests.support.Assert")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {}

local BASE_ID = "hgss.naming_screen.base"
local UPPER_ID = "hgss.naming_screen.page_upper"
local LOWER_ID = "hgss.naming_screen.page_lower"
local SYMBOLS_ID = "hgss.naming_screen.page_symbols"

local function withNaming(manifest)
  manifest.reference = { width = 256, height = 192 }
  FieldUiFixture.addStartMenuIconContract(manifest)
  FieldUiFixture.addNamingSemantics(manifest)
  return manifest
end

local function reject(mutate, message)
  local manifest = withNaming(FieldUiFixture.manifest())
  mutate(manifest)
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok, message)
  Assert.equal(assert(err).code, "FIELD_UI_MANIFEST_INVALID")
end

function T.complete_naming_chrome_validates()
  local manifest = withNaming(FieldUiFixture.manifest())
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isTrue(ok, "a complete naming section must validate: " .. tostring(err and err.message))
end

function T.manifest_without_naming_chrome_is_rejected()
  local manifest = FieldUiFixture.manifest()
  manifest.reference = { width = 256, height = 192 }
  Assert.isNil(manifest.namingScreen, "the shared fixture carries no naming section")
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  Assert.isFalse(ok, "naming chrome is required, so a manifest without it must fail")
  Assert.equal(assert(err).code, "FIELD_UI_MANIFEST_INVALID")
end

function T.missing_base_is_rejected()
  reject(function(m)
    m.namingScreen.base = nil
    m.assets[BASE_ID] = nil
  end, "a naming section without its base must fail")
end

function T.missing_one_page_is_rejected()
  reject(function(m)
    m.namingScreen.pages.symbols = nil
    m.assets[SYMBOLS_ID] = nil
  end, "a naming section without its symbols page must fail")
end

function T.extra_page_is_rejected()
  reject(function(m)
    m.assets["hgss.naming_screen.page_extra"] = {
      image = "assets/generated/field/ui/naming-screen-page-extra.png",
      width = 256,
      height = 112,
    }
    m.namingScreen.pages.extra = { asset = "hgss.naming_screen.page_extra", width = 256, height = 112 }
  end, "normal naming carries exactly three pages, so a fourth must fail")
end

function T.unknown_page_key_is_rejected()
  reject(function(m)
    m.namingScreen.pages.upper = nil
    m.namingScreen.pages.digits = { asset = UPPER_ID, width = 256, height = 112 }
  end, "an unknown page key must fail instead of standing in for a normal page")
end

function T.wrong_base_dimensions_are_rejected()
  reject(function(m)
    m.namingScreen.base.width = 128
    m.assets[BASE_ID].width = 128
  end, "a base narrower than the canonical surface must fail")
end

function T.wrong_page_dimensions_are_rejected()
  reject(function(m)
    m.namingScreen.pages.lower.height = 192
    m.assets[LOWER_ID].height = 192
  end, "a full-height page overlay must fail")
end

function T.wrong_page_placement_is_rejected()
  reject(function(m)
    m.namingScreen.placement.y = 0
  end, "page placement anywhere but the canonical y=80 must fail")
end

function T.invalid_asset_path_is_rejected()
  reject(function(m)
    m.assets[UPPER_ID] = nil
  end, "a page naming an asset the manifest does not index must fail")
end

function T.source_member_ids_do_not_leak_into_the_naming_section()
  local manifest = withNaming(FieldUiFixture.manifest())
  local forbidden = { member = true, memberId = true, narcId = true, alias = true, fileId = true }
  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for key, nested in pairs(value) do
      if type(key) == "string" and forbidden[key] then
        Assert.isTrue(false, "naming manifest leaks source detail '" .. key .. "' at " .. path)
      end
      scan(nested, path .. "." .. tostring(key))
    end
  end
  scan(manifest.namingScreen, "namingScreen")
end

function T.sprite_visuals_without_offset_anchor_or_image_reference_are_rejected()
  reject(function(m)
    m.namingScreen.controls.upper.offset = nil
  end, "a control visual without its generated frame offset must fail")
  reject(function(m)
    m.namingScreen.controls.back.anchor = nil
  end, "a control visual without its canonical anchor must fail")
  reject(function(m)
    m.namingScreen.controls.ok.asset = "hgss.naming_screen.missing"
  end, "a control visual naming an asset the manifest does not index must fail")
  reject(function(m)
    m.namingScreen.cursor.keyboard.origin = nil
  end, "the keyboard cursor without its stepping origin must fail")
  reject(function(m)
    m.namingScreen.cursor.home.ok = nil
  end, "a missing home cursor variant must fail")
  reject(function(m)
    m.namingScreen.entrySlots.selected = nil
  end, "a missing selected slot visual must fail")
  reject(function(m)
    m.namingScreen.playerSubjects.female.anchor = { x = 0, y = 0 }
  end, "a player subject away from its source anchor must fail")
  reject(function(m)
    m.namingScreen.text.keyboard.cells[1][1].width = 17
  end, "a keyboard text cell wider than the 16px source column must fail")
  reject(function(m)
    m.namingScreen.text.name.advanceX = 8
  end, "an entered-name advance other than 12px must fail")
end

function T.stale_static_subject_and_cursor_records_are_rejected()
  reject(function(m)
    m.namingScreen.playerSubjects.male =
      { asset = "hgss.naming_screen.subject_male", anchor = { x = 24, y = 8 }, offset = { x = 0, y = 0 } }
  end, "a static subject record without animation frames must fail")
  reject(function(m)
    m.namingScreen.cursor.keyboard =
      { asset = "hgss.naming_screen.cursor_keyboard", anchor = { x = 26, y = 91 }, offset = { x = 0, y = 0 } }
  end, "a static cursor record without animation frames must fail")
  reject(function(m)
    m.namingScreen.entrySlots.selected =
      { asset = "hgss.naming_screen.slot_selected", anchor = { x = 80, y = 39 }, offset = { x = 0, y = 0 } }
  end, "a static selected slot without animation frames must fail")
  reject(function(m)
    m.namingScreen.pokemonSubject = nil
  end, "a missing Pokémon naming subject contract must fail")
end

function T.malformed_animation_records_are_rejected()
  reject(function(m)
    m.namingScreen.playerSubjects.male.loopStartFrameIdx = 5
  end, "a loop start outside the animation frames must fail")
  reject(function(m)
    m.namingScreen.playerSubjects.male.frames[1].duration = 0
  end, "a zero-duration frame must fail")
  reject(function(m)
    m.namingScreen.playerSubjects.male.playMode = "ping_pong"
  end, "an unsupported play mode must fail")
  reject(function(m)
    m.namingScreen.playerSubjects.male.pulseAsset = "hgss.naming_screen.cursor_keyboard_mask"
  end, "a subject record carrying a pulse-mask role must fail")
  reject(function(m)
    m.namingScreen.playerSubjects.male.frames[1].pulseRect = { x = 0, y = 0, width = 16, height = 16 }
  end, "a subject frame carrying a pulse rect must fail")
  reject(function(m)
    m.namingScreen.cursor.keyboard.pulseAsset = nil
  end, "a cursor record without its pulse-mask atlas must fail")
  reject(function(m)
    m.namingScreen.cursor.keyboard.frames[1].pulseRect.width = m.namingScreen.cursor.keyboard.frames[1].rect.width + 1
  end, "a pulse rect wider than its frame must fail")
  reject(function(m)
    m.namingScreen.cursor.keyboard.frames[1].pulseRect = nil
  end, "a cursor frame without its mask rect must fail")
  reject(function(m)
    m.namingScreen.pokemonSubject.frames[1].iconFrame = 0
  end, "a Pokémon frame outside the one-based icon atlas must fail")
  reject(function(m)
    m.namingScreen.pokemonSubject.frames[1].asset = "hgss.naming_screen.base"
  end, "a Pokémon frame must not reference duplicated generated pixels")
end

return { tests = T }
