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
local PngReader = require("tests.support.PngReader")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.StarterChoiceAssetCompiler")
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
  Assert.equal(#scene.ballPositions, 3, "exactly three source ball positions")
  local seen = {}
  for index, position in ipairs(scene.ballPositions) do
    assertFinite(position.x, "ball position " .. index .. " x")
    assertFinite(position.y, "ball position " .. index .. " y")
    assertFinite(position.z, "ball position " .. index .. " z")
    local key = position.x .. "," .. position.y .. "," .. position.z
    Assert.isTrue(seen[key] == nil, "ball positions are distinct")
    seen[key] = true
  end
  local camera = assert(scene.camera, "scene carries source camera parameters")
  Assert.equal(camera.transitionTicks, 8, "camera transition is eight ticks")
  local out = assert(camera.out, "outside camera parameters")
  local inside = assert(camera.inside, "inside camera parameters")
  assertFinite(out.angleX, "outside camera angle")
  assertFinite(out.perspective, "outside camera perspective")
  assertFinite(inside.angleX, "inside camera angle")
  assertFinite(inside.perspective, "inside camera perspective")
  Assert.deepEqual(out.target, { x = 0, y = 0, z = 14 }, "outside camera target")
  Assert.deepEqual(inside.target, { x = 0, y = 0, z = 12 }, "inside camera target")
  Assert.equal(out.distance, 100, "outside camera distance")
  Assert.equal(inside.distance, 60, "inside camera distance")
  Assert.isTrue(out.angleX < inside.angleX, "outside view looks down more steeply than inside")
  Assert.isTrue(out.perspective > inside.perspective, "outside view is wider than inside")
  local rotation = assert(scene.ballYRotation, "scene carries ball Y rotations")
  assertFinite(rotation.out, "ball outside Y rotation")
  assertFinite(rotation.inside, "ball inside Y rotation")
  Assert.notNil(scene.wobble, "scene carries normalized wobble timing")

  local messages = assert(manifest.messages, "manifest carries decoded chooser messages")
  Assert.keySet(messages, "confirm,initial")
  Assert.isTrue(type(messages.initial) == "string" and #messages.initial > 0, "initial message is decoded")
  Assert.isTrue(type(messages.confirm) == "string" and #messages.confirm > 0, "confirm message is decoded")

  local sprites = assert(manifest.speciesSprites, "manifest carries species-display sprites")
  Assert.keySet(sprites, "chikorita,cyndaquil,totodile")
  local assets = assert(bundle.assets, "compilation returns referenced asset payloads")
  for _, id in ipairs({ "chikorita", "cyndaquil", "totodile" }) do
    local entry = assert(sprites[id], id .. " sprite entry is present")
    Assert.isTrue(
      type(entry.image) == "string" and entry.image:find("assets/generated/starter_choice/", 1, true) == 1,
      id .. " sprite uses a starter-choice generated path"
    )
    local bytes = assert(assets[entry.image], id .. " sprite payload is compiled")
    local width, height = PngReader.rgba(bytes)
    Assert.isTrue(width > 0 and height > 0, id .. " sprite payload is a real image")
  end

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

return RomSuite.fromFacts(T)
