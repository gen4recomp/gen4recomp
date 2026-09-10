-- ROM-gated script-corpus verification: decodes every scr_seq member of the
-- real dump in one traversal, validates the produced semantic scripts, pins
-- the closed sound-opcode partition and opcode 726 soundplate lowering, and
-- owns the source script-audio player-role invariants derived from that
-- traversal and one parsed source SDAT.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local Sdat = require("libs.nds.src.nitro.sound.Sdat")
local Verifier = require("romdump.src.digest.script.Verifier")
local S = require("gen4.script")

local T = {}

local SUPPORTED_OPS = { 73, 74, 75, 78, 79, 80, 81, 82, 84, 85, 87, 726 }
local CRY_OPS = { 76, 77, 89, 90, 91, 92 }
local ABSENT_OPS = { 83, 86, 88, 93, 544, 575, 664, 665, 666 }
local REACHABLE_EXCLUDED_OPS = { 218, 779 }
local SOUND_NAME_KEYWORDS = { "SE", "BGM", "Fanfare", "Cry", "Chatot", "Music", "Sound" }

local SDAT_PATH = "data/sound/gs_sound_data.sdat"

local ALLOWED_REACHABLE_SOUND = {}
for _, op in ipairs(SUPPORTED_OPS) do
  ALLOWED_REACHABLE_SOUND[op] = true
end
for _, op in ipairs(CRY_OPS) do
  ALLOWED_REACHABLE_SOUND[op] = true
end
for _, op in ipairs(REACHABLE_EXCLUDED_OPS) do
  ALLOWED_REACHABLE_SOUND[op] = true
end

local ALLOWED_VERIFIER_MESSAGES = {
  ["return below an empty script stack"] = true,
  ["return with no matching call"] = true,
}

local function soundRelated(name)
  for _, keyword in ipairs(SOUND_NAME_KEYWORDS) do
    if name:find(keyword, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function scrub(step)
  step.movementComplete = nil
  step.movementUnsupported = nil
  step.yieldsNextTick = nil
  step.sourceNotes = nil
end

T["corpus decodes validates and sound partition remains closed"] = function(romFs)
  local sdatBytes = assert(romFs:readSourcePath(SDAT_PATH), "cannot read " .. SDAT_PATH)
  local sdat, parseErr = Sdat.open(sdatBytes, SDAT_PATH)
  Assert.notNil(sdat, "cannot parse " .. SDAT_PATH .. ": " .. tostring(parseErr))
  sdat = assert(sdat)

  local sequenceIdBySymbol = {}
  for id = 0, sdat.counts.sequences - 1 do
    local record = sdat.sequences[id]
    if record ~= nil and record.fileId ~= nil then
      local symbol = sdat.symbols.sequences[id]
      Assert.notNil(symbol, "used sequence " .. id .. " has a symbol")
      Assert.isTrue(type(symbol) == "string" and #symbol > 0, "used sequence " .. id .. " symbol non-empty")
      if sequenceIdBySymbol[symbol] ~= nil then
        error(
          "duplicate sequence symbol " .. symbol .. " for ids " .. tostring(sequenceIdBySymbol[symbol]) .. " and " .. id,
          0
        )
      end
      sequenceIdBySymbol[symbol] = id
    end
  end

  local function resolvePlayerId(symbol)
    local sequenceId = sequenceIdBySymbol[symbol]
    Assert.notNil(sequenceId, "script audio reference " .. tostring(symbol) .. " resolves to a used sequence")
    local record = sdat.sequences[assert(sequenceId)]
    Assert.notNil(record, "sequence " .. tostring(sequenceId) .. " record present")
    return record.playerId
  end

  local players = {
    bgm = {},
    fanfare = {},
    effect = {},
    waitEffect = {},
  }
  local variableFanfares = 0
  local unexpectedProblems = {}

  local archive, memberIrs = FieldScripts.decode(romFs)

  local scriptCount = 0
  local decodeNotes = 0
  local reachable = {}
  local raw726 = 0
  local unsupported726 = 0
  local semanticCount = 0

  FieldScripts.eachScript(archive, memberIrs, function(member, index, steps, lowered)
    scriptCount = scriptCount + 1
    local script = memberIrs[member].scripts[index]
    if script.decodeNote ~= nil then
      decodeNotes = decodeNotes + 1
    end
    local report = Verifier.verifyScript(steps, script, memberIrs[member], lowered.omissions)
    if not report.ok then
      local isAllowedLocation = (member == 151 and index == 5)
      local allAllowed = true
      for _, problem in ipairs(report.problems) do
        local message = problem.message
        if type(problem) == "string" then
          message = problem
        end
        if not ALLOWED_VERIFIER_MESSAGES[message] then
          allAllowed = false
          break
        end
      end
      if not (isAllowedLocation and allAllowed) then
        unexpectedProblems[#unexpectedProblems + 1] =
          { member = member, scriptIndex = index, messages = report.problems }
      end
    end
    for _, ins in ipairs(script.instructions) do
      local sites = reachable[ins.opcode]
      if sites == nil then
        sites = {}
        reachable[ins.opcode] = sites
      end
      if #sites < 3 then
        sites[#sites + 1] = ("member %d script %d offset 0x%04X"):format(member, script.index, ins.offset)
      end
      if ins.opcode == 726 then
        raw726 = raw726 + 1
      end
    end
    if lowered.unsupported then
      for _, node in ipairs(lowered.unsupported) do
        if node.command == 726 then
          unsupported726 = unsupported726 + 1
        end
      end
    end
    FieldScripts.eachStep(steps, function(step)
      if step.op == "process_soundplate" then
        semanticCount = semanticCount + 1
      end
      local op = step.op
      if op == "play_music" then
        players.bgm[resolvePlayerId(step.music)] = true
      elseif op == "play_fanfare" then
        if type(step.fanfare) == "string" then
          players.fanfare[resolvePlayerId(step.fanfare)] = true
        else
          variableFanfares = variableFanfares + 1
        end
      elseif op == "play_sound" or op == "stop_sound" then
        Assert.isTrue(type(step.sound) == "string", op .. " operands are constants")
        players.effect[resolvePlayerId(step.sound)] = true
      elseif op == "wait_sound" then
        Assert.isTrue(type(step.sound) == "string", "wait_sound operands are constants")
        players.waitEffect[resolvePlayerId(step.sound)] = true
      end
    end)
    FieldScripts.eachStep(steps, scrub)
    local ok, err = S.validate({ api = 1, id = "check", steps = steps })
    if not ok then
      error("script " .. member .. "/" .. index .. " fails validation: " .. tostring(err))
    end
  end)

  Assert.isTrue(scriptCount > 2000, "expected the full script corpus")
  Assert.equal(decodeNotes, 0)
  do
    local lines = {}
    for _, entry in ipairs(unexpectedProblems) do
      local msgs = {}
      for _, problem in ipairs(entry.messages) do
        local m = problem.message
        if type(problem) == "string" then
          m = problem
        end
        msgs[#msgs + 1] = tostring(m)
      end
      lines[#lines + 1] = ("member %d script %d: %s"):format(entry.member, entry.scriptIndex, table.concat(msgs, ", "))
    end
    Assert.equal(#unexpectedProblems, 0, "unexpected verifier problems: " .. table.concat(lines, " | "))
  end

  local missing = {}
  for _, op in ipairs(SUPPORTED_OPS) do
    if reachable[op] == nil then
      missing[#missing + 1] = CommandCatalog.name(op) .. " (" .. tostring(op) .. ")"
    end
  end
  Assert.equal(#missing, 0, "supported sound opcodes have no retail callsite: " .. table.concat(missing, ", "))

  local diverged = {}
  for _, op in ipairs(ABSENT_OPS) do
    if reachable[op] ~= nil then
      diverged[#diverged + 1] = CommandCatalog.name(op)
        .. " ("
        .. tostring(op)
        .. ") at "
        .. table.concat(reachable[op], "; ")
    end
  end
  Assert.equal(#diverged, 0, "unsupported sound opcodes reached the retail corpus: " .. table.concat(diverged, " || "))

  local gone = {}
  for _, op in ipairs(REACHABLE_EXCLUDED_OPS) do
    if reachable[op] == nil then
      gone[#gone + 1] = CommandCatalog.name(op) .. " (" .. tostring(op) .. ")"
    end
  end
  Assert.equal(#gone, 0, "reachable-excluded sound opcodes lost their retail callsites: " .. table.concat(gone, ", "))

  local unexpected = {}
  for op, sites in pairs(reachable) do
    if not ALLOWED_REACHABLE_SOUND[op] and soundRelated(CommandCatalog.name(op)) then
      unexpected[#unexpected + 1] = CommandCatalog.name(op)
        .. " ("
        .. tostring(op)
        .. ") at "
        .. table.concat(sites, "; ")
    end
  end
  Assert.equal(
    #unexpected,
    0,
    "sound-related field opcodes outside the closed partition: " .. table.concat(unexpected, " || ")
  )

  Assert.isTrue(raw726 >= 1, "retail corpus must reach opcode 726")
  Assert.equal(unsupported726, 0, "no 726 callsite may lower as unsupported")
  Assert.isTrue(semanticCount >= 1, "at least one semantic process_soundplate must originate from 726")
  Assert.equal(semanticCount, raw726, "every raw 726 callsite must survive as a semantic process_soundplate")

  Assert.isTrue(variableFanfares >= 1, "retail scripts select fanfares dynamically")
  Assert.isTrue(next(players.bgm) ~= nil, "field scripts play BGM")
  Assert.isTrue(next(players.effect) ~= nil, "field scripts play effects")

  local function intersects(a, b)
    for playerId in pairs(a) do
      if b[playerId] then
        return true
      end
    end
    return false
  end

  Assert.isFalse(intersects(players.bgm, players.fanfare), "a fanfare never shares a player id with the BGM players")
  Assert.isFalse(intersects(players.bgm, players.effect), "an effect never shares a player id with the BGM players")
  for playerId in pairs(players.waitEffect) do
    Assert.isTrue(players.effect[playerId] == true, "WaitSE observes only effect players")
  end

  local mapPlayers = {}
  for record in MapCatalog.all() do
    for _, field in ipairs({ "dayMusic", "nightMusic" }) do
      local symbol = "SEQ_" .. record[field]
      local sequenceId = sequenceIdBySymbol[symbol]
      Assert.notNil(
        sequenceId,
        record.symbol .. " " .. field .. " " .. tostring(record[field]) .. " resolves to a sequence"
      )
      mapPlayers[sdat.sequences[assert(sequenceId)].playerId] = true
    end
  end
  local count = 0
  local only = nil
  for playerId in pairs(mapPlayers) do
    count = count + 1
    only = playerId
  end
  Assert.equal(count, 1, "map music always plays on one fixed player id")
  Assert.isTrue(players.bgm[assert(only)] == true, "the map-music player is a BGM player")

  for role, set in pairs(players) do
    for playerId in pairs(set) do
      local player = sdat.players[playerId]
      Assert.notNil(player, role .. " player " .. playerId .. " exists")
      Assert.equal(player.maxSequences, 1, role .. " player " .. playerId .. " declares exactly one sequence slot")
    end
  end
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.slow = true
suite.metadata.tags = { "script", "corpus" }
return suite
