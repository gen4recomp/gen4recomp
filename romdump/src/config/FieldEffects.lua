-- HGSS field-effect source selections. These are producer-only facts from
-- the curated field_static_models archive; generated assets carry semantic
-- definitions and cache references instead of source archive details.
--
-- Surf attachment presentation (pret/pokeheartgold ov01_021FE7AC,
-- ov01_021FE868, ov01_021FE8C8): the surf resource loader attaches the field
-- model selected below, starts player presentation at {0, 0x4000, 0x4000},
-- and bounces an oscillator height between 0x1000 and 0x4000 in 0x400 steps.
-- Player presentation Y is the oscillator plus 0x4000, player Z stays 0x4000,
-- and the attachment Y is the oscillator minus 0x1000 relative to logical
-- player Y. Source geometry uses 16 model units per world tile.

local MODEL_UNITS_PER_TILE = 16
local SURF_OSCILLATOR_MIN = 0x1000 / (0x1000 * MODEL_UNITS_PER_TILE)
local SURF_OSCILLATOR_MAX = 0x4000 / (0x1000 * MODEL_UNITS_PER_TILE)
local SURF_OSCILLATOR_STEP = 0x400 / (0x1000 * MODEL_UNITS_PER_TILE)
local SURF_PLAYER_BASE = 0x4000 / (0x1000 * MODEL_UNITS_PER_TILE)
local SURF_ATTACHMENT_BASE = -0x1000 / (0x1000 * MODEL_UNITS_PER_TILE)

return {
  schema = 1,
  archive = {
    alias = "field_static_models",
    path = "a/1/0/3",
  },
  animationArchive = {
    alias = "field_static_models",
    path = "a/1/0/3",
  },
  effects = {
    warp_entrance = {
      renderer = 3,
      modelMembers = { 85 },
      animationMembers = {},
    },
    tall_grass = {
      renderer = 8,
      modelMembers = { 126 },
      animationMembers = { 140 },
      lifecycle = {
        mode = "hold_until_owner_moves",
        holdFrame = 12,
      },
      placementOffset = { x = 0, y = 0, z = 0.625 },
    },
    very_tall_grass = {
      renderer = 12,
      modelMembers = { 122 },
      animationMembers = { 146 },
      lifecycle = {
        mode = "hold_until_owner_moves",
        holdFrame = 12,
      },
      placementOffset = { x = 0, y = 0, z = 0.625 },
    },
    trainer_reveal = {
      renderer = 1,
      modelMembers = { 124 },
      animationMembers = { 148 },
      lifecycle = {
        mode = "once",
        frameCount = 7,
      },
      placementOffset = { x = 0, y = 0, z = 0.5 },
    },
    surf_attachment = {
      modelMembers = { 86 },
      animationMembers = {},
      presentation = {
        initialPlayerOffset = { x = 0, y = SURF_PLAYER_BASE, z = SURF_PLAYER_BASE },
        oscillator = {
          initialY = SURF_OSCILLATOR_MIN,
          minY = SURF_OSCILLATOR_MIN,
          maxY = SURF_OSCILLATOR_MAX,
          stepY = SURF_OSCILLATOR_STEP,
        },
        playerBaseOffset = { x = 0, y = SURF_PLAYER_BASE, z = SURF_PLAYER_BASE },
        attachmentBaseOffset = { x = 0, y = SURF_ATTACHMENT_BASE, z = 0 },
        yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
      },
    },
    follower_transition = {
      -- The transient follower effect: source models 129 ("monsterball") and
      -- 104 ("mb_out") plus the texture animation bound to model 104.
      -- animatedModelMember names the clip target explicitly so a swapped or
      -- corrupt companion can never silently rebind the animation.
      -- placementOffset carries the traced source-model-unit vertical offset;
      -- the compiler normalizes it into runtime tiles.
      modelMembers = { 129, 104 },
      animationMembers = { 164 },
      animatedModelMember = 104,
      lifecycle = {
        mode = "once",
        preludeTicks = 2,
      },
      placementOffset = { x = 0, y = 6, z = 0 },
    },
  },
}
