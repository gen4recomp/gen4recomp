-- Production-composed New Bark friend-house signpost contract. Boots the
-- real field runtime, starts the real generated New Bark script through the
-- production script composition, and stops before rendering. The expected
-- name and label are derived from the generated message banks at run time,
-- so no retail wording is pinned here: the test proves the substitution
-- actually happened (resolved text equals counterpart name plus label) and
-- the signpost dismisses through the normal confirmation flow.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "field-core", "map:60" },
    tags = { "field", "signpost", "text" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local FRIEND_HOUSE_SCRIPT = "vanilla.hgss.scr_seq.0842.script_016"

-- The visible glyph text of the currently printed signpost message.
local function signpostText(game)
  local parts = {}
  for _, line in ipairs(game.runtime.signpost:status().visibleLines) do
    for _, token in ipairs(line) do
      if token.kind == "glyph" then
        parts[#parts + 1] = token.text
      end
    end
  end
  return table.concat(parts)
end

-- The New Bark friend-house sign reads the opposite protagonist's canonical
-- name from the generated name bank, types the house label normally, and
-- dismisses through normal confirmation instead of faulting or stranding a
-- modal window.
function T.tests.friend_house_signpost_prints_the_counterpart_name_and_dismisses()
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness:boot({
    versionId = versionId,
    map = TOWN,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:startScript(FRIEND_HOUSE_SCRIPT)
    -- The typed house label must reach print completion without faulting:
    -- before the counterpart-name support lands, starting this print faults
    -- the script with the unsupported-name error instead. The scheduler
    -- archives the fault as a script.error record rather than raising
    -- through the tick, so the test watches for that record explicitly.
    local printed = false
    for _ = 1, 480 do
      game:step()
      if #game:recordsForScript(FRIEND_HOUSE_SCRIPT, "script.error") > 0 then
        break
      end
      local status = game.runtime.signpost:status()
      if status.active and status.printDone then
        printed = true
        break
      end
    end
    local faults = game:recordsForScript(FRIEND_HOUSE_SCRIPT, "script.error")
    Assert.equal(
      #faults,
      0,
      "the friend-house script must resolve its counterpart name without faulting; got "
        .. (faults[1] and faults[1].payload.code or "no record")
    )
    Assert.isTrue(printed, "the friend-house signpost must complete its typed print")
    local resolved = signpostText(game)
    -- Expectations come from the same generated banks the runtime reads: the
    -- counterpart name selected by the fresh protagonist's gender, plus the
    -- house-label template with its substitution marker removed.
    local cache = CacheFs.forVersion(versionId)
    local gender = game.runtime.playerData.profile.gender
    local names = assert(cache:loadLua(FieldMessageCache.bankPath(445)), "generated name bank 445 is required")
    local expectedName = assert(names.messages[gender == 0 and 1 or 0], "counterpart name is required").text
    local house = assert(cache:loadLua(FieldMessageCache.bankPath(542)), "generated bank 542 is required")
    local template = assert(house.messages[35], "house-label message is required").text
    local label = assert(template:match("^%b{}(.*)$"), "house-label template carries one leading substitution")
    Assert.equal(resolved, expectedName .. label, "the signpost names the counterpart's house")
    -- Normal dismissal through confirmation: the script runs to its end and
    -- releases the field with no modal window left behind.
    local dismissed = nil
    for _ = 1, 480 do
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
      local snapshot = game:snapshot()
      if not snapshot.fieldLocked and not game.runtime.signpost:status().active then
        dismissed = snapshot
        break
      end
    end
    Assert.notNil(dismissed, "the friend-house signpost must dismiss through normal confirmation")
    Assert.equal(game:renderAttempts(), 0, "the signpost flow must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
