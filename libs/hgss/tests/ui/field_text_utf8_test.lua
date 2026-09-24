-- Cross-module UTF-8 contract: the fixture font carries one real multibyte
-- glyph (É, U+00C9, two-byte UTF-8, compiled-code 360 with advance 6), and
-- every consumer that turns text into glyphs must iterate full UTF-8
-- sequences, never bytes. The player name containing the glyph validates
-- against the fixture charmap, the shared text renderer produces one glyph
-- run per sequence with the encoded glyph's own quad and advance, drawn text
-- visits the atlas once per sequence, and the dialogue theme's measurement
-- returns exactly the glyph's advance. The trainer card path through the
-- shared renderer is covered in trainer_card_renderer_test.lua.

local Assert = require("tests.support.Assert")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {}

local MULTIBYTE = "\195\137" -- É = U+00C9
local MULTIBYTE_CODE = 360
local MULTIBYTE_ADVANCE = 6
local ASCII_ADVANCE = 8

-- The card font plus the real multibyte glyph, written through the same
-- cache builder the card renderer tests use.
local function fixtureCache()
  return FieldUiFixture.trainerCardCache(FieldUiFixture.cardFontDefWithMultibyte())
end

-- The shared fake graphics namespace (tests/support/FakeGraphics) records
-- every draw and created image. Image sizes: the 512x32 card font atlas, its
-- semantic glyph mask atlas, and the 96x32 focus-indicator strip, in the
-- order the renderer acquires them.
local function fakeGraphics()
  return require("tests.support.FakeGraphics").new({ imageSizes = { { 512, 32 }, { 16, 16 }, { 96, 128 } } })
end

local function renderer()
  return FieldTextRenderer.new({ cacheFs = fixtureCache(), graphics = fakeGraphics() })
end

-- The player name containing the multibyte glyph validates against the
-- fixture charmap: glyph count and encodability are sequence-based, so a
-- seven-glyph name of two-byte sequences is within the 1..7 limit.
function T.multibyte_player_name_validates_against_the_fixture_charmap()
  local def = FieldUiFixture.cardFontDefWithMultibyte()
  local context = { charmap = def.charmap, frameIndexes = { [0] = true } }
  local record = {
    profile = { name = MULTIBYTE, gender = 0, trainerId = 0, money = 3000 },
    options = { textFrame = 0, textSpeed = "mid" },
  }
  local validated = assert(PlayerData.validate(record, context))
  Assert.equal(validated.profile.name, MULTIBYTE)
  local seven = {
    profile = { name = string.rep(MULTIBYTE, 7), gender = 1, trainerId = 65535, money = 3000 },
    options = { textFrame = 0, textSpeed = "fast" },
  }
  Assert.notNil(PlayerData.validate(seven, context), "seven two-byte glyphs are seven glyphs, not fourteen bytes")
end

-- The glyph run for the two-byte sequence in a drawn line is exactly one
-- atlas visit carrying the encoded glyph's quad and advance, never two
-- fallback runs per byte.
function T.draw_line_visits_each_multibyte_glyph_once()
  local lg = fakeGraphics()
  local text = FieldTextRenderer.new({ cacheFs = fixtureCache(), graphics = lg })
  text:drawLine({ { kind = "glyph", code = 360, text = MULTIBYTE, raw = { 360 } } }, 10, 20)
  local draws = lg.draws
  Assert.equal(#draws, 1, "a two-byte glyph draws once, not per byte")
  Assert.equal(draws[1].quad.x, (MULTIBYTE_CODE - 1) * ASCII_ADVANCE)
  Assert.equal(draws[1].x, 10)
  Assert.equal(draws[1].y, 20)
  text:release()
end

-- Production presentation never invents diagnostic marker text and never
-- reserves marker-string width: a control token in a line draws nothing and
-- does not advance x, so the following glyph starts at the original x.
function T.control_tokens_draw_nothing_and_do_not_offset_the_following_glyph()
  local lg = fakeGraphics()
  local text = FieldTextRenderer.new({ cacheFs = fixtureCache(), graphics = lg })
  local wait = { kind = "wait", control = 514, name = "WAIT", args = {} }
  local glyph = { kind = "glyph", code = 1, text = "A", raw = { 1 } }
  local tokens = { wait, glyph }
  ---@cast tokens MessageToken[]
  text:drawLine(tokens, 10, 20)
  local draws = lg.draws
  Assert.equal(#draws, 1, "the control token draws no marker text")
  Assert.equal(draws[1].x, 10, "WAIT occupies zero pixels; the glyph starts at the original x")
  Assert.equal(draws[1].y, 20)
  text:release()
end

-- The measured width of the multibyte glyph is exactly its own advance, and
-- a mixed name sums per glyph.
function T.text_width_measures_glyph_advances_not_bytes()
  local text = renderer()
  Assert.equal(text:textWidth(MULTIBYTE), MULTIBYTE_ADVANCE)
  Assert.equal(text:textWidth(MULTIBYTE .. "lise"), MULTIBYTE_ADVANCE + 4 * ASCII_ADVANCE)
  text:release()
end

-- Drawn text visits the atlas once per glyph sequence at the reference
-- position with the encoded glyph's quad.
function T.draw_text_draws_each_multibyte_glyph_once()
  local lg = fakeGraphics()
  local text = FieldTextRenderer.new({ cacheFs = fixtureCache(), graphics = lg })
  text:drawText(MULTIBYTE, 10, 20)
  local draws = lg.draws
  Assert.equal(#draws, 1, "a two-byte glyph draws once, not per byte")
  Assert.equal(draws[1].quad.x, (MULTIBYTE_CODE - 1) * ASCII_ADVANCE)
  Assert.equal(draws[1].x, 10)
  Assert.equal(draws[1].y, 20)
  text:release()
end

-- The dialogue theme's plain-text measurement returns exactly the glyph's
-- advance, matching the shared renderer's own measurement.
function T.dialogue_theme_measurement_uses_glyph_advances()
  local def = FieldUiFixture.cardFontDefWithMultibyte()
  local measured = FieldDialogueTheme.measureText(def)(MULTIBYTE)
  Assert.equal(measured, MULTIBYTE_ADVANCE)
end

return { tests = T }
