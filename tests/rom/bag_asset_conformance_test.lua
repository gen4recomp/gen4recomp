-- ROM conformance: the field-bag presentation compiles from the real dump.
-- The bag archive resolves through the semantic alias, every audited
-- member decodes, the manifest carries eight tabs, six slots, and both
-- gender heroes with pocket-indexed clips, recompilation is deterministic,
-- and no item-icon bytes enter the bag class. Assertions are coverage
-- relationships and cross-reference validity, never catalog snapshots or
-- committed commercial payloads.

local Assert = require("tests.support.Assert")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local BagSources = require("romdump.src.config.BagSources")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local HgssArchives = require("romdump.src.config.HgssArchives")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local Hashing = require("romdump.src.digest.Hashing")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local compiledByVersion = {}

local function compileBundle(romFs)
  local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
  return assert(BagAssetCompiler.compile(romFs))
end

local function bundleFor(romFs, versionId)
  if compiledByVersion[versionId] == nil then
    compiledByVersion[versionId] = compileBundle(romFs)
  end
  return compiledByVersion[versionId]
end

function T.bag_archive_resolves_through_the_semantic_alias(romFs, _)
  local entry = HgssArchives.resolve("bag_ui")
  Assert.equal(entry.narcId, 15)
  Assert.equal(entry.path, "a/0/1/5")
  local archive = assert(romFs:openNarc("bag_ui"))
  Assert.equal(archive:memberCount(), 95, "the bag archive member census anchors coverage")
end

function T.required_source_members_decode(romFs, _)
  local archive = assert(romFs:openNarc("bag_ui"))
  local function memberBytes(memberId)
    local bytes = assert(archive:readMember(memberId), "bag member " .. memberId .. " must exist")
    return bytes
  end
  local function assertDecodes(kind, memberId, what)
    local record, err = G2dDecoder[kind](memberBytes(memberId), { label = what })
    Assert.notNil(record, what .. " must decode: " .. (err and err.message or "?"))
  end
  for _, memberId in ipairs({
    BagSources.screens.upperBase,
    BagSources.screens.upperAlternate,
    BagSources.screens.upperBackdropMale,
    BagSources.screens.upperBackdropFemale,
    BagSources.screens.listSlots,
    BagSources.screens.listWash,
    BagSources.screens.actionSlots,
    BagSources.screens.actionWash,
    BagSources.screens.confirmation,
    BagSources.screens.quantity,
    BagSources.screens.quantityAlt,
  }) do
    assertDecodes("decodeScreen", memberId, "bag screen " .. memberId)
  end
  for _, memberId in ipairs({ BagSources.chars.upper, BagSources.chars.lower }) do
    assertDecodes("decodeChar", memberId, "bag char " .. memberId)
  end
  assertDecodes("decodeChar", BagSources.chars.registrationMarker, "bag registration marker char")
  for _, memberId in ipairs({ BagSources.palettes.upper, BagSources.palettes.lower }) do
    assertDecodes("decodePalette", memberId, "bag palette " .. memberId)
  end
  assertDecodes("decodeCell", BagSources.sprites.tabs.cell, "bag tab cell")
  assertDecodes("decodeCell", BagSources.sprites.cursor.cell, "bag cursor cell")
  assertDecodes("decodeCell", BagSources.sprites.strip.cell, "bag strip cell")
  assertDecodes("decodeAnimation", BagSources.sprites.tabs.anim, "bag tab animation")
  assertDecodes("decodeAnimation", BagSources.sprites.cursor.anim, "bag cursor animation")
  assertDecodes("decodeAnimation", BagSources.sprites.strip.anim, "bag strip animation")
  local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
  local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
  for _, gender in ipairs({ "male", "female" }) do
    local selection = BagSources.hero[gender]
    local model = assert(Nsbmd.decode(memberBytes(selection.model), { alias = "bag_ui", memberId = selection.model }))
    Assert.equal(#model.models, 1, gender .. " hero must carry one model")
    for slot = 0, 7 do
      for _, memberId in ipairs({ selection.patternBase + slot, selection.jointBase + slot }) do
        local decoded = assert(
          NitroAnimation.decode(memberBytes(memberId), { alias = "bag_ui", memberId = memberId }),
          gender .. " animation member " .. memberId .. " must decode"
        )
        Assert.equal(#decoded.animations, 1, gender .. " animation member " .. memberId .. " carries one clip")
      end
    end
  end
end

function T.compile_emits_tabs_slots_and_both_heroes(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local manifest = bundle.manifest
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the compiled manifest must pass the shared schema")
  Assert.equal(manifest.schema, BagCache.SCHEMA)
  Assert.equal(manifest.logicalSize.width, 256)
  Assert.equal(manifest.logicalSize.height, 192)
  Assert.equal(#manifest.interactive.pocketTabs.rects, 8)
  for index, tab in ipairs(manifest.interactive.pocketTabs.rects) do
    Assert.equal(tab.x, (index - 1) * 32, "tab " .. index .. " tiles the strip row")
    Assert.equal(tab.y, 0)
  end
  Assert.equal(#manifest.interactive.itemSlots.slots, 6)
  local columns, rows = {}, {}
  for _, slot in ipairs(manifest.interactive.itemSlots.slots) do
    columns[slot.rect.x] = true
    rows[slot.rect.y] = true
  end
  local function keyCount(set)
    local count = 0
    for _ in pairs(set) do
      count = count + 1
    end
    return count
  end
  Assert.equal(keyCount(columns), 2, "slots sit in two columns")
  Assert.equal(keyCount(rows), 3, "slots sit in three rows")
  for _, gender in ipairs({ "male", "female" }) do
    local descriptor = manifest.hero.model[gender]
    local ok, err = pcall(ModelAsset.validate, descriptor)
    Assert.isTrue(ok, gender .. " hero descriptor must validate: " .. tostring(err))
    Assert.equal(#descriptor.animations, 17, gender .. " hero carries eight poses, eight patterns, one material")
    local seenClipNames = {}
    for _, clip in ipairs(descriptor.animations) do
      Assert.equal(clip.name, clip.id, gender .. " hero clip name is the semantic clip id")
      Assert.isNil(seenClipNames[clip.name], gender .. " hero carries two clips named " .. tostring(clip.name))
      seenClipNames[clip.name] = true
    end
  end
  Assert.equal(#manifest.hero.animations.states, 8)
  for _, state in ipairs(manifest.hero.animations.states) do
    for _, gender in ipairs({ "male", "female" }) do
      local found = 0
      for _, clip in ipairs(manifest.hero.model[gender].animations) do
        for _, name in ipairs(clip.semanticNames) do
          if name == state.pose or name == state.pattern then
            found = found + 1
          end
        end
      end
      Assert.equal(found, 2, state.pocket .. " resolves one pose and one pattern for " .. gender)
    end
  end
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    Assert.notNil(bundle.assets[path], "referenced asset " .. path .. " must be compiled")
  end
end

function T.compiled_presentation_lengths_land_in_tile_space(romFs, versionId)
  local manifest = bundleFor(romFs, versionId).manifest
  local MapUnits = require("romdump.src.digest.map.MapUnits")
  local divisor = MapUnits.MODEL_UNITS_PER_TILE
  local facts = BagSources.presentation
  local camera = manifest.hero.presentation.camera
  Assert.equal(camera.distance, facts.camera.distance / divisor, "compiled camera distance is normalized to tiles")
  Assert.equal(camera.clipNear, facts.camera.clipNear / divisor, "compiled near plane is normalized to tiles")
  Assert.equal(camera.clipFar, facts.camera.clipFar / divisor, "compiled far plane is normalized to tiles")
  Assert.deepEqual(camera.target, {
    x = facts.camera.target.x / divisor,
    y = facts.camera.target.y / divisor,
    z = facts.camera.target.z / divisor,
  }, "compiled camera target is normalized to tiles")
  Assert.deepEqual(manifest.hero.presentation.transform.translation, {
    x = facts.transform.translation.x / divisor,
    y = facts.transform.translation.y / divisor,
    z = facts.transform.translation.z / divisor,
  }, "compiled hero placement is normalized to tiles")
  Assert.equal(camera.angleXDegrees, facts.camera.angleXDegrees, "camera pitch is not a length")
  Assert.equal(camera.angleYDegrees, facts.camera.angleYDegrees, "camera yaw is not a length")
  Assert.equal(camera.perspectiveType, facts.camera.perspectiveType, "perspective type is not a length")
  Assert.equal(camera.perspectiveAngle, facts.camera.perspectiveAngle, "perspective angle is not a length")
  Assert.deepEqual(
    manifest.hero.presentation.transform.rotation,
    facts.transform.rotation,
    "hero rotation is not a length"
  )
  Assert.deepEqual(manifest.hero.presentation.transform.scale, facts.transform.scale, "hero scale is not a length")
  -- The compiled material registers keep the audited RGB555 immediates as
  -- semantic colors: mid-gray diffuse/specular/emission, dimmer ambient.
  Assert.deepEqual(manifest.hero.presentation.materials, {
    diffuse = { r = 15, g = 15, b = 15 },
    ambient = { r = 10, g = 10, b = 10 },
    specular = { r = 15, g = 15, b = 15 },
    emission = { r = 15, g = 15, b = 15 },
  }, "compiled material registers keep the audited global colors")
end

function T.geometries_fit_the_canonical_panes(romFs, versionId)
  local manifest = bundleFor(romFs, versionId).manifest
  local function fits(rect, what)
    Assert.isTrue(rect.x + rect.width <= 256 and rect.y + rect.height <= 192, what .. " must fit the pane")
  end
  for _, tab in ipairs(manifest.interactive.pocketTabs.rects) do
    fits(tab, "tab")
  end
  for _, slot in ipairs(manifest.interactive.itemSlots.slots) do
    fits(slot.rect, "slot")
  end
  fits(manifest.interactive.pageIndicator.rect, "page indicator")
  fits(manifest.interactive.cancel, "cancel")
  fits(manifest.hero.description.frame.rect, "description frame")
  fits(manifest.hero.description.textRect, "description text")
  for _, button in ipairs(manifest.interactive.overlays.actionMenu.buttons) do
    fits(button, "action button")
  end
  for _, digit in ipairs(manifest.interactive.overlays.quantity.digits) do
    fits(digit, "quantity digit")
  end
end

function T.recompilation_is_deterministic(romFs, versionId)
  local first = bundleFor(romFs, versionId)
  local second = compileBundle(romFs)
  Assert.equal(second.marker, first.marker, "markers must match")
  Assert.equal(Hashing.hashLua(second.manifest), Hashing.hashLua(first.manifest), "manifests must match")
  local function assetKeys(bundle)
    local keys = {}
    for path in pairs(bundle.assets) do
      keys[#keys + 1] = path
    end
    table.sort(keys)
    return keys
  end
  Assert.deepEqual(assetKeys(second), assetKeys(first), "asset sets must match")
  for _, path in ipairs(assetKeys(first)) do
    Assert.equal(second.assets[path], first.assets[path], "asset " .. path .. " must be byte-identical")
  end
end

function T.bag_class_references_no_item_icon_bytes(romFs, _)
  local inner = romFs
  local guarded = {
    resolvedNarc = function(_, alias)
      return inner:resolvedNarc(alias)
    end,
    read = function(_, fileId)
      return inner:read(fileId)
    end,
    openNarc = function(_, alias)
      Assert.isTrue(alias ~= "item_icons", "the bag compiler must never open the item icon archive")
      return inner:openNarc(alias)
    end,
    metadata = function()
      return inner:metadata()
    end,
    version = function()
      return inner:version()
    end,
  }
  local bundle = compileBundle(guarded)
  for path in pairs(bundle.assets) do
    Assert.isTrue(path:find("icon") == nil, "bag asset " .. path .. " must not carry icons")
  end
  for _, dependency in ipairs(bundle.dependencies) do
    local name = type(dependency) == "table" and dependency.name or ""
    Assert.isTrue(name:find("item_icon") == nil, "bag dependency " .. name .. " must not reference icons")
  end
end

local function segmentKinds(template)
  local kinds = {}
  for _, segment in ipairs(template.segments) do
    kinds[#kinds + 1] = segment.kind
    if segment.kind == "text" then
      Assert.isTrue(type(segment.value) == "string" and segment.value ~= "", "text segments carry display text")
    end
  end
  return kinds
end

function T.compiled_text_lowers_labels_and_templates_in_order(romFs, versionId)
  local manifest = bundleFor(romFs, versionId).manifest
  local actions = manifest.interactive.text.actions
  for _, action in ipairs({ "toss", "move", "register", "unregister", "cancel", "confirm" }) do
    Assert.isTrue(type(actions[action]) == "string" and actions[action] ~= "", action .. " label is generated text")
  end
  Assert.deepEqual(segmentKinds(manifest.interactive.text.movePrompt), { "text", "item", "text" })
  Assert.deepEqual(segmentKinds(manifest.interactive.text.tossQuantity), { "text", "item", "text" })
  Assert.deepEqual(segmentKinds(manifest.interactive.text.tossConfirm), { "text", "quantity", "text", "item", "text" })
end

function T.registration_markers_are_distinct_40x16_assets(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local registration = bundle.manifest.interactive.itemSlots.registration
  Assert.deepEqual(registration.offset, { x = 0, y = 16 })
  for _, slot in ipairs({ "slot1", "slot2" }) do
    Assert.equal(registration[slot].width, 40, slot .. " marker is 40 pixels wide")
    Assert.equal(registration[slot].height, 16, slot .. " marker is 16 pixels tall")
  end
  Assert.isTrue(registration.slot1.image ~= registration.slot2.image, "slots resolve distinct marker paths")
  local first = assert(bundle.assets[registration.slot1.image], "slot 1 marker bytes are compiled")
  local second = assert(bundle.assets[registration.slot2.image], "slot 2 marker bytes are compiled")
  Assert.isTrue(#first > 0 and #second > 0, "markers are non-empty images")
  Assert.isTrue(first ~= second, "slot 1 and slot 2 markers differ")
end

function T.marker_dependencies_cover_messages_and_marker_member(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local seen = {}
  for _, dependency in ipairs(bundle.dependencies.dependencies) do
    seen[dependency.name] = dependency.sha1
  end
  Assert.notNil(seen["messages:member:10"], "message bank 10 participates in the marker")
  Assert.notNil(seen["messages:member:0"], "message bank 0 participates in the marker")
  Assert.notNil(seen["bag_ui:member:37"], "the marker source member participates in the marker")
  Assert.deepEqual(bundle.dependencies.selection.messages, BagSources.messages)
  Assert.deepEqual(bundle.dependencies.selection.registration, BagSources.registration)
end

function T.runtime_manifest_carries_no_source_identities(romFs, versionId)
  local manifest = bundleFor(romFs, versionId).manifest
  local function check(value, what)
    if type(value) == "string" then
      Assert.isTrue(value:find("NARC_", 1, true) == nil, what .. " carries a source archive symbol")
      return
    end
    if type(value) ~= "table" then
      return
    end
    for key, item in pairs(value) do
      Assert.isTrue(key ~= "narcId" and key ~= "memberId" and key ~= "fileId", what .. " leaks " .. tostring(key))
      -- A message selection is a { bank, index } record. A lone `index` is
      -- shared compiled-model vocabulary (node, material, and animation
      -- target positions), so only the pair or a lone `bank` is a leak.
      Assert.isTrue(key ~= "bank", what .. " leaks message selection " .. tostring(key))
      if key == "index" then
        Assert.isTrue(
          type(value.bank) ~= "number",
          what .. " leaks message selection index alongside bank " .. tostring(value.bank)
        )
      end
      check(item, what .. "." .. tostring(key))
    end
  end
  check(manifest, "manifest")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
