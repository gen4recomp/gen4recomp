-- Retail choose-starter application asset inventory, compiled from a real HGSS
-- dump through the production compiler. The manifest must carry the six render
-- roles, the semantic animation bindings, the normalized scene constants, the
-- decoded chooser messages, and the three species-display sprites without
-- exposing source archive or member identities. Source basis:
-- pret/pokeheartgold src/choose_starter_app.c and src/choose_starter.c.
-- Requires a ready user-owned dump (rom_dump capability); skips otherwise.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local PngReader = require("tests.support.PngReader")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.newgame.StarterChoiceAssetCompiler")
  if not ok then
    error("the ROM-derived starter-choice compiler is missing: " .. tostring(module), 0)
  end
  return module
end

local function cache()
  local ok, module = pcall(require, "libs.assets.src.StarterChoiceAssetCache")
  if not ok then
    error("the starter-choice cache contract is missing: " .. tostring(module), 0)
  end
  return module
end

local function finite(value)
  return type(value) == "number" and value == value and value < math.huge and value > -math.huge
end

local function assertFinite(value, what)
  Assert.isTrue(finite(value), what .. " must be a finite number")
end

local function assertValidModel(models, role)
  local desc = models[role]
  Assert.notNil(desc, "model role " .. role .. " is present")
  local ok, err = pcall(ModelAsset.validate, desc)
  Assert.isTrue(ok, "model role " .. role .. " passes normalized validation: " .. tostring(err))
  return desc
end

local function resolveBinding(desc, binding, what)
  Assert.notNil(desc.animations, what .. " owns a compiled animation list")
  if type(binding) == "string" then
    for _, clip in ipairs(desc.animations) do
      if clip.id == binding or clip.name == binding then
        return clip
      end
    end
    error(what .. " binding " .. binding .. " resolves to no clip on its model", 0)
  end
  if type(binding) == "number" and binding % 1 == 0 then
    local clip = desc.animations[binding]
    Assert.notNil(clip, what .. " binding index " .. tostring(binding) .. " is in range")
    return clip
  end
  error(what .. " binding must name a clip or a descriptor-local index", 0)
end

local function assertResolves(desc, binding, what)
  local clip = resolveBinding(desc, binding, what)
  Assert.isTrue(type(clip.frameCount) == "number" and clip.frameCount >= 1, what .. " resolves to a playable clip")
end

local function assertNoSourceIdentities(value, path)
  if type(value) == "string" then
    Assert.isTrue(value:find("NARC_", 1, true) == nil, path .. " carries no source archive symbol")
    Assert.isTrue(value:match("^a/%d+/%d+/%d+$") == nil, path .. " carries no source archive path")
    return
  end
  if type(value) ~= "table" then
    return
  end
  for key, item in pairs(value) do
    if type(key) == "string" then
      Assert.isTrue(key:find("NARC_", 1, true) == nil, path .. " carries no source archive symbol")
    end
    assertNoSourceIdentities(item, path .. "." .. tostring(key))
  end
end

local function assertPreparedLine(line, what)
  Assert.isTrue(type(line) == "table" and #line >= 1, what .. " is a non-empty glyph line")
  for _, glyph in ipairs(line) do
    Assert.keySet(glyph, "code,colorIndex,kind", what .. " glyph carries only its render fields")
    Assert.equal(glyph.kind, "glyph", what .. " glyph is render-ready")
    Assert.isTrue(
      type(glyph.code) == "number" and glyph.code % 1 == 0 and glyph.code >= 0 and glyph.code <= 65535,
      what .. " glyph code is a field-font code"
    )
    Assert.isTrue(
      type(glyph.colorIndex) == "number"
        and glyph.colorIndex % 1 == 0
        and glyph.colorIndex >= 0
        and glyph.colorIndex < FieldMessageText.COLOR_VARIANT_COUNT,
      what .. " glyph color stays in the field palette range"
    )
  end
end

local function assertPreparedMessage(message, what)
  Assert.isTrue(type(message) == "table", what .. " is a prepared message record, not a marker string")
  Assert.keySet(message, "lines", what .. " carries only its prepared lines")
  local lines = assert(message.lines, what .. " carries prepared lines")
  Assert.isTrue(type(lines) == "table" and #lines >= 1 and #lines <= 2, what .. " keeps the source line count")
  for index, line in ipairs(lines) do
    assertPreparedLine(line, what .. " line " .. index)
  end
end

local function assertNoMarkerText(value, path)
  if type(value) == "string" then
    Assert.isTrue(value:find("{", 1, true) == nil, path .. " carries no marker text")
    return
  end
  if type(value) ~= "table" then
    return
  end
  for key, item in pairs(value) do
    assertNoMarkerText(item, path .. "." .. tostring(key))
  end
end

local function assertBackdropEntry(entry, assets, what)
  Assert.notNil(entry, what .. " backdrop entry is present")
  Assert.isTrue(
    type(entry.image) == "string" and entry.image:find("assets/generated/starter_choice/", 1, true) == 1,
    what .. " backdrop uses a chooser generated path"
  )
  Assert.isTrue(
    type(entry.width) == "number"
      and entry.width >= 1
      and entry.width % 1 == 0
      and type(entry.height) == "number"
      and entry.height >= 1
      and entry.height % 1 == 0,
    what .. " backdrop carries positive integer dimensions"
  )
  local bytes = assert(assets[entry.image], what .. " backdrop payload is compiled")
  local width, height = PngReader.rgba(bytes)
  Assert.equal(width, entry.width, what .. " backdrop payload width matches the manifest")
  Assert.equal(height, entry.height, what .. " backdrop payload height matches the manifest")
end

function T.retail_application_inventory_compiles_from_the_real_dump(romFs)
  local bundle = assert(compiler().compile(romFs))
  local manifest = assert(bundle.manifest, "compilation returns a manifest")
  local family =
    assert(DerivedAssetContract.starterChoice, "the derived asset contract declares the starter-choice family")
  Assert.equal(manifest.schema, family.schema, "manifest carries the contract schema")
  Assert.deepEqual(manifest.reference, { width = 256, height = 192 }, "DS reference viewport")

  local models = assert(manifest.models, "manifest carries normalized 3D roles")
  Assert.keySet(models, "ball1,ball2,ball3,ballEffect,tabletop,turntable")
  local descs = {}
  for _, role in ipairs({ "tabletop", "turntable", "ballEffect", "ball1", "ball2", "ball3" }) do
    descs[role] = assertValidModel(models, role)
  end

  local animations = assert(manifest.animations, "manifest carries semantic animation bindings")
  Assert.equal(#animations.ballRock, 3, "three ball rock bindings")
  Assert.notNil(animations.ballOpen, "ball open binding is present")
  Assert.notNil(animations.ballEffect, "ball effect binding is present")
  Assert.notNil(animations.turntable, "turntable binding is present")
  for index, binding in ipairs(animations.ballRock) do
    assertResolves(descs["ball" .. index], binding, "ball rock binding " .. index)
  end
  for _, role in ipairs({ "ball1", "ball2", "ball3" }) do
    assertResolves(descs[role], animations.ballOpen, "ball open binding on " .. role)
  end
  assertResolves(descs.ballEffect, animations.ballEffect, "ball effect binding")
  assertResolves(descs.turntable, animations.turntable, "turntable binding")

  local scene = assert(manifest.scene, "manifest carries normalized scene constants")
  local layout = assert(scene.ballLayout, "scene carries the source ball ring layout")
  Assert.equal(layout.radius, 32, "the ring radius matches the source model")
  Assert.equal(layout.modelY, 14, "model origins sit at the source height")
  Assert.equal(layout.touchYOffsetY, 13, "touch centers sit above the model origins")
  Assert.deepEqual(layout.slotAnglesDegrees, { 0, 120, 240 }, "slots are one step apart on the ring")
  Assert.near(layout.inspectArcDegrees, -30.76, 0.01, "the inspect arc matches the source endpoint")
  local turntable = assert(scene.turntable, "scene carries turntable facts")
  Assert.equal(turntable.selectionStepDegrees, 120, "one selection step spans a third of the ring")
  Assert.near(turntable.rotationDegreesPerTick, 0.5, 1e-9, "the turntable rate matches the source rate")
  local timing = assert(scene.timing, "scene carries observable timing boundaries")
  Assert.equal(timing.cameraTicks, 8, "the camera path lasts eight source steps")
  Assert.equal(timing.ballArcTicks, 8, "the inspect arc lasts eight source steps")
  Assert.equal(timing.smallWobbleFrame, 80, "the small-wobble phase carries the source frame")
  Assert.equal(timing.infoFadeTicks, 10, "the info fade carries the source boundary")
  Assert.equal(timing.machineFadeTicks, 16, "the machine fade carries the source boundary")
  local camera = assert(scene.camera, "scene carries source camera parameters")
  local out = assert(camera.out, "outside camera parameters")
  local inside = assert(camera.inside, "inside camera parameters")
  assertFinite(out.angleX, "outside camera angle")
  assertFinite(out.perspective, "outside camera perspective")
  assertFinite(inside.angleX, "inside camera angle")
  assertFinite(inside.perspective, "inside camera perspective")
  Assert.near(out.perspective, 49.61, 1e-9, "outside field carries the doubled source half-angle")
  Assert.near(inside.perspective, 45.4, 1e-9, "inside field carries the doubled source half-angle")
  Assert.deepEqual(out.target, { x = 0, y = 15, z = 14 }, "outside camera target")
  Assert.deepEqual(inside.target, { x = 0, y = 0, z = 12 }, "inside camera target")
  Assert.equal(out.distance, 100, "outside camera distance")
  Assert.equal(inside.distance, 60, "inside camera distance")
  Assert.isTrue(out.angleX < inside.angleX, "outside view looks down more steeply than inside")
  Assert.isTrue(out.perspective > inside.perspective, "outside view is wider than inside")
  Assert.isNil(camera.transitionTicks, "no universal transition duration remains on the camera")

  local messages = assert(manifest.messages, "manifest carries decoded chooser messages")
  Assert.keySet(messages, "bottom,confirm,inspect,topInitial")
  assertPreparedMessage(messages.topInitial, "the initial top message")
  Assert.isTrue(type(messages.inspect) == "table" and #messages.inspect == 3, "one inspect description per slot")
  Assert.isTrue(type(messages.confirm) == "table" and #messages.confirm == 3, "one confirm description per slot")
  for index = 1, 3 do
    assertPreparedMessage(messages.inspect[index], "inspect description " .. index)
    assertPreparedMessage(messages.confirm[index], "confirm description " .. index)
  end
  assertPreparedMessage(messages.bottom.normal, "the normal bottom prompt")
  assertPreparedMessage(messages.bottom.confirm, "the confirm bottom prompt")

  local background = assert(manifest.background, "the chooser owns its generated backdrop")
  local backdropEntry = background
  Assert.keySet(backdropEntry, "height,image,width", "the backdrop is one flat record")
  Assert.isTrue(
    type(backdropEntry.image) == "string" and backdropEntry.image:find("assets/generated/starter_choice/", 1, true) == 1,
    "backdrop uses a chooser generated path"
  )
  local assets = assert(bundle.assets, "compilation returns referenced asset payloads")
  local backdropBytes = assert(assets[backdropEntry.image], "backdrop payload is compiled")
  local backdropWidth, backdropHeight = PngReader.rgba(backdropBytes)
  Assert.isTrue(backdropWidth > 0 and backdropHeight > 0, "backdrop payload is a real image")

  Assert.isNil(manifest.speciesSprites, "no fixed species image catalog remains")

  for _, desc in pairs(descs) do
    for _, path in ipairs(ModelAsset.referencedPaths(desc)) do
      Assert.notNil(assets[path], "referenced model payload " .. path .. " is compiled")
    end
  end

  assertNoSourceIdentities(manifest, "manifest")

  Assert.isTrue(type(bundle.marker) == "string" and #bundle.marker > 0, "compilation returns a marker")
  local dependencies = assert(bundle.dependencies, "compilation returns source dependencies")
  Assert.isTrue(type(dependencies.dependencies) == "table", "dependencies list source hashes")
  Assert.isTrue(#dependencies.dependencies > 0, "every read source is stamped into dependencies")

  Assert.isTrue(cache().validateManifest(manifest), "the runtime cache contract accepts the manifest")
end

function T.chooser_manifest_carries_semantic_roles_source_geometry_and_owned_backdrop(romFs)
  local bundle = assert(compiler().compile(romFs))
  local manifest = assert(bundle.manifest, "compilation returns a manifest")
  local assets = assert(bundle.assets, "compilation returns referenced asset payloads")
  Assert.deepEqual(manifest.reference, { width = 256, height = 192 }, "one logical surface keeps the 256x192 reference")

  local messages = assert(manifest.messages, "manifest carries decoded chooser messages")
  assertPreparedMessage(messages.topInitial, "the initial top message")
  Assert.isTrue(type(messages.inspect) == "table" and #messages.inspect == 3, "one inspect description per slot")
  Assert.isTrue(type(messages.confirm) == "table" and #messages.confirm == 3, "one confirm description per slot")
  for index = 1, 3 do
    assertPreparedMessage(messages.inspect[index], "inspect description " .. index)
    assertPreparedMessage(messages.confirm[index], "confirm description " .. index)
  end
  local bottom = assert(messages.bottom, "manifest carries bottom prompt roles")
  assertPreparedMessage(bottom.normal, "the normal bottom prompt")
  assertPreparedMessage(bottom.confirm, "the confirm bottom prompt")
  Assert.isNil(messages.initial, "the legacy single initial field is gone")

  local scene = assert(manifest.scene, "manifest carries normalized scene constants")
  local layout = assert(scene.ballLayout, "scene carries the source ball ring layout")
  Assert.equal(layout.radius, 32, "the ring radius matches the source model")
  Assert.equal(layout.modelY, 14, "model origins sit at the source height")
  Assert.equal(layout.touchYOffsetY, 13, "touch centers sit above the model origins")
  Assert.deepEqual(layout.slotAnglesDegrees, { 0, 120, 240 }, "slots are one step apart on the ring")
  Assert.near(layout.inspectArcDegrees, -30.76, 0.01, "the inspect arc matches the source endpoint")
  local turntable = assert(scene.turntable, "scene carries turntable facts")
  Assert.equal(turntable.selectionStepDegrees, 120, "one selection step spans a third of the ring")
  Assert.near(turntable.rotationDegreesPerTick, 0.5, 1e-9, "the turntable rate matches the source rate")
  local timing = assert(scene.timing, "scene carries observable timing boundaries")
  Assert.equal(timing.cameraTicks, 8, "the camera path lasts eight source steps")
  Assert.equal(timing.ballArcTicks, 8, "the inspect arc lasts eight source steps")
  Assert.equal(timing.smallWobbleFrame, 80, "the small-wobble phase carries the source frame")
  Assert.equal(timing.infoFadeTicks, 10, "the info fade carries the source boundary")
  Assert.equal(timing.machineFadeTicks, 16, "the machine fade carries the source boundary")
  Assert.isNil(scene.ballPositions, "invented linear ball positions are gone")
  Assert.isNil(scene.ballYRotation, "the misleading rotation pair is gone")
  Assert.isNil(scene.camera.transitionTicks, "no universal transition duration remains on the camera")

  local background = assert(manifest.background, "the chooser owns its generated backdrop")
  assertBackdropEntry(background, assets, "single")

  Assert.isNil(manifest.speciesSprites, "no fixed species image catalog remains")

  assertNoSourceIdentities(manifest, "manifest")

  Assert.isTrue(cache().validateManifest(manifest), "the runtime cache contract accepts the manifest")
end

function T.compiled_messages_preserve_source_lines_and_species_colors(romFs)
  local bundle = assert(compiler().compile(romFs))
  local manifest = assert(bundle.manifest, "compilation returns a manifest")
  local messages = assert(manifest.messages, "manifest carries decoded chooser messages")

  assertPreparedMessage(messages.topInitial, "the initial top message")
  Assert.equal(#messages.topInitial.lines, 2, "the initial top message keeps both source lines")
  assertPreparedMessage(messages.bottom.confirm, "the confirm bottom prompt")
  Assert.equal(#messages.bottom.confirm.lines, 2, "the confirm bottom prompt keeps both source lines")
  assertPreparedMessage(messages.bottom.normal, "the normal bottom prompt")

  Assert.isTrue(type(messages.inspect) == "table" and #messages.inspect == 3, "one inspect description per slot")
  Assert.isTrue(type(messages.confirm) == "table" and #messages.confirm == 3, "one confirm description per slot")
  for index = 1, 3 do
    assertPreparedMessage(messages.inspect[index], "inspect description " .. index)
    assertPreparedMessage(messages.confirm[index], "confirm description " .. index)
    for _, message in ipairs({ messages.inspect[index], messages.confirm[index] }) do
      local seenColored, seenReset = false, false
      for _, line in ipairs(message.lines) do
        for _, glyph in ipairs(line) do
          if glyph.colorIndex ~= 0 then
            seenColored = true
          elseif seenColored then
            seenReset = true
          end
        end
      end
      Assert.isTrue(seenColored, "species description " .. index .. " keeps its source color span")
      Assert.isTrue(seenReset, "species description " .. index .. " resets to the base color")
    end
  end

  assertNoMarkerText(messages, "messages")

  Assert.isTrue(cache().validateManifest(manifest), "the runtime cache contract accepts the manifest")
end

return RomSuite.fromFacts(T)
