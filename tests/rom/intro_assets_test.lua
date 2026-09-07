-- ROM-conformance scenarios for the semantic Professor Oak intro asset class.
-- Source member identities are asserted only in producer provenance; runtime
-- records are checked through their semantic background/widget contract.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.newgame.IntroAssetCompiler")
  if not ok then
    error("the ROM-derived intro compiler is missing: " .. tostring(module), 0)
  end
  return module
end

local function payloadBytes(bundle)
  local paths = {}
  for path in pairs(bundle.assets) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local bytes = {}
  for _, path in ipairs(paths) do
    bytes[#bytes + 1] = path .. "\0" .. bundle.assets[path]
  end
  return table.concat(bytes, "\0")
end

local function sourceMember(bundle, role)
  for _, item in ipairs(bundle.dependencies.dependencies) do
    if item.role == role then
      return item.memberId
    end
  end
  error("missing dependency role " .. role, 2)
end

local function sourceArchive(bundle, role)
  for _, item in ipairs(bundle.dependencies.dependencies) do
    if item.role == role then
      return item.archive
    end
  end
  error("missing dependency role " .. role, 2)
end

local function confirmationDependency(bundle, memberId)
  for _, item in ipairs(bundle.dependencies.dependencies) do
    if item.archive == "intro" and item.memberId == memberId and item.role:find("confirmation", 1, true) then
      return item
    end
  end
  return nil
end

local function assertConfirmationSource(bundle, versionId)
  -- After TextButton migration, confirmation backing is no longer a generated asset.
  for _, id in ipairs({ "confirmation_yes", "confirmation_no" }) do
    Assert.isNil(bundle.manifest.widgets[id], id .. " is not a generated asset")
  end
  for _, memberId in ipairs({ 48, 37, 33 }) do
    Assert.isNil(
      confirmationDependency(bundle, memberId),
      versionId .. " confirmation backing provenance must not include intro member " .. memberId
    )
  end
end

local function assertBallSource(bundle)
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    for role, memberId in pairs({
      ["resdat-header"] = 78,
      ["resdat-char-table"] = 26,
      ["resdat-palette-table"] = 27,
      ["resdat-cell-table"] = 25,
      ["resdat-animation-table"] = 24,
    }) do
      Assert.equal(sourceMember(bundle, id .. ":" .. role), memberId, id .. " uses shared resdat mapping")
      Assert.equal(sourceArchive(bundle, id .. ":" .. role), "NARC_data_resdat")
    end
  end
end

local function assertVariant(bundle, versionId, paletteMember)
  Assert.equal(bundle.manifest.schemaVersion, 11)
  Assert.equal(bundle.manifest.variant, versionId)
  Assert.equal(sourceMember(bundle, "background:char"), 0)
  Assert.equal(sourceMember(bundle, "background:screen"), 3)
  Assert.equal(sourceMember(bundle, "background:palette"), paletteMember)
  Assert.equal(bundle.manifest.background.width, 1)
  Assert.equal(bundle.manifest.background.height, 192)
  Assert.equal(bundle.manifest.background.sampling, "linear")

  local _, height, rgba = PngReader.rgba(bundle.assets[bundle.manifest.background.image])
  local colors = {}
  for row = 0, height - 1 do
    colors[rgba:sub(row * 4 + 1, row * 4 + 4)] = true
  end
  local distinct = 0
  for _ in pairs(colors) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct > 1, "the source-derived background gradient is not flat")

  local marill = bundle.manifest.widgets.marill
  for index, frame in ipairs(marill.frames) do
    local _, _, frameRgba = PngReader.rgba(bundle.assets[frame.image])
    local visible = false
    for offset = 1, #frameRgba, 4 do
      local _, _, _, a = string.byte(frameRgba, offset, offset + 3)
      if a > 0 then
        visible = true
        break
      end
    end
    Assert.isTrue(visible, versionId .. " Marill frame " .. index .. " must contain decoded OAM pixels")
  end
end

local function assertGenderSource(bundle)
  for _, id in ipairs({ "gender_male", "gender_female" }) do
    Assert.notNil(bundle.manifest.widgets[id], id .. " semantic selector is present")
    Assert.isTrue(#bundle.manifest.widgets[id].frames > 0, id .. " has visible frames")
    Assert.notNil(bundle.assets[bundle.manifest.widgets[id].frames[1].image], id .. " has image output")
  end
  Assert.deepEqual(bundle.manifest.widgets.gender_male.sourceCenter, { x = 64, y = 104 })
  Assert.deepEqual(bundle.manifest.widgets.gender_female.sourceCenter, { x = 192, y = 104 })
  Assert.deepEqual(bundle.manifest.genderSelector.buttons.male.bounds, {
    x = 18,
    y = 25,
    width = 93,
    height = 148,
  })
  Assert.isNil(bundle.manifest.profileConfirmation, "screen-space confirmation records are not published")
  Assert.isNil(bundle.manifest.genderSelector.buttons.male.hitBounds, "touch hit bounds are not published")
  for _, id in ipairs({ "gender_male", "gender_female" }) do
    for role, memberId in pairs({
      ["resdat-header"] = 78,
      ["resdat-char-table"] = 26,
      ["resdat-palette-table"] = 27,
      ["resdat-cell-table"] = 25,
      ["resdat-animation-table"] = 24,
    }) do
      Assert.equal(sourceMember(bundle, id .. ":" .. role), memberId, id .. " uses shared resdat mapping")
      Assert.equal(sourceArchive(bundle, id .. ":" .. role), "NARC_data_resdat")
    end
  end
  Assert.notNil(bundle.manifest.widgets.male, "main male portrait remains distinct")
  Assert.notNil(bundle.manifest.widgets.female, "main female portrait remains distinct")
end

function T.both_variants_compile_the_correct_gradient(romFs, versionId)
  local first = assert(compiler().compile(romFs))
  local second = assert(compiler().compile(romFs))
  assertVariant(first, versionId, versionId == "heartgold" and 1 or 2)
  assertGenderSource(first)
  assertConfirmationSource(first, versionId)
  assertBallSource(first)
  Assert.equal(first.manifest.widgets.ball_open.sourceCenter.x, 160)
  Assert.equal(first.manifest.widgets.ball_open.sourceCenter.y, 80)
  Assert.isTrue(#first.manifest.widgets.ball_open.frames > 0, "ball_open has animation frames")
  Assert.deepEqual(first.manifest, second.manifest, "same source produces deterministic manifest")
  Assert.deepEqual(first.dependencies, second.dependencies, "same source produces deterministic provenance")
  Assert.equal(payloadBytes(first), payloadBytes(second), "same source produces deterministic image bytes")
end

function T.compiled_visuals_are_stable_semantic_widgets(romFs)
  local bundle = assert(compiler().compile(romFs))
  Assert.keySet(
    bundle.manifest.widgets,
    "ball_open,female,gender_female,gender_male,male,marill,marill_appear,oak,shrink_female,shrink_male"
  )
  for id, widget in pairs(bundle.manifest.widgets) do
    Assert.equal(widget.sampling, "nearest", id .. " uses nearest sampling")
    Assert.isTrue(widget.width < 256 or widget.height < 192, id .. " is not a full-screen visual")
    Assert.isTrue(widget.anchor.x >= 0 and widget.anchor.x <= widget.width, id .. " anchor x is bounded")
    Assert.isTrue(widget.anchor.y >= 0 and widget.anchor.y <= widget.height, id .. " anchor y is bounded")
    Assert.isTrue(widget.sourceBounds.x + widget.sourceBounds.width <= 256, id .. " source bounds fit width")
    Assert.isTrue(widget.sourceBounds.y + widget.sourceBounds.height <= 192, id .. " source bounds fit height")
    Assert.isTrue(#widget.frames > 0, id .. " has visible frames")
    for frameIndex, frame in ipairs(widget.frames) do
      Assert.equal(frame.width, widget.width, id .. " frame " .. frameIndex .. " width is stable")
      Assert.equal(frame.height, widget.height, id .. " frame " .. frameIndex .. " height is stable")
      Assert.deepEqual(frame.anchor, widget.anchor, id .. " frame " .. frameIndex .. " anchor is stable")
      Assert.isTrue(frame.duration > 0, id .. " frame " .. frameIndex .. " has fixed timing")
      local _, decodedHeight = PngReader.rgba(bundle.assets[frame.image])
      Assert.equal(decodedHeight, frame.height, id .. " frame payload has declared height")
    end
  end
  Assert.equal(bundle.manifest.widgets.ball_open.sourceCenter.x, 160)
  Assert.equal(bundle.manifest.widgets.ball_open.sourceCenter.y, 80)
  Assert.equal(bundle.manifest.widgets.marill_appear.sourceCenter.x, 160)
  Assert.equal(bundle.manifest.widgets.marill.sourceCenter.x, 160)
  Assert.isNil(bundle.manifest.widgets.ball)
end

local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")

local function withMarillPlayback(manifest, playMode, loopStartFrameIdx)
  local widgets = {}
  for id, widget in pairs(manifest.widgets) do
    widgets[id] = widget
  end
  local marill = {}
  for key, value in pairs(manifest.widgets.marill) do
    marill[key] = value
  end
  marill.playMode = playMode
  marill.loopStartFrameIdx = loopStartFrameIdx
  widgets.marill = marill
  local copy = {}
  for key, value in pairs(manifest) do
    copy[key] = value
  end
  copy.widgets = widgets
  return copy
end

function T.compiled_reveal_animations_carry_their_source_playback_policy(romFs)
  local bundle = assert(compiler().compile(romFs))
  local appear = assert(bundle.manifest.widgets.marill_appear)
  local marill = assert(bundle.manifest.widgets.marill)
  local ball = assert(bundle.manifest.widgets.ball_open)

  Assert.equal(appear.playMode, "forward")
  Assert.equal(ball.playMode, "forward")
  Assert.equal(marill.playMode, "forward_loop")
  Assert.equal(marill.loopStartFrameIdx, 0)
  Assert.equal(#marill.frames, 2)
  Assert.equal(marill.frames[1].duration, 12)
  Assert.equal(marill.frames[2].duration, 60)
  for id, widget in pairs({ marill_appear = appear, marill = marill, ball_open = ball }) do
    Assert.isTrue(
      type(widget.loopStartFrameIdx) == "number"
        and widget.loopStartFrameIdx % 1 == 0
        and widget.loopStartFrameIdx >= 0
        and widget.loopStartFrameIdx < #widget.frames,
      id .. " loop start is a zero-based frame index"
    )
  end

  local valid, validErr = IntroAssetCache.validateManifest(bundle.manifest)
  Assert.isTrue(valid, validErr and validErr.message or "the enriched intro manifest is invalid")

  local missing, missingErr = IntroAssetCache.validateManifest(withMarillPlayback(bundle.manifest, nil, 0))
  Assert.isFalse(missing, "a reveal animation without playback policy must be rejected")
  Assert.equal(assert(missingErr).code, "INTRO_MANIFEST_INVALID")

  local unknown, unknownErr = IntroAssetCache.validateManifest(withMarillPlayback(bundle.manifest, "loop_forever", 0))
  Assert.isFalse(unknown, "an unrecognized play mode must be rejected")
  Assert.equal(assert(unknownErr).code, "INTRO_MANIFEST_INVALID")

  local outOfRange, outOfRangeErr =
    IntroAssetCache.validateManifest(withMarillPlayback(bundle.manifest, "forward_loop", #marill.frames))
  Assert.isFalse(outOfRange, "a loop start outside the frame table must be rejected")
  Assert.equal(assert(outOfRangeErr).code, "INTRO_MANIFEST_INVALID")
end

return RomSuite.fromFacts(T)
