-- ROM conformance: the field-bag presentation compiles from the real dump.
-- The bag archive resolves through the semantic alias, every audited
-- member decodes, the manifest carries eight tabs, six slots, and both
-- gender heroes with pocket-indexed clips, recompilation is deterministic,
-- and no item-icon bytes enter the bag class. Assertions are coverage
-- relationships and cross-reference validity, never catalog snapshots or
-- committed commercial payloads.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local BagSources = require("romdump.src.config.BagSources")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local HgssArchives = require("romdump.src.config.HgssArchives")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local Hashing = require("romdump.src.digest.Hashing")
local PngReader = require("tests.support.PngReader")
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

-- Bundle assets are Lua strings or finalized LÖVE Data values; the
-- determinism contract compares byte content, never object identity (two
-- compiles hand back distinct Data objects holding identical PNG bytes).
local function assetBytes(value)
  if type(value) == "string" then
    return value
  end
  assert(
    type(value) == "userdata" and type(value.getFFIPointer) == "function" and type(value.getSize) == "function",
    "bundle assets are strings or LÖVE Data"
  )
  return ffi.string(value:getFFIPointer(), value:getSize())
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
  assertDecodes("decodeAnimation", BagSources.sprites.tabs.anim, "bag tab animation")
  assertDecodes("decodeAnimation", BagSources.sprites.cursor.anim, "bag cursor animation")
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
  fits(manifest.interactive.cancel.rect, "cancel")
  fits(manifest.interactive.cancel.textRect, "cancel text window")
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
    Assert.equal(
      assetBytes(second.assets[path]),
      assetBytes(first.assets[path]),
      "asset " .. path .. " must be byte-identical"
    )
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

-- The finalized state backgrounds visibly contain the static Cancel
-- face/chrome before runtime draws any text: the canonical Cancel rect
-- carries richer opaque content than a same-size plain wash strip from the
-- same background.
function T.finalized_backgrounds_carry_static_cancel_chrome(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local cancel = bundle.manifest.interactive.cancel
  local function distinctOpaqueColors(rgba, width, rect)
    local colors = {}
    for y = rect.y, rect.y + rect.height - 1 do
      for x = rect.x, rect.x + rect.width - 1 do
        local offset = (y * width + x) * 4 + 1
        if string.byte(rgba, offset + 3) ~= 0 then
          local key = string.byte(rgba, offset)
            .. ","
            .. string.byte(rgba, offset + 1)
            .. ","
            .. string.byte(rgba, offset + 2)
          colors[key] = true
        end
      end
    end
    local count = 0
    for _ in pairs(colors) do
      count = count + 1
    end
    return count
  end
  for _, state in ipairs({ "browse", "action" }) do
    for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
      local published = bundle.manifest.interactive.backgrounds[state][pocket]
      local variants = published
      if state ~= "browse" then
        variants = { published }
      end
      for _, background in ipairs(variants) do
        local _, _, rgba =
          PngReader.rgba(assert(bundle.assets[background.image], state .. "/" .. pocket .. " must compile"))
        local chrome = distinctOpaqueColors(rgba, 256, cancel.rect)
        local wash = distinctOpaqueColors(rgba, 256, { x = 0, y = 168, width = 64, height = 24 })
        Assert.isTrue(
          chrome > wash,
          state .. "/" .. pocket .. " Cancel chrome must enrich the Cancel rect beyond plain wash"
        )
      end
    end
  end
end

-- The compiled lower pane publishes one realized browse background per
-- pocket and visible occupied-item count 0..6: an empty row and a full row
-- resolve distinct compiled chrome instead of one static image.
function T.compiled_browse_backgrounds_carry_seven_count_variants_per_pocket(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local manifest = bundle.manifest
  for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
    local variants =
      assert(manifest.interactive.backgrounds.browse[pocket], pocket .. " must publish its browse count variants")
    Assert.equal(#variants, 7, pocket .. " publishes one browse visual per visible count 0..6")
    for count = 0, 6 do
      local visual = assert(variants[count + 1], pocket .. " publishes its count " .. count .. " visual")
      Assert.isTrue(type(visual.image) == "string", pocket .. " count " .. count .. " publishes one realized image")
      Assert.equal(visual.width, 256, pocket .. " count " .. count .. " keeps the pane width")
      Assert.equal(visual.height, 192, pocket .. " count " .. count .. " keeps the pane height")
      Assert.notNil(bundle.assets[visual.image], pocket .. " count " .. count .. " image bytes must be compiled")
    end
  end
  local emptyImage = assert(
    manifest.interactive.backgrounds.browse.items[1].image,
    "the empty items browse variant must publish its image"
  )
  local fullImage = assert(
    manifest.interactive.backgrounds.browse.items[7].image,
    "the full items browse variant must publish its image"
  )
  Assert.isTrue(
    assetBytes(assert(bundle.assets[emptyImage], "the empty browse bytes must be compiled"))
      ~= assetBytes(assert(bundle.assets[fullImage], "the full browse bytes must be compiled")),
    "the empty and full browse variants must carry distinct slot chrome"
  )
end

-- The compiled Cancel control publishes the source label area centered on
-- the Cancel face: the narrower label span, not the full button bound.
function T.compiled_cancel_carries_the_centered_label_area(romFs, versionId)
  local manifest = bundleFor(romFs, versionId).manifest
  local cancel = assert(manifest.interactive.cancel, "the compiled manifest must publish cancel geometry")
  Assert.deepEqual(
    cancel.labelRect,
    { x = 200, y = 168, width = 48, height = 16 },
    "the cancel label area keeps the source centering span"
  )
  Assert.equal(
    cancel.labelRect.x + cancel.labelRect.width / 2,
    224,
    "the label area centers on the middle of the cancel face"
  )
  Assert.isTrue(
    cancel.labelRect.x >= cancel.rect.x
      and cancel.labelRect.y >= cancel.rect.y
      and cancel.labelRect.x + cancel.labelRect.width <= cancel.rect.x + cancel.rect.width
      and cancel.labelRect.y + cancel.labelRect.height <= cancel.rect.y + cancel.rect.height,
    "the label area stays inside the cancel control"
  )
end

-- Each browse count variant replays from an independent copy of the decoded
-- source screen: the full-count variant must match the pristine source
-- composition exactly over the mutation footprint, so earlier count
-- mutations cannot leak across variants through a shared mutable screen.
function T.browse_count_variants_start_from_independent_source_copies(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local archive = assert(romFs:openNarc("bag_ui"))
  local function decoded(kind, memberId, what)
    local bytes = assert(archive:readMember(memberId), "bag member " .. memberId .. " must exist")
    local record, err = G2dDecoder[kind](bytes, { label = what })
    Assert.notNil(record, what .. " must decode: " .. (err and err.message or "?"))
    return assert(record)
  end
  local charData = decoded("decodeChar", BagSources.chars.lower, "lower char")
  local palette = decoded("decodePalette", BagSources.palettes.lower, "lower palette")
  local remap = assert(BagSources.lowerPaletteBanks, "the producer must declare its lower palette banks")
  local effective = {}
  for index, color in ipairs(palette.colors) do
    effective[index] = color
  end
  for destination = 0, 3 do
    local sourceBank = remap.offsets[destination + 1]
    for entry = 0, remap.bankSize - 1 do
      effective[destination * remap.bankSize + entry + 1] = palette.colors[sourceBank * remap.bankSize + entry + 1]
    end
  end
  local wash = decoded("decodeScreen", BagSources.screens.listWash, "list wash")
  local slots = decoded("decodeScreen", BagSources.screens.listSlots, "list slots")
  local BagPresentationCompiler = require("romdump.src.digest.ui.BagPresentationCompiler")
  local layers = {
    G2dRasterizer.renderScreen(charData, { colors = effective }, wash, { role = "conformance-list-wash" }),
    G2dRasterizer.renderScreen(charData, { colors = effective }, slots, { role = "conformance-list-slots" }),
  }
  local pristine = BagPresentationCompiler.cropImage(
    BagPresentationCompiler.composeImages(layers, "conformance browse"),
    256,
    192,
    "conformance browse"
  )
  local function slotRegion(rgba)
    local rows = {}
    for y = 32, 159 do
      rows[#rows + 1] = rgba:sub(y * 256 * 4 + 1, (y + 1) * 256 * 4)
    end
    return table.concat(rows)
  end
  local expected = slotRegion(pristine.pixels)
  local variants = assert(bundle.manifest.interactive.backgrounds.browse.items, "items must publish its count variants")
  local _, _, fullRgba = PngReader.rgba(assert(bundle.assets[variants[7].image], "the count 6 bytes must be compiled"))
  Assert.equal(slotRegion(fullRgba), expected, "the count 6 variant must carry the unmutated source screen")
  local _, _, emptyRgba = PngReader.rgba(assert(bundle.assets[variants[1].image], "the count 0 bytes must be compiled"))
  Assert.isTrue(
    slotRegion(emptyRgba) ~= expected,
    "the count 0 variant must mutate the slot region, proving the comparison is sensitive"
  )
end

-- The pocket strip replays the retained pocket-state palette: the effective
-- palette starts from the base tab palette, copies state banks 8..15 over
-- destination banks 0..7, then copies the active pocket bank over itself, in
-- that order. This replay is written independently of the compiler's own
-- helper; only the audited member selection, selectors, and geometry are
-- shared.
local function replayEffectivePalette(baseColors, stateColors, pocketIndex)
  local bankSize = 16
  local effective = {}
  for index, color in ipairs(baseColors) do
    effective[index] = color
  end
  local function copyBank(fromBank, toBank)
    for entry = 0, bankSize - 1 do
      effective[toBank * bankSize + entry + 1] = stateColors[fromBank * bankSize + entry + 1]
    end
  end
  Assert.isTrue(#stateColors >= 16 * bankSize, "the retained palette must carry banks 0..15")
  Assert.isTrue(#effective >= 8 * bankSize, "the effective palette must carry banks 0..7")
  for destBank = 0, 7 do
    copyBank(8 + destBank, destBank)
  end
  copyBank(pocketIndex, pocketIndex)
  return { colors = effective }
end

local function packBytes(buffer)
  local out = {}
  for i = 1, #buffer, 4096 do
    out[#out + 1] = string.char(unpack(buffer, i, math.min(i + 4095, #buffer)))
  end
  return table.concat(out)
end

-- Composite the eight realized normal frames into one transparent 256x32
-- strip at the canonical tab anchors: each frame draws at its tab-rect
-- center plus its own raster offset, in pocket order, with alpha-zero
-- pixels preserving the strip beneath.
local function compositeStrip(frames, rects)
  local width, height = 256, 32
  local buffer = {}
  for i = 1, width * height * 4 do
    buffer[i] = 0
  end
  for index, frame in ipairs(frames) do
    local rect = assert(rects[index], "tab rectangle " .. index .. " must be audited")
    local destX = rect.x + rect.width / 2 + frame.offset.x
    local destY = rect.y + rect.height / 2 + frame.offset.y
    Assert.isTrue(
      destX >= 0 and destY >= 0 and destX + frame.width <= width and destY + frame.height <= height,
      "normal tab " .. index .. " placement must fit the canonical strip"
    )
    for y = 0, frame.height - 1 do
      for x = 0, frame.width - 1 do
        local sourceOffset = (y * frame.width + x) * 4 + 1
        if string.byte(frame.pixels, sourceOffset + 3) ~= 0 then
          local targetOffset = ((destY + y) * width + (destX + x)) * 4
          local r, g, b = string.byte(frame.pixels, sourceOffset, sourceOffset + 2)
          buffer[targetOffset + 1], buffer[targetOffset + 2], buffer[targetOffset + 3], buffer[targetOffset + 4] =
            r, g, b, 255
        end
      end
    end
  end
  return packBytes(buffer)
end

-- Each published pocket strip must equal the independently replayed retail
-- palette realization for its active pocket: the base tab members plus the
-- retained pocket-state writes, rasterized and composited without calling
-- the compiler's palette helper or reading the manifest output.
function T.pocket_strips_replay_the_retained_palette_state(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local manifest = bundle.manifest
  Assert.equal(manifest.schema, "g4-bag-assets-v8", "the rebuilt bag cache must publish the strip contract")
  local strips =
    assert(manifest.interactive.pocketTabs.strips, "the rebuilt manifest must publish one strip per active pocket")
  local keys = {}
  for key in pairs(strips) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  Assert.deepEqual(keys, {
    "balls",
    "battle_items",
    "berries",
    "items",
    "key_items",
    "mail",
    "medicine",
    "tmhm",
  }, "strips carry exactly the eight canonical pockets")
  Assert.isNil(manifest.interactive.pocketTabs.normal, "no pocket-independent normal array may survive")
  local archive = assert(romFs:openNarc("bag_ui"))
  local function decoded(kind, memberId, what)
    local bytes = assert(archive:readMember(memberId), "bag member " .. memberId .. " must exist")
    local record, err = G2dDecoder[kind](bytes, { label = what })
    Assert.notNil(record, what .. " must decode: " .. (err and err.message or "?"))
    return assert(record)
  end
  local group = BagSources.sprites.tabs
  local charData = decoded("decodeChar", group.char, "tab char")
  local basePalette = decoded("decodePalette", group.palette, "tab base palette")
  local statePalette = decoded("decodePalette", BagSources.palettes.tabState, "tab state palette")
  local cellData = decoded("decodeCell", group.cell, "tab cell")
  local animation = decoded("decodeAnimation", group.anim, "tab animation")
  local selectors = assert(BagSources.spriteStates.tabs.normal, "normal tab selectors must be audited")
  Assert.equal(#selectors, 8, "eight normal tab selectors are required")
  local selection = assert(bundle.dependencies.selection, "the bundle must carry its dependency selection")
  local paletteFacts = assert(selection.tabPaletteState, "the selection must carry the tab palette facts")
  Assert.equal(paletteFacts.bankSize, 16, "the tab palette facts keep the sixteen-color bank size")
  local transfers = assert(paletteFacts.transfers, "the tab palette facts must carry ordered transfers")
  Assert.equal(#transfers, 2, "the tab palette replay carries its base and selected transfers")
  Assert.deepEqual(
    transfers[1],
    { sourceBank = 8, destBank = 0, bankCount = 8 },
    "the base transfer covers eight banks"
  )
  Assert.deepEqual(
    transfers[2],
    { sourceBank = "pocket", destBank = "pocket", bankCount = 1 },
    "the selected transfer overrides one bank"
  )
  local realized = {}
  for _, case in ipairs({
    { pocket = "items", index = 0 },
    { pocket = "medicine", index = 1 },
    { pocket = "balls", index = 2 },
    { pocket = "tmhm", index = 3 },
    { pocket = "berries", index = 4 },
    { pocket = "mail", index = 5 },
    { pocket = "battle_items", index = 6 },
    { pocket = "key_items", index = 7 },
  }) do
    local effective = replayEffectivePalette(basePalette.colors, statePalette.colors, case.index)
    local frames = {}
    for position, selector in ipairs(selectors) do
      local sequence =
        assert(animation.anims[selector.animation + 1], "normal tab " .. position .. " selects a sequence")
      Assert.equal(#sequence.frames, 1, "normal tab " .. position .. " realizes one static frame")
      frames[position] = G2dRasterizer.renderAnimationFrame(
        charData,
        effective,
        cellData,
        sequence,
        1,
        { role = "conformance-strip-" .. case.pocket .. "-" .. position },
        selector.palette
      )
    end
    local expected = compositeStrip(frames, BagSources.geometry.tabs)
    local visual = assert(strips[case.pocket], case.pocket .. " must publish its active-pocket strip")
    Assert.equal(visual.width, 256, case.pocket .. " strip keeps the canonical strip width")
    Assert.equal(visual.height, 32, case.pocket .. " strip keeps the canonical strip height")
    local width, height, rgba =
      PngReader.rgba(assert(bundle.assets[visual.image], case.pocket .. " bytes must compile"))
    Assert.equal(width, 256, case.pocket .. " strip image is 256 pixels wide")
    Assert.equal(height, 32, case.pocket .. " strip image is 32 pixels tall")
    Assert.equal(rgba, expected, case.pocket .. " strip pixels match the independent palette replay")
    for region = 0, 7 do
      local opaque = 0
      for y = 0, 31 do
        for x = region * 32, region * 32 + 31 do
          if string.byte(rgba, (y * 256 + x) * 4 + 4) ~= 0 then
            opaque = opaque + 1
          end
        end
      end
      Assert.isTrue(opaque > 0, case.pocket .. " strip icon region " .. region .. " carries source content")
    end
    realized[case.pocket] = rgba
  end
  Assert.isTrue(realized.items ~= realized.balls, "the items and balls pocket states must differ")
end

-- The compiled hero presentation must carry the retail edge-color table as
-- semantic channel records: three chromatic entries followed by five black
-- entries, never a fabricated all-black table.
function T.hero_edge_colors_carry_the_retail_table(romFs, versionId)
  local manifest = bundleFor(romFs, versionId).manifest
  local edgeColors =
    assert(manifest.hero.presentation.edgeColors, "the rebuilt manifest must publish its hero edge colors")
  Assert.deepEqual(edgeColors, {
    { r = 10, g = 10, b = 10 },
    { r = 15, g = 9, b = 4 },
    { r = 20, g = 20, b = 20 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
  }, "the compiled edge records match the retail table")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
