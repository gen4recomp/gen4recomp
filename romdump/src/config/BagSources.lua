-- Producer-side semantic inventory of the field-bag presentation sources:
-- NARC 15 member selection, canonical geometry, hero model/animation
-- selection, and normalized presentation facts. The audit basis is
-- pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- asm/overlay_15.s (the field-bag application; Bag_Init opens NARC 15 and
-- every member below is loaded by an audited call site), plus
-- include/camera.h, include/sprite_system.h, include/bg_window.h, and
-- include/text.h for the called-API signatures. Pure data and pure
-- functions; no I/O. Never imported by runtime: libs/assets, game, and
-- script packages must not require this module.
--
-- Audited member selection (NARC 15 = bag_ui; all member identities are
-- zero-based):
--
-- 2D backgrounds: char 7 + screens 9/54/93/94 (upper pane; 93 is the female
-- backdrop and 94 the male backdrop, selected by the gender byte; 54 and 9
-- are the mode-swapped description frame screens) and char 46 + screens
-- 39/42/43/44/45/52/53 (lower pane; 43+39 browse, 44+42 action menu, 45
-- confirmation, 52/53 quantity). Raster palettes 8 (upper) and 40 (lower)
-- reproduce the retail layer colors; palette slots and the text-layer
-- GetPlttData selections (40/41) stay producer-side.
--
-- Sprites: the 39-entry ManagedSpriteTemplate table at ov15_02200B0C binds
-- three bag resource groups. Tabs and widgets use char 51 + palette 47 +
-- cell 49 + anim 50 (tab sprites sit at centers 16+32k, y 16 with anim and
-- palette slot equal to the pocket index; the highlight reuses anim 8 and
-- palette slot 9). The top strip uses char 26 + palette 15 + cell 25 +
-- anim 24. The selection cursor uses char 6 + cell 5 + palette 47 + anim 4
-- (four sequences for the four cursor cells). Item icons resolve through
-- archive 18 (GetItemIndexMapping/GetItemIconCell/GetItemIconAnim) and are
-- never compiled here. NANR 21 loads with no static template binding and is
-- recorded but not compiled.
--
-- Hero 3D: the model init selects by the gender byte (0 is male): model 55
-- with pattern members 57-64, joint members 65-72, and material member 73,
-- or model 74 with pattern members 76-83, joint members 84-91, and material
-- member 92. The first pattern member of each group (56/75) is never read.
-- The active state slot is the selected pocket 0..7 (compared against 8,
-- wrapped modulo 8, and switched on pocket change), so each state pairs one
-- pattern clip with one joint clip plus the shared material clip.
--
-- Geometry: window tiles convert at 8 pixels per tile. Item slots come from
-- the twelve-entry window table at ov15_02200908 (two layers sharing six
-- grid positions); tab centers from the per-pocket placement table at
-- ov15_02200AB8 (sprite centers, matching the template row); icon centers
-- from the same table's slot entries; the cursor anchor from the sprite
-- position update (y 177, x stepping 16 from 16); the count readout and
-- Cancel windows from the lower-screen window setup; the description window
-- and its text origin from the upper-screen window setup and the
-- description printer; action buttons and quantity digits from their window
-- tables. The upper pane carries the hero and description; the lower pane
-- carries tabs, slots, and affordances.
--
-- Presentation: the per-frame camera copies target (0,0,0), distance
-- 0x153B51, and the angle block (x 0xE982, y 0x1420) from static tables;
-- perspective type/angle and clip planes (near 0x7B000, far 0x6A4000) are
-- static. The global material registers are the setup immediates:
-- NNS_G3dGlbMaterialColorDiffAmb(0x3DEF, 0x294A, FALSE) and
-- NNS_G3dGlbMaterialColorSpecEmi(0x3DEF, 0x3DEF, FALSE), so diffuse,
-- specular, and emission are mid-gray 15 and ambient is gray 10 rather
-- than white/zero. The model init additionally forces the material
-- ambient onto the global register (ModifyMatFlag FALSE/AMBIENT) while
-- diffuse, specular, and emission stay per-material.
--
-- Action text: msg_0010.gmm supplies the toss/register/unregister/cancel/
-- confirm labels and the move/toss prompt templates; msg_0000.gmm supplies
-- the generic move label. The compiler lowers the token streams to semantic
-- labels and text/item/quantity template segments.
--
-- Registration markers: Bag UI character member 37 holds the 104x16 source
-- bitmap; slot 1 copies source X 24 and slot 2 copies source X 64 (Y 0,
-- 40x16 each), placed slot-locally at offset (0, 16). The hero draws with identity rotation, unit scale, translation
-- (0,-48,0), and four white lights all pointing down positive x: the hero
-- init loops four times over NNS_G3dGlbLightVector(i, 0x1000, 0, 0) with
-- NNS_G3dGlbLightColor(i, 0x7FFF), so every light carries unit vector
-- (1, 0, 0) in manifest float domain (0x1000 is 1.0 fixed-point) and white
-- color (31, 31, 31).

local BagSources = {}

BagSources.provenance = {
  repo = "pret/pokeheartgold",
  commit = "0985e8718df4f25e64d6507d89c0c97c0d288981",
  sources = {
    "asm/overlay_15.s",
    "asm/include/overlay_15.inc",
    "include/camera.h",
    "include/sprite_system.h",
    "include/bg_window.h",
    "include/text.h",
    "files/msgdata/msg/msg_0010.gmm",
    "files/msgdata/msg/msg_0000.gmm",
  },
}

BagSources.archive = {
  alias = "bag_ui",
  symbol = "NARC_a_0_1_5",
}

-- Screen (NSCR) members by semantic role.
BagSources.screens = {
  upperBase = 54,
  upperAlternate = 9,
  upperBackdropMale = 94,
  upperBackdropFemale = 93,
  listSlots = 43,
  listWash = 39,
  actionSlots = 44,
  actionWash = 42,
  confirmation = 45,
  quantity = 52,
  quantityAlt = 53,
}

-- Character (NCGR) members by semantic role. The registration marker source
-- is the bitmap the retail registration blit copies its two slot regions
-- from; see `BagSources.registration` for the audited crop facts.
BagSources.chars = {
  upper = 7,
  lower = 46,
  registrationMarker = 37,
}

-- Palette (NCLR) members used for rasterization by semantic role.
BagSources.palettes = {
  upper = 8,
  lower = 40,
}

-- Sprite (NCGR/NCER/NANR/NCLR) members by widget group.
BagSources.sprites = {
  strip = { char = 26, cell = 25, anim = 24, palette = 15 },
  cursor = { char = 6, cell = 5, anim = 4, palette = 47 },
  tabs = { char = 51, cell = 49, anim = 50, palette = 47 },
}

-- Source-selected sprite states. Animation and palette numbers stay in this
-- producer-only audit; generated visuals contain only the realized pixels.
BagSources.spriteStates = {
  tabs = {
    normal = {
      { animation = 0, palette = 0 },
      { animation = 1, palette = 1 },
      { animation = 2, palette = 2 },
      { animation = 3, palette = 3 },
      { animation = 4, palette = 4 },
      { animation = 5, palette = 5 },
      { animation = 6, palette = 6 },
      { animation = 7, palette = 7 },
    },
    selected = { animation = 8, palette = 9 },
  },
  cursor = { animations = { 0, 1, 2, 3 } },
  strip = { animation = 0 },
}

-- BG surfaces are listed in retail bottom-to-top order. The producer applies
-- transparency while composing them, so this ordering never reaches runtime.
BagSources.lowerLayers = {
  browse = { "listWash", "listSlots" },
  action = { "actionWash", "actionSlots" },
  quantity = { "quantity", "quantityAlt" },
  confirmation = { "confirmation" },
}

-- Audited but uncompiled: NANR 21 loads with no static template binding, so
-- no compiled selection references it.
BagSources.unboundAnimations = { 21 }

-- Semantic message selection for the generated action labels and prompt
-- templates. Banks are msgdata members (bank 10 = msg_0010.gmm, bank 0 =
-- msg_0000.gmm); indexes are zero-based message ids within the bank. The
-- runtime manifest carries only the lowered labels/templates, never these
-- selectors. Pinned facts: msg_0010 carries TRASH (1), REGISTER (2),
-- CONFIRM (5), CANCEL (8), DESELECT (18), the move prompt (46), the toss
-- quantity prompt (53), and the toss confirmation prompt (55); msg_0000
-- carries the generic MOVE label (3) reused for the manual reorder action.
BagSources.messages = {
  actionLabels = {
    toss = { bank = 10, index = 1 },
    move = { bank = 0, index = 3 },
    register = { bank = 10, index = 2 },
    unregister = { bank = 10, index = 18 },
    cancel = { bank = 10, index = 8 },
    confirm = { bank = 10, index = 5 },
  },
  templates = {
    movePrompt = { bank = 10, index = 46 },
    tossQuantity = { bank = 10, index = 53 },
    tossConfirm = { bank = 10, index = 55 },
  },
}

-- Source widget placement and visibility. Template entry 0 of the
-- 39-entry ManagedSpriteTemplate table at ov15_02200B0C is the strip widget
-- (char 26 + palette 15 + cell 25 + anim 24 group, animation 0): its template
-- position is the sprite center (177, 14), matching the tab convention where
-- template centers coincide with their rect centers (entry 9 at (16, 16) is
-- the center of the first 32x32 tab rect). The creation path hides it and no
-- audited state path ever shows it again: sprite index 0 is hidden at init
-- and every SetDrawFlag(1) in overlay_15.s addresses other sprite indexes,
-- so normal browse never renders the strip. Placement is the template sprite
-- center; states name the audited browse participation only.
BagSources.widgets = {
  sourceStrip = {
    placement = { x = 177, y = 14 },
    states = { browsing = false },
  },
}

-- Spare hero pattern members the model init never reads.
BagSources.sparePatternMembers = { 56, 75 }

-- Hero model/animation member selection by gender.
BagSources.hero = {
  male = { model = 55, patternBase = 57, jointBase = 65, material = 73 },
  female = { model = 74, patternBase = 76, jointBase = 84, material = 92 },
  states = {
    { slot = 0, pocket = "items" },
    { slot = 1, pocket = "medicine" },
    { slot = 2, pocket = "balls" },
    { slot = 3, pocket = "tmhm" },
    { slot = 4, pocket = "berries" },
    { slot = 5, pocket = "mail" },
    { slot = 6, pocket = "battle_items" },
    { slot = 7, pocket = "key_items" },
  },
}

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

-- Canonical pane geometry in pixels. Tab rectangles tile the top strip row;
-- slots form the two-column by three-row grid with per-slot icon centers;
-- the cursor anchor is center-origin with the audited stepping.
BagSources.geometry = {
  tabs = {
    rect(0, 0, 32, 32),
    rect(32, 0, 32, 32),
    rect(64, 0, 32, 32),
    rect(96, 0, 32, 32),
    rect(128, 0, 32, 32),
    rect(160, 0, 32, 32),
    rect(192, 0, 32, 32),
    rect(224, 0, 32, 32),
  },
  highlight = { animIndex = 8, paletteSlot = 9 },
  slots = {
    { rect = rect(32, 40, 88, 32), iconCenter = { x = 48, y = 56 } },
    { rect = rect(160, 40, 88, 32), iconCenter = { x = 176, y = 56 } },
    { rect = rect(32, 80, 88, 32), iconCenter = { x = 48, y = 96 } },
    { rect = rect(160, 80, 88, 32), iconCenter = { x = 176, y = 96 } },
    { rect = rect(32, 120, 88, 32), iconCenter = { x = 48, y = 136 } },
    { rect = rect(160, 120, 88, 32), iconCenter = { x = 176, y = 136 } },
  },
  cursorAnchor = { size = 16, y = 177, xBase = 16, xStep = 16, count = 8, origin = "center" },
  countReadout = { rect = rect(80, 168, 56, 16), textAt = { x = 0, y = 0 } },
  cancel = rect(192, 168, 56, 16),
  descriptionFrame = rect(0, 144, 256, 48),
  descriptionText = rect(20, 144, 236, 48),
  actionButtons = {
    rect(8, 136, 80, 16),
    rect(104, 136, 80, 16),
    rect(8, 168, 80, 16),
    rect(104, 168, 80, 16),
  },
  quantityDigits = {
    rect(128, 112, 16, 24),
    rect(160, 112, 16, 24),
    rect(192, 112, 16, 24),
  },
}

-- Registration marker source facts. The retail registration path loads Bag
-- UI character member 37 as a 104x16 source bitmap (BlitBitmapRectToWindow
-- contract per include/bg_window.h) and copies one 40x16 region per slot at
-- source Y 0: slot 1 from source X 24, slot 2 from source X 64. The compiled
-- markers are placed slot-locally at the destination offset below.
BagSources.registration = {
  bitmapWidth = 104,
  bitmapHeight = 16,
  markerWidth = 40,
  markerHeight = 16,
  sourceY = 0,
  slot1X = 24,
  slot2X = 64,
  offset = { x = 0, y = 16 },
}

-- Normalized hero presentation facts. Angles convert from the source u16
-- domain (v/65536*360 degrees); fixed-point values convert at 1/4096. The
-- perspective angle is the raw u16 the camera init loads with a halfword
-- read at CameraParam offset +14: the u8 perspective type at +12 is
-- followed by an alignment pad at +13, so the audited static bytes
-- 01 0A at +14/+15 are 0x0A01 (2561), converted by the runtime through
-- the pinned sine/cosine perspective convention.
BagSources.presentation = {
  camera = {
    target = { x = 0, y = 0, z = 0 },
    distance = 1391441 / 4096,
    angleXDegrees = 59778 / 65536 * 360,
    angleYDegrees = 5152 / 65536 * 360,
    perspectiveType = 0,
    perspectiveAngle = 2561,
    clipNear = 503808 / 4096,
    clipFar = 6963200 / 4096,
  },
  transform = {
    translation = { x = 0, y = -48, z = 0 },
    rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    scale = { x = 1, y = 1, z = 1 },
  },
  lights = {
    count = 4,
    color = { r = 31, g = 31, b = 31 },
    vectors = {
      { x = 1, y = 0, z = 0 },
      { x = 1, y = 0, z = 0 },
      { x = 1, y = 0, z = 0 },
      { x = 1, y = 0, z = 0 },
    },
  },
  -- Global material color registers as raw RGB555 words from the setup
  -- immediates above; the compiler normalizes them to semantic colors.
  materials = {
    diffuse = 0x3DEF,
    ambient = 0x294A,
    specular = 0x3DEF,
    emission = 0x3DEF,
  },
}

return BagSources
