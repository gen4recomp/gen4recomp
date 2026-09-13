-- Compiles the fresh-game standard-init event initializer from the decoded
-- source `_std_init` standard script (pret/pokeheartgold
-- files/fielddata/script/scr_seq/scr_seq_0149.s): every `SetFlag` becomes a
-- `set_flag` event operation and `LotoIDSet` becomes a `roll_loto_id`
-- lottery operation, both in source order under a single `operations` array.
-- Any other side-effecting source command fails the build instead of being
-- silently dropped. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")
local Hashing = require("romdump.src.digest.Hashing")

local NewGameInitCompiler = {}

NewGameInitCompiler.ERROR = {
  UNSUPPORTED_SIDE_EFFECT = "NEW_GAME_INIT_UNSUPPORTED_SIDE_EFFECT",
  UNKNOWN_FLAG_SYMBOL = "NEW_GAME_INIT_UNKNOWN_FLAG_SYMBOL",
  SOURCE_INVALID = "NEW_GAME_INIT_SOURCE_INVALID",
}

function NewGameInitCompiler.compile(input)
  assert(type(input) == "table", "compile requires an input table")
  assert(type(input.versionId) == "string", "compile requires a versionId")
  assert(type(input.standardScriptMember) == "number", "compile requires the standard script member id")
  assert(type(input.instructions) == "table", "compile requires decoded instructions")
  assert(type(input.symbolTable) == "table", "compile requires the flag symbol table")
  local variableSymbols = input.variableSymbols or input.variableTable
  local terminated = false
  local operations = {}

  for index, instruction in ipairs(input.instructions) do
    if terminated then
      Errors.raise(
        NewGameInitCompiler.ERROR.SOURCE_INVALID,
        "standard init script has instructions after End",
        { index = index }
      )
    end
    local mnemonic = instruction.mnemonic
    if mnemonic == "SetFlag" then
      local symbol = instruction.operands[1]
      local id = input.symbolTable[symbol]
      if id == nil then
        Errors.raise(
          NewGameInitCompiler.ERROR.UNKNOWN_FLAG_SYMBOL,
          "unknown startup flag symbol " .. tostring(symbol),
          { symbol = symbol, index = index }
        )
      end
      operations[#operations + 1] = { op = "set_flag", id = id, symbol = symbol }
    elseif mnemonic == "LotoIDSet" then
      local vars = require("libs.assets.src.field.FieldScriptSymbols").variablesByName
      local lowId = vars.VAR_LOTO_NUMBER_LO
      local highId = vars.VAR_LOTO_NUMBER_HI
      if variableSymbols ~= nil then
        if variableSymbols.VAR_LOTO_NUMBER_LO == nil or variableSymbols.VAR_LOTO_NUMBER_HI == nil then
          Errors.raise(
            NewGameInitCompiler.ERROR.SOURCE_INVALID,
            "lottery variable symbols are missing",
            { index = index }
          )
        end
        lowId = variableSymbols.VAR_LOTO_NUMBER_LO
        highId = variableSymbols.VAR_LOTO_NUMBER_HI
      end
      operations[#operations + 1] = {
        op = "roll_loto_id",
        lowVariableId = lowId,
        lowVariableSymbol = "VAR_LOTO_NUMBER_LO",
        highVariableId = highId,
        highVariableSymbol = "VAR_LOTO_NUMBER_HI",
      }
    elseif mnemonic == "End" then
      terminated = true
    else
      Errors.raise(
        NewGameInitCompiler.ERROR.UNSUPPORTED_SIDE_EFFECT,
        "unsupported startup side-effecting command " .. tostring(mnemonic),
        { mnemonic = mnemonic, index = index }
      )
    end
  end
  if not terminated then
    Errors.raise(NewGameInitCompiler.ERROR.SOURCE_INVALID, "standard init script must terminate with End", {})
  end

  local artifact = {
    schema = NewGameInitCache.SCHEMA,
    versionId = input.versionId,
    operations = operations,
    sourceDependency = {
      standardScriptMember = input.standardScriptMember,
      sha1 = input.sourceSha1 or "",
    },
  }
  local ok, err = NewGameInitCache.validate(artifact)
  if not ok then
    Errors.raise(NewGameInitCompiler.ERROR.SOURCE_INVALID, "compiled startup artifact is invalid", {
      cause = err and err.message or tostring(err),
    })
  end
  return artifact
end

local function standardInitMember(stdCatalog)
  for _, group in ipairs(stdCatalog.groups) do
    if stdCatalog.namesById[group.threshold] == "init" then
      return group.member
    end
  end
  error("standard-script catalog has no 'init' group")
end

function NewGameInitCompiler.compileFromRom(romFs, sha1hex, hashLua)
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local ok, result = pcall(function()
    assert(
      romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc,
      "compileFromRom requires a RomFs-shaped object"
    )
    local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
    local ScriptMembers = require("romdump.src.reference.hgss.script_members")
    local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

    local archiveInfo = assert(romFs:resolvedNarc("field_scripts"), "field_scripts NARC is unavailable")
    local archive = assert(romFs:openNarc("field_scripts"))
    local sourcePath = "romfs/" .. archiveInfo.path
    local catalog = { flags = require("romdump.src.reference.hgss.flags").byId }

    local stdCatalog = SourceCatalog.catalog()
    local member = standardInitMember(stdCatalog)
    local memberBytes = assert(archive:memberView(member), "standard init script member is not readable")
    local memberIr = assert(
      ScriptBinaryDecoder.parseMember(memberBytes, member, sourcePath, {
        msgBank = ScriptMembers.banks[member],
        catalog = catalog,
      }),
      "standard init script member is not decodable"
    )
    local script = assert(memberIr.scripts[0], "standard init script has no script index 0")

    local instructions = {}
    for _, ins in ipairs(script.instructions) do
      local operands = {}
      for operandIndex, operand in ipairs(ins.operands) do
        operands[operandIndex] = operand.raw
      end
      instructions[#instructions + 1] = { mnemonic = ins.name:gsub("^ScrCmd_", ""), operands = operands }
    end

    local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
    local sourceBytes = assert(archive:readMember(member))
    local artifact = NewGameInitCompiler.compile({
      versionId = romFs:version(),
      standardScriptMember = member,
      instructions = instructions,
      symbolTable = FieldScriptSymbols.flagsByName,
      variableSymbols = FieldScriptSymbols.variablesByName,
      sourceSha1 = sha1hex(sourceBytes),
    })

    local depHash = hashLua(artifact)
    local romSha1 = romFs:metadata().sha1
    local marker = NewGameInitCache.marker(romSha1, depHash)
    return { artifact = artifact, marker = marker, romSha1 = romSha1, depHash = depHash }
  end)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result, 0)
end

return NewGameInitCompiler
