-- Retail projection lock for the Bag hero: an independent test-side camera and
-- base-transform path projects real compiled hero geometry into the canonical
-- 256x192 pane and requires the production hero renderer to agree there.
--
-- Authority: pret/pokeheartgold src/camera.c (eye from target, distance,
-- pitch, yaw), src/gf_3d_render.c (G3_ViewPort(0,0,255,191) full-viewport
-- setup with base translation/rotation/scale), asm/overlay_15.s (Bag camera
-- target/distance/angle/perspective/clip facts and the static (0,-45,0) hero
-- base translation), and the NitroSDK MTX_LookAt convention
-- (look = eye - target, right = up x look, up = look x right).
--
-- The expected path below never calls the production hero camera/model
-- builders and never reads its composed view/projection/model matrices: eye,
-- look-at, half-angle perspective, base translation, and the NDC-to-pixel map
-- are all recomputed here from the pinned raw facts. Shared nitro
-- model/animation decoding and pose evaluation are reused infrastructure, not
-- the seam under test; the seam under test is base/camera/viewport
-- composition. Both genders and two pocket states at frame 0 and a later
-- frame are covered; the comparison runs before responsive host scaling, so
-- the canonical result is topology-independent by construction.
local Assert = require("tests.support.Assert")
local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
local BagHeroPresenter = require("libs.hgss.src.presentation.BagHeroPresenter")
local BagHeroRenderer = require("libs.hgss.src.presentation.BagHeroRenderer")
local BagSources = require("romdump.src.config.BagSources")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local RomSuite = require("tests.rom.support.RomSuite")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")

local T = {}

local TILE = MapUnits.MODEL_UNITS_PER_TILE
-- Pinned Bag overlay facts: fixed-point camera lengths at 1/4096, u16 angles
-- over the full circle, the u16 half-angle perspective index, and the static
-- hero base translation in source model units.
local RAW = {
  distance = 1391441,
  angleX = 59778,
  angleY = 5152,
  perspectiveAngle = 2561,
  clipNear = 503808,
  clipFar = 6963200,
  baseY = -45,
}
local CANVAS_WIDTH = 256
local CANVAS_HEIGHT = 192
-- One canonical pixel: float reproduction of fx32 trig/projection
-- quantization plus NDC-to-pixel rounding moves silhouette edges by subpixel
-- amounts, and a pixel is the raster granularity. Anything beyond one pixel
-- is a real composition seam, not quantization.
local PIXEL_TOLERANCE = 1.0
local LATER_FRAME = 8
local _DIAGNOSTIC_DUMP = os.getenv("BAG_HERO_ORACLE_DIAG") == "1"

local function degrees(raw)
  return raw * 360 / 65536
end

local function tilesFromFixed(raw)
  return (raw / 4096) / TILE
end

local function sub(a, b)
  return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

local function cross(a, b)
  return {
    a[2] * b[3] - a[3] * b[2],
    a[3] * b[1] - a[1] * b[3],
    a[1] * b[2] - a[2] * b[1],
  }
end

local function dot(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function normalize(v, what)
  local length = math.sqrt(dot(v, v))
  assert(length > 0, what .. " must be non-degenerate")
  return { v[1] / length, v[2] / length, v[3] / length }
end

-- Retail eye from camera.c: yaw spins the pitch-flattened distance around the
-- target, pitch lifts it. Angles arrive as source u16 facts, never as the
-- production manifest's derived degrees.
local function retailEye()
  local distance = tilesFromFixed(RAW.distance)
  local pitch = math.rad(degrees(RAW.angleX))
  local yaw = math.rad(degrees(RAW.angleY))
  local horizontal = distance * math.cos(pitch)
  return {
    math.sin(yaw) * horizontal,
    math.sin(-pitch) * distance,
    math.cos(yaw) * horizontal,
  }
end

-- NitroSDK MTX_LookAt order: look = eye - target, right = up x look,
-- up = look x right, rows [right, up, look] with negative dot-product
-- translation. Since look is the backward axis, this is the standard
-- right-handed look-at: the third row carries look itself. Column-major.
local function retailView(eye, target)
  local look = normalize(sub(eye, target), "the retail view direction")
  local right = normalize(cross({ 0, 1, 0 }, look), "the retail view right axis")
  local up = cross(look, right)
  return {
    right[1],
    up[1],
    look[1],
    0,
    right[2],
    up[2],
    look[2],
    0,
    right[3],
    up[3],
    look[3],
    0,
    -dot(right, eye),
    -dot(up, eye),
    -dot(look, eye),
    1,
  }
end

-- Half-angle perspective: the raw u16 index converts to a half field of view
-- over the full circle, doubled to the full vertical field. Column-major.
local function retailProjection()
  local halfFov = RAW.perspectiveAngle * 2 * math.pi / 65536
  local fullFov = halfFov * 2
  local focal = 1 / math.tan(fullFov / 2)
  local aspect = CANVAS_WIDTH / CANVAS_HEIGHT
  local near = tilesFromFixed(RAW.clipNear)
  local far = tilesFromFixed(RAW.clipFar)
  return {
    focal / aspect,
    0,
    0,
    0,
    0,
    focal,
    0,
    0,
    0,
    0,
    (far + near) / (near - far),
    -1,
    0,
    0,
    (2 * far * near) / (near - far),
    0,
  }
end

-- Static hero base translation normalized once into tile units with identity
-- rotation and unit scale: a pure translation. Column-major.
local function retailModel()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, RAW.baseY / TILE, 0, 1 }
end

local function transformAffine(m, x, y, z)
  return m[1] * x + m[5] * y + m[9] * z + m[13],
    m[2] * x + m[6] * y + m[10] * z + m[14],
    m[3] * x + m[7] * y + m[11] * z + m[15]
end

local function transformClip(m, x, y, z, w)
  return m[1] * x + m[5] * y + m[9] * z + m[13] * w,
    m[2] * x + m[6] * y + m[10] * z + m[14] * w,
    m[3] * x + m[7] * y + m[11] * z + m[15] * w,
    m[4] * x + m[8] * y + m[12] * z + m[16] * w
end

-- Retail full viewport 0..255 x 0..191: NDC [-1,1] spans the 256x192 pane,
-- NDC Y up maps to pixel Y down.
local function toPixels(ndcX, ndcY)
  return (ndcX * 0.5 + 0.5) * CANVAS_WIDTH, (0.5 - ndcY * 0.5) * CANVAS_HEIGHT
end

local function projectBounds(view, projection, model, cornersByMesh, poseByMesh)
  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge
  for meshId, corners in pairs(cornersByMesh) do
    local pose = assert(poseByMesh[meshId], "posed mesh " .. tostring(meshId) .. " needs its draw matrix")
    for _, corner in ipairs(corners) do
      local px, py, pz = transformAffine(pose, corner[1], corner[2], corner[3])
      local mx, my, mz = transformAffine(model, px, py, pz)
      local vx, vy, vz, vw = transformClip(view, mx, my, mz, 1)
      assert(vw > 0, "hero geometry must sit in front of the retail camera")
      -- The clip divide normalizes the homogeneous projection into NDC.
      local cx, cy, _, cw = transformClip(projection, vx, vy, vz, vw)
      assert(cw ~= 0, "hero geometry must project with a finite depth")
      local sx, sy = toPixels(cx / cw, cy / cw)
      assert(sx == sx and sy == sy, "projected hero pixels must be finite")
      minX = math.min(minX, sx)
      minY = math.min(minY, sy)
      maxX = math.max(maxX, sx)
      maxY = math.max(maxY, sy)
    end
  end
  assert(minX <= maxX and minY <= maxY, "the projected hero must cover pixels")
  return { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

local function copyMatrix(m)
  local out = {}
  for index = 1, 16 do
    out[index] = assert(m[index], "pose matrices carry sixteen entries")
  end
  return out
end

local function compileBundle(romFs)
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.notNil(bundle, "the production Bag compiler must rebuild the hero bundle: " .. tostring(err))
  return assert(bundle)
end

local function stubCache()
  return {
    read = function(_)
      return nil
    end,
  }
end

-- Decode one gender hero into posed mesh corners: real compiled geometry
-- AABBs plus real per-mesh pose draw matrices at the requested frame. The
-- pose backend is reused infrastructure; camera, base, and viewport stay
-- oracle-owned.
local function poseCorners(bundle, gender, pocket, frame)
  local manifest = assert(bundle.manifest)
  local descriptor = assert(assert(manifest.hero).model[gender], "the bundle carries the " .. gender .. " hero model")
  local definition = ModelDefinition.fromNitroDescriptor(descriptor, { key = "bag-hero:" .. gender })
  local cornersByMesh = {}
  local meshes = assert(definition.meshes, "the " .. gender .. " hero definition carries meshes")
  Assert.isTrue(#meshes > 0, "the " .. gender .. " hero carries geometry")
  local dummyMeshes = {}
  for _, mesh in ipairs(meshes) do
    local bytes = assert(bundle.assets[mesh.geometry], "compiled hero geometry must be present for " .. mesh.id)
    local decoded = SceneMesh.decode(bytes, "bag-hero:" .. gender .. "/" .. mesh.id)
    local geometry = SceneDescriptor.meshGeometry(decoded.vertices)
    mesh.center = geometry.center
    local bounds = geometry.bounds
    cornersByMesh[mesh.id] = {
      { bounds.minX, bounds.minY, bounds.minZ },
      { bounds.maxX, bounds.minY, bounds.minZ },
      { bounds.minX, bounds.maxY, bounds.minZ },
      { bounds.maxX, bounds.maxY, bounds.minZ },
      { bounds.minX, bounds.minY, bounds.maxZ },
      { bounds.maxX, bounds.minY, bounds.maxZ },
      { bounds.minX, bounds.maxY, bounds.maxZ },
      { bounds.maxX, bounds.maxY, bounds.maxZ },
    }
    dummyMeshes[mesh.id] = {}
  end
  local states = assert(assert(manifest.hero).animations.states, "the bundle carries hero pocket states")
  local state = nil
  for _, entry in ipairs(states) do
    if entry.pocket == pocket then
      state = entry
    end
  end
  Assert.notNil(state, "pocket " .. pocket .. " must be a compiled hero state")
  local material = assert(assert(manifest.hero).animations.material[gender], "the bundle carries the material binding")
  local instance = ModelInstance.new(definition)
  instance:play(assert(state).pose, { loopMode = "loop" })
  instance:play(assert(state).pattern, { loopMode = "loop" })
  instance:play(material, { loopMode = "loop" })
  for _ = 1, frame do
    instance:updateFixed()
  end
  instance:evaluatePose()
  return { definition = definition, instance = instance, dummyMeshes = dummyMeshes, cornersByMesh = cornersByMesh }
end

---@param presenter BagHeroPresenter
---@return { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }
local function settledFraming(presenter)
  local status = presenter:status()
  return assert(status.framing, "the settled hero status carries its interpolated framing")
end

---@param actual { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }
---@param expected { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }
---@param what string
local function assertFramingNear(actual, expected, what)
  Assert.near(actual.angleXDegrees, expected.angleXDegrees, 1e-9, what .. " pitch matches its source record")
  Assert.near(actual.angleYDegrees, expected.angleYDegrees, 1e-9, what .. " yaw matches its source record")
  Assert.near(actual.distance, expected.distance, 1e-9, what .. " distance matches its source record")
  Assert.near(actual.modelY, expected.modelY, 1e-9, what .. " model height matches its source record")
end

-- Oracle eye from one settled framing record: the same retail eye math the
-- static oracle uses, parameterized by the interpolated framing values the
-- presenter publishes instead of the static camera facts.
---@param record { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }
---@return number[]
local function viewFromFraming(record)
  local pitch = math.rad(record.angleXDegrees)
  local yaw = math.rad(record.angleYDegrees)
  local horizontal = record.distance * math.cos(pitch)
  return retailView({
    math.sin(yaw) * horizontal,
    math.sin(-pitch) * record.distance,
    math.cos(yaw) * horizontal,
  }, { 0, 0, 0 })
end

-- Oracle base from one settled framing record: the same pure model-height
-- translation the static oracle uses, parameterized by the interpolated
-- model height instead of the static base value.
---@param record { angleXDegrees: number, angleYDegrees: number, distance: number, modelY: number }
---@return number[]
local function modelFromFraming(record)
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, record.modelY, 0, 1 }
end

-- Collect pure per-mesh pose draw matrices under an identity base: the dummy-- render meshes are distinct per id, so each returned draw item maps back to
-- its mesh without reading production internals. Base, view, and projection
-- stay caller-owned, so one shared pose feeds both the oracle and the
-- runtime comparison.
local function collectPose(posed)
  posed.instance.transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  local items = posed.instance:drawItems(posed.dummyMeshes)
  Assert.isTrue(#items > 0, "the pose keeps visible meshes")
  local reverse = {}
  for id, dummy in pairs(posed.dummyMeshes) do
    reverse[dummy] = id
  end
  local byMesh = {}
  for _, item in ipairs(items) do
    local id = assert(reverse[item.mesh], "every draw item maps back to its mesh")
    Assert.isNil(byMesh[id], "mesh " .. tostring(id) .. " draws once per pose")
    byMesh[id] = copyMatrix(item.transform)
  end
  return byMesh
end

-- Pinned raw facts stay raw facts: the audited source integers and the base
-- translation are asserted as literals, separately from any derived screen
-- placement, so a future edit cannot move both sides together.
function T.pinned_hero_facts_keep_their_source_values(_)
  local presentation = assert(BagSources.presentation, "the producer pins hero presentation facts")
  local camera = assert(presentation.camera, "the pinned facts carry the Bag camera")
  Assert.equal(camera.distance, RAW.distance / 4096, "the pinned camera distance keeps its fixed-point fact")
  Assert.equal(camera.angleXDegrees, degrees(RAW.angleX), "the pinned pitch keeps its u16 fact")
  Assert.equal(camera.angleYDegrees, degrees(RAW.angleY), "the pinned yaw keeps its u16 fact")
  Assert.equal(camera.perspectiveType, 0, "the pinned camera stays perspective")
  Assert.equal(camera.perspectiveAngle, RAW.perspectiveAngle, "the pinned half-angle keeps its u16 fact")
  Assert.equal(camera.clipNear, RAW.clipNear / 4096, "the pinned near plane keeps its fixed-point fact")
  Assert.equal(camera.clipFar, RAW.clipFar / 4096, "the pinned far plane keeps its fixed-point fact")
  local transform = assert(presentation.transform, "the pinned facts carry the hero base transform")
  Assert.deepEqual(
    transform.translation,
    { x = 0, y = RAW.baseY, z = 0 },
    "the pinned base translation keeps its static source value"
  )
  Assert.deepEqual(
    transform.rotation,
    { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    "the pinned base rotation keeps its identity source value"
  )
  Assert.deepEqual(transform.scale, { x = 1, y = 1, z = 1 }, "the pinned base scale keeps its unit source value")
end

-- Exactly one model-unit normalization boundary: the compiler emits camera
-- lengths and the base translation in the same tile unit as compiled
-- geometry, so no second runtime divide is justified.
function T.hero_lengths_share_one_normalization_boundary(romFs)
  local bundle = compileBundle(romFs)
  local manifest = assert(bundle.manifest)
  local camera = assert(assert(manifest.hero).presentation.camera, "the bundle carries the hero camera")
  Assert.near(camera.distance, tilesFromFixed(RAW.distance), 1e-9, "compiled distance normalizes once into tiles")
  Assert.near(camera.clipNear, tilesFromFixed(RAW.clipNear), 1e-9, "compiled near plane normalizes once into tiles")
  Assert.near(camera.clipFar, tilesFromFixed(RAW.clipFar), 1e-9, "compiled far plane normalizes once into tiles")
  local translation = assert(assert(manifest.hero).presentation.transform.translation, "the bundle carries its base")
  Assert.near(translation.y, RAW.baseY / TILE, 1e-9, "compiled base translation normalizes once into tiles")
  -- Compiled hero vertices live in the same tile unit: a missing or doubled
  -- divide would scale them by sixteen either way.
  local largest = 0
  for _, gender in ipairs({ "male", "female" }) do
    local descriptor = assert(assert(manifest.hero).model[gender], "the bundle carries the " .. gender .. " model")
    local definition = ModelDefinition.fromNitroDescriptor(descriptor, { key = "bag-hero:" .. gender })
    for _, mesh in ipairs(assert(definition.meshes, "the hero carries meshes")) do
      local decoded = SceneMesh.decode(assert(bundle.assets[mesh.geometry]), "bag-hero:" .. gender)
      for _, vertex in ipairs(decoded.vertices) do
        largest = math.max(largest, math.abs(vertex[1]), math.abs(vertex[2]), math.abs(vertex[3]))
      end
    end
  end
  Assert.isTrue(largest > 0, "compiled hero geometry is nonempty")
  Assert.isTrue(largest < 32, "compiled hero geometry shares the tile unit, got extent " .. largest)
end

-- The runtime canonical hero must match the independent retail projection for
-- both genders and two pocket states at frame 0 and a later frame, inside
-- one raster pixel. The production matrices are read as the actual side;
-- every expected value above is oracle-derived.
function T.canonical_hero_matches_the_independent_retail_projection(romFs)
  local bundle = compileBundle(romFs)
  local manifest = assert(bundle.manifest)
  Assert.equal(manifest.schema, "g4-bag-assets-v7", "the oracle compares against the current hero contract")
  local states = assert(assert(manifest.hero).animations.states, "the bundle carries hero pocket states")
  Assert.isTrue(#states >= 2, "the oracle needs two pocket states")
  local pockets = { states[1].pocket, states[2].pocket }
  Assert.isTrue(pockets[1] ~= pockets[2], "the oracle needs two distinct pockets")

  local eye = retailEye()
  local expectedView = retailView(eye, { 0, 0, 0 })
  local expectedProjection = retailProjection()
  local expectedModel = retailModel()

  local renderer = BagHeroRenderer.new({ cacheFs = stubCache(), manifest = manifest })
  local actualView = assert(renderer._view, "the runtime carries its composed view")
  local actualProjection = assert(renderer._projection, "the runtime carries its composed projection")
  local actualModel = assert(renderer._modelTransform, "the runtime carries its composed base transform")

  if _DIAGNOSTIC_DUMP then
    local function maxDiff(a, b)
      local worst, at = 0, 0
      for index = 1, 16 do
        local delta = math.abs(a[index] - b[index])
        if delta > worst then
          worst, at = delta, index
        end
      end
      return worst, at
    end
    local viewDiff, viewAt = maxDiff(expectedView, actualView)
    local projDiff, projAt = maxDiff(expectedProjection, actualProjection)
    local modelDiff, modelAt = maxDiff(expectedModel, actualModel)
    print(
      string.format(
        "DIAG stage maxdiff view=%.6g@%d projection=%.6g@%d model=%.6g@%d",
        viewDiff,
        viewAt,
        projDiff,
        projAt,
        modelDiff,
        modelAt
      )
    )
    do
      local parts = {}
      for index = 1, 16 do
        parts[#parts + 1] = string.format("%d:%.4f/%.4f", index, expectedView[index], actualView[index])
      end
      print("DIAG view expected/actual " .. table.concat(parts, " "))
    end
    local camera = assert(manifest.hero.presentation.camera, "diag camera")
    print(
      string.format(
        "DIAG manifest camera distance=%.6f angleX=%.6f angleY=%.6f persp=%s near=%.6f far=%.6f baseY=%.6f",
        camera.distance,
        camera.angleXDegrees,
        camera.angleYDegrees,
        tostring(camera.perspectiveAngle),
        camera.clipNear,
        camera.clipFar,
        assert(manifest.hero.presentation.transform.translation).y
      )
    )
  end

  for _, gender in ipairs({ "male", "female" }) do
    for _, pocket in ipairs(pockets) do
      for _, frame in ipairs({ 0, LATER_FRAME }) do
        local label = gender .. " " .. pocket .. " frame " .. frame
        local posed = poseCorners(bundle, gender, pocket, frame)
        -- One shared pose feeds both sides: the backend is reused
        -- infrastructure, while base, camera, and viewport composition is
        -- what disagrees if this fails.
        local pose = collectPose(posed)
        local expected = projectBounds(expectedView, expectedProjection, expectedModel, posed.cornersByMesh, pose)
        local actual = projectBounds(actualView, actualProjection, actualModel, posed.cornersByMesh, pose)
        if _DIAGNOSTIC_DUMP then
          print(
            string.format(
              "DIAG %s expected=(%.3f,%.3f)-(%.3f,%.3f) actual=(%.3f,%.3f)-(%.3f,%.3f)",
              label,
              expected.minX,
              expected.minY,
              expected.maxX,
              expected.maxY,
              actual.minX,
              actual.minY,
              actual.maxX,
              actual.maxY
            )
          )
        end
        Assert.near(actual.minX, expected.minX, PIXEL_TOLERANCE, label .. " matches the retail left bound")
        Assert.near(actual.minY, expected.minY, PIXEL_TOLERANCE, label .. " matches the retail top bound")
        Assert.near(actual.maxX, expected.maxX, PIXEL_TOLERANCE, label .. " matches the retail right bound")
        Assert.near(actual.maxY, expected.maxY, PIXEL_TOLERANCE, label .. " matches the retail bottom bound")
      end
    end
  end
end

-- Source-faithful hero framing: the compiled hero presentation carries the
-- pocket-aware framing records (baseline plus one per canonical pocket for
-- both genders) with the fixed-tick transition duration, normalized to
-- finite semantic values.
--
-- Authority: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- asm/overlay_15.s (ov15_02200790 framing table, ov15_021FDAF4 transition
-- duration).
function T.compiled_hero_carries_pocket_framing_for_both_genders(romFs)
  local bundle = compileBundle(romFs)
  local manifest = assert(bundle.manifest)
  local presentation = assert(assert(manifest.hero).presentation, "the bundle carries the hero presentation")
  local framing = assert(presentation.framing, "the bundle carries the pocket-aware hero framing")
  Assert.equal(framing.transitionTicks, 7, "the framing transition keeps its fixed-tick duration")
  for _, gender in ipairs({ "male", "female" }) do
    local baseline = assert(framing.baseline[gender], gender .. " publishes its baseline framing record")
    local pockets = assert(framing.byGender[gender], gender .. " publishes its pocket framing records")
    local seen = 0
    for _, pocket in ipairs({
      "items",
      "medicine",
      "balls",
      "tmhm",
      "berries",
      "mail",
      "battle_items",
      "key_items",
    }) do
      local record = assert(pockets[pocket], gender .. " publishes the " .. pocket .. " framing record")
      seen = seen + 1
      for _, field in ipairs({ "angleXDegrees", "angleYDegrees", "distance", "modelY" }) do
        local value = record[field]
        Assert.isTrue(
          type(value) == "number" and value == value and value < math.huge and value > -math.huge,
          gender .. " " .. pocket .. " framing " .. field .. " must be a finite number"
        )
      end
    end
    Assert.equal(seen, 8, gender .. " publishes all eight pocket framing records")
    for _, field in ipairs({ "angleXDegrees", "angleYDegrees", "distance", "modelY" }) do
      local value = baseline[field]
      Assert.isTrue(
        type(value) == "number" and value == value and value < math.huge and value > -math.huge,
        gender .. " baseline framing " .. field .. " must be a finite number"
      )
    end
  end
end

-- The normalized framing values reproduce the pinned source table:
-- baseline plus two pocket records per gender convert fixed-point
-- lengths at 1/4096 into tile units and u16 angles over the full circle.
--
-- Authority: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- asm/overlay_15.s (ov15_02200790 sixteen-byte records: u16 X/Y angles,
-- fixed-point distance, fixed-point model Y; record 0 baseline, records
-- 1..8 canonical pockets, two gender groups of nine).
function T.compiled_framing_matches_the_pinned_source_records(romFs)
  local bundle = compileBundle(romFs)
  local manifest = assert(bundle.manifest)
  local framing = assert(assert(manifest.hero).presentation.framing, "the bundle carries the pocket-aware hero framing")
  local pinned = {
    male = {
      baseline = { angleX = 59778, angleY = 5152, distance = 1391441, modelY = -163840 },
      items = { angleX = 61058, angleY = 26393, distance = 1391445, modelY = -151552 },
      medicine = { angleX = 57479, angleY = 18472, distance = 932689, modelY = -188416 },
    },
    female = {
      baseline = { angleX = 59778, angleY = 5152, distance = 1391441, modelY = -163840 },
      items = { angleX = 60546, angleY = 14368, distance = 1203027, modelY = -184320 },
      medicine = { angleX = 59778, angleY = 7968, distance = 1096529, modelY = -163840 },
    },
  }
  for _, gender in ipairs({ "male", "female" }) do
    local expected = pinned[gender]
    local records = { baseline = assert(framing.baseline[gender]) }
    for _, pocket in ipairs({ "items", "medicine" }) do
      records[pocket] = assert(framing.byGender[gender][pocket])
    end
    for label, record in pairs(records) do
      local raw = assert(expected[label], gender .. " " .. label .. " carries a pinned source record")
      Assert.near(
        record.angleXDegrees,
        raw.angleX * 360 / 65536,
        1e-9,
        gender .. " " .. label .. " pitch matches its u16 source angle"
      )
      Assert.near(
        record.angleYDegrees,
        raw.angleY * 360 / 65536,
        1e-9,
        gender .. " " .. label .. " yaw matches its u16 source angle"
      )
      Assert.near(
        record.distance,
        (raw.distance / 4096) / TILE,
        1e-9,
        gender .. " " .. label .. " distance matches its fixed-point source length in tiles"
      )
      Assert.near(
        record.modelY,
        (raw.modelY / 4096) / TILE,
        1e-9,
        gender .. " " .. label .. " model height matches its fixed-point source length in tiles"
      )
    end
  end
end

-- Settling two pockets reframes the hero: the presenter opens at the neutral
-- baseline, resolves each settled pocket to its own source framing record
-- over seven fixed ticks while the static projection facts stay untouched,
-- and the two settled framings project the posed hero to different
-- canonical bounds, so the model moves with the active pocket.
function T.settled_pockets_reframe_the_hero_from_source_records(romFs)
  local bundle = compileBundle(romFs)
  local manifest = assert(bundle.manifest)
  Assert.equal(manifest.schema, "g4-bag-assets-v7", "the reframe comparison uses the current hero contract")
  local states = assert(assert(manifest.hero).animations.states, "the bundle carries hero pocket states")
  Assert.isTrue(#states >= 2, "the reframe needs two pocket states")
  local pocketA, pocketB = states[1].pocket, states[2].pocket
  Assert.isTrue(pocketA ~= pocketB, "the reframe needs two distinct pockets")
  local framing = assert(assert(manifest.hero).presentation.framing, "the bundle carries the pocket-aware hero framing")
  Assert.equal(framing.transitionTicks, 7, "the reframe keeps its fixed-tick duration")
  local records = assert(framing.byGender.male, "the bundle carries the male pocket framing")
  local recordA = assert(records[pocketA], "the bundle carries the " .. pocketA .. " framing record")
  local recordB = assert(records[pocketB], "the bundle carries the " .. pocketB .. " framing record")
  local separation = math.abs(recordA.angleXDegrees - recordB.angleXDegrees)
    + math.abs(recordA.angleYDegrees - recordB.angleYDegrees)
    + math.abs(recordA.distance - recordB.distance)
    + math.abs(recordA.modelY - recordB.modelY)
  Assert.isTrue(separation > 1e-6, "the two settled pockets carry distinct source framing")

  local presenter = BagHeroPresenter.new({ manifest = manifest, gender = "male" })
  assertFramingNear(
    settledFraming(presenter),
    assert(framing.baseline.male, "the bundle carries the male baseline"),
    "construction opens at the neutral baseline"
  )
  for _ = 1, 7 do
    presenter:updateFixed()
  end
  assertFramingNear(settledFraming(presenter), recordA, "the settled opening pocket matches its source record")
  presenter:selectPocket(pocketB)
  for _ = 1, 7 do
    presenter:updateFixed()
  end
  assertFramingNear(settledFraming(presenter), recordB, "the settled switched pocket matches its source record")

  local presentation = assert(assert(manifest.hero).presentation, "the bundle keeps its presentation facts")
  local camera = assert(presentation.camera, "the reframe keeps the static camera facts")
  Assert.equal(camera.perspectiveType, 0, "the reframe keeps the perspective projection")
  Assert.isTrue(type(presentation.transform) == "table", "the reframe keeps the static base transform facts")

  local expectedProjection = retailProjection()
  local posedA = poseCorners(bundle, "male", pocketA, 7)
  local settledA = projectBounds(
    viewFromFraming(recordA),
    expectedProjection,
    modelFromFraming(recordA),
    posedA.cornersByMesh,
    collectPose(posedA)
  )
  local posedB = poseCorners(bundle, "male", pocketB, 7)
  local settledB = projectBounds(
    viewFromFraming(recordB),
    expectedProjection,
    modelFromFraming(recordB),
    posedB.cornersByMesh,
    collectPose(posedB)
  )
  local moved = math.abs(settledA.minX - settledB.minX)
    + math.abs(settledA.minY - settledB.minY)
    + math.abs(settledA.maxX - settledB.maxX)
    + math.abs(settledA.maxY - settledB.maxY)
  Assert.isTrue(
    moved > PIXEL_TOLERANCE,
    "settling the second pocket moves the projected hero bounds, got total displacement " .. moved
  )
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
