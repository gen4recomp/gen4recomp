-- Source-only member selection for the generated HGSS field-UI class. Every
-- NARC alias/member number lives here and in the dependencies/provenance
-- records; the generated manifest never carries them. Member numbers are
-- zero-based per the repository convention. The signpost source-type domain
-- is exactly {0,1,2,3}: `LoadMapSignpostFrameAndGraphic` (asm/render_window.s
-- at the pinned decomp commit) always reads NARC 0x24 member 1 and selects
-- palette bank `type * 0x20`, with no alternate palette source for any other
-- type value; `tests/rom/script_corpus_test.lua`'s "signpost contracts hold
-- on the real corpus" case decodes every DirectionSignpost/SetSignpostMap
-- instruction (opcodes 55/56) in the real scr_seq corpus and pins this exact
-- domain, so a future corpus change that introduces a new type value fails
-- loudly there instead of silently widening this list. Type 0 and 1
-- additionally load the map-specific wayfinding graphic (the `type > 1`
-- branch skips it); the wayfinding member is map + 0x21 for type 0 and
-- map + 2 for type 1, over the corpus-audited map ranges. Start Menu members
-- follow src/start_menu.c and overlay 27 at pret/pokeheartgold
-- 008257708bd41df5b8c9037e019088ba24df0a87: the MAIN BG triple (char 12,
-- screen 13, palette 15) carries only the bottom-panel chrome, the SUB set
-- (char 8, screen 9, palette 7) sits behind the entry windows, the eleven
-- 20-tile icon chars with the shared cell/anim banks (16/17) and OBJ palette
-- image (14) supply the entry sprites, and cursor char/palette/cell/anim are
-- 64/61/62/63. The icon rows, context rows, action-to-icon map, sprite
-- bases, and label windows below transcribe the overlay-27 icon/context
-- mapping and sprite-base/window tables; the per-icon cell/anim members
-- (19/20...) have no traced consumer and are not selected. Dialogue frames follow
-- LoadUserFrameGfx2 (member = frame + 2, palette = frame + 0x1A), Trainer
-- Card members src/overlay_trainer_card_main.s. No sound archive is
-- selected: the branch does not reproduce the source Start Menu effects. Normal naming chrome
-- follows src/naming_screen.c at pret/pokeheartgold
-- 008257708bd41df5b8c9037e019088ba24df0a87: the normal player/Pokemon path
-- loads the full 256x192 base screen 4 on the main base layer and switches
-- the keyboard layer through `pageNum + 6`, cycling page numbers 0..2, so
-- the normal pages are screens 6 (Upper), 7 (Lower), and 8 (Symbols).
-- Screen 9 belongs to the special numpad path and stays outside this
-- contract, as do the unmapped members 5, 17, and 18. Palette 0 is the main
-- BG palette and char 2 the shared background character bank. The keyboard
-- layers sit at y=-80 in the 192-high BG coordinate system, so the visible
-- 112-high page content belongs at canonical y=80 over the base. The normal
-- OBJ stack is char 10, palette 1 (nine 16-color banks selected per OAM
-- object), NCER 12, and NANR 14. The semantic animation/anchor table below
-- transcribes src/naming_screen.c `sUISpritesParam`, the home-row cursor
-- tables, the entry-slot/subject creation, and the keyboard window geometry:
-- page controls use anims 3/8/13 (selected 0/5/10), Back/OK use 23/25
-- (selected 24/26), the support backing uses 37, the keyboard cursor uses 39
-- with home variants 40 (page controls) and 41 (Back/OK), entry slots use 43
-- (selected 44), and the player subjects use 48/49. The fourth page slot
-- (sprite 3 at y=200, sprite 4 hidden) serves the special paths and stays
-- outside the normal contract. Entered-name glyphs start at (80,24) advancing
-- 12px; entry slots start at (80,39) stepping 12px; keyboard text cells are
-- 16px columns on 19px rows from the page-art origin; the keyboard cursor
-- steps 16px by 19px from (26,91); the player subject anchors at (24,8).

return {
  schema = 1,
  provenance = {
    repo = "pret/pokeheartgold",
    commit = "0985e8718df4f25e64d6507d89c0c97c0d288981",
    sources = {
      { path = "src/start_menu.c" },
      { path = "asm/render_window.s" },
      { path = "src/overlay_trainer_card_main.s" },
      { path = "src/naming_screen.c" },
      { path = "src/yes_no_prompt.c" },
    },
  },
  startMenu = {
    alias = "start_menu",
    backgroundCharMember = 12,
    backgroundScreenMember = 13,
    backgroundPaletteMember = 15,
    -- The SUB background set behind the entry windows: char 8, screen 9,
    -- palette 7 (ov27_0225AC00; the CEEC/CEF0/CEF4 triples all resolve to
    -- this set for every menu mode).
    subBackgroundCharMember = 8,
    subBackgroundScreenMember = 9,
    subBackgroundPaletteMember = 7,
    -- The shared icon OBJ bank: eleven 20-tile 4bpp sprite chars, the shared
    -- icon cell/anim banks every icon sprite is built from, and the shared
    -- OBJ palette image whose second 16-color bank is the selection
    -- highlight (ov27_0225AD0C tail, ov27_0225AEA8, ov27_0225B398).
    iconCharMembers = { 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48 },
    iconCellMember = 16,
    iconAnimMember = 17,
    iconPaletteMember = 14,
    -- Every normal icon visual composes the shared animation's stable opening
    -- frame; the selected visual renders the same frame through the shared
    -- selection palette bank (zero-based). Indices are zero-based into the
    -- decoded banks.
    iconAnim = 0,
    iconSelectedPalette = 1,
    cursorCharMember = 64,
    cursorPaletteMember = 61,
    cursorCellMember = 62,
    cursorAnimMember = 63,
    -- The 13 retail icon rows (Lua index = retail icon index + 1) from the
    -- ov27_0225CF94 table: the sprite char member per icon row, the
    -- bank-196 label id, and the label kind. Rows 9-10 are text-only (no
    -- icon art); row 11 is the external poke-icon path (char member FFFF in
    -- source, resolved at runtime outside this archive). Row 3 (Bag) carries
    -- the conditional female art (char 27) as a first-class variant. The
    -- per-icon cell/anim members (19/20...) have no traced retail consumer
    -- and stay out of this contract.
    iconRows = {
      { art = "sprite", char = 18, label = 0, labelKind = "static" },
      { art = "sprite", char = 21, label = 1, labelKind = "static" },
      { art = "sprite", char = 24, femaleChar = 27, label = 2, labelKind = "static" },
      { art = "sprite", char = 30, label = 14, labelKind = "static" },
      { art = "sprite", char = 33, label = 3, labelKind = "player_name" },
      { art = "sprite", char = 36, label = 4, labelKind = "static" },
      { art = "sprite", char = 39, label = 5, labelKind = "static" },
      { art = "sprite", char = 42, label = 8, labelKind = "static" },
      { art = "text", label = 32, labelKind = "static" },
      { art = "text", label = 32, labelKind = "static" },
      { art = "poke_icon", label = 32, labelKind = "static" },
      { art = "sprite", char = 45, label = 34, labelKind = "static" },
      { art = "sprite", char = 48, label = 35, labelKind = "static" },
    },
    -- The 7 context-to-icon rows from the ov27_0225CFC8 table (one icon
    -- index per sprite slot, `false` for the 0x0D none holes). Each retail
    -- row carries 8 columns; only the first 7 feed the sprite slots and no
    -- traced reader consumes the 8th column, so every row transcribes its
    -- first 7 entries (row 2's 8th column carries icon 8, the text-only row
    -- that stays addressable through the icon table rather than any sprite
    -- slot). Row 1 is the normal context. Row-to-context name assignments
    -- stay open; only the normal row's mapping is pinned by retail behavior.
    contexts = {
      { 0, 1, 2, 3, 4, 5, 6 },
      { 7, 0, 1, 2, 3, 4, 6 },
      { 7, 0, 1, 3, 4, 6, 10 },
      { 7, 0, 1, 3, 4, 6, 9 },
      { 11, 0, 1, 2, 12, 4, 6 },
      { 1, 2, 4, 6, false, false, false },
      { 1, 4, 6, false, false, false, false },
    },
    -- The normal visual actions: semantic action id to retail icon index
    -- (src/start_menu.c sActionToIconIndex). Only icon-backed actions are
    -- visual buttons; the cancel sentinel and the bookkeeping specials carry
    -- no icon slot and stay source-policy facts outside the visual menu.
    actionIcons = {
      ["vanilla.pokedex"] = 0,
      ["vanilla.pokemon"] = 1,
      ["vanilla.bag"] = 2,
      ["vanilla.pokegear"] = 3,
      ["vanilla.trainer_card"] = 4,
      ["vanilla.save"] = 5,
      ["vanilla.options"] = 6,
    },
    -- The 7 normal action anchors from the ov27_0225D038 table, keyed by
    -- display position 0..6 (display position p occupied touch slot p+2;
    -- slot 1 is the cancel region). Retail pixel coordinates.
    actionAnchors = {
      [0] = { x = 24, y = 22 },
      [1] = { x = 24, y = 62 },
      [2] = { x = 24, y = 102 },
      [3] = { x = 24, y = 142 },
      [4] = { x = 104, y = 22 },
      [5] = { x = 104, y = 62 },
      [6] = { x = 104, y = 102 },
    },
    -- The 7 entry-label windows from the ov27_0225D074 tile grid (first 7 of
    -- the 8 pairs; 9x2 tiles each), in pixels, keyed by display position.
    labelWindows = {
      [0] = { x = 8, y = 48, width = 72, height = 16 },
      [1] = { x = 8, y = 88, width = 72, height = 16 },
      [2] = { x = 8, y = 128, width = 72, height = 16 },
      [3] = { x = 8, y = 168, width = 72, height = 16 },
      [4] = { x = 88, y = 48, width = 72, height = 16 },
      [5] = { x = 88, y = 88, width = 72, height = 16 },
      [6] = { x = 88, y = 128, width = 72, height = 16 },
    },
    -- The cancel/header touch bound plus the 7 normal touch regions from the
    -- ov27_0225CF68 table, in pixels, keyed by display position. Half-open
    -- bounds (x <= p < x+width), matching the runtime comparator.
    cancelTouchRegion = { x = 8, y = 0, width = 152, height = 16 },
    touchRegions = {
      [0] = { x = 16, y = 22, width = 60, height = 32 },
      [1] = { x = 16, y = 62, width = 60, height = 32 },
      [2] = { x = 16, y = 102, width = 60, height = 32 },
      [3] = { x = 16, y = 142, width = 60, height = 32 },
      [4] = { x = 96, y = 22, width = 60, height = 32 },
      [5] = { x = 96, y = 62, width = 60, height = 32 },
      [6] = { x = 96, y = 102, width = 60, height = 32 },
    },
    -- The ordered directional candidates from the ov27_0225D0B4 table: three
    -- display positions per direction, keyed by display position. The runtime
    -- selects the first candidate that is currently visible.
    navigationCandidates = {
      [0] = { up = { 3, 2, 1 }, down = { 1, 2, 3 }, left = { 4, 0, 0 }, right = { 4, 0, 0 } },
      [1] = { up = { 0, 3, 2 }, down = { 2, 3, 0 }, left = { 5, 1, 0 }, right = { 5, 1, 0 } },
      [2] = { up = { 1, 0, 3 }, down = { 3, 0, 1 }, left = { 6, 2, 0 }, right = { 6, 2, 0 } },
      [3] = { up = { 2, 1, 0 }, down = { 0, 1, 2 }, left = { 6, 3, 0 }, right = { 6, 3, 0 } },
      [4] = { up = { 6, 5, 4 }, down = { 5, 6, 4 }, left = { 0, 4, 0 }, right = { 0, 4, 0 } },
      [5] = { up = { 4, 6, 5 }, down = { 6, 4, 5 }, left = { 1, 5, 0 }, right = { 1, 5, 0 } },
      [6] = { up = { 5, 4, 6 }, down = { 4, 5, 6 }, left = { 2, 6, 0 }, right = { 2, 6, 0 } },
    },
  },
  dialogueFrames = {
    alias = "dialogue_frames",
    standardFrameMember = 0,
    standardPaletteMember = 25,
    firstFrameMember = 2,
    frameCount = 20,
    firstPaletteMember = 26,
    continueCursorMember = 0x16,
  },
  signposts = {
    alias = "signpost_graphics",
    frameMember = 0,
    paletteMember = 1,
    -- (type, map) -> member: the wayfinding member is map + 0x21 for type 0
    -- and map + 2 for type 1 (LoadMapSignpostFrameAndGraphic), over the
    -- corpus-audited map ranges.
    wayfinding = {
      [0] = { memberBase = 0x21, maps = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 } },
      [1] = { memberBase = 2, maps = { 0, 1, 2, 3, 4, 5, 6, 8, 10, 13, 14, 15, 19, 21 } },
    },
    -- Every signpost source type in the real corpus (see the module header:
    -- pinned to {0,1,2,3} by the script-corpus census), kept as raw numbers
    -- (the style catalogue owns their semantics).
    sourceTypes = { 0, 1, 2, 3 },
  },
  trainerCard = {
    alias = "trainer_card_graphics",
    frontCharMember = 41,
    frontScreenMember = 47,
    frontPaletteMember = 11,
  },
  namingScreen = {
    alias = "naming_screen",
    paletteMember = 0,
    charMember = 2,
    baseScreenMember = 4,
    pageScreenMembers = { upper = 6, lower = 7, symbols = 8 },
    objCharMember = 10,
    objPaletteMember = 1,
    objCellMember = 12,
    objAnimMember = 14,
    -- Source animation identities (zero-based) per semantic visual. Only the
    -- normal-path roles are selected; the special-path fourth page slot and
    -- the selected-control page-switch frames stay outside this contract.
    objAnims = {
      upper = 3,
      lower = 8,
      symbols = 13,
      back = 23,
      ok = 25,
      backing = 37,
      cursorKeyboard = 39,
      cursorHomePage = 40,
      cursorHomeConfirm = 41,
      slotNormal = 43,
      slotSelected = 44,
      subjectMale = 48,
      subjectFemale = 49,
      pokemonSubject = 50,
    },
    -- Sequence 50's two source cells both use the one icon frame loaded by
    -- NamingScreen_LoadMonIcon; only their OAM placement changes.
    pokemonSubjectCells = { 52, 53 },
    -- Resting page placement: the active keyboard BG rests scrolled to
    -- X=-11, so the 256-wide page overlay draws displaced +11 screen pixels
    -- over the canonical surface.
    pagePlacement = { x = 11, y = 80, width = 256, height = 112 },
    -- Final screen anchors for the composed visuals. The home-row controls
    -- are child sprites of the support backing at x=22, so the published
    -- anchors already include that parent transform.
    objAnchors = {
      upper = { x = 26, y = 68 },
      lower = { x = 58, y = 68 },
      symbols = { x = 90, y = 68 },
      back = { x = 158, y = 68 },
      ok = { x = 198, y = 68 },
      backing = { x = 22, y = 56 },
      subject = { x = 24, y = 8 },
    },
    -- Home-row cursor draw positions per control (the source cursor-x table
    -- at y=68); the keyboard cursor steps from its own origin below.
    homeCursorAnchors = {
      upper = { x = 25, y = 68 },
      lower = { x = 57, y = 68 },
      symbols = { x = 89, y = 68 },
      back = { x = 158, y = 68 },
      ok = { x = 198, y = 68 },
    },
    cursorOrigin = { x = 26, y = 91 },
    cursorStepX = 16,
    cursorStepY = 19,
    entryOrigin = { x = 80, y = 39 },
    entryStepX = 12,
    nameOrigin = { x = 80, y = 24 },
    nameAdvanceX = 12,
    -- Keyboard window the retail keyboard fill owns before text is printed:
    -- the window opens at tile (2,1), so page-local (16,8), spanning 26x12
    -- tiles (208x96 pixels). The fill paints the page frame slot over the
    -- whole window, then 13x5 16x19 cells taking the companion slot wherever
    -- (row + column) parity is odd; the final bottom pixel row keeps the
    -- frame slot. Both slots resolve through palette bank 1 (retail opens
    -- the keyboard windows with palette 1). Glyphs print 4 pixels below each row top on the 16-pixel
    -- column pitch, so the runtime text cells derive from this same record.
    keyboardWindow = {
      x = 16,
      y = 8,
      width = 208,
      height = 96,
      columns = 13,
      rows = 5,
      cellWidth = 16,
      rowHeight = 19,
      textInsetY = 4,
      pages = {
        upper = { base = 4, alternate = 3 },
        lower = { base = 7, alternate = 6 },
        symbols = { base = 13, alternate = 12 },
      },
    },
  },
  -- The compact two-row choice prompt follows src/yes_no_prompt.c: the
  -- confirmation row renders through the first prompt palette bank and the
  -- rejection row through the second, from the shared character bank. The
  -- shape-0 screens are 6x4 tiles (48x32 pixels) each: YES normal/selected
  -- are members 2/3 and NO normal/selected are members 4/5 of
  -- NARC_system_touch_subwindow, with the palette in member 0 and the
  -- shared char bank in member 1. Only this producer reads these member
  -- numbers; the generated manifest carries semantic asset ids alone.
  yesNoPrompt = {
    alias = "touch_subwindow",
    paletteMember = 0,
    charMember = 1,
    yesNormalScreen = 2,
    yesSelectedScreen = 3,
    noNormalScreen = 4,
    noSelectedScreen = 5,
  },
}
