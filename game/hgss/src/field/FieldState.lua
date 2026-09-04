-- Interactive presentation over the non-rendering field runtime.

local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldActorPresentation = require("game.hgss.src.field.FieldActorPresentation")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StandardFade = require("libs.hgss.src.presentation.StandardFade")

local KEY_DIRECTIONS =
  { w = "north", up = "north", s = "south", down = "south", a = "west", left = "west", d = "east", right = "east" }
local GAMEPAD_DIRECTIONS = { dpup = "north", dpdown = "south", dpleft = "west", dpright = "east" }

---@class FieldStateOptions
---@field zoomConfig table<string, unknown>? runtime zoom configuration (runtime contract)
---@field development boolean? product mode (the default) hides the playtest HUD
---@field initialFadeIn boolean? one-shot covered entry: first frame fully black, then reveal
---@field topologyProvider (fun(width: number, height: number): ScreenTopology)?
---@field saveStore table<string, unknown>? global GameSaveStore
---@field saveValidation GameSaveValidation? shared version-aware GameSave validator
---@field audioOutput table<string, unknown>? audio-output host namespace for deterministic runtime audio

---@class FieldState
---@field runtime FieldRuntime?
---@field presentationResources FieldPresentationResources?
---@field actorPresentation FieldActorPresentation?
---@field _lastGeometrySignature string? the structural presentation-geometry signature the last sync consumed
---@field _pollPresentationTopology boolean whether injected topology changes are polled during draw
---@field worldParts table[][] ordered map, static building, animated building, neighbor, entrance-indicator, actor, movement-emote, and terrain-effect draw arrays
---@field worldActorItems table[] persistent actor items kept in the world raster
---@field spriteItems table[] persistent presentation-resolution actor sprites
---@field _entryFade StandardFade? one-shot covered-entry reveal, nil when inactive or complete
---@field _entryAccumulator number source-frame time held for the covered-entry reveal
---@field development boolean product mode (default) hides the playtest HUD and ignores the F1/F2 developer binds
---@field topologyProvider fun(width: number, height: number): ScreenTopology
local FieldState = {}
FieldState.__index = FieldState

---@class FieldState.Font
---@field getWidth fun(self: FieldState.Font, text: string): number

local NO_DRAWS = {}

-- The presentation-only covered-entry cadence: one shared-fade step per
-- source frame, isolated from field simulation timing.
local ENTRY_SOURCE_FRAME = 1 / 30
local ENTRY_EPSILON = 1e-12
local ENTRY_MAX_CATCH_UP = 6

local function defaultScreenTopology(width, height)
  local os = love.system and love.system.getOS and love.system.getOS() or ""
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = os == "Android" or os == "iOS",
    role = "world",
  })
end

---@param game table<string, unknown> finalized unpublished game or validated loaded GameSave
---@param options FieldStateOptions?
---@return FieldState
function FieldState.new(game, options)
  options = options or {}
  -- Only the documented runtime contract crosses the boundary: the finalized
  -- or loaded game is the runtime's save authority, while state-only options
  -- such as topologyProvider must never become runtime options.
  local runtimeOptions = {
    zoomConfig = options.zoomConfig,
    presentation = true,
    saveStore = options.saveStore,
    saveValidation = options.saveValidation,
    audioOutput = options.audioOutput,
  }
  -- Construction is binary: FieldRuntime.new either raised (boot failed) or
  -- returned a fully usable runtime, so presentation resources are acquired
  -- unconditionally. A failure here releases the booted runtime exactly once
  -- through the shared disposal and rethrows.
  local runtime = FieldRuntime.new(game, runtimeOptions)
  local self = setmetatable({
    runtime = runtime,
    development = options.development == true,
    topologyProvider = options.topologyProvider or defaultScreenTopology,
    _pollPresentationTopology = options.topologyProvider ~= nil,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    _entryFade = options.initialFadeIn == true and StandardFade.new({ direction = "in", color = 0 }) or nil,
    _entryAccumulator = 0,
  }, FieldState)
  local ok, err = pcall(function()
    self.presentationResources = FieldPresentationResources.new(runtime --[[@as FieldPresentationResourcesRuntime]])
    local width, height = love.graphics.getDimensions()
    -- The initial presentation-geometry sync: pointer input must work
    -- before the user has resized the window, so the runtime computes and
    -- stores the Start Menu placement as soon as the graphics dimensions are
    -- known.
    self:resize(width, height)
    runtime.menuHost:setPresentationMetrics(function(text)
      local font = love.graphics.getFont() --[[@as FieldState.Font]]
      return font:getWidth(text)
    end)
    self.actorPresentation = FieldActorPresentation.new(runtime --[[@as FieldActorPresentationRuntime]])
    self.actorPresentation:sync()
  end)
  if not ok then
    self:dispose()
    error(err)
  end
  return self
end

function FieldState:update(dt)
  self.runtime:update(dt)
  self:_advanceEntryCover(dt)
  assert(self.actorPresentation, "field actor presentation is unavailable"):sync()
end

-- Advances the one-shot covered-entry reveal on the source-frame cadence,
-- never per host-render frame. Simulation timing is untouched; excess time
-- beyond the catch-up budget is discarded like the field fixed tick.
function FieldState:_advanceEntryCover(dt)
  local fade, steps = self._entryFade, 0
  if fade == nil then
    return
  end
  self._entryAccumulator = self._entryAccumulator + dt
  while self._entryAccumulator + ENTRY_EPSILON >= ENTRY_SOURCE_FRAME and steps < ENTRY_MAX_CATCH_UP do
    self._entryAccumulator = self._entryAccumulator - ENTRY_SOURCE_FRAME
    steps = steps + 1
    fade:updateSourceFrame()
    if fade:status().completed then
      break
    end
  end
  if self._entryAccumulator + ENTRY_EPSILON >= ENTRY_SOURCE_FRAME then
    local discarded = math.floor((self._entryAccumulator + ENTRY_EPSILON) / ENTRY_SOURCE_FRAME)
    self._entryAccumulator = self._entryAccumulator - discarded * ENTRY_SOURCE_FRAME
  end
  if fade:status().completed then
    self._entryFade = nil
    self._entryAccumulator = 0
  end
end

-- Single predicate for the covered-entry input gate: while the one-shot
-- reveal is active, new gameplay presses are ignored.
function FieldState:_entryCoverActive()
  return self._entryFade ~= nil
end

-- Every actor the frame draws: the ROM-derived player billboard first, then the
-- object actors the manager considers present. Records stay presentation-neutral;
-- FieldActorDraw turns them into world draw items against the resident visuals.
function FieldState:_actorDraws(alpha)
  return assert(self.actorPresentation, "field actor presentation is unavailable"):drawItems(alpha)
end

-- The surf attachment follows the player's interpolated render position, so
-- it is drawn only when the avatar owner reports an active surf, using the
-- same fixed-tick phase the session steps and the live attachment offset.
---@param alpha number
---@return table[]
function FieldState:_surfDrawItems(alpha)
  local resources = assert(self.presentationResources, "field presentation resources are unavailable")
  local renderer = resources.fieldSurfRenderer
  if renderer == nil then
    return NO_DRAWS
  end
  local runtime = assert(self.runtime, "field runtime is unavailable")
  local avatar = runtime.playerAvatar
  if avatar == nil then
    return NO_DRAWS
  end
  local presentation = avatar:presentationState()
  if not presentation.surf.active then
    return NO_DRAWS
  end
  local anchor = runtime.player:renderPosition(alpha)
  local surfPresentation = assert(resources.surfPresentation, "surf presentation is unavailable")
  local yaw = assert(surfPresentation.yawDegrees[runtime.player.facing], "surf presentation is missing facing yaw")
  return renderer:drawItems({
    visible = true,
    position = {
      x = anchor.x,
      y = anchor.y + presentation.surf.attachmentOffsetY,
      z = anchor.z,
    },
    rotationDegrees = yaw,
    scale = 1,
    fieldEffect = "surf_attachment",
  })
end

-- Refresh the persistent ordered scene parts: the session-owned physical
-- window when outdoor cells are active, otherwise the full logical scene,
-- then actors and transient effects. Logical scene geometry is retained for
-- environment and discontinuous maps but is never drawn alongside cells.
function FieldState:_worldParts(alpha)
  local resources = assert(self.presentationResources, "field presentation resources are unavailable")
  local runtimeMap = self.runtime.runtimeMap
  local worldParts = self.worldParts
  if runtimeMap.coverage then
    worldParts[1] = runtimeMap.coverage:worldParts()
    worldParts[2] = NO_DRAWS
    worldParts[3] = NO_DRAWS
    worldParts[4] = NO_DRAWS
  else
    local sceneRuntime = assert(runtimeMap.sceneRuntime, "field scene presentation is unavailable")
    worldParts[1] = sceneRuntime.mapDraws
    worldParts[2] = sceneRuntime.staticBuildingDraws
    worldParts[3] = sceneRuntime.animatedBuildingDraws
    worldParts[4] = runtimeMap.neighborRuntime and runtimeMap.neighborRuntime.draws or NO_DRAWS
  end
  local indicator = assert(self.runtime.fieldEntranceIndicator, "field entrance indicator is unavailable")
  worldParts[5] = resources.fieldEntranceIndicatorRenderer:drawItems(indicator:status())
  local actorItems = self:_actorDraws(alpha)
  local worldActorItems = self.worldActorItems
  local spriteItems = self.spriteItems
  for index = #worldActorItems, 1, -1 do
    worldActorItems[index] = nil
  end
  for index = #spriteItems, 1, -1 do
    spriteItems[index] = nil
  end
  for _, item in ipairs(actorItems) do
    if item.billboardProjection == true then
      spriteItems[#spriteItems + 1] = item
    else
      worldActorItems[#worldActorItems + 1] = item
    end
  end
  worldParts[6] = worldActorItems
  for _, item in ipairs(self:_surfDrawItems(alpha)) do
    worldActorItems[#worldActorItems + 1] = item
  end
  -- _actorDraws (above) refreshed the actor presentation records with this frame's
  -- presentation-neutral records, which is the only place activeEmoteKind
  -- survives; FieldActorDraw's rendered items do not carry it.
  worldParts[7] = resources.fieldEmoteRenderer:drawItems(assert(self.actorPresentation):records())
  local terrain = self.runtime.fieldTerrainEffectController
  local terrainRenderer = resources.fieldTerrainEffectRenderer
  worldParts[8] = terrainRenderer and terrainRenderer:drawItems(terrain:status(), self.runtime.runtimeMap) or NO_DRAWS
  return worldParts
end

-- The structural presentation-geometry signature: the window dimensions plus
-- every surface identity, role, and safe rectangle. A safe-area change with
-- the same window dimensions must recompute the placement, and a change
-- must not be reported while nothing structural moved (so an active Start
-- Menu pointer capture is not cancelled unnecessarily).
---@param width integer
---@param height integer
---@param topology ScreenTopology
---@return string
function FieldState:_geometrySignature(width, height, topology)
  local parts = { tostring(width), tostring(height) }
  for _, surface in ipairs(topology.surfaces) do
    local safe = surface.safeRect or surface.rect
    parts[#parts + 1] = string.format(
      "|%s:%s:%d:%d:%d:%d",
      tostring(surface.id),
      tostring(surface.role),
      safe.x,
      safe.y,
      safe.width,
      safe.height
    )
  end
  return table.concat(parts)
end

function FieldState:_recordGeometrySignature(width, height, topology)
  self._lastGeometrySignature = self:_geometrySignature(width, height, topology)
end

function FieldState:resize(width, height)
  local provider = self.topologyProvider or defaultScreenTopology
  local topology = provider(width, height)
  self.runtime:resizePresentation(width, height, topology)
  if self._pollPresentationTopology then
    self:_recordGeometrySignature(width, height, topology)
  end
end

function FieldState:_drawFieldAttachedUi(resources, hostStatus, alpha)
  if hostStatus.menu or hostStatus.application then
    return
  end
  local fieldScale = self.runtime.viewport:logicalPixelScale(self.runtime.camera.zoom)
  local bounds = self.runtime.viewport.worldViewport
  if type(bounds) ~= "table" or type(bounds.width) ~= "number" or type(bounds.height) ~= "number" then
    bounds = self.runtime.viewport.referenceFrame
  end
  if type(bounds) ~= "table" or type(bounds.width) ~= "number" or type(bounds.height) ~= "number" then
    bounds = {
      x = 0,
      y = 0,
      width = assert(self.runtime.viewport.width),
      height = assert(self.runtime.viewport.height),
    }
  end
  bounds = {
    x = bounds.x,
    y = bounds.y,
    width = math.max(bounds.width, 256 * fieldScale),
    height = math.max(bounds.height, 48 * fieldScale),
  }
  if self.runtime.dialogue:isModal() then
    local manifestPlacement = assert(self.runtime.uiManifest).dialogueFrames.continueCursor.placement
    local presentation = DialoguePresentationLayout.compute(bounds, {
      scale = fieldScale,
      cursorPlacement = manifestPlacement,
    })
    resources.dialogueRenderer:draw(self.runtime.dialogue, self.runtime.viewport, fieldScale, presentation)
  end
  if self.runtime.signpost:isModal() then
    resources.signpostRenderer:draw(self.runtime.signpost, self.runtime.viewport, alpha, fieldScale)
  end
end

function FieldState:draw()
  local lg = love.graphics
  local resources = assert(self.presentationResources, "field presentation resources are unavailable")
  if self.runtime.errorText then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Field runtime failed:", 24, 24)
    lg.printf(self.runtime.errorText, 24, 48, lg.getWidth() - 48)
    return
  end
  local width, height = lg.getDimensions()
  assert(width and height, "graphics dimensions are required for field presentation")
  assert(width % 1 == 0 and height % 1 == 0, "graphics dimensions must be integral")
  width, height =
    width, --[[@as integer]]
    height --[[@as integer]]
  local resized = false
  if width ~= self.runtime.viewport.width or height ~= self.runtime.viewport.height then
    self:resize(width, height)
    resized = true
  end
  if self._pollPresentationTopology and not resized then
    local provider = self.topologyProvider or defaultScreenTopology
    local topology = provider(width, height)
    local integerWidth = width --[[@as integer]]
    local integerHeight = height --[[@as integer]]
    if self:_geometrySignature(integerWidth, integerHeight, topology) ~= self._lastGeometrySignature then
      -- Injected providers remain polling-enabled so same-size structural
      -- topology changes still reach the runtime geometry owner.
      self.runtime:resizePresentation(integerWidth, integerHeight, topology)
      self:_recordGeometrySignature(width, height, topology)
    end
  end
  assert(
    type(self.runtime.destinationWorldPresentable) == "function",
    "field runtime destination presentation capability required"
  )
  if not self.runtime:destinationWorldPresentable() then
    self:_drawScriptScreenFadeIfNeeded()
    return
  end
  local alpha = self.runtime.session:renderAlpha()
  resources.renderer:draw(
    self.runtime.runtimeMap.sceneRuntime,
    self.runtime.camera,
    self:_worldParts(alpha),
    self.spriteItems,
    self.runtime.viewport,
    alpha
  )
  assert(
    type(self.runtime.acknowledgeDestinationPresentation) == "function",
    "field runtime destination presentation acknowledgement required"
  )
  self.runtime:acknowledgeDestinationPresentation()
  -- The field/application fade: the host-owned application fade covers
  -- the surface being transitioned (the world viewport plus the Start Menu
  -- placement frame), then the unrelated warp fade over the world viewport.
  local hostStatus = self.runtime.applicationHost:status()
  if hostStatus.fadeAlpha > 0 then
    self:_drawApplicationFade(hostStatus.fadeAlpha)
  end
  local transitionStatus
  if type(self.runtime.transition.presentationStatus) == "function" then
    transitionStatus = self.runtime.transition:presentationStatus()
  else
    transitionStatus = {
      overlay = self.runtime.transition.fadeAlpha > 0 and {
        r = 0,
        g = 0,
        b = 0,
        a = self.runtime.transition.fadeAlpha,
      } or nil,
    }
  end
  local transitionOverlay = transitionStatus.overlay
  if transitionOverlay then
    local rectangle = self.runtime.viewport.worldViewport
    lg.setColor(transitionOverlay.r, transitionOverlay.g, transitionOverlay.b, transitionOverlay.a)
    lg.rectangle("fill", rectangle.x, rectangle.y, rectangle.width, rectangle.height)
  end
  -- Attached dialogue and signposts share the field scale and yield to modal
  -- application surfaces.
  self:_drawFieldAttachedUi(resources, hostStatus, alpha)
  -- The one active application surface: the Start Menu through the runtime's
  -- placement record (the same record the host maps pointer input through),
  -- the Trainer Card in the viewport, or the party screen with its icon
  -- atlas; never more than one.
  if hostStatus.menu then
    resources.startMenuRenderer:draw(hostStatus.menu, assert(self.runtime.startMenuPlacement))
  elseif hostStatus.application then
    if hostStatus.applicationId == FieldApplicationIds.POKEMON then
      assert(resources.partyScreenRenderer, "party screen renderer is unavailable"):draw(
        hostStatus.application,
        assert(hostStatus.application.layout, "the party application presents its layout"),
        assert(resources.monIconProvider, "party icon provider is unavailable")
      )
    else
      resources.trainerCardRenderer:draw(hostStatus.application, self.runtime.viewport)
    end
  end
  local presentation = self.runtime.menuHost:presentation()
  if presentation then
    resources.menuRenderer:draw(presentation)
  end
  self:_drawEntryCoverIfNeeded(width, height)
  -- The script-owned starter modal draws over the restored field while the
  -- blocking choice owns it. Portraits load once on first presentation;
  -- headless compositions never reach this path.
  local starter = self.runtime.starterChoice
  if starter ~= nil and starter:isActive() then
    starter:drawPresentation(assert(resources.textRenderer, "field text renderer is unavailable"), width, height)
  end
  if self.development then
    self:_drawHud()
  end
  self:_drawScriptScreenFadeIfNeeded()
end

local function rectUnion(existing, rect)
  if #existing == 0 then
    return { { x = rect.x, y = rect.y, width = rect.width, height = rect.height } }
  end
  -- Start with rect, subtract every existing rect using axis-aligned subtraction.
  local pending = { { x = rect.x, y = rect.y, width = rect.width, height = rect.height } }
  local result = {}
  for _, ex in ipairs(existing) do
    result[#result + 1] = ex
  end
  local nextPending = {}
  for _, piece in ipairs(pending) do
    -- Subtract existing rects one by one
    local pieces = { piece }
    for _, ex in ipairs(existing) do
      local newPieces = {}
      for _, p in ipairs(pieces) do
        local px2, py2 = p.x + p.width, p.y + p.height
        local ex2x, ex2y = ex.x + ex.width, ex.y + ex.height
        local ix1, iy1 = math.max(p.x, ex.x), math.max(p.y, ex.y)
        local ix2, iy2 = math.min(px2, ex2x), math.min(py2, ex2y)
        if ix2 <= ix1 or iy2 <= iy1 then
          newPieces[#newPieces + 1] = p
        else
          if p.x < ix1 then
            newPieces[#newPieces + 1] = { x = p.x, y = p.y, width = ix1 - p.x, height = p.height }
          end
          if px2 > ix2 then
            newPieces[#newPieces + 1] = { x = ix2, y = p.y, width = px2 - ix2, height = p.height }
          end
          if p.y < iy1 then
            newPieces[#newPieces + 1] = { x = ix1, y = p.y, width = ix2 - ix1, height = iy1 - p.y }
          end
          if py2 > iy2 then
            newPieces[#newPieces + 1] = { x = ix1, y = iy2, width = ix2 - ix1, height = py2 - iy2 }
          end
        end
      end
      pieces = newPieces
    end
    for _, p in ipairs(pieces) do
      nextPending[#nextPending + 1] = p
    end
  end
  for _, p in ipairs(nextPending) do
    result[#result + 1] = p
  end
  return result
end

function FieldState:_drawScriptScreenFadeIfNeeded()
  local screenFade = self.runtime.screenFade
  if screenFade == nil then
    return
  end
  local status = screenFade:status()
  if status.overlay == nil then
    return
  end
  local topology = self.runtime.screenTopology
  assert(topology ~= nil and type(topology.surfaces) == "table", "script screen fade requires a current topology")
  local surfaces = topology.surfaces
  local rects = {}
  for _, surface in ipairs(surfaces) do
    rects = rectUnion(rects, surface.rect)
  end
  local lg = love.graphics
  local overlay = status.overlay
  local prevR, prevG, prevB, prevA = lg.getColor()
  lg.setColor(overlay.r, overlay.g, overlay.b, overlay.a)
  for _, rect in ipairs(rects) do
    lg.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  end
  lg.setColor(prevR, prevG, prevB, prevA)
end

-- The one-shot covered-entry overlay: full current presentation surface at
-- the shared fade coefficient, drawn after the field world and UI it
-- covers. Dimensions are read fresh every frame so a mid-reveal resize
-- stays fully covered; the fade object is dropped once complete.
---@param width number
---@param height number
function FieldState:_drawEntryCoverIfNeeded(width, height)
  local fade = self._entryFade
  if fade == nil then
    return
  end
  local coefficient = fade:status().coefficient
  if coefficient <= 0 then
    return
  end
  local lg = love.graphics
  lg.setColor(0, 0, 0, coefficient / 16)
  lg.rectangle("fill", 0, 0, width, height)
end

-- The application fade coverage: the world viewport plus the Start Menu
-- placement frame as a set of non-overlapping rectangles, so the union of
-- separated surfaces is painted once each and the gap between them never is.
-- The world rect is always painted; the frame contributes only the strips
-- outside its intersection with the world (a fully contained frame adds
-- nothing, so no region is alpha-doubled).
---@param world ScreenTopology.Rectangle
---@param frame ScreenTopology.Rectangle
---@return ScreenTopology.Rectangle[]
local function fadeRects(world, frame)
  local rects = { world }
  local ix = math.max(world.x, frame.x)
  local iy = math.max(world.y, frame.y)
  local ix2 = math.min(world.x + world.width, frame.x + frame.width)
  local iy2 = math.min(world.y + world.height, frame.y + frame.height)
  if ix2 <= ix or iy2 <= iy then
    -- Disjoint surfaces: the frame is painted in full.
    rects[#rects + 1] = frame
    return rects
  end
  if frame.x < ix then
    rects[#rects + 1] = { x = frame.x, y = frame.y, width = ix - frame.x, height = frame.height }
  end
  if frame.x + frame.width > ix2 then
    rects[#rects + 1] = { x = ix2, y = frame.y, width = frame.x + frame.width - ix2, height = frame.height }
  end
  if frame.y < iy then
    rects[#rects + 1] = { x = ix, y = frame.y, width = ix2 - ix, height = iy - frame.y }
  end
  if frame.y + frame.height > iy2 then
    rects[#rects + 1] = { x = ix, y = iy2, width = ix2 - ix, height = frame.y + frame.height - iy2 }
  end
  return rects
end

-- The application fade: the union of the world viewport and the Start Menu
-- placement frame, so on a dual-display topology the auxiliary surface region
-- goes black with the world and no menu surface can stay visible while only
-- the world viewport fades. Disjoint surfaces paint as separate rectangles
-- (the gap between them stays untouched), and overlapping regions are
-- painted once, never twice.
---@param alpha number
function FieldState:_drawApplicationFade(alpha)
  local lg = love.graphics
  local world = self.runtime.viewport.worldViewport
  local frame = assert(self.runtime.startMenuPlacement, "the application fade requires the placement record").frame
  lg.setColor(0, 0, 0, alpha)
  for _, rect in
    ipairs(fadeRects(world, frame --[[@as ScreenTopology.Rectangle]]))
  do
    lg.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  end
end

-- The playtest HUD: map identity, the player's field state, the save status,
-- and the controls. Everything else stays out of the frame until the real
-- game UI replaces even this.
function FieldState:_drawHud()
  local lg = love.graphics
  local lines = {
    string.format("map %d  %s", self.runtime.runtimeMap.mapId, self.runtime.runtimeMap.mapSymbol),
    string.format(
      "player (%d,%d) y %.3f surface %d %s %s",
      self.runtime.player.fieldX,
      self.runtime.player.fieldZ,
      self.runtime.player.worldY,
      self.runtime.player.surfaceId,
      self.runtime.player.facing,
      self.runtime.player.motion
    ),
    self.runtime.saveStatus or "save not written this run",
    "WASD/arrows move   Z/Space/Enter action   X/Backspace cancel   M menu   -/= zoom" .. "   0 reset zoom   Esc quit",
  }
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 12, 12, 900, 20 * #lines + 12)
  lg.setColor(0.9, 0.95, 1)
  for index, line in ipairs(lines) do
    lg.print(line, 20, 12 + (index - 1) * 20)
  end
end

---@param key string
function FieldState:keypressed(key, _, _)
  if key == "escape" then
    love.event.quit(0)
  end
  if self:_entryCoverActive() then
    return
  end
  if self.runtime.actionKeys[key] then
    self.runtime.input:pressAction("key:" .. key)
  end
  if self.runtime.cancelKeys[key] then
    self.runtime.input:pressCancel("key:" .. key)
  end
  if self.runtime.menuKeys[key] then
    self.runtime.input:pressMenu("key:" .. key)
  end
  if key == "-" or key == "kp-" then
    self.runtime.zoom:zoomOut()
    self.runtime:applyZoomChange()
    return
  end
  if key == "=" or key == "+" or key == "kp+" then
    self.runtime.zoom:zoomIn()
    self.runtime:applyZoomChange()
    return
  end
  if key == "0" or key == "kp0" then
    self.runtime.zoom:reset()
    self.runtime:applyZoomChange()
    return
  end
  local direction = KEY_DIRECTIONS[key]
  if direction then
    self.runtime.input:pressDirection(direction, "key:" .. key)
  end
end

---@param key string
function FieldState:keyreleased(key, _)
  -- Release mirrors press: one physical key may drive several held semantic
  -- states (e.g. Action bound to an arrow key), so every matching binding
  -- releases, never just the first.
  if self.runtime.actionKeys[key] then
    self.runtime.input:releaseAction("key:" .. key)
  end
  if self.runtime.cancelKeys[key] then
    self.runtime.input:releaseCancel("key:" .. key)
  end
  if self.runtime.menuKeys[key] then
    self.runtime.input:releaseMenu("key:" .. key)
  end
  local direction = KEY_DIRECTIONS[key]
  if direction then
    self.runtime.input:releaseDirection("key:" .. key)
  end
end

-- Focus loss clears held and edge state so a blurred window cannot feed a
-- stale Action into the next frame's dialogue or movement.
---@param focused boolean
function FieldState:focus(focused)
  if not focused then
    self.runtime.input:clearAll()
  end
end

-- Gamepad Action is the south face button ("a"), Cancel the east face
-- button ("b"), and Menu the west face button ("x"), mapped alongside the
-- keyboard bindings. The physical source identity includes the joystick id
-- so two pads cannot alias one button.
---@param joystick love.Joystick
---@param button string
function FieldState:gamepadpressed(joystick, button)
  if self:_entryCoverActive() then
    return
  end
  local source = "gamepad:" .. joystick:getID() .. ":" .. button
  if button == "a" then
    self.runtime.input:pressAction(source)
  end
  if button == "b" then
    self.runtime.input:pressCancel(source)
  end
  if button == "x" then
    self.runtime.input:pressMenu(source)
  end
  local direction = GAMEPAD_DIRECTIONS[button]
  if direction then
    self.runtime.input:pressDirection(direction, source)
  end
end

---@param joystick love.Joystick
---@param button string
function FieldState:gamepadreleased(joystick, button)
  local source = "gamepad:" .. joystick:getID() .. ":" .. button
  if button == "a" then
    self.runtime.input:releaseAction(source)
  end
  if button == "b" then
    self.runtime.input:releaseCancel(source)
  end
  if button == "x" then
    self.runtime.input:releaseMenu(source)
  end
  local direction = GAMEPAD_DIRECTIONS[button]
  if direction then
    self.runtime.input:releaseDirection(source)
  end
end

-- FieldInput owns the paired-axis cache and hysteresis so all physical
-- directions enter the same source-aware state machine.
---@param joystick love.Joystick
---@param axis string
---@param value number
function FieldState:gamepadaxis(joystick, axis, value)
  if axis ~= "leftx" and axis ~= "lefty" then
    return
  end
  if self:_entryCoverActive() then
    return
  end
  local source = "gamepad:" .. joystick:getID() .. ":left"
  self.runtime.input:setStickAxis(source, axis == "leftx" and "x" or "y", value)
end

---@param x number
---@param y number
---@param button integer
function FieldState:mousepressed(x, y, button, _, _)
  if self:_entryCoverActive() then
    return
  end
  if button == 1 then
    self.runtime.input:pointerDown("mouse:1", x, y)
  end
end

---@param x number
---@param y number
---@param istouch boolean
function FieldState:mousemoved(x, y, _, _, istouch)
  if self:_entryCoverActive() then
    return
  end
  if not istouch then
    self.runtime.input:pointerMove("mouse:1", x, y)
  end
end

---@param x number
---@param y number
---@param button integer
function FieldState:mousereleased(x, y, button, _, _)
  if button == 1 then
    self.runtime.input:pointerUp("mouse:1", x, y)
  end
end

---@param x number
---@param y number
function FieldState:wheelmoved(x, y)
  if self:_entryCoverActive() then
    return
  end
  self.runtime.input:pointerScroll("mouse", x, y)
end

---@param id unknown
---@param x number
---@param y number
function FieldState:touchpressed(id, x, y)
  if self:_entryCoverActive() then
    return
  end
  self.runtime.input:pointerDown("touch:" .. tostring(id), x, y)
end

---@param id unknown
---@param x number
---@param y number
function FieldState:touchmoved(id, x, y)
  if self:_entryCoverActive() then
    return
  end
  self.runtime.input:pointerMove("touch:" .. tostring(id), x, y)
end

---@param id unknown
---@param x number
---@param y number
function FieldState:touchreleased(id, x, y)
  self.runtime.input:pointerUp("touch:" .. tostring(id), x, y)
end

function FieldState:dispose()
  self._entryFade = nil
  self._entryAccumulator = 0
  self._lastGeometrySignature = nil
  if self.worldParts then
    self.worldParts[5] = nil
    self.worldParts[7] = nil
    self.worldParts[8] = nil
  end
  self.worldActorItems = nil
  self.spriteItems = nil
  if self.actorPresentation then
    self.actorPresentation:dispose()
    self.actorPresentation = nil
  end
  if self.presentationResources then
    self.presentationResources:dispose()
    self.presentationResources = nil
  end
  if self.runtime then
    self.runtime:dispose()
    self.runtime = nil
  end
end

return FieldState
