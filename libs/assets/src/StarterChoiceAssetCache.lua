-- Strict validation for the generated choose-starter application assets: the
-- source-independent manifest the retail tabletop/turntable/ball scene
-- compiles to, with semantic animation bindings, normalized scene constants,
-- decoded chooser messages, and species-display sprites. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local Validate = require("libs.assets.src.Validate")

local M = {
  FORMAT = Contract.starterChoice.cacheFormat,
  SCHEMA = Contract.starterChoice.schema,
  MANIFEST_ERROR = "STARTER_CHOICE_MANIFEST_INVALID",
}

local DATA_DIR = "data/generated/starter_choice"
local ASSET_DIR = "assets/generated/starter_choice"

local MODEL_ROLES = { "tabletop", "turntable", "ballEffect", "ball1", "ball2", "ball3" }
local REQUIRED_MODELS = {}
for _, role in ipairs(MODEL_ROLES) do
  REQUIRED_MODELS[role] = true
end

local SPRITE_IDS = { "chikorita", "cyndaquil", "totodile" }
local REQUIRED_SPRITES = {}
for _, id in ipairs(SPRITE_IDS) do
  REQUIRED_SPRITES[id] = true
end

---@param message string
---@return boolean, Errors.Error?
local function invalid(message, context)
  return false, Errors.new(M.MANIFEST_ERROR, message, context or {})
end

---@param value unknown
---@return boolean
local function finite(value)
  return type(value) == "number" and value == value and value < math.huge and value > -math.huge
end

---@param label string
---@param allowed table<string, boolean>
---@return boolean, Errors.Error?
local function closedRecord(label, value, allowed)
  if type(value) ~= "table" then
    return invalid(label .. " is invalid", {})
  end
  for key in pairs(value) do
    if not allowed[key] then
      return invalid(label .. " has an unknown field " .. tostring(key), {})
    end
  end
  return true
end

---@return string
function M.dir()
  return DATA_DIR
end

---@return string
function M.assetDir()
  return ASSET_DIR
end

---@return string
function M.manifestPath()
  return DATA_DIR .. "/starter_choice.lua"
end

---@return string
function M.markerPath()
  return DATA_DIR .. "/complete"
end

---@param romSha1 string
---@param dependencyHash string
---@return string
function M.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", M.FORMAT, romSha1, dependencyHash)
end

---@param binding string|integer
---@param what string
---@return boolean, Errors.Error?
local function checkBinding(desc, binding, what)
  local animations = desc.animations
  if type(animations) ~= "table" then
    return invalid(what .. " owns no compiled animations", {})
  end
  if type(binding) == "string" then
    if binding == "" then
      return invalid(what .. " binding is empty", {})
    end
    for _, clip in ipairs(animations) do
      if clip.id == binding or clip.name == binding then
        return true
      end
    end
    return invalid(what .. " binding " .. binding .. " resolves to no clip on its model", {})
  end
  if type(binding) == "number" and binding % 1 == 0 then
    if animations[binding] == nil then
      return invalid(what .. " binding index " .. tostring(binding) .. " is out of range", {})
    end
    return true
  end
  return invalid(what .. " binding must name a clip or a descriptor-local index", {})
end

---@return boolean, Errors.Error?
local function checkAnimations(models, animations)
  local ok, err = closedRecord("manifest animations", animations, {
    ballRock = true,
    ballOpen = true,
    ballEffect = true,
    turntable = true,
  })
  if not ok then
    return false, err
  end
  if not Validate.isArray(animations.ballRock) or #animations.ballRock ~= 3 then
    return invalid("manifest animations ballRock must carry exactly three bindings", {})
  end
  for index, binding in ipairs(animations.ballRock) do
    local bindingOk, bindingErr = checkBinding(models["ball" .. index], binding, "ball rock binding " .. index)
    if not bindingOk then
      return false, bindingErr
    end
  end
  for _, role in ipairs({ "ball1", "ball2", "ball3" }) do
    local openOk, openErr = checkBinding(models[role], animations.ballOpen, "ball open binding on " .. role)
    if not openOk then
      return false, openErr
    end
  end
  local effectOk, effectErr = checkBinding(models.ballEffect, animations.ballEffect, "ball effect binding")
  if not effectOk then
    return false, effectErr
  end
  return checkBinding(models.turntable, animations.turntable, "turntable binding")
end

---@param label string
---@param distance number
---@return boolean, Errors.Error?
local function checkCameraEnd(label, value, target, distance)
  local ok, err = closedRecord(label, value, { angleX = true, perspective = true, target = true, distance = true })
  if not ok then
    return false, err
  end
  if not finite(value.angleX) or not finite(value.perspective) then
    return invalid(label .. " angle and perspective must be finite numbers", {})
  end
  local targetOk, targetErr = closedRecord(label .. " target", value.target, { x = true, y = true, z = true })
  if not targetOk then
    return false, targetErr
  end
  if value.target.x ~= target.x or value.target.y ~= target.y or value.target.z ~= target.z then
    return invalid(label .. " target does not match the retail camera target", {})
  end
  if value.distance ~= distance then
    return invalid(label .. " distance does not match the retail camera distance", {})
  end
  return true
end

---@return boolean, Errors.Error?
local function checkScene(scene)
  local ok, err = closedRecord("manifest scene", scene, {
    ballPositions = true,
    camera = true,
    ballYRotation = true,
    wobble = true,
  })
  if not ok then
    return false, err
  end
  if not Validate.isArray(scene.ballPositions) or #scene.ballPositions ~= 3 then
    return invalid("manifest scene must carry exactly three ball positions", {})
  end
  local seen = {}
  for index, position in ipairs(scene.ballPositions) do
    local positionOk, positionErr = closedRecord("ball position " .. index, position, { x = true, y = true, z = true })
    if not positionOk then
      return false, positionErr
    end
    if not finite(position.x) or not finite(position.y) or not finite(position.z) then
      return invalid("ball position " .. index .. " coordinates must be finite numbers", {})
    end
    local key = position.x .. "," .. position.y .. "," .. position.z
    if seen[key] then
      return invalid("ball positions must be distinct", {})
    end
    seen[key] = true
  end
  local camera = scene.camera
  local cameraOk, cameraErr =
    closedRecord("manifest scene camera", camera, { out = true, inside = true, transitionTicks = true })
  if not cameraOk then
    return false, cameraErr
  end
  local outOk, outErr = checkCameraEnd("outside camera", camera.out, { x = 0, y = 0, z = 14 }, 100)
  if not outOk then
    return false, outErr
  end
  local insideOk, insideErr = checkCameraEnd("inside camera", camera.inside, { x = 0, y = 0, z = 12 }, 60)
  if not insideOk then
    return false, insideErr
  end
  if camera.transitionTicks ~= 8 then
    return invalid("camera transition must last eight ticks", {})
  end
  local rotationOk, rotationErr =
    closedRecord("manifest scene ballYRotation", scene.ballYRotation, { out = true, inside = true })
  if not rotationOk then
    return false, rotationErr
  end
  if not finite(scene.ballYRotation.out) or not finite(scene.ballYRotation.inside) then
    return invalid("ball Y rotations must be finite numbers", {})
  end
  if type(scene.wobble) ~= "table" then
    return invalid("manifest scene wobble timing is required", {})
  end
  if type(scene.wobble.frameCount) ~= "number" or scene.wobble.frameCount < 1 or scene.wobble.frameCount % 1 ~= 0 then
    return invalid("manifest scene wobble frameCount must be a positive integer", {})
  end
  return true
end

---@param messages table<string, unknown>
---@return boolean, Errors.Error?
local function checkMessages(messages)
  local ok, err = closedRecord("manifest messages", messages, { initial = true, confirm = true })
  if not ok then
    return false, err
  end
  for _, key in ipairs({ "initial", "confirm" }) do
    if type(messages[key]) ~= "string" or messages[key] == "" then
      return invalid("manifest message " .. key .. " must be a decoded non-empty string", {})
    end
  end
  return true
end

---@param id string
---@param entry table<string, unknown>
---@return boolean, Errors.Error?
local function checkSprite(id, entry)
  local ok, err = closedRecord("species sprite " .. id, entry, { image = true, width = true, height = true })
  if not ok then
    return false, err
  end
  if type(entry.image) ~= "string" or entry.image:find(ASSET_DIR .. "/", 1, true) ~= 1 then
    return invalid("species sprite " .. id .. " must use a starter-choice generated path", {})
  end
  if
    type(entry.width) ~= "number"
    or entry.width < 1
    or entry.width % 1 ~= 0
    or type(entry.height) ~= "number"
    or entry.height < 1
    or entry.height % 1 ~= 0
  then
    return invalid("species sprite " .. id .. " dimensions must be positive integers", {})
  end
  return true
end

---@param sprites table<string, unknown>
---@return boolean, Errors.Error?
local function checkSprites(sprites)
  if type(sprites) ~= "table" then
    return invalid("manifest speciesSprites are required", {})
  end
  for id in pairs(sprites) do
    if not REQUIRED_SPRITES[id] then
      return invalid("manifest contains an unknown species sprite " .. tostring(id), {})
    end
  end
  for _, id in ipairs(SPRITE_IDS) do
    if sprites[id] == nil then
      return invalid("manifest is missing species sprite " .. id, {})
    end
    local ok, err = checkSprite(id, sprites[id])
    if not ok then
      return false, err
    end
  end
  return true
end

---@param value unknown
---@param path string
---@return boolean, Errors.Error?
local function checkNoSourceIdentities(value, path)
  if type(value) == "string" then
    if value:find("NARC_", 1, true) ~= nil then
      return invalid(path .. " carries a source archive symbol", {})
    end
    if value:match("^a/%d+/%d+/%d+$") ~= nil then
      return invalid(path .. " carries a source archive path", {})
    end
    return true
  end
  if type(value) ~= "table" then
    return true
  end
  for key, item in pairs(value) do
    if type(key) == "string" and key:find("NARC_", 1, true) ~= nil then
      return invalid(path .. " carries a source archive symbol", {})
    end
    local ok, err = checkNoSourceIdentities(item, path .. "." .. tostring(key))
    if not ok then
      return false, err
    end
  end
  return true
end

---@param manifest table<string, unknown>
---@return boolean, Errors.Error?
function M.validateManifest(manifest)
  if type(manifest) ~= "table" or manifest.schema ~= M.SCHEMA then
    return invalid("manifest schema mismatch", { expected = M.SCHEMA })
  end
  local ok, err = closedRecord("manifest", manifest, {
    schema = true,
    reference = true,
    models = true,
    animations = true,
    scene = true,
    messages = true,
    speciesSprites = true,
  })
  if not ok then
    return false, err
  end
  if type(manifest.reference) ~= "table" or manifest.reference.width ~= 256 or manifest.reference.height ~= 192 then
    return invalid("manifest reference viewport is invalid", {})
  end
  if type(manifest.models) ~= "table" then
    return invalid("manifest models are required", {})
  end
  for role in pairs(manifest.models) do
    if not REQUIRED_MODELS[role] then
      return invalid("manifest contains an unknown model role " .. tostring(role), {})
    end
  end
  for _, role in ipairs(MODEL_ROLES) do
    if manifest.models[role] == nil then
      return invalid("manifest is missing model role " .. role, {})
    end
    local valid, modelErr = pcall(ModelAsset.validate, manifest.models[role])
    if not valid then
      if Errors.is(modelErr) then
        return invalid("model role " .. role .. " is invalid: " .. Errors.format(modelErr), { role = role })
      end
      error(modelErr, 0)
    end
  end
  local animationsOk, animationsErr = checkAnimations(manifest.models, manifest.animations)
  if not animationsOk then
    return false, animationsErr
  end
  local sceneOk, sceneErr = checkScene(manifest.scene)
  if not sceneOk then
    return false, sceneErr
  end
  local messagesOk, messagesErr = checkMessages(manifest.messages)
  if not messagesOk then
    return false, messagesErr
  end
  local spritesOk, spritesErr = checkSprites(manifest.speciesSprites)
  if not spritesOk then
    return false, spritesErr
  end
  return checkNoSourceIdentities(manifest, "manifest")
end

-- Every cache-relative path the manifest references: model geometry and
-- textures plus the species-display sprite images. Raises on a malformed
-- manifest, matching ModelAsset.referencedPaths.
---@param manifest table<string, unknown>
---@return string[]
function M.referencedPaths(manifest)
  assert(M.validateManifest(manifest), "starter-choice manifest is invalid")
  local paths = {}
  for _, role in ipairs(MODEL_ROLES) do
    for _, path in ipairs(ModelAsset.referencedPaths(manifest.models[role])) do
      paths[#paths + 1] = path
    end
  end
  for _, id in ipairs(SPRITE_IDS) do
    paths[#paths + 1] = manifest.speciesSprites[id].image
  end
  return paths
end

function M.isReady(cacheFs, expectedMarker)
  if cacheFs:read(M.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(M.manifestPath())
  if type(manifest) ~= "table" or not M.validateManifest(manifest) then
    return false
  end
  for _, path in ipairs(M.referencedPaths(manifest)) do
    if not cacheFs:exists(path, "file") then
      return false
    end
  end
  return true
end

return M
