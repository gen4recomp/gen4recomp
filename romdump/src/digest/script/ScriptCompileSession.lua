-- Owns the reusable source/catalog context for member-level script
-- compilation. The session is producer-local and is never exposed to runtime.

local Hashing = require("romdump.src.digest.Hashing")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local Coverage = require("romdump.src.digest.script.Coverage")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local ScriptMembers = require("romdump.src.reference.hgss.script_members")

local Session = {}
Session.__index = Session

local function catalogs()
  return {
    sounds = require("romdump.src.reference.hgss.sndseq").byId,
    flags = require("romdump.src.reference.hgss.flags").byId,
    vars = require("romdump.src.reference.hgss.vars").byId,
    maps = require("romdump.src.reference.hgss.maps").byId,
    spawns = require("romdump.src.reference.hgss.spawns").byId,
  }
end

function Session.new(romFs, plan, opts)
  assert(romFs and romFs.openNarc, "script compile session requires RomFs")
  assert(type(plan) == "table" and type(plan.generationKey) == "string", "script compile session requires a plan")
  opts = opts or {}
  local archive = assert(romFs:openNarc("field_scripts"))
  assert(archive:memberCount() == plan.memberCount, "script plan no longer matches the source archive")
  return setmetatable({
    romFs = romFs,
    plan = plan,
    archive = archive,
    stdCatalog = SourceCatalog.catalog(),
    catalog = catalogs(),
    romSha1 = romFs:metadata().sha1,
    version = romFs:version(),
    sha1hex = opts.sha1hex or Hashing.sha1hex,
  }, Session)
end

local function memberPlan(plan, memberId)
  for _, candidate in ipairs(plan.members) do
    if candidate.memberId == memberId then
      return candidate
    end
  end
  error("script member is not part of the plan: " .. tostring(memberId), 2)
end

function Session:compileMember(memberId)
  local planned = memberPlan(self.plan, memberId)
  local view = assert(self.archive:memberView(memberId))
  local memberIr = assert(ScriptBinaryDecoder.parseMember(view, memberId, self.plan.sourcePath, {
    msgBank = ScriptMembers.banks[memberId],
    catalog = self.catalog,
  }))
  local scriptIndices = {}
  for _, entry in ipairs(planned.scripts) do
    scriptIndices[#scriptIndices + 1] = entry.scriptIndex
  end
  local sourceHash = self.sha1hex(view)
  local resources, results = ScriptCompiler.translateMember(memberIr, scriptIndices, {
    stdCatalog = self.stdCatalog,
    romSha1 = self.romSha1,
    repository = "g4recomp",
    game = self.version,
    sourceHash = sourceHash,
  })
  local expected = {}
  for _, entry in ipairs(planned.scripts) do
    expected[entry.scriptIndex] = entry.id
  end
  for _, entry in ipairs(resources) do
    assert(entry.id == expected[entry.scriptIndex], "script plan public id mismatch")
  end
  return {
    memberId = memberId,
    marker = planned.marker,
    sourceHash = sourceHash,
    resources = resources,
    results = results,
    coverage = Coverage.record(memberIr, results, {
      repository = "g4recomp",
      romSha1 = self.romSha1,
    }),
  }
end

function Session:close()
  self.archive = nil
  return true
end

return Session
