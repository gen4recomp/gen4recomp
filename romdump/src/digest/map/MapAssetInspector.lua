-- Target asset inspector. Turns a resolved map into a deterministic,
-- payload-free inventory of exactly what the map needs: field containers,
-- map-model geometry, texture packs, and placed-building models. It is the
-- observable surface for reviewing the target texture and geometry inventory:
-- every set is sorted, and every unsupported format/opcode surfaces as a
-- structured decode error rather than silent success.
--
-- It runs under LÖVE (it needs an open RomFs) but holds no draw state and
-- writes nothing to the repository. Raw formats stop here: it hands the rest of
-- the pipeline normalized records, never NARC offsets.

local MapResolver = require("romdump.src.digest.map.MapResolver")
local AreaData = require("romdump.src.digest.map.AreaData")
local LandData = require("romdump.src.digest.map.LandData")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local DsPolygonAttr = require("libs.nds.src.gx.DsPolygonAttr")
local HgssFieldLighting = require("romdump.src.digest.field.HgssFieldLighting")
local HgssFieldLightProfile = require("romdump.src.digest.field.HgssFieldLightProfile")
local HgssPermissionGrid = require("romdump.src.digest.field.HgssPermissionGrid")
local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local MeshCompiler = require("romdump.src.digest.model.MeshCompiler")
local BuildModelAnimList = require("romdump.src.digest.model.BuildModelAnimList")

-- NitroSystem animation-resource magic -> what it drives. The distinction the
-- build-model transform cares about is joint (node SRT) vs. everything else:
-- only BCA0 can move geometry; BTA0/BMA0 animate texture and material and
-- leave the node matrix alone.
local ANIM_KIND = {
  BCA0 = "joint-srt",
  BTA0 = "texture-srt",
  BMA0 = "material",
}

local MapAssetInspector = {}

local function sha1(bytes)
  if love and love.data then
    local raw = love.data.hash("sha1", bytes)
    return (raw:gsub(".", function(c)
      return string.format("%02x", string.byte(c))
    end))
  end
  return nil
end

local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

-- Read a NARC member, validating the member id against the archive size.
-- Returns bytes, member sha1.
local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(
    memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count)
  )
  local bytes = assert(narc:readMember(memberId))
  return bytes, sha1(bytes)
end

-- Aggregate GX opcode counts across a model's shapes into a name->count map.
local function collectGxOpcodes(model)
  local counts = {}
  for _, shp in ipairs(model.shapes) do
    for op, n in pairs(shp.opcodeCounts) do
      local name = GxDisplayList.opcodeName(op) or string.format("0x%02X", op)
      counts[name] = (counts[name] or 0) + n
    end
  end
  return counts
end

local function collectSbcOpcodes(model)
  local counts = {}
  for _, cmd in ipairs(model.sbc.commands) do
    counts[cmd.name] = (counts[cmd.name] or 0) + 1
  end
  return counts
end

-- Empty target-material/state inventory. Sets are keyed for dedup; bump() folds
-- a model's materials/shapes in. accumulate() below turns it into sorted lists.
local function newInventory()
  return {
    modelCount = 0,
    materialCount = 0,
    itemTags = {},
    polygonModes = {},
    polygonAlphas = {},
    lightMasks = {},
    cullModes = {},
    polygonIds = {},
    polyAttrMasks = {},
    texImageParamMasks = {},
    flagCounts = { translucentDepthWrite = 0, depthEqual = 0, fog = 0, farClip = 0, oneDot = 0 },
    ownership = { diffuse = 0, ambient = 0, vertexColor = 0, specular = 0, emission = 0, shininess = 0 },
    setVertexColor = 0,
    useShininessTable = 0,
    gxOpcodes = {},
    textureFormats = {},
    shapesWithDlPolygonAttr = 0,
  }
end

-- Fold one decoded model's material and shape state into the inventory.
local function accumulate(inv, model)
  inv.modelCount = inv.modelCount + 1
  for _, mat in ipairs(model.materials) do
    inv.materialCount = inv.materialCount + 1
    inv.itemTags[mat.itemTag] = true
    inv.polyAttrMasks[string.format("0x%08X", mat.polyAttrMask)] = true
    inv.texImageParamMasks[string.format("0x%08X", mat.texImageParamMask)] = true
    if mat.setVertexColor then
      inv.setVertexColor = inv.setVertexColor + 1
    end
    if mat.useShininessTable then
      inv.useShininessTable = inv.useShininessTable + 1
    end
    for channel, owned in pairs(mat.owns) do
      if owned then
        inv.ownership[channel] = (inv.ownership[channel] or 0) + 1
      end
    end
    -- Effective polygon state: every target material fully masks polyAttr, so the
    -- raw word is the effective word (asserted in the merge gate).
    local a = DsPolygonAttr.decode(mat.polyAttrRaw)
    inv.polygonModes[a.polygonMode] = true
    inv.polygonAlphas[a.polygonAlpha] = true
    inv.lightMasks[a.lightMask] = true
    inv.cullModes[a.cullMode] = true
    inv.polygonIds[a.polygonId] = true
    if a.translucentDepthWrite then
      inv.flagCounts.translucentDepthWrite = inv.flagCounts.translucentDepthWrite + 1
    end
    if a.depthEqual then
      inv.flagCounts.depthEqual = inv.flagCounts.depthEqual + 1
    end
    if a.fogEnabled then
      inv.flagCounts.fog = inv.flagCounts.fog + 1
    end
    if a.farClipEnabled then
      inv.flagCounts.farClip = inv.flagCounts.farClip + 1
    end
    if a.oneDotEnabled then
      inv.flagCounts.oneDot = inv.flagCounts.oneDot + 1
    end
  end
  for op, n in pairs(collectGxOpcodes(model)) do
    inv.gxOpcodes[op] = (inv.gxOpcodes[op] or 0) + n
  end
  for _, shp in ipairs(model.shapes) do
    if shp.geometry.polygonAttrs and #shp.geometry.polygonAttrs > 0 then
      inv.shapesWithDlPolygonAttr = inv.shapesWithDlPolygonAttr + 1
    end
  end
end

-- Resolve the inventory sets into sorted lists for a deterministic report.
local function finalizeInventory(inv)
  inv.itemTags = sortedKeys(inv.itemTags)
  inv.polygonModes = sortedKeys(inv.polygonModes)
  inv.polygonAlphas = sortedKeys(inv.polygonAlphas)
  inv.lightMasks = sortedKeys(inv.lightMasks)
  inv.cullModes = sortedKeys(inv.cullModes)
  inv.polygonIds = sortedKeys(inv.polygonIds)
  inv.polyAttrMasks = sortedKeys(inv.polyAttrMasks)
  inv.texImageParamMasks = sortedKeys(inv.texImageParamMasks)
  inv.textureFormats = sortedKeys(inv.textureFormats)
  return inv
end

local function summarizeTexturePack(nsbtx)
  local formats, dims, names, palNames = {}, {}, {}, {}
  for _, t in ipairs(nsbtx.textures) do
    formats[t.format] = true
    dims[string.format("%dx%d", t.width, t.height)] = true
    names[#names + 1] = t.name
  end
  for _, p in ipairs(nsbtx.palettes) do
    palNames[#palNames + 1] = p.name
  end
  table.sort(names)
  table.sort(palNames)
  return {
    textureCount = #nsbtx.textures,
    paletteCount = #nsbtx.palettes,
    formats = sortedKeys(formats),
    dimensions = sortedKeys(dims),
    names = names,
    paletteNames = palNames,
  }
end

local function summarizeMapModel(nsbmd)
  local model = nsbmd.models[1]
  local texNames, palNames = {}, {}
  for _, a in ipairs(model.textureAssociations) do
    texNames[#texNames + 1] = a.name
  end
  for _, a in ipairs(model.paletteAssociations) do
    palNames[#palNames + 1] = a.name
  end
  table.sort(texNames)
  table.sort(palNames)
  return {
    modelCount = #nsbmd.models,
    modelName = model.name,
    nodeCount = model.info.numNode,
    materialCount = model.info.numMat,
    shapeCount = model.info.numShp,
    vertexCount = model.info.numVertex,
    sbcOpcodes = collectSbcOpcodes(model),
    gxOpcodes = collectGxOpcodes(model),
    referencedTextureNames = texNames,
    referencedPaletteNames = palNames,
    bounds = model.bounds,
    embeddedTextures = nsbmd.embeddedTextures ~= nil,
  }
end

-- Union two axis-aligned bounds in model or tile space.
local function unionBounds(a, b)
  if not a then
    return b
  end
  if not b then
    return a
  end
  return {
    min = {
      math.min(a.min[1], b.min[1]),
      math.min(a.min[2], b.min[2]),
      math.min(a.min[3], b.min[3]),
    },
    max = {
      math.max(a.max[1], b.max[1]),
      math.max(a.max[2], b.max[2]),
      math.max(a.max[3], b.max[3]),
    },
  }
end

local function sliceBounds(batch)
  local numeric = batch.arena.numeric
  local first = numeric[batch.vertexOffset]
  local minX, minY, minZ = first.x, first.y, first.z
  local maxX, maxY, maxZ = minX, minY, minZ
  for offset = 1, batch.vertexCount - 1 do
    local vertex = numeric[batch.vertexOffset + offset]
    minX, maxX = math.min(minX, vertex.x), math.max(maxX, vertex.x)
    minY, maxY = math.min(minY, vertex.y), math.max(maxY, vertex.y)
    minZ, maxZ = math.min(minZ, vertex.z), math.max(maxZ, vertex.z)
  end
  return {
    min = { minX, minY, minZ },
    max = { maxX, maxY, maxZ },
  }
end

local function rawDisplayListBounds(model)
  local bounds
  for _, shp in ipairs(model.shapes) do
    bounds = unionBounds(bounds, shp.geometry and shp.geometry.bounds)
  end
  return bounds
end

local function collectPosScaleOptions(model)
  local normal, inverse = 0, 0
  for _, cmd in ipairs(model.sbc.commands) do
    if cmd.opcode == 0x0B then -- POSSCALE
      if cmd.inverse then
        inverse = inverse + 1
      else
        normal = normal + 1
      end
    end
  end
  return { normal = normal, inverse = inverse }
end

local function summarizeNodes(model)
  local out = {}
  for _, node in ipairs(model.nodes) do
    out[#out + 1] = {
      index = node.index,
      name = node.name,
      flagsRaw = node.flagsRaw,
      matrixStackIndex = node.matrixStackIndex,
    }
  end
  return out
end

-- Compile a building model through the same path the runtime uses and report
-- per-draw bounds plus an aggregate. Failures are captured so the inspector can
-- still report raw/decoder state even when a model is not yet compilable.
local function compileDiagnostics(model)
  local ok, batches = pcall(MeshCompiler.compile, model)
  if not ok then
    return { drawBounds = {}, aggregateBounds = nil, error = tostring(batches) }
  end
  local drawBounds = {}
  local aggregate
  for _, batch in ipairs(batches) do
    local b = sliceBounds(batch)
    drawBounds[#drawBounds + 1] = {
      nodeIndex = batch.nodeIndex,
      materialIndex = batch.materialIndex,
      shapeIndex = batch.shapeIndex,
      bounds = b,
    }
    aggregate = unionBounds(aggregate, b)
  end
  return { drawBounds = drawBounds, aggregateBounds = aggregate }
end

-- Resolve the external animations a build model references. `listNarc` holds one
-- 0x18-byte record per member (exterior_build_anim_list); each referenced id
-- indexes `resNarc` (build_anim), a mixed archive of NitroSystem
-- animation resources. Returns a list of { resourceId, magic, kind, name }.
---@param listNarc RomFs.Narc
---@param resNarc RomFs.Narc
---@param memberId integer
---@return table[]
local function resolveAnimations(listNarc, resNarc, memberId)
  if memberId >= listNarc:memberCount() then
    return {}
  end
  local record = BuildModelAnimList.decode(listNarc:readMember(memberId))
  local out = {}
  for _, resourceId in ipairs(record.ids) do
    local entry = { resourceId = resourceId }
    if resourceId < resNarc:memberCount() then
      local bytes = assert(resNarc:readMember(resourceId))
      entry.magic = bytes:sub(1, 4)
      entry.kind = ANIM_KIND[entry.magic] or "unknown"
      -- NitroSystem animation name: 16 bytes at 0x34, NUL-padded.
      entry.name = bytes:sub(0x35, 0x44):gsub("%z.*$", "")
    else
      entry.kind = "missing"
    end
    out[#out + 1] = entry
  end
  return out
end

-- Decode every unique placed-building model in the archive chosen by area type.
local function inspectBuildings(romFs, area, buildings, warnings, inv)
  local alias = area.areaType == "indoor" and "interior_build_models"
    or area.areaType == "outdoor" and "exterior_build_models"
  if not alias then
    warnings[#warnings + 1] = "unsupported area type for building selection: " .. tostring(area.areaTypeRaw)
    return { archiveAlias = nil, modelIds = {}, placements = #buildings, modelSummaries = {} }
  end

  local uniqueIds = {}
  for _, b in ipairs(buildings) do
    uniqueIds[b.modelMemberId] = true
  end
  local ids = sortedKeys(uniqueIds)

  local placementSummaries = {}
  for _, pl in ipairs(buildings) do
    placementSummaries[#placementSummaries + 1] = {
      index = pl.index,
      modelMemberId = pl.modelMemberId,
      position = pl.position,
      rotation = pl.rotation,
      scaleRaw = pl.scaleRaw,
      scale = pl.scale,
    }
  end

  local narc = assert(romFs:openNarc(alias))
  -- Outdoor build models carry external animations; indoor ones do not.
  local animListNarc = alias == "exterior_build_models" and romFs:openNarc("exterior_build_anim_list")
  local animResNarc = alias == "exterior_build_models" and romFs:openNarc("build_anim")
  local summaries = {}
  for _, memberId in ipairs(ids) do
    local ok, bytes = pcall(readMember, narc, alias, memberId)
    if not ok then
      warnings[#warnings + 1] = string.format("building model %d: %s", memberId, tostring(bytes))
    else
      local nsbmd, err = Nsbmd.decode(bytes, { alias = alias, memberId = memberId })
      if not nsbmd then
        warnings[#warnings + 1] = string.format("building model %d decode failed: %s", memberId, tostring(err))
      else
        local model = nsbmd.models[1]
        accumulate(inv, model)
        if nsbmd.embeddedTextures then
          for _, t in ipairs(nsbmd.embeddedTextures.textures) do
            inv.textureFormats[t.format] = true
          end
        end
        summaries[#summaries + 1] = {
          memberId = memberId,
          modelName = model.name,
          nodeCount = model.info.numNode,
          materialCount = model.info.numMat,
          shapeCount = model.info.numShp,
          hasEmbeddedTextures = nsbmd.embeddedTextures ~= nil,
          bounds = model.bounds,
          scaleInfo = {
            posScale = model.info.posScale,
            invPosScale = model.info.invPosScale,
            boxPosScale = model.info.boxPosScale,
            boxInvPosScale = model.info.boxInvPosScale,
          },
          nodeSummary = summarizeNodes(model),
          posScaleOptions = collectPosScaleOptions(model),
          rawBounds = rawDisplayListBounds(model),
          compiledDiagnostics = compileDiagnostics(model),
          animations = animListNarc and animResNarc and resolveAnimations(animListNarc, animResNarc, memberId) or {},
        }
      end
    end
  end
  return {
    archiveAlias = alias,
    modelIds = ids,
    placements = #buildings,
    modelSummaries = summaries,
    placementSummaries = placementSummaries,
  }
end

-- Produce the full inventory report for a semantic map id or symbol.
function MapAssetInspector.inspect(romFs, idOrSymbol)
  local warnings = {}
  local resolved = assert(MapResolver.resolve(romFs, idOrSymbol))

  local areaNarc = assert(romFs:openNarc("area_data"))
  local areaBytes, areaSha = readMember(areaNarc, "area_data", resolved.areaDataMemberId)
  local area = assert(AreaData.decode(areaBytes, { alias = "area_data", memberId = resolved.areaDataMemberId }))

  local landNarc = assert(romFs:openNarc("land_data"))
  local landBytes, landSha = readMember(landNarc, "land_data", resolved.landDataMemberId)
  local land = assert(
    LandData.decode(landBytes, { mapId = resolved.map.id, alias = "land_data", memberId = resolved.landDataMemberId })
  )
  -- LandData already decoded the placed-building records; reuse them.
  local buildings = land.buildings

  local mapModel = assert(
    Nsbmd.decode(
      land.mapModelBytes,
      { alias = "land_data", memberId = resolved.landDataMemberId, section = "map-model" }
    )
  )

  local mapTexNarc = assert(romFs:openNarc("map_textures"))
  local mapTexBytes, mapTexSha = readMember(mapTexNarc, "map_textures", area.mapTexturePackId)
  local mapTexPack = assert(Nsbtx.decode(mapTexBytes, { alias = "map_textures", memberId = area.mapTexturePackId }))

  local bldTexNarc = assert(romFs:openNarc("building_textures"))
  local bldTexBytes, bldTexSha = readMember(bldTexNarc, "building_textures", area.buildingTexturePackId)
  local bldTexPack =
    assert(Nsbtx.decode(bldTexBytes, { alias = "building_textures", memberId = area.buildingTexturePackId }))

  -- Target material/polygon-state inventory: fold the map
  -- model and every placed building model, plus the area texture-pack formats.
  local inv = newInventory()
  accumulate(inv, mapModel.models[1])
  for _, t in ipairs(mapTexPack.textures) do
    inv.textureFormats[t.format] = true
  end
  for _, t in ipairs(bldTexPack.textures) do
    inv.textureFormats[t.format] = true
  end
  -- Raw permission-byte distribution (a source diagnostic: the hard-block bit
  -- and response id split happens only inside HgssPermissionGrid).
  local rawPermissions = landBytes:sub(land.offsets.permissions + 1, land.offsets.permissions + land.sizes.permissions)
  local permissionGrid = assert(HgssPermissionGrid.decode(rawPermissions, { mapId = resolved.map.id }))
  local buildingReport = inspectBuildings(romFs, area, buildings, warnings, inv)

  -- Field-light profile: resolve the area's light type, read and parse the
  -- selected text table, and select the noon record for a deterministic sample.
  local selected = HgssFieldLighting.resolve(area.lightTypeRaw)
  local lightText = assert(romFs:readSourcePath(selected.sourcePath))
  local profile = assert(HgssFieldLightProfile.parse(lightText, { sourcePath = selected.sourcePath }))
  local noonRecord = FieldLightProfile.select(profile, FieldLightProfile.DEFAULT_TIME_SECONDS)

  local report = {
    versionId = romFs:version(),
    map = {
      id = resolved.map.id,
      symbol = resolved.map.symbol,
      matrixMemberId = resolved.matrixMemberId,
      areaDataMemberId = resolved.areaDataMemberId,
      eventMemberId = resolved.map.eventMemberId,
    },
    resolved = {
      matrixName = resolved.matrix.name,
      matrixWidth = resolved.matrix.width,
      matrixHeight = resolved.matrix.height,
      matrixX = resolved.matrixX,
      matrixZ = resolved.matrixZ,
      matrixIndex = resolved.matrixIndex,
      landDataMemberId = resolved.landDataMemberId,
      altitude = resolved.matrixAltitude,
      worldOriginX = resolved.worldOriginX,
      worldOriginZ = resolved.worldOriginZ,
    },
    area = {
      buildingTexturePackId = area.buildingTexturePackId,
      mapTexturePackId = area.mapTexturePackId,
      dynamicTextureType = area.dynamicTextureType,
      areaType = area.areaType,
      lightType = area.lightTypeRaw,
    },
    land = {
      memberSize = #landBytes,
      bgsPayloadSize = #land.bgs.payload,
      permissionsSize = land.sizes.permissions,
      buildingSectionSize = land.sizes.buildings,
      buildingCount = #buildings,
      modelSize = land.sizes.model,
      bdhcSize = land.sizes.bdhc,
      modelMagic = land.mapModelBytes:sub(1, 4),
      bdhcMagic = land.sizes.bdhc > 0 and land.bdhcBytes:sub(1, 4) or "",
      permissionValues = permissionGrid.usedPermissionValues,
      behaviorValues = permissionGrid.usedBehaviorValues,
      -- Derived section offsets. The permission grid is NOT at a fixed 0x14: for
      -- ordinary maps a non-empty soundplate (BGS) block shifts it, matching the
      -- decomp's dynamic field loader (the fixed-0x14 TerrainAttributes path
      -- serves only Battle Tower / dynamic-warp maps).
      offsets = {
        bgs = land.offsets.bgs,
        permissions = land.offsets.permissions,
        buildings = land.offsets.buildings,
        model = land.offsets.model,
        bdhc = land.offsets.bdhc,
      },
      memberEndMatches = (land.offsets.bdhc + land.sizes.bdhc == #landBytes),
    },
    mapModel = summarizeMapModel(mapModel),
    mapTexturePack = summarizeTexturePack(mapTexPack),
    buildingTexturePack = summarizeTexturePack(bldTexPack),
    buildings = buildingReport,
    featureInventory = finalizeInventory(inv),
    lighting = {
      lightTypeRaw = area.lightTypeRaw,
      profileId = selected.profileId,
      sourcePath = selected.sourcePath,
      sourceSha1 = sha1(lightText),
      recordCount = #profile.records,
      noonStartHalfSeconds = noonRecord.startHalfSeconds,
      noonEnabledLightMask = noonRecord.enabledLightMask,
    },
    source = {
      areaData = { alias = "area_data", memberId = resolved.areaDataMemberId, sha1 = areaSha },
      landData = { alias = "land_data", memberId = resolved.landDataMemberId, sha1 = landSha },
      mapTexture = { alias = "map_textures", memberId = area.mapTexturePackId, sha1 = mapTexSha },
      buildingTexture = { alias = "building_textures", memberId = area.buildingTexturePackId, sha1 = bldTexSha },
    },
    warnings = warnings,
  }
  return report
end

-- Format a report as a deterministic, human-readable line list for stdout.
function MapAssetInspector.lines(report)
  local L = {}
  local function add(fmt, ...)
    L[#L + 1] = string.format(fmt, ...)
  end
  add("== %s :: %s (id %d) ==", report.versionId, report.map.symbol, report.map.id)
  add(
    "resolved: matrix %q %dx%d cell (%d,%d) index %d land %d origin (%d,%d)",
    report.resolved.matrixName,
    report.resolved.matrixWidth,
    report.resolved.matrixHeight,
    report.resolved.matrixX,
    report.resolved.matrixZ,
    report.resolved.matrixIndex,
    report.resolved.landDataMemberId,
    report.resolved.worldOriginX,
    report.resolved.worldOriginZ
  )
  add(
    "area: type=%s mapTexPack=%d bldTexPack=%d dynTex=0x%X light=%d",
    report.area.areaType,
    report.area.mapTexturePackId,
    report.area.buildingTexturePackId,
    report.area.dynamicTextureType,
    report.area.lightTypeRaw
  )
  local l = report.land
  add(
    "land: size=%d bgs=%d perms=0x%X buildings=%d(%d recs) model=%d bdhc=%d magic=%s",
    l.memberSize,
    l.bgsPayloadSize,
    l.permissionsSize,
    l.buildingSectionSize,
    l.buildingCount,
    l.modelSize,
    l.bdhcSize,
    l.modelMagic
  )
  add(
    "  offsets: bgs=0x%X perms=0x%X buildings=0x%X model=0x%X bdhc=0x%X endMatches=%s",
    l.offsets.bgs,
    l.offsets.permissions,
    l.offsets.buildings,
    l.offsets.model,
    l.offsets.bdhc,
    tostring(l.memberEndMatches)
  )
  add("  behavior values:   %s", table.concat(l.behaviorValues, " "))
  add("  permission values: %s (hard-block bit 0x80 | response 0x7F)", table.concat(l.permissionValues, " "))
  local mm = report.mapModel
  add(
    "mapModel: %s models=%d nodes=%d materials=%d shapes=%d verts=%d",
    mm.modelName,
    mm.modelCount,
    mm.nodeCount,
    mm.materialCount,
    mm.shapeCount,
    mm.vertexCount
  )
  add(
    "  bounds min(%.2f,%.2f,%.2f) max(%.2f,%.2f,%.2f)",
    mm.bounds.min[1],
    mm.bounds.min[2],
    mm.bounds.min[3],
    mm.bounds.max[1],
    mm.bounds.max[2],
    mm.bounds.max[3]
  )
  local function opcodeLine(label, counts)
    local parts = {}
    for _, name in ipairs(sortedKeys(counts)) do
      parts[#parts + 1] = name .. "=" .. counts[name]
    end
    add("  %s: %s", label, table.concat(parts, " "))
  end
  opcodeLine("SBC opcodes", mm.sbcOpcodes)
  opcodeLine("GX opcodes", mm.gxOpcodes)
  add("  textures referenced: %s", table.concat(mm.referencedTextureNames, " "))
  local mt = report.mapTexturePack
  add(
    "mapTexturePack: %d textures %d palettes formats=[%s] dims=[%s]",
    mt.textureCount,
    mt.paletteCount,
    table.concat(mt.formats, ","),
    table.concat(mt.dimensions, ",")
  )
  local bt = report.buildingTexturePack
  add(
    "buildingTexturePack: %d textures %d palettes formats=[%s]",
    bt.textureCount,
    bt.paletteCount,
    table.concat(bt.formats, ",")
  )
  local function boundsLine(label, bounds)
    if not bounds then
      return add("    %s: nil", label)
    end
    add(
      "    %s: min(%.2f,%.2f,%.2f) max(%.2f,%.2f,%.2f)",
      label,
      bounds.min[1],
      bounds.min[2],
      bounds.min[3],
      bounds.max[1],
      bounds.max[2],
      bounds.max[3]
    )
  end

  local b = report.buildings
  add(
    "buildings: archive=%s placements=%d uniqueModels=[%s]",
    tostring(b.archiveAlias),
    b.placements,
    table.concat(b.modelIds, ",")
  )
  for _, s in ipairs(b.modelSummaries) do
    add(
      "  model %d %q: nodes=%d materials=%d shapes=%d embeddedTex=%s",
      s.memberId,
      s.modelName,
      s.nodeCount,
      s.materialCount,
      s.shapeCount,
      tostring(s.hasEmbeddedTextures)
    )
    local si = s.scaleInfo
    add(
      "    scale: posScale=%.4f invPosScale=%.4f boxPosScale=%.4f boxInvPosScale=%.4f",
      si.posScale,
      si.invPosScale,
      si.boxPosScale,
      si.boxInvPosScale
    )
    local nodeParts = {}
    for _, n in ipairs(s.nodeSummary) do
      nodeParts[#nodeParts + 1] =
        string.format("%d:%s flags=0x%04X slot=%d", n.index, n.name, n.flagsRaw, n.matrixStackIndex)
    end
    add("    nodes: %s", table.concat(nodeParts, " | "))
    add("    posScale ops: normal=%d inverse=%d", s.posScaleOptions.normal, s.posScaleOptions.inverse)
    if #s.animations > 0 then
      local parts = {}
      for _, a in ipairs(s.animations) do
        parts[#parts + 1] = string.format("res %d %s(%s) %q", a.resourceId, a.kind, a.magic or "?", a.name or "")
      end
      add("    animations: %s", table.concat(parts, " | "))
    else
      add("    animations: none")
    end
    boundsLine("raw dl bounds", s.rawBounds)
    local cd = s.compiledDiagnostics
    if cd.error then
      add("    compiled: ERROR %s", cd.error)
    else
      add("    compiled draws: %d", #cd.drawBounds)
      -- n is the draw's position in SBC submission order: the compiled batch
      -- list IS the submission sequence (see MeshCompiler).
      for n, d in ipairs(cd.drawBounds) do
        boundsLine(
          string.format("      draw n=%d node=%d mat=%d shp=%d", n, d.nodeIndex, d.materialIndex, d.shapeIndex),
          d.bounds
        )
      end
      boundsLine("    compiled aggregate bounds", cd.aggregateBounds)
    end
  end
  for _, pl in ipairs(b.placementSummaries) do
    add(
      "  placement %d: model=%d pos=(%.2f,%.2f,%.2f) scaleRaw=(0x%08X,0x%08X,0x%08X) scale=(%.4f,%.4f,%.4f)",
      pl.index,
      pl.modelMemberId,
      pl.position.x,
      pl.position.y,
      pl.position.z,
      pl.scaleRaw.width,
      pl.scaleRaw.height,
      pl.scaleRaw.length,
      pl.scale.width,
      pl.scale.height,
      pl.scale.length
    )
  end
  local fi = report.featureInventory
  add(
    "featureInventory: models=%d materials=%d itemTags=[%s]",
    fi.modelCount,
    fi.materialCount,
    table.concat(fi.itemTags, ",")
  )
  add(
    "  polygonModes=[%s] polygonAlphas=[%s] lightMasks=[%s] cullModes=[%s]",
    table.concat(fi.polygonModes, ","),
    table.concat(fi.polygonAlphas, ","),
    table.concat(fi.lightMasks, ","),
    table.concat(fi.cullModes, ",")
  )
  add(
    "  polygonIds=[%s] polyAttrMasks=[%s] texImageParamMasks=[%s]",
    table.concat(fi.polygonIds, ","),
    table.concat(fi.polyAttrMasks, ","),
    table.concat(fi.texImageParamMasks, ",")
  )
  add(
    "  flags: translucentDepthWrite=%d depthEqual=%d fog=%d farClip=%d oneDot=%d",
    fi.flagCounts.translucentDepthWrite,
    fi.flagCounts.depthEqual,
    fi.flagCounts.fog,
    fi.flagCounts.farClip,
    fi.flagCounts.oneDot
  )
  add(
    "  ownership: diffuse=%d ambient=%d vertexColor=%d specular=%d emission=%d shininess=%d",
    fi.ownership.diffuse,
    fi.ownership.ambient,
    fi.ownership.vertexColor,
    fi.ownership.specular,
    fi.ownership.emission,
    fi.ownership.shininess
  )
  add(
    "  setVertexColor=%d useShininessTable=%d shapesWithDlPolygonAttr=%d textureFormats=[%s]",
    fi.setVertexColor,
    fi.useShininessTable,
    fi.shapesWithDlPolygonAttr,
    table.concat(fi.textureFormats, ",")
  )
  opcodeLine("  GX opcodes(all models)", fi.gxOpcodes)
  local lt = report.lighting
  add(
    "lighting: lightTypeRaw=%d profile=%d %s records=%d noonStart=%d noonMask=0x%X",
    lt.lightTypeRaw,
    lt.profileId,
    lt.sourcePath,
    lt.recordCount,
    lt.noonStartHalfSeconds,
    lt.noonEnabledLightMask
  )
  if #report.warnings == 0 then
    add("warnings: none")
  else
    table.sort(report.warnings)
    for _, w in ipairs(report.warnings) do
      add("WARNING: %s", w)
    end
  end
  return L
end

return MapAssetInspector
