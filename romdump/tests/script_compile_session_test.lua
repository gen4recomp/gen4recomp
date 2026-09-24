-- Script member session tests cover the source-byte hashing boundary and a
-- successful translation through the default compiler path.

local Assert = require("tests.support.Assert")
local Hashing = require("romdump.src.digest.Hashing")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local Session = require("romdump.src.digest.script.ScriptCompileSession")
local Narc = require("libs.nds.src.nitro.Narc")
local NarcBuilder = require("tests.support.NarcBuilder")
local ScriptFixture = require("tests.support.ScriptFixture")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local PINNED_FANFARE_MEMBER = 148
local PINNED_FANFARE_PAIR = { "SEQ_ME_HYOUKA1", "SEQ_ME_HYOUKA6" }

local function context(memberId, id)
  return { memberId = memberId, id = id }
end

local function varFanfareSteps()
  return {
    { op = "play_fanfare", fanfare = { value = "var", id = "x8000" } },
    { op = "stop" },
  }
end

function T.variable_fanfare_expands_to_the_pinned_pair_for_the_pinned_member()
  local sounds = {}
  local deps = Session.directDependencies(varFanfareSteps(), sounds, context(PINNED_FANFARE_MEMBER, "test.fanfare"))
  Assert.deepEqual(deps.audioSequences, PINNED_FANFARE_PAIR)
  Assert.deepEqual(deps.scriptTargets, {})
end

function T.variable_fanfare_outside_the_pinned_member_fails()
  local sounds = {}
  local failure = Assert.throws(function()
    Session.directDependencies(varFanfareSteps(), sounds, context(PINNED_FANFARE_MEMBER + 1, "test.fanfare"))
  end, "a variable fanfare outside the pinned member must fail")
  Assert.equal(failure.code, "SCRIPT_MEMBER_INVALID")
end

function T.dependency_extraction_requires_member_source_context()
  local sounds = {}
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- the missing context is the invalid input under test
    Session.directDependencies(varFanfareSteps(), sounds, nil)
  end, "missing source context must fail")
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- the context-free id is the invalid input under test
    Session.directDependencies(varFanfareSteps(), sounds, "test.fanfare")
  end, "a bare resource id without member identity must fail")
end

function T.nested_branches_contribute_audio_and_exclude_local_labels()
  local sounds = {}
  local steps = {
    { op = "play_music", music = "SEQ_GS_NAMINORI" },
    { op = "label", name = "loop" },
    { op = "call", target = "loop" },
    {
      op = "if",
      condition = { condition = "flag", id = 1 },
      yes = { { op = "play_fanfare", fanfare = "SEQ_ME_HYOUKA1" } },
      no = { { op = "stop_sound", sound = "SEQ_SE_GS_N_SESERAGI" } },
    },
    {
      op = "switch",
      value = 1,
      cases = {
        [1] = { { op = "wait_sound", sound = "SEQ_SE_GS_N_SESERAGI" } },
        [2] = { { op = "call_common", target = "common.other" } },
      },
      default = { { op = "temporary_music", music = "SEQ_GS_TITLE" } },
    },
    { op = "stop" },
  }
  local deps = Session.directDependencies(steps, sounds, context(3, "common.signpost"))
  Assert.deepEqual(deps.audioSequences, { "SEQ_GS_NAMINORI", "SEQ_GS_TITLE", "SEQ_ME_HYOUKA1", "SEQ_SE_GS_N_SESERAGI" })
  Assert.deepEqual(deps.scriptTargets, { "common.other" })
end

function T.numeric_sequence_references_normalize_through_the_sound_catalog()
  local sounds = { [1014] = "SEQ_SE_GS_N_SESERAGI" }
  local deps = Session.directDependencies({
    { op = "play_sound", sound = 1014 },
    { op = "stop" },
  }, sounds, context(3, "common.signpost"))
  Assert.deepEqual(deps.audioSequences, { "SEQ_SE_GS_N_SESERAGI" })
  Assert.deepEqual(deps.scriptTargets, {})
end

function T.dynamic_sound_and_music_operands_fail()
  local sounds = {}
  local soundFailure = Assert.throws(function()
    Session.directDependencies({
      { op = "play_sound", sound = { value = "var", id = "x8000" } },
      { op = "stop" },
    }, sounds, context(3, "common.signpost"))
  end, "a dynamic sound operand must fail")
  Assert.equal(soundFailure.code, "SCRIPT_MEMBER_INVALID")
  local musicFailure = Assert.throws(function()
    Session.directDependencies({
      { op = "play_music", music = { value = "var", id = "x4000" } },
      { op = "stop" },
    }, sounds, context(3, "common.signpost"))
  end, "a dynamic music operand must fail")
  Assert.equal(musicFailure.code, "SCRIPT_MEMBER_INVALID")
  local numericFailure = Assert.throws(function()
    Session.directDependencies({
      { op = "play_sound", sound = 999999 },
      { op = "stop" },
    }, sounds, context(3, "common.signpost"))
  end, "an unknown numeric sequence must fail")
  Assert.equal(numericFailure.code, "SCRIPT_MEMBER_INVALID")
end

function T.member_session_hashes_the_exact_binary_view_bytes()
  local memberBytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = { { op = 2, args = {} } } },
    },
  })
  local archive = assert(Narc.open(NarcBuilder.build({ memberBytes }), "synthetic scripts"))
  local id = ScriptCompiler.publicId(0, 0, SourceCatalog.catalog())
  local plan = {
    generationKey = string.rep("a", 40),
    sourcePath = "romfs/scr_seq.narc",
    memberCount = 1,
    members = {
      {
        memberId = 0,
        marker = "member-marker",
        scripts = { { scriptIndex = 0, id = id } },
      },
    },
  }
  local romFs = {
    openNarc = function(_, alias)
      Assert.equal(alias, "field_scripts")
      return archive
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }

  local session = assert(Session.new(romFs, plan))
  local compiled = assert(session:compileMember(0))

  Assert.equal(compiled.sourceHash, Hashing.sha1hex(memberBytes))
  Assert.equal(#compiled.sourceHash, 40)
  Assert.isTrue(compiled.sourceHash:match("^[0-9a-f]+$") ~= nil)
  Assert.equal(#compiled.resources, 1)
  Assert.isTrue(compiled.results[0].report.complete)
end

function T.compile_member_attaches_direct_dependency_facts_to_every_resource()
  local memberBytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = { { op = 2, args = {} } } },
    },
  })
  local archive = assert(Narc.open(NarcBuilder.build({ memberBytes }), "synthetic scripts"))
  local id = ScriptCompiler.publicId(0, 0, SourceCatalog.catalog())
  local plan = {
    generationKey = string.rep("b", 40),
    sourcePath = "romfs/scr_seq.narc",
    memberCount = 1,
    members = {
      {
        memberId = 0,
        marker = "member-marker",
        scripts = { { scriptIndex = 0, id = id } },
      },
    },
  }
  local romFs = {
    openNarc = function()
      return archive
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  local session = assert(Session.new(romFs, plan))
  local compiled = assert(session:compileMember(0))
  Assert.equal(#compiled.resources, 1)
  local direct = compiled.resources[1].directDependencies
  Assert.isTrue(type(direct) == "table", "every compiled resource carries compiler dependency facts")
  Assert.deepEqual(direct.audioSequences, {})
  Assert.deepEqual(direct.scriptTargets, {})
end

return { metadata = { capabilities = {} }, tests = T }
