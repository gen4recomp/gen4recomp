-- Shared decode/walk helpers for ROM suites that consume the real field-script
-- corpus: opens scr_seq.narc and decodes every member through the production
-- decoder, then walks the structured steps of each script (lowering and
-- structuring included) so the corpus pass is defined once.

local FieldScripts = {}

-- Message/sound catalogs shared by the full and explicit-member decode paths
-- so subset reads canonicalize exactly like the whole-archive decode.
local function catalog()
  return {
    sounds = require("romdump.src.reference.hgss.sndseq").byId,
    flags = require("romdump.src.reference.hgss.flags").byId,
    vars = require("romdump.src.reference.hgss.vars").byId,
    maps = require("romdump.src.reference.hgss.maps").byId,
    spawns = require("romdump.src.reference.hgss.spawns").byId,
  }
end

---@param romFs table
---@return table archive
---@return table[] memberIrs
function FieldScripts.decode(romFs)
  local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
  local ScriptMembers = require("romdump.src.reference.hgss.script_members")
  local archive = assert(romFs:openNarc("field_scripts"))
  local memberIrs = ScriptBinaryDecoder.decodeArchive(archive, ScriptMembers.banks, "romfs/scr_seq.narc", catalog())
  return archive, memberIrs
end

-- Decode exactly the requested field-script members through the production
-- member decoder with the same banks/catalogs as the full decode. Reads
-- happen once per unique id in caller order; the result is a sparse table
-- keyed by original member id (header members stay absent, as in the full
-- decode) so eachScript consumes it unchanged. The archive walk itself
-- still visits members in archive order.
---@param romFs table
---@param memberIds integer[]
---@return table archive
---@return table memberIrs
function FieldScripts.decodeMembers(romFs, memberIds)
  local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
  local ScriptMembers = require("romdump.src.reference.hgss.script_members")
  assert(type(memberIds) == "table", "decodeMembers needs an array of member ids")
  local archive = assert(romFs:openNarc("field_scripts"))
  local count = archive:memberCount()
  local ordered = {}
  local wanted = {}
  for position, memberId in ipairs(memberIds) do
    if type(memberId) ~= "number" or memberId ~= math.floor(memberId) or memberId < 0 or memberId >= count then
      error(
        "field-script member " .. tostring(memberId) .. " at position " .. position .. " is not a valid member id",
        0
      )
    end
    if not wanted[memberId] then
      wanted[memberId] = true
      ordered[#ordered + 1] = memberId
    end
  end
  local shared = catalog()
  local memberIrs = {}
  for _, memberId in ipairs(ordered) do
    local bytes = archive:readMember(memberId)
    memberIrs[memberId] = ScriptBinaryDecoder.parseMember(bytes, memberId, "romfs/scr_seq.narc", {
      msgBank = ScriptMembers.banks[memberId],
      catalog = shared,
    })
  end
  return archive, memberIrs
end

---@param archive table
---@param memberIrs table[]
---@param fn fun(member: integer, index: integer, steps: table[], lowered: table)
function FieldScripts.eachScript(archive, memberIrs, fn)
  local stdCatalog = require("romdump.src.digest.script.SourceCatalog").catalog()
  local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
  local Structurer = require("romdump.src.digest.script.Structurer")
  for member = 0, archive:memberCount() - 1 do
    local ir = memberIrs[member]
    if ir ~= nil then
      for index, script in pairs(ir.scripts) do
        local lowered = SemanticLowering.lowerScript(script, ir, { stdCatalog = stdCatalog })
        fn(member, index, Structurer.structure(lowered, index), lowered)
      end
    end
  end
end

---@param items table[]
---@param fn fun(step: table)
function FieldScripts.eachStep(items, fn)
  for _, item in ipairs(items) do
    if item.op == "if" then
      FieldScripts.eachStep(item.yes, fn)
      FieldScripts.eachStep(item.no, fn)
    elseif item.op == "switch" then
      for _, caseSteps in pairs(item.cases) do
        FieldScripts.eachStep(caseSteps, fn)
      end
      FieldScripts.eachStep(item.default, fn)
    else
      fn(item)
    end
  end
end

return FieldScripts
