-- TerrainMaterialAnimator: the terrain playback state for one map runtime --
-- the shared per-name texture-swap clocks (the field manager's per-tick
-- counter state machine over the compiled fldtanime schedule) and the
-- looping area texture-SRT playback (the compiled NSBTA clip), composed
-- over { record, runtime } bindings the loaders build from the generated
-- scene-form material records and the runtime material tables the draw
-- items reference.
--
-- Each texture-swap animation name owns one clock over its replacement
-- schedule: construction puts the clock on schedule entry 1 with 0 ticks
-- elapsed and leaves every runtime material on its initial image (the base
-- material.texture stays outside the replacement schedule), acquiring every
-- replacement image up front through the injected resolver. Each
-- updateFixed counts one tick; when the current entry's durationTicks
-- expires the clock advances (wrapping at the schedule end) and only then
-- swaps every member of the group to the new entry's own preloaded image --
-- so the first switch lands one tick later than an intuitive implementation.
-- Same-name materials share one clock and stay in phase, each selecting from
-- its own preloaded array -- neighbor cells compile against their own packs,
-- so same-name arrays may hold different paths; the asset cache validates
-- that same-name schedules agree.
--
-- The texture-SRT clip plays through one looping AnimationPlayer: area NSBTA
-- frame 0 is sampled at construction, and updateFixed advances one frame and
-- re-samples every SRT-bound material through TextureSrtEvaluator (the
-- shared composition with MaterialEvaluator); unbound materials keep the
-- matrix construction initialized. Construction initializes every binding's
-- texMatrix -- the static srt, or the frame-0 NSBTA sample for a clip
-- target -- so a fully static scene needs no separate path. updateFixed
-- performs no acquisition, filesystem access, descriptor mutation, or
-- draw-list rebuild. The animator owns only Lua playback/counter state --
-- the image pool owns every Image and remains the sole release owner.
-- Records and the clip are read-only. Pure domain module.
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")
local CompiledNsbtaSampler = require("libs.nds.src.nitro.g3d.CompiledNsbtaSampler")
local TextureSrtEvaluator = require("libs.hgss.src.presentation.TextureSrtEvaluator")

---@class TerrainMaterialAnimator
---@field groups { steps: table<string, unknown>, scheduleIndex: integer, ticksInScheduleEntry: integer, members: table[] }[]
---@field srtBindings { record: table<string, unknown>, runtime: table<string, unknown>, targetIndex: integer }[]
---@field clip table<string, unknown>|false
---@field player table<string, unknown>|nil
local TerrainMaterialAnimator = {}
TerrainMaterialAnimator.__index = TerrainMaterialAnimator

-- Build the playback state over the loaders' bindings. The asset cache owns
-- generated-data validation (including the same-name schedule agreement the
-- shared clocks rely on); only true local programming faults are asserted
-- here. `clip` is the compiled texsrt clip or false for no area animation.
-- The base material image stays outside the replacement schedule: the loader
-- bound material.texture, the schedule entries only supply alternate frames.
---@param bindings { record: table<string, unknown>, runtime: table<string, unknown> }[] scene material record + live runtime material table<string, unknown>
---@param clip table<string, unknown>|false the compiled texsrt clip or false for no area animation
---@param resolveImage fun(path: string, wrapX: string, wrapY: string): unknown the pool-backed image resolver
---@param checkpoint fun()? optional safe boundary after an image acquisition
---@return TerrainMaterialAnimator
function TerrainMaterialAnimator.new(bindings, clip, resolveImage, checkpoint)
  assert(type(bindings) == "table", "TerrainMaterialAnimator.new requires the bindings")
  assert(
    clip == false or type(clip) == "table",
    "TerrainMaterialAnimator.new requires the compiled texsrt clip or false"
  )
  assert(type(resolveImage) == "function", "TerrainMaterialAnimator.new requires the image resolver")

  local player
  local targetIndexByName
  if clip then
    player = AnimationPlayer.new(clip)
    targetIndexByName = {}
    for _, track in ipairs(clip.tracks) do
      targetIndexByName[track.target] = track.targetIndex
    end
  end

  local groups = {}
  local groupByName = {}
  local srtBindings = {}

  for _, binding in ipairs(bindings) do
    local record = assert(binding.record, "TerrainMaterialAnimator.new requires bindings with records")
    local runtime = assert(binding.runtime, "TerrainMaterialAnimator.new requires bindings with runtime materials")

    local swap = record.textureSwap
    if swap then
      local group = groupByName[swap.name]
      if not group then
        group = {
          steps = swap.steps,
          scheduleIndex = 1,
          ticksInScheduleEntry = 0,
          members = {},
        }
        groups[#groups + 1] = group
        groupByName[swap.name] = group
      end

      local wrap = assert(runtime.wrap, "TerrainMaterialAnimator requires the runtime material's resolved wrap")
      local images = {}
      for scheduleIndex, step in ipairs(swap.steps) do
        images[scheduleIndex] = resolveImage(step.texture, wrap.x, wrap.y)
        if checkpoint then
          checkpoint()
        end
      end
      group.members[#group.members + 1] = {
        runtime = runtime,
        images = images,
      }
    end

    local targetIndex = targetIndexByName and targetIndexByName[record.name]
    local sampled
    if targetIndex ~= nil then
      sampled = CompiledNsbtaSampler.sample(clip, targetIndex, player.frameFx)
      srtBindings[#srtBindings + 1] = { record = record, runtime = runtime, targetIndex = targetIndex }
    end
    runtime.texMatrix = TextureSrtEvaluator.matrix(record, sampled)
  end

  return setmetatable({
    groups = groups,
    srtBindings = srtBindings,
    clip = clip,
    player = player,
  }, TerrainMaterialAnimator)
end

-- Advance every shared clock exactly once: each texture-swap group takes one
-- counter step, and when the current schedule entry's duration crosses, the
-- clock advances (wrapping at the schedule end) and every member selects the
-- new entry from its own preloaded array; the looping SRT player advances
-- one frame and each targeted material's matrix is re-sampled. Untargeted
-- matrices keep their base value. The first switch lands one tick later than
-- an intuitive implementation: the base image shows for the first entry's
-- full duration, and only a crossing swaps to the first alternate. Image
-- assignment happens only inside the crossing branch. No acquisition,
-- filesystem access, or record mutation here.
function TerrainMaterialAnimator:updateFixed()
  for _, group in ipairs(self.groups) do
    local entry = group.steps[group.scheduleIndex]
    if entry.durationTicks > group.ticksInScheduleEntry then
      group.ticksInScheduleEntry = group.ticksInScheduleEntry + 1
    else
      group.ticksInScheduleEntry = 1
      group.scheduleIndex = group.scheduleIndex % #group.steps + 1
      for _, member in ipairs(group.members) do
        member.runtime.image = member.images[group.scheduleIndex]
      end
    end
  end

  if self.player then
    self.player:updateFixed()
    local frameFx = self.player.frameFx
    local clip = assert(self.clip)
    for _, binding in ipairs(self.srtBindings) do
      local sampled = CompiledNsbtaSampler.sample(clip, binding.targetIndex, frameFx)
      ---@cast sampled SampledTexSrtState
      binding.runtime.texMatrix = TextureSrtEvaluator.matrix(binding.record, sampled)
    end
  end
end

-- Seek playback to the shared field clock without replaying historical ticks.
-- Texture schedules are periodic, so at most one schedule cycle is inspected;
-- the SRT player is directly positioned in its fixed-point loop.
function TerrainMaterialAnimator:seekFixedTick(fieldTick)
  assert(
    type(fieldTick) == "number" and fieldTick >= 0 and fieldTick % 1 == 0,
    "field tick must be a non-negative integer"
  )
  for _, group in ipairs(self.groups) do
    local cycle = 0
    for _, step in ipairs(group.steps) do
      cycle = cycle + math.max(1, step.durationTicks + 1)
    end
    local remaining = fieldTick % cycle
    group.scheduleIndex, group.ticksInScheduleEntry = 1, 0
    while true do
      local duration = group.steps[group.scheduleIndex].durationTicks
      local span = math.max(1, duration + 1)
      if remaining < span then
        break
      end
      remaining = remaining - span
      group.scheduleIndex = group.scheduleIndex % #group.steps + 1
    end
    group.ticksInScheduleEntry = remaining
    for _, member in ipairs(group.members) do
      member.runtime.image = member.images[group.scheduleIndex]
    end
  end
  if self.player then
    local clip = self.clip
    assert(type(clip) == "table", "terrain animation clip required")
    self.player.frameFx = (fieldTick * AnimationPlayer.FRAME_UNIT) % (clip.frameCount * AnimationPlayer.FRAME_UNIT)
    for _, binding in ipairs(self.srtBindings) do
      local sampled = CompiledNsbtaSampler.sample(clip, binding.targetIndex, self.player.frameFx)
      ---@cast sampled SampledTexSrtState
      binding.runtime.texMatrix = TextureSrtEvaluator.matrix(binding.record, sampled)
    end
  end
end

return TerrainMaterialAnimator
