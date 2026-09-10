-- Script player facade avatar-transition coverage: the generated queue/apply
-- carriers delegate to the one avatar-transition owner through production
-- FieldScripts composition, the scheduler timing matches the source
-- queue/yield/apply contract, and map swaps rebind the live player while
-- keeping the same owner (pending transitions belong to the session, not to
-- a map object instance).

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldScripts = require("game.hgss.src.field.FieldScripts")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldPlayerAvatarState = require("libs.hgss.src.actors.FieldPlayerAvatarState")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")

local T = { tests = {} }
local SCRIPT_GENERATION = string.rep("a", 40)
local SCRIPT_MARKER = "script-cache-v4:rom-sha:dep-sha"

local VISUAL_STATES = {
  "walking",
  "cycling",
  "surfing",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

local SLICE_ID = "test.avatar_heal_slice"
local SLICE_CHUNK = [[
return {
  api = 1,
  id = "test.avatar_heal_slice",
  steps = {
    { op = "queue_avatar_transition", transition = "heal" },
    { op = "yield_tick" },
    { op = "apply_avatar_transitions" },
    { op = "play_sound", sound = "SEQ_SLICE_MARK" },
    { op = "queue_avatar_transition", transition = "walking" },
    { op = "yield_tick" },
    { op = "apply_avatar_transitions" },
    { op = "play_sound", sound = "SEQ_SLICE_RESTORED" },
    { op = "stop" },
  },
}
]]

local function capability()
  local states = {}
  for index, name in ipairs(VISUAL_STATES) do
    states[name] = 1000 + index
  end
  return { id = "hero", gender = 0, states = states }
end

local function surfPresentation()
  return {
    initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
    playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
    yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
  }
end

local function overrideFs(files)
  local ids = {}
  for id in pairs(files) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local manifest = "return {"
  for index, id in ipairs(ids) do
    manifest = manifest .. string.format("%q%s", id, index < #ids and ", " or "")
  end
  manifest = manifest .. "}\n"
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return manifest
      end
      for id, content in pairs(files) do
        if path == ScriptOverrides.DIR .. "/" .. id .. ".lua" then
          return content
        end
      end
      return nil
    end,
  }
end

local function stubActors()
  local function noop() end
  return {
    getActor = function()
      return nil
    end,
    show = noop,
    hide = noop,
    setPosition = noop,
    setFacing = noop,
    setMovementType = noop,
    setAnimationPaused = noop,
    getPosition = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    getFacing = function()
      return "south"
    end,
    numericId = function()
      return nil
    end,
    actorIdForMapIndex = function()
      return nil
    end,
    cameraTargetId = function()
      return nil
    end,
    partnerId = function()
      return nil
    end,
    isVisible = function()
      return true
    end,
    setPresentationOffset = noop,
    clearPresentationOffset = noop,
  }
end

-- Build production FieldScripts around the real transition owner. `files`
-- selects the override layer: empty for bare facade tests, the heal slice
-- for scheduler-driven choreography. `avatarComposition` selects which
-- collaborators enter the production constructor: both by default, neither,
-- or one half for constructor-failure coverage. The materializer mirrors the
-- runtime composition: it applies pending transitions through the owner,
-- swaps the recording visual only when the graphic changed, and plays the
-- ordered sound intents through the recording audio.
local function build(files, avatarComposition)
  avatarComposition = avatarComposition or "both"
  assert(
    avatarComposition == "both"
      or avatarComposition == "none"
      or avatarComposition == "owner-only"
      or avatarComposition == "applier-only",
    "unknown avatar composition: " .. tostring(avatarComposition)
  )
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(ScriptCache.markerPath(), SCRIPT_MARKER)
  cache:write(ScriptCache.generationMarkerPath(SCRIPT_GENERATION), SCRIPT_MARKER)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
  })
  cache:writeLua(ScriptCache.generationIndexPath(SCRIPT_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = SCRIPT_MARKER,
    resources = {},
  })
  local owner = FieldPlayerAvatarState.new({
    capability = capability(),
    surfPresentation = surfPresentation(),
    initialState = "walking",
  })
  local audio = { played = {} }
  function audio:play(sound)
    audio.played[#audio.played + 1] = { sound = sound, visual = owner:status().visualState }
  end
  local visual = { spriteId = owner:currentSpriteId(), swaps = {} }
  function visual:setAvatar(spriteId)
    visual.swaps[#visual.swaps + 1] = spriteId
    visual.spriteId = spriteId
  end
  local player = { fieldX = 10, fieldZ = 10, worldY = 0, facing = "south" }
  local opts = {
    cacheFs = cache,
    overrideFs = overrideFs(files),
    eventState = FieldEventState.new(),
    actors = stubActors(),
    player = player,
    profile = { gender = 0, name = "Gold" },
    dialogue = {
      isModal = function()
        return false
      end,
    },
    messageProvider = {},
    layout = function()
      return {}
    end,
    fontDef = { charmap = {} },
    signpost = {
      isModal = true,
      updateFixed = function() end,
    },
    windowStyles = {
      resolve = function()
        return {}
      end,
    },
    transition = {},
    mapLoader = {},
    sourceMap = { fieldData = { mapId = 7, scriptBankId = 3, initScripts = {} } },
    auxiliaryUi = {
      advance = function() end,
    },
    menu = {},
    contextChoice = {},
    audio = audio,
  }
  if avatarComposition == "both" or avatarComposition == "owner-only" then
    opts.playerAvatar = owner
  end
  if avatarComposition == "both" or avatarComposition == "applier-only" then
    opts.avatarApplier = function()
      local result = owner:applyTransitions()
      if result.spriteChanged then
        visual:setAvatar(result.spriteId)
      end
      for _, symbol in ipairs(result.sounds) do
        audio:play(symbol)
      end
      return result
    end
  end
  local platform = FieldScripts.new(opts --[[@as FieldScriptsOptions]])
  return { platform = platform, owner = owner, player = player, audio = audio, visual = visual }
end

function T.tests.avatar_composition_preserves_absent_and_present_capabilities()
  local withoutAvatarTransitions = build({}, "none")
  Assert.notNil(withoutAvatarTransitions.platform, "avatar transition support remains optional")

  local fixture = build({ [SLICE_ID] = SLICE_CHUNK })
  local composed = assert(fixture.platform.composition:effective(SLICE_ID))
  fixture.platform.scheduler:createForeground(composed, nil, 100)
  fixture.platform.scheduler:step(100, nil)
  -- First tick: heal is queued and the script yields with the visual
  -- unchanged and the marker silent.
  Assert.isTrue(fixture.owner:status().pending.heal, "the first tick must queue heal")
  Assert.equal(fixture.owner:status().visualState, "walking")
  Assert.equal(#fixture.audio.played, 0)
  fixture.platform.scheduler:step(101, nil)
  -- Second tick: heal applies, the marker runs in the same tick observing
  -- the heal visual, then walking queues behind a second yield.
  Assert.equal(#fixture.audio.played, 1)
  Assert.equal(fixture.audio.played[1].sound, "SEQ_SLICE_MARK")
  Assert.equal(fixture.audio.played[1].visual, "heal", "the marker must run after the apply in the same tick")
  Assert.equal(fixture.visual.spriteId, 1008, "the materializer swaps to the heal graphic on change")
  Assert.deepEqual(fixture.visual.swaps, { 1008 })
  Assert.isTrue(fixture.owner:status().pending.walking)
  fixture.platform.scheduler:step(102, nil)
  -- Third tick: the durable walking graphic restores, the restore marker
  -- runs same-tick, and the script completes.
  Assert.equal(#fixture.audio.played, 2)
  Assert.equal(fixture.audio.played[2].sound, "SEQ_SLICE_RESTORED")
  Assert.equal(fixture.audio.played[2].visual, "walking")
  Assert.equal(fixture.visual.spriteId, 1001, "the materializer restores the walking graphic")
  Assert.deepEqual(fixture.visual.swaps, { 1008, 1001 })
  local status = fixture.owner:status()
  Assert.equal(status.durableState, "walking")
  Assert.equal(status.visualState, "walking")
  Assert.isNil(next(status.pending))
  Assert.isNil(fixture.platform.scheduler:foregroundEnvironmentId())
  -- Avatar choreography never moves the player.
  Assert.equal(fixture.player.fieldX, 10)
  Assert.equal(fixture.player.fieldZ, 10)
end

function T.tests.avatar_facade_delegates_to_the_same_owner_across_map_swaps()
  local fixture = build({})
  local facade = fixture.platform.player
  facade:queueAvatarTransition("rocket")
  Assert.isTrue(fixture.owner:status().pending.rocket, "queueing must delegate to the transition owner")
  Assert.equal(fixture.player.fieldX, 10, "queueing must not mutate logical movement")
  Assert.equal(fixture.player.fieldZ, 10)
  facade:applyAvatarTransitions()
  local status = fixture.owner:status()
  Assert.equal(status.visualState, "rocket")
  Assert.equal(status.durableState, "rocket")
  Assert.isNil(next(status.pending))
  Assert.equal(fixture.visual.spriteId, 1010, "the apply swaps the visual through the materializer")
  Assert.deepEqual(fixture.visual.swaps, { 1010 })
  local newPlayer = { fieldX = 3, fieldZ = 5, worldY = 0, facing = "north" }
  local destination = { fieldData = { mapId = 11, scriptBankId = 9, initScripts = {} } }
  fixture.platform:onMapSwap(newPlayer --[[@as FieldPlayer]], destination --[[@as RuntimeFieldMap]])
  Assert.equal(facade:position().fieldX, 3, "the live player rebinds while the owner persists")
  facade:queueAvatarTransition("walking")
  Assert.isTrue(fixture.owner:status().pending.walking, "the same owner survives map rebinds")
end

function T.tests.avatar_composition_rejects_each_half_at_construction()
  local ownerOnlyConstructed, ownerOnlyError = pcall(function()
    return build({}, "owner-only")
  end)
  local applierOnlyConstructed, applierOnlyError = pcall(function()
    return build({}, "applier-only")
  end)
  Assert.isFalse(ownerOnlyConstructed, "owner-only composition must fail at construction")
  Assert.isTrue(
    tostring(ownerOnlyError):find("playerAvatar", 1, true) ~= nil,
    "owner-only failure must identify the paired collaborators: " .. tostring(ownerOnlyError)
  )
  Assert.isFalse(applierOnlyConstructed, "applier-only composition must fail at construction")
  Assert.isTrue(
    tostring(applierOnlyError):find("playerAvatar", 1, true) ~= nil,
    "applier-only failure must identify the paired collaborators: " .. tostring(applierOnlyError)
  )
end

function T.tests.avatar_owner_must_be_queue_apply_shaped()
  local fixture = build({})
  local err = Assert.throws(function()
    fixture.platform.player:setAvatarState({})
  end)
  Assert.isTrue(
    tostring(err):find("queue/apply", 1, true) ~= nil,
    "a shapeless owner must fail at the wiring boundary: " .. tostring(err)
  )
end

-- The runtime materializer under recording collaborators: the owner applies
-- first, the visual swaps only when the graphic changed, and the ordered
-- sound intents play through the audio host in source order.
local function recordingMaterializer(owner)
  local order = {}
  local visual = { spriteId = owner:currentSpriteId(), swaps = 0 }
  function visual:setAvatar(spriteId)
    visual.swaps = visual.swaps + 1
    visual.spriteId = spriteId
    order[#order + 1] = "swap:" .. tostring(spriteId)
  end
  local audio = { played = {} }
  function audio:play(sound)
    audio.played[#audio.played + 1] = sound
    order[#order + 1] = "play:" .. tostring(sound)
  end
  local runtime = setmetatable({ playerAvatar = owner, playerVisual = visual, audio = audio }, FieldRuntime)
  return runtime, visual, audio, order
end

local function freshOwner()
  return FieldPlayerAvatarState.new({
    capability = capability(),
    surfPresentation = surfPresentation(),
    initialState = "walking",
  })
end

function T.tests.runtime_materializer_swaps_the_visual_then_plays_sounds_in_order()
  local owner = freshOwner()
  owner:queueTransition("cycling")
  local runtime, visual, audio, order = recordingMaterializer(owner)
  local result = runtime:applyAvatarTransitions()
  Assert.isTrue(result.spriteChanged)
  Assert.equal(visual.spriteId, owner:currentSpriteId())
  Assert.equal(visual.spriteId, 1002, "the cycling graphic presents after the apply")
  Assert.deepEqual(audio.played, { "SEQ_SE_DP_JITENSYA" })
  Assert.deepEqual(order, { "swap:1002", "play:SEQ_SE_DP_JITENSYA" }, "the swap lands before its sounds")
end

function T.tests.runtime_materializer_skips_the_visual_swap_when_the_graphic_is_unchanged()
  local owner = freshOwner()
  local runtime, visual, audio, _ = recordingMaterializer(owner)
  local result = runtime:applyAvatarTransitions()
  Assert.isFalse(result.spriteChanged)
  Assert.equal(visual.swaps, 0, "an unchanged graphic must not touch the player visual")
  Assert.equal(#audio.played, 0, "an empty apply plays no sounds")
end

function T.tests.runtime_materializer_fails_when_no_audio_host_can_play_transition_sounds()
  local owner = freshOwner()
  owner:queueTransition("cycling")
  local runtime = setmetatable({
    playerAvatar = owner,
    playerVisual = {
      setAvatar = function() end,
    },
  }, FieldRuntime)
  local err = Assert.throws(function()
    runtime:applyAvatarTransitions()
  end)
  Assert.isTrue(
    tostring(err):find("field avatar transition audio host required", 1, true) ~= nil,
    "sounds without an audio host must fail loudly: " .. tostring(err)
  )
end

return T
