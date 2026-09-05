-- Generic script audio wait semantics: cry waits observe only the cry owner.

local Assert = require("tests.support.Assert")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local SoundWaitTask = require("libs.hgss.src.script.tasks.SoundWaitTask")

local function runtimeWithAudio(audio)
  local tasks = {}
  local run = {
    instance = { scriptId = "field-cry", locals = {}, textArgs = {} },
    services = { audio = audio },
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType, spec)
        tasks[#tasks + 1] = { type = taskType, spec = spec }
        return "task:" .. taskType
      end,
    },
    tick = 1,
    input = {},
  }
  return run, tasks
end

local T = {}

function T.wait_cry_ignores_unrelated_audio()
  local cryFinished = false
  local unrelatedEffectFinished = false
  local played = {}
  local audio = {
    playCry = function(_, species, pattern)
      played[#played + 1] = { species = species, pattern = pattern }
    end,
    isCryFinished = function()
      return cryFinished
    end,
    isEffectWaitComplete = function()
      return unrelatedEffectFinished
    end,
  }
  local run, tasks = runtimeWithAudio(audio)

  Assert.equal(Runtime.executeNode({ op = "play_cry", species = 183, pattern = 11 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(played, { { species = 183, pattern = 11 } }, "play_cry forwards the source pattern")
  Assert.equal(Runtime.executeNode({ op = "wait_cry" }, run), Runtime.OUTCOME_BLOCK)

  local task = assert(tasks[1], "wait_cry creates a sound-wait task")
  local context = { services = run.services, instance = run.instance }
  local state = SoundWaitTask.create(task.spec, context)
  Assert.isFalse(SoundWaitTask.poll(state, context).complete == true, "the cry keeps the wait blocked")

  cryFinished = true
  Assert.isTrue(SoundWaitTask.poll(state, context).complete == true, "cry completion resumes the wait")
  Assert.isFalse(unrelatedEffectFinished, "an unrelated effect does not control wait_cry")
end

return { tests = T }
