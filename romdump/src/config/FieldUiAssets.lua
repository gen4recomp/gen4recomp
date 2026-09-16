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
-- follow src/start_menu.c, dialogue frames LoadUserFrameGfx2 (member =
-- frame + 2, palette = frame + 0x1A), Trainer Card members
-- src/overlay_trainer_card_main.s. No sound archive is selected: the branch
-- does not reproduce the source Start Menu effects. Normal naming chrome
-- follows src/naming_screen.c at pret/pokeheartgold
-- 008257708bd41df5b8c9037e019088ba24df0a87: the normal player/Pokemon path
-- loads the full 256x192 base screen 4 on the main base layer and switches
-- the keyboard layer through `pageNum + 6`, cycling page numbers 0..2, so
-- the normal pages are screens 6 (Upper), 7 (Lower), and 8 (Symbols).
-- Screen 9 belongs to the special numpad path and stays outside this
-- contract, as do the unmapped members 5, 17, and 18. Palette 0 is the main
-- BG palette and char 2 the shared background character bank. The keyboard
-- layers sit at y=-80 in the 192-high BG coordinate system, so the visible
-- 112-high page content belongs at canonical y=80 over the base.

return {
  schema = 1,
  provenance = {
    repo = "pret/pokeheartgold",
    commit = "7e25c842061d026f43fe6efbd7be0ec94c50839d",
    sources = {
      { path = "src/start_menu.c" },
      { path = "asm/render_window.s" },
      { path = "src/overlay_trainer_card_main.s" },
      { path = "src/naming_screen.c" },
    },
  },
  startMenu = {
    alias = "start_menu",
    backgroundCharMember = 12,
    backgroundScreenMember = 13,
    backgroundPaletteMember = 15,
    cursorCharMember = 64,
    cursorPaletteMember = 61,
    cursorCellMember = 62,
    cursorAnimMember = 63,
  },
  dialogueFrames = {
    alias = "dialogue_frames",
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
  },
}
