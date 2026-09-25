-- Owns the reusable source/catalog context for member-level script
-- compilation. The session is producer-local and is never exposed to runtime.

local Hashing = require("romdump.src.digest.Hashing")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local Coverage = require("romdump.src.digest.script.Coverage")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local ScriptMembers = require("romdump.src.reference.hgss.script_members")
local ScriptAudioFacts = require("romdump.src.reference.hgss.script_audio")
local Errors = require("libs.errors.src.Errors")

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

-- Direct dependency facts for one final structured resource: sorted unique
-- audio sequence symbols plus sorted unique cross-script target ids. The
-- compiler attaches this record to every member resource entry; the writer
-- persists it in the member sidecar without recomputation, and the summary
-- joins sidecars into the transitive per-member closure.
local MUSIC_OPS = { play_music = "music", temporary_music = "music" }
local FANFARE_OPS = { play_fanfare = "fanfare" }
local SOUND_OPS = { play_sound = "sound", stop_sound = "sound", wait_sound = "sound" }

-- Pinned retail members whose source scripts resolve a variable fanfare
-- operand dynamically (currently only member 148). Every other member
-- with the same operand shape fails instead of inheriting the pair.
local variableFanfareMembers = {}
for _, memberId in ipairs(ScriptAudioFacts.variableFanfareMembers) do
  variableFanfareMembers[memberId] = true
end

local function invalidDependency(context, message)
  Errors.raise("SCRIPT_MEMBER_INVALID", message, {
    memberId = context.memberId,
    id = context.id,
  })
end

local function addSequence(set, list, symbol)
  if set[symbol] == nil then
    set[symbol] = true
    list[#list + 1] = symbol
  end
end

local function canonicalSequence(sounds, operand, context, op)
  if type(operand) == "string" then
    return operand
  end
  if type(operand) == "number" then
    local symbol = sounds[operand]
    if type(symbol) ~= "string" then
      invalidDependency(context, "unknown numeric sequence reference for " .. op .. ": " .. tostring(operand))
    end
    return symbol
  end
  invalidDependency(context, "unsupported dynamic audio operand for " .. op)
end

local function collectAudio(step, sounds, audioSet, audioList, context)
  local field = MUSIC_OPS[step.op]
  if field ~= nil then
    addSequence(audioSet, audioList, canonicalSequence(sounds, step[field], context, step.op))
    return
  end
  field = SOUND_OPS[step.op]
  if field ~= nil then
    addSequence(audioSet, audioList, canonicalSequence(sounds, step[field], context, step.op))
    return
  end
  if FANFARE_OPS[step.op] ~= nil then
    local operand = step.fanfare
    if type(operand) == "string" then
      addSequence(audioSet, audioList, operand)
    elseif type(operand) == "number" then
      addSequence(audioSet, audioList, canonicalSequence(sounds, operand, context, step.op))
    elseif type(operand) == "table" and operand.value == "var" then
      if not variableFanfareMembers[context.memberId] then
        invalidDependency(context, "unsupported dynamic fanfare source")
      end
      for _, symbol in ipairs(ScriptAudioFacts.variableFanfareSequences) do
        addSequence(audioSet, audioList, symbol)
      end
    else
      invalidDependency(context, "unsupported dynamic audio operand for play_fanfare")
    end
  end
end

local function collectTargets(step, localLabels, targetSet, targetList)
  if step.op == "call_common" then
    if type(step.target) == "string" and targetSet[step.target] == nil then
      targetSet[step.target] = true
      targetList[#targetList + 1] = step.target
    end
  elseif step.op == "goto_script" then
    if type(step.script) == "string" and targetSet[step.script] == nil then
      targetSet[step.script] = true
      targetList[#targetList + 1] = step.script
    end
  elseif step.op == "goto_compared" or step.op == "call_compared" then
    if type(step.script) == "string" and targetSet[step.script] == nil then
      targetSet[step.script] = true
      targetList[#targetList + 1] = step.script
    end
  elseif step.op == "call" then
    if type(step.target) == "string" and localLabels[step.target] == nil and targetSet[step.target] == nil then
      targetSet[step.target] = true
      targetList[#targetList + 1] = step.target
    end
  end
end

local function collectLabels(steps, localLabels)
  for _, step in ipairs(steps) do
    if step.op == "label" then
      if type(step.name) == "string" then
        localLabels[step.name] = true
      end
    elseif step.op == "if" then
      if type(step.yes) == "table" then
        collectLabels(step.yes, localLabels)
      end
      if type(step.no) == "table" then
        collectLabels(step.no, localLabels)
      end
    elseif step.op == "switch" then
      if type(step.cases) == "table" then
        for _, caseSteps in pairs(step.cases) do
          if type(caseSteps) == "table" then
            collectLabels(caseSteps, localLabels)
          end
        end
      end
      if type(step.default) == "table" then
        collectLabels(step.default, localLabels)
      end
    end
  end
end

local function collectSteps(steps, sounds, localLabels, audioSet, audioList, targetSet, targetList, context)
  for _, step in ipairs(steps) do
    if step.op == "if" then
      if type(step.yes) == "table" then
        collectSteps(step.yes, sounds, localLabels, audioSet, audioList, targetSet, targetList, context)
      end
      if type(step.no) == "table" then
        collectSteps(step.no, sounds, localLabels, audioSet, audioList, targetSet, targetList, context)
      end
    elseif step.op == "switch" then
      if type(step.cases) == "table" then
        local keys = {}
        for key in pairs(step.cases) do
          keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
          return tostring(a) < tostring(b)
        end)
        for _, key in ipairs(keys) do
          if type(step.cases[key]) == "table" then
            collectSteps(step.cases[key], sounds, localLabels, audioSet, audioList, targetSet, targetList, context)
          end
        end
      end
      if type(step.default) == "table" then
        collectSteps(step.default, sounds, localLabels, audioSet, audioList, targetSet, targetList, context)
      end
    else
      collectAudio(step, sounds, audioSet, audioList, context)
      collectTargets(step, localLabels, targetSet, targetList)
    end
  end
end

---@param steps table[] final structured resource steps
---@param sounds table<number, string> pinned numeric-to-symbol sequence catalog
---@param context { memberId: integer, id: string } source identity of the resource under inspection
---@return { audioSequences: string[], scriptTargets: string[] }
function Session.directDependencies(steps, sounds, context)
  assert(type(steps) == "table", "dependency extraction requires resource steps")
  assert(type(sounds) == "table", "dependency extraction requires the pinned sound catalog")
  if type(context) ~= "table" or type(context.memberId) ~= "number" or context.memberId % 1 ~= 0 then
    Errors.raise("SCRIPT_MEMBER_INVALID", "dependency extraction requires member source context", {})
  end
  local source = {
    memberId = context.memberId,
    id = type(context.id) == "string" and context.id or "unknown",
  }
  local localLabels = {}
  collectLabels(steps, localLabels)
  local audioSet, audioList = {}, {}
  local targetSet, targetList = {}, {}
  collectSteps(steps, sounds, localLabels, audioSet, audioList, targetSet, targetList, source)
  table.sort(audioList)
  table.sort(targetList)
  return { audioSequences = audioList, scriptTargets = targetList }
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
  local sourceHash = self.sha1hex(view:toString())
  local resources, results = ScriptCompiler.translateMember(memberIr, scriptIndices, {
    stdCatalog = self.stdCatalog,
    romSha1 = self.romSha1,
    repository = "portemon",
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
  for _, entry in ipairs(resources) do
    entry.directDependencies =
      Session.directDependencies(entry.resource.steps, self.catalog.sounds, { memberId = memberId, id = entry.id })
  end
  return {
    memberId = memberId,
    marker = planned.marker,
    sourceHash = sourceHash,
    resources = resources,
    results = results,
    coverage = Coverage.record(memberIr, results, {
      repository = "portemon",
      romSha1 = self.romSha1,
    }),
  }
end

function Session:close()
  self.archive = nil
  return true
end

return Session
