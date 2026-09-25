-- The concrete party-screen application owns its icon-preparation wait: it
-- reports pending/error preparation instead of normal selection input,
-- stays cancellable while waiting, discards held activation received
-- before readiness, and releases its preparation interest exactly once on
-- close or disposal. Swaps and close results keep their existing meaning
-- once preparation is ready.

local Assert = require("tests.support.Assert")
local PartyScreenState = require("game.hgss.src.field.PartyScreenState")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function fakeCatalog()
  return {
    species = function(_)
      return { name = "Chikorita", genderRatio = 127 }
    end,
    iconSelection = function(_, mon)
      return mon.species .. "/f" .. mon.form
    end,
  }
end

local function fakeService(calls)
  local catalog = fakeCatalog()
  return {
    partyCount = function(_)
      return 2
    end,
    partyRevision = function(_)
      return 1
    end,
    partyMon = function(_)
      return {
        species = "CHIKORITA",
        form = 0,
        isEgg = false,
        personality = 0,
        nickname = "CHIKO",
        condition = { currentHp = 20, status = 0 },
      }
    end,
    partyMonDerived = function(_)
      return { maxHp = 20, level = 5 }
    end,
    catalog = function(_)
      return catalog
    end,
    swapPartyMons = function(_, a, b)
      calls.swaps[#calls.swaps + 1] = { a, b }
    end,
  }
end

---@param ready boolean
---@param failure string?
---@param calls table<string, unknown>
---@return PartyScreenState state
---@return table<string, fun(): integer> probes
local function openParty(ready, failure, calls)
  local preparations = 0
  local cancels = 0
  local service = fakeService(calls)
  local measurement = {
    width = 800,
    height = 600,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 800, height = 600 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "party-screen-state-test:800x600",
  }
  local state = PartyScreenState.new({
    service = service,
    measureDisplay = function()
      return measurement
    end,
    prepareIcons = function(_)
      preparations = preparations + 1
      return ready, failure
    end,
    cancelIconPreparation = function()
      cancels = cancels + 1
    end,
  })
  return state,
    {
      preparations = function()
        return preparations
      end,
      cancels = function()
        return cancels
      end,
    }
end

-- Activation held while icons prepare must not select anything: the screen
-- reports pending preparation and stays there until readiness arrives.
function T.opening_waits_for_icon_preparation_before_accepting_selection()
  local calls = { swaps = {} }
  local state, _ = openParty(false, nil, calls)
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.preparationState, "pending", "the screen waits for icon preparation before normal input")
  Assert.isNil(status.action, "held activation never selects while preparation is pending")
  Assert.equal(#calls.swaps, 0, "no swap fires before readiness")
  state:dispose()
end

-- Closing or disposing a waiting screen drops its preparation interest
-- exactly once; a late readiness arrival cannot reopen or draw it. The
-- same exactly-once release holds for a screen disposed after readiness.
function T.closing_releases_icon_preparation_exactly_once()
  local calls = { swaps = {} }
  local state, probes = openParty(false, nil, calls)
  state:updateFixed({})
  state:dispose()
  Assert.equal(probes.cancels(), 1, "disposal cancels the outstanding preparation exactly once")
  Assert.isNil(state:takeResult(), "disposal reports no close after cancelling")
  local readyCalls = { swaps = {} }
  local readyState, readyProbes = openParty(true, nil, readyCalls)
  readyState:updateFixed({})
  readyState:dispose()
  Assert.equal(readyProbes.cancels(), 1, "disposal releases a finished preparation exactly once")
end

-- Once preparation is ready the existing selection, swap, and close
-- behavior is unchanged. This guards current behavior through the new
-- required collaborators: it passes before and after the wait lands.
function T.ready_preparation_preserves_selection_and_close()
  local calls = { swaps = {} }
  local state, probes = openParty(true, nil, calls)
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.action, "action_choice", "selection input works after readiness")
  Assert.equal(#calls.swaps, 0, "opening the action choice swaps nothing")
  Assert.isNil(state:takeResult(), "opening the action choice completes nothing")
  Assert.equal(probes.cancels(), 0, "nothing cancels while the screen stays open")
  state:dispose()
end

return { tests = T }
