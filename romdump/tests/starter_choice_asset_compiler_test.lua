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
  Assert.equal(layout.radius, 2, "the ring radius is normalized to the compiled model unit")
  Assert.equal(layout.modelY, 0.875, "model origins are normalized to the compiled model unit")
  Assert.equal(layout.touchYOffsetY, 0.8125, "touch centers are normalized to the compiled model unit")
  Assert.near(
    layout.inspectPivotYOffsetY,
    13.453 / 16,
    1e-9,
    "the selected-ball arc pivots at the normalized inspect height"
  )
  Assert.deepEqual(layout.slotAnglesDegrees, { 0, 120, 240 }, "slots are one step apart on the ring")
  Assert.near(layout.inspectArcDegrees, -30.76, 0.01, "the inspect arc matches the source endpoint")
  local turntable = assert(scene.turntable, "scene carries turntable facts")
  Assert.equal(turntable.selectionStepDegrees, 120, "one selection step spans a third of the ring")
  Assert.near(turntable.rotationDegreesPerTick, 11.25, 1e-9, "the turntable rate matches the source rate")
  local timing = assert(scene.timing, "scene carries observable timing boundaries")
  Assert.equal(timing.cameraTicks, 8, "the camera path lasts eight source steps")
  Assert.equal(timing.ballArcTicks, 8, "the inspect arc lasts eight source steps")
  Assert.equal(timing.smallWobbleFrame, 80, "the small-wobble phase carries the source frame")
  Assert.equal(timing.infoFadeTicks, 10, "the info fade carries the source boundary")
  Assert.equal(timing.machineFadeTicks, 16, "the machine fade carries the source boundary")
  local camera = assert(scene.camera, "scene carries source camera parameters")
  Assert.equal(camera.near, 0.25, "the near plane is normalized to the compiled model unit")
  Assert.equal(camera.far, 16, "the far plane is normalized to the compiled model unit")
  local out = assert(camera.out, "outside camera parameters")
  local inside = assert(camera.inside, "inside camera parameters")
  assertFinite(out.angleX, "outside camera angle")
  assertFinite(out.perspective, "outside camera perspective")
  assertFinite(inside.angleX, "inside camera angle")
  assertFinite(inside.perspective, "inside camera perspective")
  Assert.near(out.perspective, 49.61, 1e-9, "outside field carries the doubled source half-angle")
  Assert.near(inside.perspective, 45.4, 1e-9, "inside field carries the doubled source half-angle")
  Assert.deepEqual(out.target, { x = 0, y = 0.9375, z = 0.875 }, "outside camera target is normalized")
  Assert.deepEqual(inside.target, { x = 0, y = 0.9375, z = 0.75 }, "inside camera target is normalized")
  Assert.equal(out.distance, 6.25, "outside camera distance is normalized")
  Assert.equal(inside.distance, 3.75, "inside camera distance is normalized")
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

  local assets = assert(bundle.assets, "compilation returns referenced asset payloads")
  local backgrounds = assert(manifest.backgrounds, "the chooser owns its generated background roles")
  local hostEntry = assert(backgrounds.host, "host decoration is retained")
  Assert.keySet(hostEntry, "height,image,width", "the host decoration is one flat record")
  local hostBytes = assert(assets[hostEntry.image], "host payload is compiled")
  local hostWidth, hostHeight = PngReader.rgba(hostBytes)
  Assert.equal(hostWidth, hostEntry.width, "host payload width matches the manifest")
  Assert.equal(hostHeight, hostEntry.height, "host payload height matches the manifest")
  local info = assert(backgrounds.info, "the info artwork roles are present")
  Assert.equal(info.overlayAlpha, 5 / 16, "the overlay blend coefficient matches the source alpha pair")
  for _, role in ipairs({ "base", "overlay" }) do
    assertBackdropEntry(info[role], assets, role)
  end

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
  Assert.equal(layout.radius, 2, "the ring radius is normalized to the compiled model unit")
  Assert.equal(layout.modelY, 0.875, "model origins are normalized to the compiled model unit")
  Assert.equal(layout.touchYOffsetY, 0.8125, "touch centers are normalized to the compiled model unit")
  Assert.near(
    layout.inspectPivotYOffsetY,
    13.453 / 16,
    1e-9,
    "the selected-ball arc pivots at the normalized inspect height"
  )
  Assert.deepEqual(layout.slotAnglesDegrees, { 0, 120, 240 }, "slots are one step apart on the ring")
  Assert.near(layout.inspectArcDegrees, -30.76, 0.01, "the inspect arc matches the source endpoint")
  local turntable = assert(scene.turntable, "scene carries turntable facts")
  Assert.equal(turntable.selectionStepDegrees, 120, "one selection step spans a third of the ring")
  Assert.near(turntable.rotationDegreesPerTick, 11.25, 1e-9, "the turntable rate matches the source rate")
  local timing = assert(scene.timing, "scene carries observable timing boundaries")
  Assert.equal(timing.cameraTicks, 8, "the camera path lasts eight source steps")
  Assert.equal(timing.ballArcTicks, 8, "the inspect arc lasts eight source steps")
  Assert.equal(timing.smallWobbleFrame, 80, "the small-wobble phase carries the source frame")
  Assert.equal(timing.infoFadeTicks, 10, "the info fade carries the source boundary")
  Assert.equal(timing.machineFadeTicks, 16, "the machine fade carries the source boundary")
  Assert.isNil(scene.ballPositions, "invented linear ball positions are gone")
  Assert.isNil(scene.ballYRotation, "the misleading rotation pair is gone")
  Assert.isNil(scene.camera.transitionTicks, "no universal transition duration remains on the camera")

  local backgrounds = assert(manifest.backgrounds, "the chooser owns its generated background roles")
  assertBackdropEntry(backgrounds.host, assets, "host")
  local info = assert(backgrounds.info, "the info artwork roles are present")
  assertBackdropEntry(info.base, assets, "base")
  assertBackdropEntry(info.overlay, assets, "overlay")

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

local function ballMeshRadius(romFs, bundle)
  local stamped = assert(bundle.dependencies.dependencies, "dependencies list source hashes")
  local memberId = nil
  for _, entry in ipairs(stamped) do
    if entry.role == "model:ball" then
      memberId = entry.memberId
    end
  end
  Assert.notNil(memberId, "the ball source member is stamped into dependencies")
  local archive = assert(romFs:openNarc("NARC_application_choose_starter_choose_starter_main_res"))
  local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
  local MeshCompiler = require("romdump.src.digest.model.MeshCompiler")
  local decoded = assert(Nsbmd.decode(assert(archive:readMember(memberId)), { alias = "test", memberId = memberId }))
  local radius = 0
  local ballModel = assert(decoded.models[1], "the ball member carries one model")
  for _, batch in ipairs(MeshCompiler.compile(ballModel)) do
    for _, vertex in ipairs(batch.vertices) do
      local horizontal = math.sqrt(vertex.x * vertex.x + vertex.z * vertex.z)
      if horizontal > radius then
        radius = horizontal
      end
    end
  end
  Assert.isTrue(radius > 0, "the compiled ball mesh has a nonzero extent")
  return radius
end

local function projectBall(center, meshRadius, camera)
  local elevation = math.rad(-camera.angleX)
  local eye = {
    x = camera.target.x,
    y = camera.target.y + camera.distance * math.sin(elevation),
    z = camera.target.z + camera.distance * math.cos(elevation),
  }
  local forward = {
    x = camera.target.x - eye.x,
    y = camera.target.y - eye.y,
    z = camera.target.z - eye.z,
  }
  local length = math.sqrt(forward.x * forward.x + forward.y * forward.y + forward.z * forward.z)
  forward = { x = forward.x / length, y = forward.y / length, z = forward.z / length }
  local right = { x = forward.z, y = 0, z = -forward.x }
  local rightLength = math.sqrt(right.x * right.x + right.z * right.z)
  right = { x = right.x / rightLength, y = 0, z = right.z / rightLength }
  local up = {
    x = right.y * forward.z - right.z * forward.y,
    y = right.z * forward.x - right.x * forward.z,
    z = right.x * forward.y - right.y * forward.x,
  }
  local view = { x = center.x - eye.x, y = center.y - eye.y, z = center.z - eye.z }
  local depth = view.x * forward.x + view.y * forward.y + view.z * forward.z
  local focal = math.tan(math.rad(camera.perspective) / 2) * depth
  return {
    depth = depth,
    x = (view.x * right.x + view.y * right.y + view.z * right.z) / focal,
    y = (view.x * up.x + view.y * up.y + view.z * up.z) / focal,
    extent = meshRadius / focal,
  }
end

function T.scene_dimensions_and_clipping_share_the_compiled_model_unit(romFs)
  local bundle = assert(compiler().compile(romFs))
  local manifest = assert(bundle.manifest, "compilation returns a manifest")
  local layout = assert(manifest.scene.ballLayout, "scene carries the ball ring layout")
  Assert.equal(layout.radius, 2, "the ring radius is normalized")
  Assert.equal(layout.modelY, 0.875, "model origins are normalized")
  Assert.equal(layout.touchYOffsetY, 0.8125, "touch centers are normalized")
  Assert.near(
    layout.inspectPivotYOffsetY,
    13.453 / 16,
    1e-9,
    "the selected-ball arc pivots at the normalized inspect height"
  )
  local camera = assert(manifest.scene.camera, "scene carries the camera contract")
  Assert.equal(camera.near, 0.25, "the near plane is normalized")
  Assert.equal(camera.far, 16, "the far plane is normalized")
  Assert.deepEqual(camera.out.target, { x = 0, y = 0.9375, z = 0.875 }, "outside camera target is normalized")
  Assert.equal(camera.out.distance, 6.25, "outside camera distance is normalized")
  Assert.deepEqual(camera.inside.target, { x = 0, y = 0.9375, z = 0.75 }, "inside camera target is normalized")
  Assert.equal(camera.inside.distance, 3.75, "inside camera distance is normalized")
  Assert.near(camera.out.perspective, 49.61, 1e-9, "outside field keeps the source half-angle doubling")
  Assert.near(camera.inside.perspective, 45.4, 1e-9, "inside field keeps the source half-angle doubling")

  local meshRadius = ballMeshRadius(romFs, bundle)
  local seen = projectBall({ x = layout.radius, y = layout.modelY, z = 0 }, meshRadius, camera.out)
  Assert.isTrue(seen.depth > camera.near and seen.depth < camera.far, "the ball sits inside the clipping planes")
  Assert.isTrue(math.abs(seen.x) < 1 and math.abs(seen.y) < 1, "the ball projects inside the frame")
  Assert.isTrue(seen.extent > 0.05 and seen.extent < 0.9, "the compiled ball covers a plausible frame extent")

  local raw = projectBall({ x = 32, y = 14, z = 0 }, meshRadius, {
    target = { x = 0, y = 15, z = 14 },
    distance = 100,
    angleX = camera.out.angleX,
    perspective = camera.out.perspective,
  })
  Assert.isTrue(raw.extent < 0.03, "the previous raw-unit mismatch shrinks the compiled ball out of view")
end

function T.tabletop_uses_its_authored_texture_binding(romFs)
  local bundle = assert(compiler().compile(romFs))
  local manifest = assert(bundle.manifest, "compilation returns a manifest")
  local tabletop = assertValidModel(manifest.models, "tabletop")
  Assert.notNil(tabletop, "the tabletop descriptor is present")
  local dependencies = assert(bundle.dependencies, "compilation returns source dependencies")
  for _, entry in ipairs(assert(dependencies.unresolvedMaterials, "unresolved bindings are reported")) do
    Assert.isTrue(entry.role ~= "tabletop", "no unexplained tabletop binding remains")
  end
  assertNoSourceIdentities(manifest, "manifest")
end

function T.tabletop_without_its_expected_texture_data_is_a_source_error(romFs)
  local archive = assert(romFs:openNarc("NARC_application_choose_starter_choose_starter_main_res"))
  local turntableBytes = assert(archive:readMember(1), "the turntable member reads")
  local start = turntableBytes:find("TEX0", 1, true)
  Assert.notNil(start, "the turntable member carries an embedded texture section")
  local patched = turntableBytes:sub(1, start - 1) .. "TEXx" .. turntableBytes:sub(start + 4)
  local realOpen = romFs.openNarc
  local wrapped = setmetatable({}, {
    __index = function(_, key)
      if key == "readMember" then
        return function(_, memberId)
          if memberId == 0 then
            return patched
          end
          return archive:readMember(memberId)
        end
      end
      local value = archive[key]
      if type(value) == "function" then
        return function(_, ...)
          return value(archive, ...)
        end
      end
      return value
    end,
  })
  romFs.openNarc = function(_, symbol)
    if symbol == "NARC_application_choose_starter_choose_starter_main_res" then
      return wrapped
    end
    return realOpen(romFs, symbol)
  end
  local ok, result, err = pcall(compiler().compile, romFs)
  romFs.openNarc = realOpen
  Assert.isTrue(ok, "the failure must surface as a typed error rather than a raw throw")
  Assert.isNil(result, "a tabletop naming textures without embedded texture data must fail")
  Assert.equal(assert(err).code, "STARTER_CHOICE_SOURCE_INVALID", "the failure uses the starter source family")
end

local function probePixel(assets, image, x, y)
  local width, _, rgba = PngReader.rgba(assert(assets[image], "image payload " .. image .. " is compiled"))
  local base = (y * width + x) * 4
  local r, g, b, a = string.byte(rgba, base + 1, base + 4)
  return width, { r, g, b, a }
end

function T.info_backgrounds_come_from_source_artwork(romFs)
  local bundle = assert(compiler().compile(romFs))
  local manifest = assert(bundle.manifest, "compilation returns a manifest")
  local assets = assert(bundle.assets, "compilation returns referenced asset payloads")
  local backgrounds = assert(manifest.backgrounds, "manifest carries background roles")
  local host = assert(backgrounds.host, "host decoration is retained")
  Assert.equal(host.width, 512, "host decoration keeps its dimensions")
  Assert.equal(host.height, 192, "host decoration keeps its dimensions")
  local info = assert(backgrounds.info, "manifest carries the info artwork roles")
  Assert.equal(info.overlayAlpha, 5 / 16, "the overlay blend coefficient matches the source alpha pair")
  for _, role in ipairs({ "base", "overlay" }) do
    local entry = assert(info[role], role .. " entry is present")
    Assert.equal(entry.width, 256, role .. " spans the logical surface")
    Assert.equal(entry.height, 192, role .. " spans the logical surface")
    local width = PngReader.rgba(assert(assets[entry.image], role .. " payload is compiled"))
    Assert.equal(width, 256, role .. " payload width matches the manifest")
    Assert.isTrue(entry.image ~= host.image, role .. " is not the host gradient")
  end
  local _, baseSample = probePixel(assets, info.base.image, 8, 8)
  Assert.deepEqual(baseSample, { 107, 107, 115, 255 }, "base artwork probe matches the source decode")
  local _, baseEdge = probePixel(assets, info.base.image, 240, 20)
  Assert.deepEqual(baseEdge, { 156, 156, 156, 255 }, "base edge probe matches the source decode")
  local _, overlayLine = probePixel(assets, info.overlay.image, 118, 29)
  Assert.deepEqual(overlayLine, { 58, 58, 58, 255 }, "overlay artwork probe matches the source decode")
  local _, overlayHole = probePixel(assets, info.overlay.image, 128, 100)
  Assert.deepEqual(overlayHole, { 0, 0, 0, 0 }, "overlay transparency exposes the lower layer")
  assertNoSourceIdentities(manifest, "manifest")
  Assert.isTrue(cache().validateManifest(manifest), "the runtime cache contract accepts the manifest")
end

function T.surface_records_carry_source_geometry_and_rear_plane_color(romFs)
  local bundle = assert(compiler().compile(romFs))
  local manifest = assert(bundle.manifest, "compilation returns a manifest")
  local surfaces = assert(manifest.surfaces, "manifest carries surface records")
  Assert.deepEqual(surfaces.machine.prompt, {
    box = { x = 8, y = 152, width = 232, height = 32 },
    textOrigin = { x = 8, y = 152 },
    framed = false,
  }, "machine prompt geometry and frame policy")
  Assert.deepEqual(surfaces.info.message, {
    box = { x = 16, y = 152, width = 216, height = 32 },
    textOrigin = { x = 16, y = 152 },
    framed = true,
  }, "info message geometry and frame policy")
  Assert.deepEqual(surfaces.info.portrait, { x = 88, y = 56, width = 80, height = 80 }, "portrait slot")
  local clear = assert(surfaces.machine.clearColor, "machine clear color is present")
  Assert.equal(clear.r, 1, "machine clear red")
  Assert.equal(clear.g, 1, "machine clear green")
  Assert.isTrue(math.abs(clear.b - 16 / 31) < 1e-9, "machine clear blue matches the source rear plane")
  Assert.equal(clear.a, 1, "machine clear alpha")
  Assert.isTrue(cache().validateManifest(manifest), "the runtime cache contract accepts the manifest")
end

return RomSuite.fromFacts(T)
