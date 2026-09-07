-- Compiles every field-actor sprite referenced by the map catalog into normalized
-- `g4-field-actor-v3`
-- visual definitions plus one private RGBA atlas each.
--
-- Ordinary actors use a shared camera-facing billboard and timeline. Static
-- map-object models keep their source geometry and polygon parts. Both paths
-- normalize source textures into a private RGBA atlas.
-- Source layout follows pret/pokeheartgold@b23531f6c82fc6a785058825a447d8439b38e47f:
-- asm/overlay_01_sprite_data.s, asm/overlay_01_021F8D80.s, and
-- asm/overlay_01_021F944C.s.
-- See .agents/docs/adr/field-actor-visual-representation.md for the durable
-- producer/runtime representation decision.
--
-- Every sprite-to-resource mapping is read from the ROM: the six-byte graphics
-- record gives the actor texture member, its packed word selects a visual
-- descriptor, and the descriptor's model/timeline keys resolve through the
-- overlay's own key tables. No spriteId -> member table is hardcoded.

local Errors = require("libs.errors.src.Errors")
local ZoneEvents = require("romdump.src.digest.map.ZoneEvents")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local Hashing = require("romdump.src.digest.Hashing")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")
local FieldActorGraphics = require("romdump.src.digest.actor.FieldActorGraphics")
local FieldActorFrames = require("romdump.src.digest.actor.FieldActorFrames")
local FieldActorModel = require("romdump.src.digest.actor.FieldActorModel")
local FieldActorStaticModel = require("romdump.src.digest.actor.FieldActorStaticModel")
local FieldActorTimeline = require("romdump.src.digest.actor.FieldActorTimeline")
local PlayerAvatar = require("romdump.src.reference.hgss.player_avatar")
local PoseContract = require("libs.assets.src.model.PoseContract")
local manifest = require("romdump.src.config.FieldActors")

local FieldActorCompiler = {}

local MODEL_MAGIC = "BMD0"
local TEXTURE_MAGIC = "BTX0"
local FX32_ONE = 4096
local SOURCE_MODEL_UNITS_PER_TILE = 16

-- Source HEAL/BANZAI callback: ov01_021F8AB0 applies facing-vector Z of 2<<10
-- (pret/pokeheartgold@b23531f6 asm/overlay_01_sprite_data.s, asm/overlay_01_021F72DC.s).
-- Normalized to runtime tiles via SOURCE_MODEL_UNITS_PER_TILE * FX32_ONE.
local BANZAI_FACING_Z_FX32 = 2 * 1024
local BANZAI_DISPLAY_OFFSET_Z = BANZAI_FACING_Z_FX32 / (SOURCE_MODEL_UNITS_PER_TILE * FX32_ONE)

-- Private source gesture bindings: actor family + visual descriptor -> semantic
-- gesture name + 1-based decoded range index + normalized fixed display offset.
-- Family 12 + descriptor 5 (SPRITE_PCWOMAN1) range 5 is Nurse Joy bow (state 9
-- selects animation 4, asm/overlay_01_021F72DC.s). Family 10 + descriptor 13
-- (SPRITE_BANZAIHERO/HEROINE, 200/201 via src/player_avatar.c PLAYER_STATE_HEAL)
-- ranges 1 and 2 are give/receive (states 0/1 select animations 0/1, single-level).
local GESTURE_BINDINGS = {
  ["12:5"] = {
    { rangeIndex = 5, name = "nurse_bow", displayOffset = { x = 0, y = 0, z = 0 } },
  },
  ["10:13"] = {
    { rangeIndex = 1, name = "give", displayOffset = { x = 0, y = 0, z = BANZAI_DISPLAY_OFFSET_Z } },
    { rangeIndex = 2, name = "receive", displayOffset = { x = 0, y = 0, z = BANZAI_DISPLAY_OFFSET_Z } },
  },
}

-- Source: pret/pokeheartgold 0985, ov01_02209A38. Families 16 and 17 share one
-- distinct callback struct while every other family, including the player-state
-- families below, uses a callback struct. The generated idle for every family
-- is a stationary directional pose holding the first displayed frame of its
-- facing range; locomotion stays on the explicit walk pose.
local IDLE_MODE_BY_ACTOR_FAMILY = {
  [0] = "static",
  [1] = "static",
  [3] = "static",
  [4] = "static",
  [5] = "static",
  [6] = "static",
  [7] = "static",
  [8] = "static",
  [9] = "static",
  [10] = "static",
  [11] = "static",
  [12] = "static",
  [13] = "static",
  [15] = "static",
  [16] = "static",
  [17] = "static",
  [18] = "static",
  [19] = "static",
}

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err)
  end
  return value
end

-- The configured player state visuals plus every object-event sprite used by
-- any map in the catalog. Player sprites resolve through the producer
-- player-avatar reference by gender, so every visual state is an ordinary
-- compiled field actor. Variable sprite IDs are
-- resolved by the runtime to a player graphic and are never compiled directly.
local function selectedSpriteIds(romFs)
  local variable = manifest.variableSpriteRange
  local wanted, order = {}, {}
  local function add(spriteId)
    if wanted[spriteId] then
      return
    end
    wanted[spriteId] = true
    order[#order + 1] = spriteId
  end
  for _, avatar in ipairs(manifest.avatars) do
    local states = PlayerAvatar.statesForGender(avatar.gender)
    for _, state in ipairs(PlayerAvatar.visualStates) do
      add(states[state])
    end
  end

  local archive = must(romFs:openNarc("zone_events"), "zone_event archive is unavailable")
  local variableSprites = {}
  for map in MapCatalog.all() do
    local decoded = must(
      ZoneEvents.decode(
        must(archive:readMember(map.eventMemberId)),
        { mapId = map.id, eventMemberId = map.eventMemberId }
      )
    )
    for _, object in ipairs(decoded.objectEvents) do
      if object.spriteId >= variable.first and object.spriteId <= variable.last then
        variableSprites[object.spriteId] = true
      else
        add(object.spriteId)
      end
    end
  end

  table.sort(order)
  local deferred = {}
  for spriteId in pairs(variableSprites) do
    deferred[#deferred + 1] = spriteId
  end
  table.sort(deferred)
  return order, deferred
end

-- One semantic state capability per configured playable identity: the
-- gender's complete visual-state map with compiled sprite IDs.
local function avatarCapabilities()
  local capabilities = {}
  for _, avatar in ipairs(manifest.avatars) do
    capabilities[#capabilities + 1] = {
      id = avatar.id,
      gender = avatar.gender,
      states = PlayerAvatar.statesForGender(avatar.gender),
    }
  end
  return capabilities
end

---@param pack table<string, unknown>
---@param frames table[]
---@param context Errors.Context
---@return table<string, unknown>
local function decodeAtlas(pack, frames, context)
  local width, height
  for _, frame in ipairs(frames) do
    local texture = pack.textures[frame.textureSlot + 1]
    if not texture then
      Errors.raise(
        "FIELD_ACTOR_TEXTURE_SLOT_MISSING",
        "timeline references texture slot " .. frame.textureSlot .. " but the actor resource has " .. #pack.textures,
        { textureSlot = frame.textureSlot, count = #pack.textures, context = context }
      )
    end
    local palette = pack.palettes[frame.paletteSlot + 1]
    if not palette then
      Errors.raise(
        "FIELD_ACTOR_PALETTE_SLOT_MISSING",
        "timeline references palette slot " .. frame.paletteSlot .. " but the actor resource has " .. #pack.palettes,
        { paletteSlot = frame.paletteSlot, count = #pack.palettes, context = context }
      )
    end
    width = width or texture.width
    height = height or texture.height
    if texture.width ~= width or texture.height ~= height then
      Errors.raise(
        "FIELD_ACTOR_FRAME_SIZE_MISMATCH",
        "actor frames must share one size; slot "
          .. frame.textureSlot
          .. " is "
          .. texture.width
          .. "x"
          .. texture.height
          .. ", expected "
          .. width
          .. "x"
          .. height,
        { textureSlot = frame.textureSlot, context = context }
      )
    end
    frame.texture, frame.paletteRecord = texture, palette
  end

  local decoded = {}
  local alphaUsage = { hasZero = false, hasPartial = false, hasOpaque = false }
  local textureFormat
  for _, frame in ipairs(frames) do
    local format = pack.textures[frame.textureSlot + 1].formatRaw
    textureFormat = textureFormat or format
    if format ~= textureFormat then
      Errors.raise(
        "FIELD_ACTOR_FRAME_FORMAT_MISMATCH",
        "actor frames must share one texture format; slot "
          .. frame.textureSlot
          .. " is "
          .. format
          .. ", expected "
          .. textureFormat,
        { textureSlot = frame.textureSlot, context = context }
      )
    end
  end
  for i, frame in ipairs(frames) do
    local pixels = TextureDecoder.decode(Nsbtx.decoderOpts(pack, frame.texture, frame.paletteRecord), context)
    decoded[i] = pixels
    for key in pairs(alphaUsage) do
      alphaUsage[key] = alphaUsage[key] or pixels.alphaUsage[key]
    end
    frame.texture, frame.paletteRecord = nil, nil
  end

  -- Pack the frames into one horizontal strip, row by row.
  local rows, stride = {}, width * 4
  for y = 0, height - 1 do
    local row = {}
    for i = 1, #decoded do
      row[i] = decoded[i].pixels:sub(y * stride + 1, (y + 1) * stride)
    end
    rows[y + 1] = table.concat(row)
  end

  return {
    width = width * #frames,
    height = height,
    pixels = table.concat(rows),
    frameWidth = width,
    frameHeight = height,
    alphaUsage = alphaUsage,
    textureFormat = textureFormat,
  }
end

local function idlePresentation(mode)
  return {
    mode = mode,
    cadence = mode == "animated" and 1 or 0,
  }
end

-- Turn per-range displayed frames into the direction-keyed pose sets. Ranges
-- 1-4 are the base directional set in global_fieldmap.h order; additional
-- source ranges have actor-family/state-specific selectors
-- (ov01_021FA44C/021FA458/021FA464) with no single generic runtime meaning, so
-- unclaimed ranges remain producer-private and only named semantic poses are
-- published.
local function buildPoses(perRange, ranges, idleMode)
  local order = manifest.directionOrder

  local function poseFor(index)
    local range = ranges[index]
    local frames = perRange[index]
    local ticks = 0
    for _, frame in ipairs(frames) do
      ticks = ticks + frame.ticks
    end
    return {
      frames = frames,
      loop = range.loop,
      durationTicks = ticks,
      sourceRange = { startFrame = range.startFrame, endFrame = range.endFrame, endMode = range.endMode },
    }
  end

  local directions = {}
  if #ranges < #order then
    local pose = poseFor(1)
    for _, direction in ipairs(order) do
      local idle = {
        frames = { { frameIndex = pose.frames[1].frameIndex, ticks = 1, displayOffsetY = 0 } },
        loop = true,
        durationTicks = 1,
      }
      directions[direction] = { idle = idle, walk = pose }
    end
    return directions, idlePresentation(idleMode)
  end
  for i, direction in ipairs(order) do
    local walk = poseFor(i)
    -- Idle holds the first displayed frame of its facing range.
    local idle = {
      frames = { { frameIndex = walk.frames[1].frameIndex, ticks = 1, displayOffsetY = 0 } },
      loop = true,
      durationTicks = 1,
    }
    directions[direction] = {
      idle = idle,
      walk = walk,
    }
  end
  return directions, idlePresentation(idleMode)
end

local function staticDirections()
  local directions = {}
  for _, direction in ipairs(manifest.directionOrder) do
    local pose = {
      frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } },
      loop = true,
      durationTicks = 1,
    }
    directions[direction] = { idle = pose, walk = pose }
  end
  return directions
end

local function finishStaticModel(spriteId, compiled)
  local render, atlas = compiled.render, compiled.atlas
  render.image = FieldActorCache.atlasPath(spriteId)
  local visual = {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = render,
    bounds = { width = atlas.frameWidth, height = atlas.frameHeight, depth = 0 },
    pivot = { x = 0.5, y = 1 },
    frames = { { textureSlot = 0, paletteSlot = 0 } },
    directions = staticDirections(),
    idlePresentation = { mode = "static", cadence = 0 },
    gestures = {},
  }
  return visual, atlas
end

local function buildGestures(record, perRange, ranges, context)
  local key = record.actorFamily .. ":" .. record.visualDescriptor
  local bindings = GESTURE_BINDINGS[key]
  if not bindings then
    return {}
  end
  local gestures = {}
  for _, binding in ipairs(bindings) do
    local index = binding.rangeIndex
    local frames = perRange[index]
    local range = ranges[index]
    if not frames or not range then
      Errors.raise(
        "FIELD_ACTOR_GESTURE_RANGE_MISSING",
        "gesture "
          .. binding.name
          .. " requires range "
          .. index
          .. " but descriptor "
          .. record.visualDescriptor
          .. " has "
          .. #ranges,
        {
          spriteId = context.spriteId,
          actorFamily = record.actorFamily,
          visualDescriptor = record.visualDescriptor,
          rangeIndex = index,
          gesture = binding.name,
          context = context,
        }
      )
    end
    local ticks = 0
    for _, frame in ipairs(frames) do
      ticks = ticks + frame.ticks
    end
    gestures[binding.name] = {
      pose = {
        frames = frames,
        loop = range.loop,
        durationTicks = ticks,
      },
      displayOffset = { x = binding.displayOffset.x, y = binding.displayOffset.y, z = binding.displayOffset.z },
    }
  end
  return gestures
end

---@param spriteId integer
---@param memberId integer
---@param staticArchive Narc
---@param context Errors.Context
---@return table<string, unknown>, table<string, unknown>
local function compileStaticModel(spriteId, memberId, staticArchive, context)
  local modelBytes = must(
    staticArchive:readMember(memberId),
    Errors.new(
      "FIELD_ACTOR_STATIC_MODEL_MEMBER_MISSING",
      "static model member " .. memberId .. " is absent",
      { memberId = memberId, context = context }
    )
  )
  local compiled = FieldActorStaticModel.compile(modelBytes, context, nil, manifest.staticModels.archive.path)
  return finishStaticModel(spriteId, compiled)
end

---@param romFs RomFs
---@param spriteId integer
---@param graphics table<string, unknown>
---@param archive Narc
---@param staticArchive Narc
---@return table<string, unknown>, table<string, unknown>
local function compileSprite(romFs, spriteId, graphics, archive, staticArchive)
  local context = { spriteId = spriteId, romVersion = romFs:version() } ---@type Errors.Context
  local resolved = must(FieldActorGraphics.resolve(graphics, spriteId))
  local record = resolved.record
  if resolved.staticModelMemberId then
    return compileStaticModel(spriteId, resolved.staticModelMemberId, staticArchive, context)
  end
  local descriptor = resolved.descriptor
  local idleMode = IDLE_MODE_BY_ACTOR_FAMILY[record.actorFamily]
  if not idleMode then
    Errors.raise(
      "FIELD_ACTOR_ACTOR_FAMILY_UNSUPPORTED",
      "actor family " .. record.actorFamily .. " has no normalized idle behavior",
      { actorFamily = record.actorFamily, context = context }
    )
  end

  local modelBytes = archive:readMember(descriptor.modelMemberId)
  if not modelBytes or modelBytes:sub(1, 4) ~= MODEL_MAGIC then
    Errors.raise(
      "FIELD_ACTOR_MODEL_MEMBER_INVALID",
      "shared model member " .. descriptor.modelMemberId .. " is not a " .. MODEL_MAGIC .. " resource",
      { memberId = descriptor.modelMemberId, context = context }
    )
  end
  modelBytes = assert(modelBytes)
  local textureBytes = archive:readMember(record.mapModelId)
  if not textureBytes or textureBytes:sub(1, 4) ~= TEXTURE_MAGIC then
    Errors.raise(
      "FIELD_ACTOR_TEXTURE_MEMBER_INVALID",
      "actor texture member " .. record.mapModelId .. " is not a " .. TEXTURE_MAGIC .. " resource",
      { memberId = record.mapModelId, context = context }
    )
  end
  local timelineBytes = must(
    archive:readMember(descriptor.timelineMemberId),
    Errors.new(
      "FIELD_ACTOR_TIMELINE_MEMBER_MISSING",
      "timeline member " .. descriptor.timelineMemberId .. " is absent",
      { memberId = descriptor.timelineMemberId, context = context }
    )
  )

  local timeline = must(FieldActorTimeline.decode(timelineBytes, context))
  local pack = must(Nsbtx.decode(textureBytes, context))
  local drawMode = FieldActorModel.drawMode(modelBytes, context)
  if drawMode == PoseContract.STATIC then
    local compiled = FieldActorStaticModel.compile(modelBytes, context, pack, manifest.archive.path)
    return finishStaticModel(spriteId, compiled)
  end
  if drawMode ~= PoseContract.BILLBOARD then
    Errors.raise(
      "FIELD_ACTOR_MODEL_DRAW_MODE_UNSUPPORTED",
      "actor model draw mode is " .. drawMode,
      { drawMode = drawMode, context = context }
    )
  end
  local frameSet = FieldActorFrames.collect(timeline, descriptor.ranges, #pack.textures, #pack.palettes, context)
  local frames, perRange = frameSet.frames, frameSet.perRange
  local atlas = decodeAtlas(pack, frames, context)
  local directions, idleProfile = buildPoses(perRange, descriptor.ranges, idleMode)
  local gestures = buildGestures(record, perRange, descriptor.ranges, context)

  local placement = {
    sourceSize = { width = atlas.frameWidth, height = atlas.frameHeight },
    pivot = manifest.placement.pivot,
    modelOffset = manifest.placement.modelOffset,
    billboardMode = manifest.placement.billboardMode,
    mirrorEastWest = manifest.placement.mirrorEastWest,
  }
  -- The quad, its billboard base matrix, and its polygon state are replayed from
  -- the shared model member itself, so no actor render fact is hand-authored.
  local geometry = FieldActorModel.compile(modelBytes, {
    placement = placement,
    textureFormat = atlas.textureFormat,
    alphaUsage = atlas.alphaUsage,
    context = context,
  })
  local visual = {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = {
      kind = "atlas",
      animationMode = frameSet.mode,
      image = FieldActorCache.atlasPath(spriteId),
      frameWidth = atlas.frameWidth,
      frameHeight = atlas.frameHeight,
      frameCount = #frames,
      billboardMode = placement.billboardMode,
      mirrorEastWest = placement.mirrorEastWest,
      alphaUsage = atlas.alphaUsage,
      textureFormat = atlas.textureFormat,
      alphaClass = geometry.alphaClass,
      polygon = geometry.polygon,
      -- Billboard-local quad in runtime tiles, plus the position matrix the SBC
      -- billboard command captured; the runtime composes the actor's world
      -- placement onto it and resolves the pair against the live camera.
      geometry = {
        modelName = geometry.modelName,
        vertices = geometry.vertices,
        indices = geometry.indices,
        baseTransform = geometry.baseTransform,
        anchorTiles = geometry.anchorTiles,
        bounds = geometry.bounds,
      },
    },
    bounds = { width = atlas.frameWidth, height = atlas.frameHeight, depth = 0 },
    pivot = { x = placement.pivot.x, y = placement.pivot.y },
    frames = frames,
    directions = directions,
    idlePresentation = idleProfile,
    gestures = gestures,
  }
  return visual, atlas
end

local function _loadInputs(romFs)
  assert(romFs and romFs.readOverlay and romFs.openNarc, "compile requires a RomFs-shaped object")

  local overlayBytes, overlayInfo = romFs:readOverlay(manifest.overlay.cpu, manifest.overlay.overlayId)
  must(overlayBytes, overlayInfo)
  local graphics = must(FieldActorGraphics.decode(overlayBytes, { ramAddress = overlayInfo.ramAddress }, manifest))

  local archiveInfo = romFs:resolvedNarc(manifest.archive.alias)
  if not archiveInfo then
    Errors.raise(
      "ROMFS_NARC_UNRESOLVED",
      manifest.archive.alias .. " NARC is unavailable",
      { name = manifest.archive.alias }
    )
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc(manifest.archive.alias))
  local staticArchiveInfo = romFs:resolvedNarc(manifest.staticModels.archive.alias)
  if not staticArchiveInfo then
    Errors.raise(
      "ROMFS_NARC_UNRESOLVED",
      manifest.staticModels.archive.alias .. " NARC is unavailable",
      { name = manifest.staticModels.archive.alias }
    )
  end
  local staticArchiveBytes = must(romFs:read(staticArchiveInfo.fileId))
  local staticArchive = must(romFs:openNarc(manifest.staticModels.archive.alias))

  return {
    graphics = graphics,
    overlayInfo = overlayInfo,
    archiveInfo = archiveInfo,
    archiveBytes = archiveBytes,
    archive = archive,
    staticArchiveInfo = staticArchiveInfo,
    staticArchiveBytes = staticArchiveBytes,
    staticArchive = staticArchive,
    -- The logical table span only, not the whole overlay: a change anywhere
    -- else in overlay 1 must not invalidate compiled actors.
    overlaySha1 = Hashing.sha1hex(
      overlayBytes:sub(graphics.tableOffset + 1, graphics.tableOffset + graphics.spanBytes)
    ),
  }
end

local function _dependenciesFragment(inputs, romFs)
  return {
    cacheFormat = FieldActorCache.FORMAT,
    schema = FieldActorCache.SCHEMA,
    manifestSchema = manifest.schema,
    versionRomSha1 = romFs:metadata().sha1,
    overlay = {
      cpu = manifest.overlay.cpu,
      overlayId = manifest.overlay.overlayId,
      ramAddress = inputs.overlayInfo.ramAddress,
      tableOffset = inputs.graphics.tableOffset,
      spanBytes = inputs.graphics.spanBytes,
      spanSha1 = inputs.overlaySha1,
    },
    archive = {
      symbol = inputs.archiveInfo.symbol,
      alias = inputs.archiveInfo.alias,
      narcId = inputs.archiveInfo.narcId,
      fileId = inputs.archiveInfo.fileId,
      path = inputs.archiveInfo.path,
      sha1 = Hashing.sha1hex(inputs.archiveBytes),
    },
    staticArchive = {
      symbol = inputs.staticArchiveInfo.symbol,
      alias = inputs.staticArchiveInfo.alias,
      narcId = inputs.staticArchiveInfo.narcId,
      fileId = inputs.staticArchiveInfo.fileId,
      path = inputs.staticArchiveInfo.path,
      sha1 = Hashing.sha1hex(inputs.staticArchiveBytes),
    },
  }
end

-- Compile one set of field-actor sprites through the shared overlay/model
-- pipeline. Producer-side reuse for follower visuals, which resolve through
-- the same graphics tables and normalize into the same visual definitions;
-- the caller owns visual-ID assignment and publication.
function FieldActorCompiler.compileSprites(romFs, spriteIds)
  local inputs = _loadInputs(romFs)
  local visuals, atlases = {}, {}
  for _, spriteId in ipairs(spriteIds) do
    visuals[spriteId], atlases[spriteId] =
      compileSprite(romFs, spriteId, inputs.graphics, inputs.archive, inputs.staticArchive)
  end
  return {
    visuals = visuals,
    atlases = atlases,
    graphics = inputs.graphics,
    dependencies = _dependenciesFragment(inputs, romFs),
  }
end

local function _compile(romFs)
  local inputs = _loadInputs(romFs)

  local spriteIds, variableSprites = selectedSpriteIds(romFs)
  local visuals, atlases = {}, {}
  for _, spriteId in ipairs(spriteIds) do
    visuals[spriteId], atlases[spriteId] =
      compileSprite(romFs, spriteId, inputs.graphics, inputs.archive, inputs.staticArchive)
  end

  local dependencies = _dependenciesFragment(inputs, romFs)
  dependencies.mapCatalogVersion = MapCatalog.VERSION
  dependencies.spriteIds = spriteIds

  local index = {
    schema = FieldActorCache.INDEX_SCHEMA,
    romVersion = romFs:version(),
    spriteIds = spriteIds,
    -- Sprite IDs the runtime must resolve through field variables before
    -- lookup; every value they take is one of the compiled player graphics.
    variableSprites = variableSprites,
    recordCount = inputs.graphics.recordCount,
    -- The runtime-facing actor configuration: the semantic avatar state
    -- capabilities and the variable-sprite policy come from this generated
    -- block, never from the source manifest. The manifest's addresses,
    -- archive paths, and table layouts stay in romdump.
    runtime = {
      avatars = avatarCapabilities(),
      variableSprites = {
        first = manifest.variableSpriteRange.first,
        last = manifest.variableSpriteRange.last,
        variableBase = manifest.variableVarBase,
      },
    },
  }

  local provenance = {
    schema = "g4-field-actor-provenance-v1",
    source = manifest.provenance,
    dependencies = dependencies,
    -- Per-sprite source identity (graphics record, key-table resolutions, and
    -- static-model members) for the CLI inspectors; the runtime visuals carry
    -- no source fields.
    records = inputs.graphics.bySpriteId,
    descriptors = inputs.graphics.descriptors,
    modelKeys = inputs.graphics.modelMembers.byKey,
    timelineKeys = inputs.graphics.timelineMembers.byKey,
    staticModels = inputs.graphics.staticModels,
  }

  return {
    marker = FieldActorCache.marker(romFs:metadata().sha1, Hashing.hashLua(dependencies)),
    index = index,
    visuals = visuals,
    atlases = atlases,
    dependencies = dependencies,
    provenance = provenance,
  }
end

function FieldActorCompiler.compile(romFs)
  local ok, result = pcall(_compile, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return FieldActorCompiler
