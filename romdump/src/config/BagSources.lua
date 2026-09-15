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
-- confirmation, 52/53 quantity). Raster palettes 8 (upper) and 41 (lower)
-- reproduce the retail layer colors; the lower palette below is the member
-- the retail pocket switch selects (decoded GetPlttData slot 1), and the
-- text-layer GetPlttData slot selections stay producer-side.
--
-- Sprites: the 39-entry ManagedSpriteTemplate table at ov15_02200B0C binds
-- the live bag resource groups. Tabs use char 51 + palette 47 + cell 49 +
-- anim 50: template entries 9..16 carry the eight pocket tabs at centers
-- 16+32k, y 16 with animation and palette slot equal to the pocket index,
-- and entry 19 carries the unselected Cancel face at (224, 176) with
-- animation 16 and palette slot 8. The movable focus sprite is template
-- entry 20 (animation 8, palette slot 9 at creation); ov15_021FFECC drives
-- that single sprite through the 21-record position/state table at
-- ov15_02200AB8, applying one record's X, Y, animation, and palette
-- override per call (records 0..7 tab targets, 8..13 item targets, 14..15
-- the lower-left pair, 16 Cancel, 17..20 action targets). The item-row loop
-- at ov15_02200140 instead positions template entries 1..6 -- the six item
-- icon sprites whose per-slot char/palette tags ov15_021FF8F0 rebinds to the
-- item graphics -- at their own template X/Y centers (22/152,
-- 59/100/139); those placements never pass through the focus table.
-- Entries 28..31 sit at the four action-button centers with animation 22;
-- entries 32..37 are the quantity-screen widgets driven with the tables at
-- ov15_02200A58 and ov15_02200A88; the remaining entries are auxiliary
-- states. Item icons resolve through archive 18
-- (GetItemIndexMapping/GetItemIconCell/GetItemIconAnim) and are never
-- compiled here. NANR 21 loads with no static template binding and is
-- recorded but not compiled.
--
-- The top strip (template entry 0: char 26 + palette 15 + cell 25 +
-- anim 24, sprite center (177, 14)) is intentionally uncompiled: the
-- creation path hides sprite index 0 and no audited SetDrawFlag(1) path
-- re-enables it, so it has no visible state.
--
-- Hero 3D: the model init selects by the gender byte (0 is male): model 55
-- with pattern members 57-64, joint members 65-72, and material member 73,
-- or model 74 with pattern members 76-83, joint members 84-91, and material
-- member 92. The first pattern member of each group (56/75) is never read.
-- The active state slot is the selected pocket 0..7 (compared against 8,
-- wrapped modulo 8, and switched on pocket change), so each state pairs one
-- pattern clip with one joint clip plus the shared material clip.
--
-- Geometry: window tiles convert at 8 pixels per tile. Item slots pair the
-- six touch bounds at ov15_02200684 with the six 88x32 window rectangles
-- from the twelve-entry window table at ov15_02200908 (two layers sharing
-- six grid positions); tab rects tile the top strip row; icon centers are
-- the six item-icon template placements (entries 1..6, positioned by the
-- item-row loop), never the focus table's item targets; the cursor anchor
-- from the sprite position update (y 177, x stepping 16 from 16); the count readout and
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
-- (0,-45,0), and four white lights all pointing down positive x: the hero
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

-- Palette (NCLR) members used for rasterization by semantic role. The lower
-- member feeds the pocket-dependent realization: destination banks 0..3
-- copy source banks p, p, p+1, p (16 colors each) for zero-based pocket p,
-- matching the retail lower-BG palette switch.
BagSources.palettes = {
  upper = 8,
  lower = 41,
}

-- Pocket-relative source bank offsets for the lower background realization.
-- Destination bank d (0..3) copies source bank p + offsets[d + 1], where p
-- is the zero-based pocket index and each bank holds bankSize colors.
BagSources.lowerPaletteBanks = {
  bankSize = 16,
  offsets = { 0, 0, 1, 0 },
}

-- Sprite (NCGR/NCER/NANR/NCLR) members by live widget group.
BagSources.sprites = {
  cursor = { char = 6, cell = 5, anim = 4, palette = 47 },
  tabs = { char = 51, cell = 49, anim = 50, palette = 47 },
}

-- Source-selected sprite states. Animation and palette numbers stay in this
-- producer-only audit; generated visuals contain only the realized pixels.
-- The focus states select frames of the tab resource group for the movable
-- focus sprite (template entry 20); the Cancel face selects the unselected
-- Cancel artwork for finalized-background composition.
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
  },
  focus = {
    tabs = { animation = 8, palette = 9 },
    items = { animation = 10, palette = 9 },
    cancel = { animation = 17, palette = 9 },
    actions = { animation = 23, palette = 9 },
  },
  cancelFace = { animation = 16, palette = 8 },
  cursor = { animations = { 0, 1, 2, 3 } },
}

-- BG surfaces are listed in retail bottom-to-top order. The producer applies
-- transparency while composing them, so this ordering never reaches runtime.
BagSources.lowerLayers = {
  browse = { "listWash", "listSlots" },
  action = { "actionWash", "actionSlots" },
  quantity = { "quantity", "quantityAlt" },
  confirmation = { "confirmation" },
}

-- Browse count replay facts from ov15_021FD43C over the ov15_022013A8 table:
-- six visible-count blocks of four tilemap operations for counts 0..5.
-- Count 6 performs no mutation (the source early-returns on count 6), so it
-- carries no block. Coordinates are tile-grid positions in the decoded
-- browse screen: `copy` duplicates a source rectangle onto a destination
-- rectangle of the same screen, `fill` clears a rectangle to the blank tile,
-- and `nop` replays nothing. The runtime manifest carries only the realized
-- pixels, never these operations.
BagSources.browseCountBlocks = {
  {
    { kind = "nop" },
    { kind = "fill", x = 0, y = 4, width = 32, height = 16 },
    { kind = "nop" },
    { kind = "nop" },
  },
  {
    { kind = "copy", srcX = 0, srcY = 19, destX = 0, destY = 9, width = 16, height = 1 },
    { kind = "fill", x = 0, y = 10, width = 16, height = 10 },
    { kind = "nop" },
    { kind = "fill", x = 16, y = 4, width = 16, height = 16 },
  },
  {
    { kind = "copy", srcX = 0, srcY = 19, destX = 0, destY = 9, width = 16, height = 1 },
    { kind = "nop" },
    { kind = "copy", srcX = 16, srcY = 19, destX = 16, destY = 9, width = 16, height = 1 },
    { kind = "fill", x = 0, y = 10, width = 32, height = 10 },
  },
  {
    { kind = "copy", srcX = 0, srcY = 19, destX = 0, destY = 14, width = 16, height = 1 },
    { kind = "fill", x = 0, y = 15, width = 16, height = 5 },
    { kind = "copy", srcX = 16, srcY = 19, destX = 16, destY = 9, width = 16, height = 1 },
    { kind = "fill", x = 16, y = 10, width = 16, height = 10 },
  },
  {
    { kind = "copy", srcX = 0, srcY = 19, destX = 0, destY = 14, width = 16, height = 1 },
    { kind = "nop" },
    { kind = "copy", srcX = 16, srcY = 19, destX = 16, destY = 14, width = 16, height = 1 },
    { kind = "fill", x = 0, y = 15, width = 32, height = 5 },
  },
  {
    { kind = "nop" },
    { kind = "nop" },
    { kind = "copy", srcX = 16, srcY = 19, destX = 16, destY = 14, width = 16, height = 1 },
    { kind = "fill", x = 16, y = 15, width = 16, height = 5 },
  },
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

-- Template-entry inventory beyond the tab/cursor groups: entry 0 is the
-- permanently hidden top strip; entries 1..6 are the item icons, entry 19
-- the Cancel face, entry 20 the movable focus sprite, entries 28..31 the
-- action-button faces, and entries 7..8, 17..18, 21..27, 32..38 auxiliary
-- row/quantity states. Only the entries named by the geometry/focus records
-- below select compiled visuals.

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
-- slots pair the full touch bounds with the text windows the item rows print
-- into (per-slot icon centers and the standard text-window-local name and
-- quantity anchors); Cancel pairs its full button bound with its text
-- window; the cursor anchor is center-origin with the audited stepping.
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
  slots = {
    {
      rect = rect(0, 32, 128, 42),
      textRect = rect(32, 40, 88, 32),
      iconCenter = { x = 22, y = 59 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = rect(128, 32, 128, 42),
      textRect = rect(160, 40, 88, 32),
      iconCenter = { x = 152, y = 59 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = rect(0, 74, 128, 44),
      textRect = rect(32, 80, 88, 32),
      iconCenter = { x = 22, y = 100 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = rect(128, 74, 128, 44),
      textRect = rect(160, 80, 88, 32),
      iconCenter = { x = 152, y = 100 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = rect(0, 118, 128, 36),
      textRect = rect(32, 120, 88, 32),
      iconCenter = { x = 22, y = 139 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = rect(128, 118, 128, 36),
      textRect = rect(160, 120, 88, 32),
      iconCenter = { x = 152, y = 139 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
  },
  cursorAnchor = { size = 16, y = 177, xBase = 16, xStep = 16, count = 8, origin = "center" },
  countReadout = { rect = rect(80, 168, 56, 16), textAt = { x = 0, y = 0 } },
  cancel = {
    rect = rect(192, 168, 64, 24),
    textRect = rect(192, 168, 56, 16),
    -- The CANCEL label span: retail centers the label with
    -- 8 + (48 - textWidth)/2, so the semantic label area is the 48px span
    -- centered at canonical X=224 rather than the 56px text window.
    labelRect = rect(200, 168, 48, 16),
  },
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

-- Movable focus targets in canonical pane pixels: the position records the
-- focus-table update applies to the single managed focus sprite, grouped by
-- semantic class. Eight tab targets tile the strip row, six item targets
-- mark the item rows, one Cancel target marks the Cancel face, and four
-- action targets sit on the action-button grid. These are focus anchors,
-- never item-icon geometry.
BagSources.focusTargets = {
  tabs = {
    { x = 16, y = 16 },
    { x = 48, y = 16 },
    { x = 80, y = 16 },
    { x = 112, y = 16 },
    { x = 144, y = 16 },
    { x = 176, y = 16 },
    { x = 208, y = 16 },
    { x = 240, y = 16 },
  },
  items = {
    { x = 48, y = 56 },
    { x = 176, y = 56 },
    { x = 48, y = 96 },
    { x = 176, y = 96 },
    { x = 48, y = 136 },
    { x = 176, y = 136 },
  },
  cancel = { x = 224, y = 176 },
  actions = {
    { x = 48, y = 144 },
    { x = 144, y = 144 },
    { x = 48, y = 176 },
    { x = 144, y = 176 },
  },
}

-- Item-icon placements in canonical pane pixels: the template X/Y centers
-- of the six item-icon sprites, positioned by the item-row loop. Kept apart
-- from the focus records above so a focus coordinate can never silently
-- stand in for an icon placement again.
BagSources.itemIconCenters = {
  { x = 22, y = 59 },
  { x = 152, y = 59 },
  { x = 22, y = 100 },
  { x = 152, y = 100 },
  { x = 22, y = 139 },
  { x = 152, y = 139 },
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
--
-- The `camera`/`transform` records below are the static setup facts the
-- per-frame path starts from. The per-pocket `framing` records are the
-- dynamic ov15_02200790 table states the pocket switch transitions between
-- over seven fixed ticks: two gender groups of nine raw records each
-- (record 0 is the neutral baseline, records 1..8 follow the canonical
-- pocket order). Each record carries u16 X/Y angles, a fixed-point camera
-- distance, and a fixed-point model height; the compiler normalizes them
-- into manifest values and no raw record reaches runtime.
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
    translation = { x = 0, y = -45, z = 0 },
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
  framing = {
    transitionTicks = 7,
    male = {
      { angleX = 59778, angleY = 5152, distance = 1391441, modelY = -163840 },
      { angleX = 61058, angleY = 26393, distance = 1391445, modelY = -151552 },
      { angleX = 57479, angleY = 18472, distance = 932689, modelY = -188416 },
      { angleX = 61567, angleY = 30742, distance = 1370963, modelY = -196606 },
      { angleX = 885, angleY = 22050, distance = 744270, modelY = -282623 },
      { angleX = 59265, angleY = 29991, distance = 830296, modelY = -245754 },
      { angleX = 59518, angleY = 29722, distance = 1215311, modelY = -221186 },
      { angleX = 60288, angleY = 37403, distance = 858962, modelY = -286720 },
      { angleX = 1415, angleY = 35871, distance = 1391441, modelY = -131073 },
    },
    female = {
      { angleX = 59778, angleY = 5152, distance = 1391441, modelY = -163840 },
      { angleX = 60546, angleY = 14368, distance = 1203027, modelY = -184320 },
      { angleX = 59778, angleY = 7968, distance = 1096529, modelY = -163840 },
      { angleX = 59778, angleY = 24088, distance = 867155, modelY = -196607 },
      { angleX = 61820, angleY = 6686, distance = 1391441, modelY = -163840 },
      { angleX = 384, angleY = 12834, distance = 809809, modelY = -208896 },
      { angleX = 60539, angleY = 33046, distance = 817993, modelY = -249855 },
      { angleX = 61821, angleY = 29215, distance = 875345, modelY = -172032 },
      { angleX = 1415, angleY = 20509, distance = 1391441, modelY = -131072 },
    },
  },
}

return BagSources
