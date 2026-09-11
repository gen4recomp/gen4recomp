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

return { metadata = { capabilities = {} }, tests = T }
