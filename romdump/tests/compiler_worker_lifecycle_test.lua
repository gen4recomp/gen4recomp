-- Worker source-close barrier: the close-context control owns the owned
-- source reader, and a reader that fails to close must never be
-- acknowledged as closed. The production run loop is driven with scripted
-- channels; the first job installs a throwing reader, then the barrier
-- control must surface the failure without a closure acknowledgement.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function withLove(fakeLove, fn)
  local previous = rawget(_G, "love")
  rawset(_G, "love", fakeLove)
  local ok, result = pcall(fn)
  rawset(_G, "love", previous)
  if not ok then
    error(result, 0)
  end
  return result
end

local function fakeLove()
  local backend = FakeCache.new()
  return {
    filesystem = {
      write = function(path, data)
        return backend:write(path, data)
      end,
      read = function(path)
        return backend:read(path)
      end,
      getInfo = function(path)
        return backend:getInfo(path)
      end,
      createDirectory = function(path)
        return backend:createDirectory(path)
      end,
      remove = function(path)
        return backend:remove(path)
      end,
      getDirectoryItems = function(path)
        return backend:getDirectoryItems(path)
      end,
    },
    timer = {
      getTime = function()
        return 0
      end,
    },
  }
end

local function scriptedChannel(messages)
  local pending = {}
  for _, message in ipairs(messages) do
    pending[#pending + 1] = message
  end
  local channel = {}
  function channel:push(value)
    pending[#pending + 1] = value
    return true
  end
  function channel:pop()
    if #pending == 0 then
      return nil
    end
    return table.remove(pending, 1)
  end
  function channel:demand()
    local value = self:pop()
    assert(value ~= nil, "the worker demanded beyond its scripted controls")
    return value
  end
  function channel:getCount()
    return #pending
  end
  return channel
end

local function recordingChannel()
  local received = {}
  local channel = scriptedChannel({})
  local push = channel.push
  function channel:push(value)
    received[#received + 1] = value
    return push(self, value)
  end
  return channel, received
end

function T.failed_source_close_emits_no_closure_acknowledgement()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local RomFs = require("romdump.src.source.RomFs")
  local input = scriptedChannel({
    {
      kind = "map",
      key = "60",
      jobKey = "map:60",
      versionId = "heartgold",
      generationId = "close-generation",
      epoch = 1,
      stageName = "close-stage",
      sizeClass = "normal",
      payload = { mapId = 60 },
      producerFingerprint = "producer",
    },
    { kind = "close-context", closeToken = "barrier-1" },
    { kind = "stop" },
  })
  local resultsChannel, received = recordingChannel()
  local realOpen = RomFs.open
  RomFs.open = function(_)
    return {
      close = function(_)
        error("synthetic source close failure")
      end,
    }
  end
  local runOk = withLove(fakeLove(), function()
    return pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  Assert.isTrue(runOk ~= nil, "the driven worker loop resolves")
  Assert.isTrue(#received >= 1, "the installing job reports before the barrier")
  Assert.equal(received[1].status, "failed", "the job installing the throwing reader fails instead of compiling")
  local acknowledgements = 0
  for _, message in ipairs(received) do
    if message.status == "context-closed" then
      acknowledgements = acknowledgements + 1
    end
  end
  Assert.equal(acknowledgements, 0, "a failed source close emits no closure acknowledgement")
end

return { tests = T }
