-- The reusable two-row choice prompt renderer: both button rows draw every
-- active frame from the generated button artwork, the selected row through
-- its selected visual and the other row through its normal visual, placed at
-- the controller status rectangles. Construction is failure-safe with an
-- idempotent release; a closed prompt draws nothing.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local PngWriter = require("libs.assets.src.PngWriter")
local PromptController = require("libs.hgss.src.ui.YesNoPromptController")
local PromptRenderer = require("libs.hgss.src.ui.YesNoPromptRenderer")

local T = {}

local fakeGraphics = require("tests.support.FakeGraphics").new

local function manifest()
  return FieldUiFixture.manifest()
end

local function cacheWithPrompt()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(FieldUiFixture.PROMPT_YES_NORMAL_PATH, FieldUiFixture.promptButtonBytes("yes_normal"))
  cache:write(FieldUiFixture.PROMPT_YES_SELECTED_PATH, FieldUiFixture.promptButtonBytes("yes_selected"))
  cache:write(FieldUiFixture.PROMPT_NO_NORMAL_PATH, FieldUiFixture.promptButtonBytes("no_normal"))
  cache:write(FieldUiFixture.PROMPT_NO_SELECTED_PATH, FieldUiFixture.promptButtonBytes("no_selected"))
  return cache
end

local function graphics()
  return fakeGraphics({ imageSizes = { { 48, 32 }, { 48, 32 }, { 48, 32 }, { 48, 32 } } })
end

local function statusAt(x, y, selected, highlighted)
  local controller = PromptController.new(FieldUiFixture.promptCompactSection().shapes.compact)
  controller:open({ x = x, y = y, shape = "compact", initialSelection = selected })
  local status = controller:status()
  status.selectionHighlighted = highlighted ~= false
  return status
end

local function imageIndex(lg, image)
  for index, candidate in ipairs(lg.images) do
    if candidate == image then
      return index
    end
  end
  return nil
end

local function pairKey(lg, draw)
  local quad = assert(draw.quad, "a prompt button draw carries its visual quad")
  return imageIndex(lg, draw.image) .. ":" .. quad.x .. "," .. quad.y .. "," .. quad.w .. "," .. quad.h
end

function T.draws_both_rows_with_selected_art_only_on_the_selected_row()
  local current = manifest()
  local lg = graphics()
  local renderer = PromptRenderer.new({ cacheFs = cacheWithPrompt(), manifest = current, graphics = lg })
  renderer:draw(statusAt(200, 48, "yes"))
  renderer:release()

  Assert.equal(#lg.draws, 2, "one draw per button row")
  Assert.deepEqual({ lg.draws[1].x, lg.draws[1].y }, { 200, 48 }, "the first draw lands on the YES row")
  Assert.deepEqual({ lg.draws[2].x, lg.draws[2].y }, { 200, 80 }, "the second draw lands on the NO row")
  Assert.isTrue(pairKey(lg, lg.draws[1]) ~= pairKey(lg, lg.draws[2]), "the two rows sample different visuals")
  Assert.equal(#lg.primitives, 0, "no themed primitives are drawn")
end

function T.flipping_selection_swaps_which_visual_each_row_samples()
  local current = manifest()
  local lg = graphics()
  local renderer = PromptRenderer.new({ cacheFs = cacheWithPrompt(), manifest = current, graphics = lg })
  renderer:draw(statusAt(200, 48, "yes"))
  local yesSelectedYes = pairKey(lg, lg.draws[1])
  local yesSelectedNo = pairKey(lg, lg.draws[2])
  renderer:draw(statusAt(200, 48, "no"))
  local noSelectedYes = pairKey(lg, lg.draws[3])
  local noSelectedNo = pairKey(lg, lg.draws[4])
  renderer:release()

  Assert.equal(#lg.draws, 4, "each active draw paints both rows")

  Assert.isTrue(yesSelectedYes ~= noSelectedYes, "the YES row changes visual with selection")
  Assert.isTrue(yesSelectedNo ~= noSelectedNo, "the NO row changes visual with selection")
  Assert.deepEqual({ lg.draws[3].x, lg.draws[3].y }, { 200, 48 }, "placement does not move with selection")
  Assert.deepEqual({ lg.draws[4].x, lg.draws[4].y }, { 200, 80 })
end

function T.an_unhighlighted_pending_choice_draws_both_rows_with_normal_art()
  local current = manifest()
  local lg = graphics()
  local renderer = PromptRenderer.new({ cacheFs = cacheWithPrompt(), manifest = current, graphics = lg })
  renderer:draw(statusAt(200, 48, "yes", true))
  renderer:draw(statusAt(200, 48, "yes", false))
  renderer:release()

  Assert.equal(#lg.draws, 4, "each active draw paints both rows")
  local highlightedYes = pairKey(lg, lg.draws[1])
  local highlightedNo = pairKey(lg, lg.draws[2])
  local unhighlightedYes = pairKey(lg, lg.draws[3])
  local unhighlightedNo = pairKey(lg, lg.draws[4])
  Assert.isTrue(highlightedYes ~= unhighlightedYes, "the chosen row swaps to its normal visual while unhighlighted")
  Assert.equal(highlightedNo, unhighlightedNo, "the other row keeps its normal visual")
  Assert.deepEqual({ lg.draws[3].x, lg.draws[3].y }, { 200, 48 })
  Assert.deepEqual({ lg.draws[4].x, lg.draws[4].y }, { 200, 80 })
  Assert.equal(#lg.primitives, 0, "no themed primitives are drawn")
end

local SHARED_ATLAS_ASSET = "hgss.yes_no_prompt.atlas"
local SHARED_ATLAS_PATH = "assets/generated/field/ui/yes-no-prompt-atlas.png"

-- A schema-valid prompt layout packing all four button states as distinct
-- 48x32 rects in one shared 192x32 atlas image. The icon and naming
-- contracts complete the shared fixture so the validator judges the full
-- manifest, not just the prompt section.
local function sharedAtlasManifest()
  local current = manifest()
  FieldUiFixture.addStartMenuIconContract(current)
  FieldUiFixture.addNamingSemantics(current)
  current.assets[SHARED_ATLAS_ASSET] = { image = SHARED_ATLAS_PATH, width = 192, height = 32 }
  local compact = current.yesNoPrompt.shapes.compact
  compact.yes.normal = { asset = SHARED_ATLAS_ASSET, rect = { x = 0, y = 0, width = 48, height = 32 } }
  compact.yes.selected = { asset = SHARED_ATLAS_ASSET, rect = { x = 48, y = 0, width = 48, height = 32 } }
  compact.no.normal = { asset = SHARED_ATLAS_ASSET, rect = { x = 96, y = 0, width = 48, height = 32 } }
  compact.no.selected = { asset = SHARED_ATLAS_ASSET, rect = { x = 144, y = 0, width = 48, height = 32 } }
  return current
end

local function cacheWithSharedAtlas()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(SHARED_ATLAS_PATH, PngWriter.encode(192, 32, string.rep(string.char(9, 9, 9, 255), 192 * 32)))
  return cache
end

function T.a_shared_atlas_manifest_constructs_draws_and_releases_every_prompt_state()
  local current = sharedAtlasManifest()
  local ok, err = FieldUiAssetCache.validateManifest(current)
  Assert.isTrue(ok, "the shared-atlas prompt layout stays schema-valid")
  Assert.isNil(err)
  local lg = fakeGraphics({ imageSizes = { { 192, 32 } } })
  local renderer = PromptRenderer.new({ cacheFs = cacheWithSharedAtlas(), manifest = current, graphics = lg })
  Assert.equal(#lg.images, 1, "the four states share one atlas image")
  renderer:draw(statusAt(200, 48, "yes", true))
  renderer:draw(statusAt(200, 48, "no", true))
  renderer:draw(statusAt(200, 48, "yes", false))
  renderer:release()
  renderer:release()

  Assert.equal(#lg.draws, 6, "every selection and highlight state draws both rows")
  Assert.equal(lg.draws[1].quad.x, 48, "highlighted YES samples the YES selected rect")
  Assert.equal(lg.draws[2].quad.x, 96, "highlighted YES samples the NO normal rect")
  Assert.equal(lg.draws[3].quad.x, 0, "highlighted NO samples the YES normal rect")
  Assert.equal(lg.draws[4].quad.x, 144, "highlighted NO samples the NO selected rect")
  Assert.equal(lg.draws[5].quad.x, 0, "unhighlighted draws sample the YES normal rect")
  Assert.equal(lg.draws[6].quad.x, 96, "unhighlighted draws sample the NO normal rect")
  Assert.deepEqual({ lg.draws[1].x, lg.draws[1].y }, { 200, 48 })
  Assert.deepEqual({ lg.draws[2].x, lg.draws[2].y }, { 200, 80 })
  Assert.equal(lg.images[1].released, true, "the shared image is released")
  Assert.equal(lg.images[1].releaseCount, 1, "the shared image is released exactly once")
end
function T.placement_comes_from_the_status_rectangles()
  local current = manifest()
  local lg = graphics()
  local renderer = PromptRenderer.new({ cacheFs = cacheWithPrompt(), manifest = current, graphics = lg })
  renderer:draw(statusAt(10, 20, "no"))
  renderer:release()

  Assert.equal(#lg.draws, 2)
  Assert.deepEqual({ lg.draws[1].x, lg.draws[1].y }, { 10, 20 })
  Assert.deepEqual({ lg.draws[2].x, lg.draws[2].y }, { 10, 52 })
end

function T.closed_prompts_draw_nothing()
  local current = manifest()
  local lg = graphics()
  local renderer = PromptRenderer.new({ cacheFs = cacheWithPrompt(), manifest = current, graphics = lg })
  renderer:draw(nil)
  local controller = PromptController.new(FieldUiFixture.promptCompactSection().shapes.compact)
  renderer:draw(controller:status())
  renderer:release()

  Assert.equal(#lg.draws, 0, "a closed prompt draws nothing")
  Assert.equal(lg.pushDepth(), 0, "the transform stack stays balanced")
end

function T.missing_prompt_section_fails_construction()
  local current = manifest()
  current.yesNoPrompt = nil
  local lg = graphics()
  Assert.throws(function()
    PromptRenderer.new({ cacheFs = cacheWithPrompt(), manifest = current, graphics = lg })
  end)
  Assert.equal(#lg.draws, 0)
end

function T.second_image_failure_releases_the_first_image()
  local current = manifest()
  local lg = fakeGraphics({
    imageSizes = { { 48, 32 }, { 48, 32 }, { 48, 32 }, { 48, 32 } },
    failOnImageCall = 2,
  })
  local err = Assert.throws(function()
    PromptRenderer.new({ cacheFs = cacheWithPrompt(), manifest = current, graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image failure")
  Assert.equal(#lg.images, 1, "only the first visual was created before the failure")
  Assert.equal(lg.images[1].released, true, "the first visual was released exactly once")
end

function T.release_is_idempotent_and_draw_after_release_is_a_noop()
  local current = manifest()
  local lg = graphics()
  local renderer = PromptRenderer.new({ cacheFs = cacheWithPrompt(), manifest = current, graphics = lg })
  renderer:release()
  renderer:release()
  renderer:draw(statusAt(200, 48, "yes"))
  renderer:draw(nil)

  Assert.equal(#lg.draws, 0, "a released renderer draws nothing")
end

return { tests = T }
