-- Pokemon nickname command state and source result semantics.

local Assert = require("tests.support.Assert")
local T = {}

local function requireTask()
  local ok, task = pcall(require, "libs.hgss.src.script.tasks.PokemonNicknameTask")
  Assert.isTrue(ok, "the HGSS task owns Pokemon nickname input")
  return assert(task)
end

local function fixture(hostDone, currentText, nickname)
  local mon = { species = "CHIKORITA", form = 0, nickname = nickname, personality = 1 }
  local changes = 0
  local host = { active = false, opened = {}, updates = 0, closed = 0 }
  function host:isActive()
    return self.active
  end
  function host:open(spec)
    self.active = true
    self.opened[#self.opened + 1] = spec
  end
  function host:handleInput(events)
    self.events = events
  end
  function host:updateFixed()
    self.updates = self.updates + 1
  end
  function host:status()
    if not self.active then
      return nil
    end
    return { done = hostDone, text = currentText or "CHIKORITA" }
  end
  function host:close()
    self.active = false
    self.closed = self.closed + 1
  end
  local mons = {
    partyCount = function()
      return 1
    end,
    partyMon = function(_, slot)
      Assert.equal(slot, 0)
      return mon
    end,
    catalog = function()
      return {
        species = function()
          return { nativeId = 152, name = "CHIKORITA", genderRatio = 127 }
        end,
        form = function()
          return { number = 0 }
        end,
        iconSelection = function()
          return "CHIKORITA_0"
        end,
      }
    end,
    setNickname = function(_, slot, name)
      Assert.equal(slot, 0)
      mon.nickname = name
      changes = changes + 1
    end,
  }
  return { services = { mons = mons, pokemonNaming = host }, input = { uiEvents = { { type = "confirm" } } } },
    host,
    mon,
    function()
      return changes
    end
end

function T.changed_name_commits_and_returns_zero()
  local task = requireTask()
  local ctx, host, mon, changes = fixture(true, "LEAF")
  local state = task.create({ slot = 0 }, ctx)
  local result = task.poll(state, ctx)
  Assert.isTrue(result.complete)
  Assert.equal(result.result, 0)
  Assert.equal(mon.nickname, "LEAF")
  Assert.equal(changes(), 1)
  Assert.equal(host.closed, 1)
end

function T.unchanged_name_preserves_nil_nickname_and_returns_one()
  local task = requireTask()
  local ctx, host, mon, changes = fixture(true, "")
  local state = task.create({ slot = 0 }, ctx)
  local result = task.poll(state, ctx)
  Assert.equal(host.opened[1].currentText, "", "a fresh naming session opens with an empty editing buffer")
  Assert.isTrue(result.complete)
  Assert.equal(result.result, 1)
  Assert.isNil(mon.nickname)
  Assert.equal(changes(), 0)
  Assert.equal(host.closed, 1)
end

function T.whitespace_only_submission_does_not_write_a_nickname()
  local task = requireTask()
  local ctx, host, mon, changes = fixture(true, "   ")
  local state = task.create({ slot = 0 }, ctx)
  local result = task.poll(state, ctx)
  Assert.isTrue(result.complete)
  Assert.equal(result.result, 1)
  Assert.isNil(mon.nickname)
  Assert.equal(changes(), 0)
  Assert.equal(host.closed, 1)
end

function T.exact_existing_nickname_is_unchanged()
  local task = requireTask()
  local ctx, host, mon, changes = fixture(true, "SPROUT", "SPROUT")
  local state = task.create({ slot = 0 }, ctx)
  local result = task.poll(state, ctx)
  Assert.equal(state.initialText, "SPROUT")
  Assert.equal(host.opened[1].currentText, "")
  Assert.isNil(host.opened[1].initialText)
  Assert.isTrue(result.complete)
  Assert.equal(result.result, 1)
  Assert.equal(mon.nickname, "SPROUT")
  Assert.equal(changes(), 0)
  Assert.equal(host.closed, 1)
end

function T.restored_task_reopens_with_current_text_and_original_comparison()
  local task = requireTask()
  local ctx, host = fixture(false, "LE")
  local state = task.create({ slot = 0 }, ctx)
  state.currentText = "LE"
  host.active = false
  task.poll(state, ctx)
  Assert.equal(host.opened[#host.opened].currentText, "LE")
  Assert.equal(state.initialText, "CHIKORITA")
  Assert.isNil(host.opened[#host.opened].initialText)
end

function T.cancellation_closes_an_open_host_once()
  local task = requireTask()
  local ctx, host = fixture(false)
  local state = task.create({ slot = 0 }, ctx)
  task.poll(state, ctx)
  task.cancel(state, "cancelled", ctx)
  task.cancel(state, "cancelled again", ctx)
  Assert.equal(host.closed, 1)
end

function T.invalid_party_slot_fails_before_open()
  local task = requireTask()
  local ctx, host = fixture(false)
  local ok = pcall(task.create, { slot = 1 }, ctx)
  Assert.isFalse(ok)
  Assert.equal(#host.opened, 0)
end

function T.subject_carries_personality_derived_gender_and_serializes_it()
  local task = requireTask()
  local ctx = fixture(false)
  local state = task.create({ slot = 0 }, ctx)
  Assert.equal(state.subject.gender, "female")
  Assert.isNil(task.validate(state), "the derived subject remains serializable")
  state.subject.gender = "other"
  Assert.notNil(task.validate(state), "unsupported gender facts are rejected")
end

return { tests = T }
