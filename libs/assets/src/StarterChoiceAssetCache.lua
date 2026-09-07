-- Strict validation for the generated choose-starter application assets: the
-- source-independent manifest the retail tabletop/turntable/ball scene
-- compiles to, with semantic animation bindings, source-derived scene
-- geometry/timing facts, the complete semantic message roles, and the
-- chooser-owned generated backdrop. Candidate pictures are not part of this
-- family; portraits resolve through the mon presentation pipeline. Pure
-- domain module.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
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

---@param layout table<string, unknown>
---@return boolean, Errors.Error?
local function checkBallLayout(layout)
  local ok, err = closedRecord("manifest scene ballLayout", layout, {
    radius = true,
    modelY = true,
    touchYOffsetY = true,
    slotAnglesDegrees = true,
    inspectArcDegrees = true,
  })
  if not ok then
    return false, err
  end
  if layout.radius ~= 32 then
    return invalid("ball layout radius must be the source ring radius 32", {})
  end
  if layout.modelY ~= 14 then
    return invalid("ball layout modelY must be the source model height 14", {})
  end
  if layout.touchYOffsetY ~= 13 then
    return invalid("ball layout touchYOffsetY must be the source touch offset 13", {})
  end
  if not Validate.isArray(layout.slotAnglesDegrees) or #layout.slotAnglesDegrees ~= 3 then
    return invalid("ball layout must carry exactly three slot angles", {})
  end
  for index, angle in ipairs(layout.slotAnglesDegrees) do
    if angle ~= ({ 0, 120, 240 })[index] then
      return invalid("ball layout slot angle " .. index .. " must match the source ring", {})
    end
  end
  if not finite(layout.inspectArcDegrees) or math.abs(layout.inspectArcDegrees - -30.76) > 0.01 then
    return invalid("ball layout inspectArcDegrees must be the source arc endpoint", {})
  end
  return true
end

---@param turntable table<string, unknown>
---@return boolean, Errors.Error?
local function checkTurntable(turntable)
  local ok, err = closedRecord("manifest scene turntable", turntable, {
    selectionStepDegrees = true,
    rotationDegreesPerTick = true,
  })
  if not ok then
    return false, err
  end
  if turntable.selectionStepDegrees ~= 120 then
    return invalid("turntable selection step must span a third of the ring", {})
  end
  if not finite(turntable.rotationDegreesPerTick) or math.abs(turntable.rotationDegreesPerTick - 0.5) > 1e-9 then
    return invalid("turntable rotation rate must match the source rate", {})
  end
  return true
end

---@param timing table<string, unknown>
---@return boolean, Errors.Error?
local function checkTiming(timing)
  local ok, err = closedRecord("manifest scene timing", timing, {
    cameraTicks = true,
    ballArcTicks = true,
    smallWobbleFrame = true,
    infoFadeTicks = true,
    machineFadeTicks = true,
  })
  if not ok then
    return false, err
  end
  if timing.cameraTicks ~= 8 then
    return invalid("camera path must last eight source steps", {})
  end
  if timing.ballArcTicks ~= 8 then
    return invalid("inspect arc must last eight source steps", {})
  end
  if timing.smallWobbleFrame ~= 80 then
    return invalid("small-wobble phase must carry the source frame", {})
  end
  if timing.infoFadeTicks ~= 10 then
    return invalid("info fade must carry the source boundary", {})
  end
  if timing.machineFadeTicks ~= 16 then
    return invalid("machine fade must carry the source boundary", {})
  end
  return true
end

---@param scene table<string, unknown>
---@return boolean, Errors.Error?
local function checkScene(scene)
  local ok, err = closedRecord("manifest scene", scene, {
    ballLayout = true,
    turntable = true,
    camera = true,
    timing = true,
  })
  if not ok then
    return false, err
  end
  local layoutOk, layoutErr = checkBallLayout(scene.ballLayout)
  if not layoutOk then
    return false, layoutErr
  end
  local turntableOk, turntableErr = checkTurntable(scene.turntable)
  if not turntableOk then
    return false, turntableErr
  end
  local camera = scene.camera
  local cameraOk, cameraErr = closedRecord("manifest scene camera", camera, { out = true, inside = true })
  if not cameraOk then
    return false, cameraErr
  end
  local outOk, outErr = checkCameraEnd("outside camera", camera.out, { x = 0, y = 15, z = 14 }, 100)
  if not outOk then
    return false, outErr
  end
  local insideOk, insideErr = checkCameraEnd("inside camera", camera.inside, { x = 0, y = 0, z = 12 }, 60)
  if not insideOk then
    return false, insideErr
  end
  if not (camera.out.perspective > camera.inside.perspective) then
    return invalid("outside view must be wider than inside", {})
  end
  return checkTiming(scene.timing)
end

---@param glyph table<string, unknown>
---@param what string
---@return boolean, Errors.Error?
local function checkGlyph(glyph, what)
  local ok, err = closedRecord(what, glyph, { kind = true, code = true, colorIndex = true })
  if not ok then
    return false, err
  end
  if glyph.kind ~= "glyph" then
    return invalid(what .. " must be a glyph operation", {})
  end
  if type(glyph.code) ~= "number" or glyph.code % 1 ~= 0 or glyph.code < 0 or glyph.code > 65535 then
    return invalid(what .. " code must be an integer 0..65535", {})
  end
  if
    type(glyph.colorIndex) ~= "number"
    or glyph.colorIndex % 1 ~= 0
    or glyph.colorIndex < 0
    or glyph.colorIndex >= FieldMessageText.COLOR_VARIANT_COUNT
  then
    return invalid(
      what .. " colorIndex must be an integer 0.." .. tostring(FieldMessageText.COLOR_VARIANT_COUNT - 1),
      {}
    )
  end
  return true
end

---@param message table<string, unknown>
---@param what string
---@return boolean, Errors.Error?
local function checkMessageRecord(message, what)
  local ok, err = closedRecord(what, message, { lines = true })
  if not ok then
    return false, err
  end
  if not Validate.isArray(message.lines) or #message.lines < 1 or #message.lines > 2 then
    return invalid(what .. " must carry one or two lines", {})
  end
  for index, line in ipairs(message.lines) do
    if type(line) ~= "table" or not Validate.isArray(line) or #line < 1 then
      return invalid(what .. " line " .. index .. " must be a non-empty glyph array", {})
    end
    for glyphIndex, glyph in ipairs(line) do
      local glyphOk, glyphErr = checkGlyph(glyph, what .. " line " .. index .. " glyph " .. glyphIndex)
      if not glyphOk then
        return false, glyphErr
      end
    end
  end
  return true
end

---@param messages table<string, unknown>
---@return boolean, Errors.Error?
local function checkMessages(messages)
  local ok, err = closedRecord("manifest messages", messages, {
    topInitial = true,
    inspect = true,
    confirm = true,
    bottom = true,
  })
  if not ok then
    return false, err
  end
  local initialOk, initialErr = checkMessageRecord(messages.topInitial, "manifest message topInitial")
  if not initialOk then
    return false, initialErr
  end
  for _, key in ipairs({ "inspect", "confirm" }) do
    if not Validate.isArray(messages[key]) or #messages[key] ~= 3 then
      return invalid("manifest messages " .. key .. " must carry one description per slot", {})
    end
    for index, text in ipairs(messages[key]) do
      local textOk, textErr = checkMessageRecord(text, "manifest message " .. key .. "[" .. index .. "]")
      if not textOk then
        return false, textErr
      end
    end
  end
  local bottom = messages.bottom
  local bottomOk, bottomErr = closedRecord("manifest messages bottom", bottom, { normal = true, confirm = true })
  if not bottomOk then
    return false, bottomErr
  end
  local normalOk, normalErr = checkMessageRecord(bottom.normal, "manifest message bottom.normal")
  if not normalOk then
    return false, normalErr
  end
  return checkMessageRecord(bottom.confirm, "manifest message bottom.confirm")
end

---@param label string
---@param entry table<string, unknown>
---@return boolean, Errors.Error?
local function checkBackdropEntry(label, entry)
  local ok, err = closedRecord(label, entry, { image = true, width = true, height = true })
  if not ok then
    return false, err
  end
  if type(entry.image) ~= "string" or entry.image:find(ASSET_DIR .. "/", 1, true) ~= 1 then
    return invalid(label .. " must use a starter-choice generated path", {})
  end
  if
    type(entry.width) ~= "number"
    or entry.width < 1
    or entry.width % 1 ~= 0
    or type(entry.height) ~= "number"
    or entry.height < 1
    or entry.height % 1 ~= 0
  then
    return invalid(label .. " dimensions must be positive integers", {})
  end
  return true
end

---@param background table<string, unknown>
---@return boolean, Errors.Error?
local function checkBackground(background)
  if type(background) ~= "table" then
    return invalid("manifest background is required", {})
  end
  return checkBackdropEntry("manifest background", background)
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
    background = true,
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
  local backgroundOk, backgroundErr = checkBackground(manifest.background)
  if not backgroundOk then
    return false, backgroundErr
  end
  return checkNoSourceIdentities(manifest, "manifest")
end

-- Every cache-relative path the manifest references: model geometry and
-- textures plus the chooser-owned backdrop image. Raises on a malformed
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
  local background = manifest.background
  paths[#paths + 1] = background.image
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
