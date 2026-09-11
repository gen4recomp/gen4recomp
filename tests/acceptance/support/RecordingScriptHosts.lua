-- Deterministic recording adapters for the real field-script host boundaries.
-- They acknowledge effects immediately, while retaining their semantic order.
-- `options.audio = false` omits the audio adapter so the production composition
-- can wire the real GameSound at the scriptHosts.audio slot (the field-audio
-- acceptance scenarios); camera/events remain recorded. There is no `screen`
-- adapter here: production always composes its own semantic screen-fade
-- controller (FieldRuntime's `screenFade`) regardless of scriptHosts
-- injection, so a recording stand-in would be dead capability, not an
-- observation seam.

local RecordingScriptHosts = {}

---@param options { audio: boolean? }|nil
---@return table { effects: string[], audio: table|nil, events: table }
function RecordingScriptHosts.new(options)
  options = options or {}
  local effects = {}
  local audio = { current = nil, fadeActive = false }
  local events = { records = {} }

  function audio:play(sound)
    self.current = sound
    effects[#effects + 1] = "audio:" .. sound
  end

  function audio:stop(sound)
    if self.current == sound then
      self.current = nil
    end
  end

  function audio:isEffectPlaying()
    return false
  end

  function audio:isEffectWaitComplete()
    return true
  end

  function audio:isCryFinished()
    return true
  end

  function audio:isFanfarePlaying()
    return false
  end

  function audio:playMusic(music)
    effects[#effects + 1] = "music:" .. music
  end

  function audio:stopMusic() end
  function audio:resetMusic() end
  function audio:temporaryMusic() end
  function audio:playCry() end
  function audio:playFanfare(fanfare)
    effects[#effects + 1] = "fanfare:" .. tostring(fanfare)
  end
  function audio:fadeMusicOut() end
  function audio:fadeMusicIn() end

  function audio:isMusicFadeActive()
    return self.fadeActive
  end

  function events:emit(name, payload)
    self.records[#self.records + 1] = { name = name, payload = payload }
  end

  local hosts = { effects = effects, events = events }
  if options.audio ~= false then
    hosts.audio = audio
  end
  return hosts
end

return RecordingScriptHosts
