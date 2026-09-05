-- Internal fixed-channel NNS WaveOut playback over the shared VoiceMixer.

local WaveOutPlayer = {}
WaveOutPlayer.__index = WaveOutPlayer

---@class WaveOutHandle
---@field channel integer
---@field generation integer
---@field mixerHandle { channel: integer, generation: integer }
---@field sample { metadata: table<string, unknown>, pcm: integer[] }

---@class WaveOutPlayer
---@field private _mixer VoiceMixer
---@field private _handles table<WaveOutHandle, WaveOutHandle>
---@field new fun(opts: { mixer: VoiceMixer }): WaveOutPlayer
---@field start fun(self: WaveOutPlayer, channel: integer, sample: { metadata: table<string, unknown>, pcm: integer[] }, options: { volume: integer, pan: integer, speed: integer, reverse: boolean }): WaveOutHandle?
---@field isPlaying fun(self: WaveOutPlayer, handle: WaveOutHandle): boolean
---@field setVolume fun(self: WaveOutPlayer, handle: WaveOutHandle, volume: integer)
---@field setPan fun(self: WaveOutPlayer, handle: WaveOutHandle, pan: integer)
---@field setSpeed fun(self: WaveOutPlayer, handle: WaveOutHandle, speed: integer)
---@field stop fun(self: WaveOutPlayer, handle: WaveOutHandle)

local function copySample(sample)
  local pcm = {}
  for index = #sample.pcm, 1, -1 do
    pcm[#pcm + 1] = sample.pcm[index]
  end
  return { metadata = sample.metadata, pcm = pcm }
end

local function validHandle(self, handle)
  return type(handle) == "table" and self._handles[handle] ~= nil
end

function WaveOutPlayer.new(opts)
  assert(opts and opts.mixer, "WaveOutPlayer requires a mixer")
  return setmetatable({ _mixer = opts.mixer, _handles = {} }, WaveOutPlayer) --[[@as WaveOutPlayer]]
end

function WaveOutPlayer:start(channel, sample, options)
  assert(channel == 14 or channel == 15, "WaveOut channel must be 14 or 15")
  assert(sample and sample.metadata and sample.pcm, "WaveOut requires a sample")
  assert(options and options.reverse ~= nil, "WaveOut options are required")
  local playbackSample = options.reverse and copySample(sample) or sample
  local mixerHandle = self._mixer:waveOn({
    channel = channel,
    pcm = playbackSample.pcm,
    metadata = playbackSample.metadata,
    volume = options.volume,
    pan = options.pan,
    speed = options.speed,
  })
  if mixerHandle == nil then
    return nil
  end
  local handle = {
    channel = mixerHandle.channel,
    generation = mixerHandle.generation,
    mixerHandle = mixerHandle,
    sample = playbackSample,
  } ---@type WaveOutHandle
  self._handles[handle] = handle
  return handle
end

function WaveOutPlayer:isPlaying(handle)
  if not validHandle(self, handle) then
    return false
  end
  local alive = self._mixer:isVoiceAlive(handle.mixerHandle)
  if not alive then
    self._handles[handle] = nil
  end
  return alive
end

function WaveOutPlayer:setVolume(handle, volume)
  if validHandle(self, handle) then
    assert(volume >= 0 and volume <= 127 and volume % 1 == 0, "WaveOut volume must be 0..127")
    self._mixer:updateVoice(handle.mixerHandle, { trackVolume = volume })
  end
end

function WaveOutPlayer:setPan(handle, pan)
  if validHandle(self, handle) then
    assert(pan >= 0 and pan <= 127 and pan % 1 == 0, "WaveOut pan must be 0..127")
    self._mixer:updateVoice(handle.mixerHandle, { trackPanOffset = pan - 64 })
  end
end

function WaveOutPlayer:setSpeed(handle, speed)
  if validHandle(self, handle) then
    assert(speed > 0 and speed <= 0xFFFF and speed % 1 == 0, "WaveOut speed must be a timer")
    self._mixer:updateVoice(handle.mixerHandle, { fixedTimer = speed })
  end
end

function WaveOutPlayer:stop(handle)
  if validHandle(self, handle) then
    self._mixer:stopVoice(handle.mixerHandle)
    self._handles[handle] = nil
  end
end

return WaveOutPlayer
