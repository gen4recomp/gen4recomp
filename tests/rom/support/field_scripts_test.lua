-- Explicit-member field-script decode: tests that name a finite set of
-- retail members must read and decode only those members through the
-- production member decoder, with the same catalogs the full-archive decode
-- uses. Uses synthetic members and a fake archive so no dump is required.

local Assert = require("tests.support.Assert")
local FieldScripts = require("tests.rom.support.FieldScripts")
local ScriptFixture = require("tests.support.ScriptFixture")
local BinaryView = require("libs.codec.src.BinaryView")

local T = {}

local function decodeMembers()
  Assert.equal(
    type(FieldScripts.decodeMembers),
    "function",
    "explicit-member decode is available alongside the full-archive decode"
  )
  return FieldScripts.decodeMembers
end

local function scriptMember()
  return ScriptFixture.member({
    scripts = { { offset = 0x20, instructions = { { op = 2, args = {} } } } },
  })
end

-- A fake scr_seq archive: zero-based member ids, read logging, and an open
-- counter so selection order and duplicate handling are observable.
local function fakeRomFs(memberBytes, log)
  local maxId = -1
  for id in pairs(memberBytes) do
    maxId = math.max(maxId, id)
  end
  local archive = {
    opens = 0,
    memberCount = function()
      return maxId + 1
    end,
    readMember = function(_, id)
      log[#log + 1] = id
      return assert(memberBytes[id], "fake archive has no member " .. tostring(id))
    end,
    memberView = function(_, id)
      return BinaryView.fromString(assert(memberBytes[id], "fake archive has no member " .. tostring(id)))
    end,
  }
  return {
    openNarc = function(_, name)
      Assert.equal(name, "field_scripts", "explicit-member decode opens the field-script archive")
      archive.opens = archive.opens + 1
      return archive
    end,
    archive = archive,
  }
end

T["reads only the requested members in caller order"] = function()
  local log = {}
  local romFs = fakeRomFs({ [0] = scriptMember(), [1] = scriptMember(), [2] = scriptMember() }, log)
  local archive, memberIrs = decodeMembers()(romFs, { 2, 0 })
  Assert.equal(romFs.archive.opens, 1, "the archive opens once")
  Assert.deepEqual(log, { 2, 0 }, "only the requested members are read, in caller order")
  Assert.notNil(memberIrs[2], "member 2 decodes")
  Assert.notNil(memberIrs[0], "member 0 decodes")
  Assert.isNil(memberIrs[1], "unrequested member 1 has no IR entry")
  local seen = {}
  FieldScripts.eachScript(archive, memberIrs, function(member, index)
    seen[#seen + 1] = member .. ":" .. index
  end)
  -- The walker itself is unchanged: it still visits members in archive
  -- order, while the reads above stay in caller order.
  Assert.deepEqual(seen, { "0:0", "2:0" }, "the existing walker consumes the sparse selection unchanged")
end

T["duplicate member ids decode once"] = function()
  local log = {}
  local romFs = fakeRomFs({ [0] = scriptMember(), [1] = scriptMember() }, log)
  local _, memberIrs = decodeMembers()(romFs, { 1, 1, 1 })
  Assert.deepEqual(log, { 1 }, "a repeated member id reads once")
  Assert.notNil(memberIrs[1], "member 1 decodes")
end

T["invalid member ids fail loudly"] = function()
  local decode = decodeMembers()
  local romFs = fakeRomFs({ [0] = scriptMember(), [1] = scriptMember() }, {})
  for _, bad in ipairs({ -1, 1.5, "1", true, 2, 99 }) do
    Assert.throws(function()
      decode(romFs, { bad })
    end, "member id " .. tostring(bad) .. " is rejected")
  end
end

T["selected entries match the full-archive decode"] = function()
  local bytes = { [0] = scriptMember(), [1] = scriptMember() }
  local _, full = FieldScripts.decode(fakeRomFs(bytes, {}))
  local _, subset = decodeMembers()(fakeRomFs(bytes, {}), { 1 })
  Assert.deepEqual(subset[1], full[1], "the subset decode equals the full decode entry")
end

T["header members decode to nil like the full archive"] = function()
  local bytes = { [0] = scriptMember(), [1] = "\0\0\0\0" }
  local _, full = FieldScripts.decode(fakeRomFs(bytes, {}))
  Assert.isNil(full[1], "the full decode reports the header member as nil")
  local archive, subset = decodeMembers()(fakeRomFs(bytes, {}), { 0, 1 })
  Assert.isNil(subset[1], "the subset decode reports the header member as nil")
  local seen = {}
  FieldScripts.eachScript(archive, subset, function(member, index)
    seen[#seen + 1] = member .. ":" .. index
  end)
  Assert.deepEqual(seen, { "0:0" }, "the walker skips the nil header entry")
end

return { tests = T }
