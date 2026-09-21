-- ROM-backed worker identity: two field cells sharing one animation compiler
-- memo key must publish identical animation records whether they compile
-- back to back inside one persistent worker or in isolation. The worker
-- releases transient geometry scratch at every job boundary, so no member
-- hash may leak from one cell's published record into another's.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CompilerWorker = require("romdump.src.build.CompilerWorker")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local GENERATION_ID = "field-cell-animation-identity"
local PRODUCER = "field-cell-animation-identity-producer"

local function freshScratch()
  return {
    geometryArena = GxGeometryBuffer.new(),
    gxScratch = GxDisplayList.newScratch(),
    terrainScratch = {},
  }
end

local function scriptedChannel(messages)
  local pending = {}
  for _, message in ipairs(messages) do
    pending[#pending + 1] = message
  end
  local channel = { pushed = {} }
  function channel:push(value)
    pending[#pending + 1] = value
    self.pushed[#self.pushed + 1] = value
    return true
  end
  function channel:pop()
    if #pending == 0 then
      return nil
    end
    return table.remove(pending, 1)
  end
  function channel:demand()
    local value = self:pop()
    assert(value ~= nil, "the worker demanded beyond its scripted controls")
    return value
  end
  return channel
end

local function animKey(descriptor)
  return string.format("%s:%s", tostring(descriptor.areaDataMemberId), tostring(descriptor.mapHeaderId))
end

local function memberIdSet(record)
  local set, ids = {}, {}
  local list = (
    record
    and record.terrainAnimation
    and record.terrainAnimation.fieldTextureAnimations
    and record.terrainAnimation.fieldTextureAnimations.memberSha1s
  ) or {}
  for _, entry in ipairs(list) do
    if not set[entry.memberId] then
      set[entry.memberId] = true
      ids[#ids + 1] = entry.memberId
    end
  end
  table.sort(ids)
  return set, ids
end

local function cellJob(descriptor, stageName, versionId)
  local key = string.format("%d-%d", descriptor.matrixMemberId, descriptor.index)
  return {
    kind = "field-cell",
    key = key,
    versionId = versionId,
    generationId = GENERATION_ID,
    epoch = 1,
    stageName = stageName,
    producerFingerprint = PRODUCER,
    payload = {
      matrixMemberId = descriptor.matrixMemberId,
      index = descriptor.index,
      x = descriptor.x,
      z = descriptor.z,
      mapHeaderId = descriptor.mapHeaderId,
      altitude = descriptor.altitude,
      landDataMemberId = descriptor.landDataMemberId,
      areaDataMemberId = descriptor.areaDataMemberId,
    },
  }
end

local function stageOptions(cacheFs, job)
  return {
    cacheFs = cacheFs,
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.kind .. ":" .. job.key,
    stageName = job.stageName,
  }
end

local function discardStage(cacheFs, job)
  local ok, artifact = pcall(PreparedArtifact.open, stageOptions(cacheFs, job))
  if ok and artifact:isAbortable() then
    artifact:abort()
  end
end

local function runWorker(workerId, jobs)
  local messages = {}
  for _, job in ipairs(jobs) do
    messages[#messages + 1] = job
  end
  messages[#messages + 1] = { kind = "stop" }
  local input = scriptedChannel(messages)
  local output = scriptedChannel({})
  CompilerWorker.run(workerId, input, output)
  return output.pushed
end

local function readStagedDependencies(cacheFs, job)
  local artifact = assert(PreparedArtifact.open(stageOptions(cacheFs, job)), "the worker left no stage to read back")
  local path = FieldCellCache.dependenciesPath(job.payload.matrixMemberId, job.payload.index)
  local dependencies = assert(artifact:stageFs():loadLua(path), "the staged cell carries no dependencies record")
  return dependencies
end

function T.sequential_worker_cells_keep_independent_animation_records(romFs, versionId)
  local indexBundle = assert(FieldCellCompiler.compileIndex(romFs))
  local groupOrder, groups = {}, {}
  for _, matrix in ipairs(indexBundle.index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      local key = animKey(descriptor)
      if groups[key] == nil then
        groups[key] = {}
        groupOrder[#groupOrder + 1] = key
      end
      groups[key][#groups[key] + 1] = descriptor
    end
  end
  local first, second = nil, nil
  for _, key in ipairs(groupOrder) do
    local cells = groups[key]
    if #cells >= 2 then
      local freshRecords = {}
      for i, descriptor in ipairs(cells) do
        local compiled = assert(FieldCellCompiler.compileCell(romFs, descriptor, freshScratch(), PRODUCER))
        freshRecords[i] = compiled.cell.dependencies
      end
      for i = 1, #cells do
        for j = 1, #cells do
          if i ~= j then
            local setA = memberIdSet(freshRecords[i])
            local setB = memberIdSet(freshRecords[j])
            for id in pairs(setA) do
              if not setB[id] then
                first, second = cells[i], cells[j]
                break
              end
            end
            if first ~= nil then
              break
            end
          end
        end
        if first ~= nil then
          break
        end
      end
    end
    if first ~= nil then
      break
    end
  end
  Assert.notNil(first, "the ROM corpus holds two same-map cells with distinct animation member reads")
  Assert.notNil(second, "the ROM corpus holds two same-map cells with distinct animation member reads")

  local cacheFs = CacheFs.forVersion(versionId)
  local freshJob = cellJob(second, "anim-identity-fresh", versionId)
  local sharedFirst = cellJob(first, "anim-identity-shared-first", versionId)
  local sharedSecond = cellJob(second, "anim-identity-shared-second", versionId)
  discardStage(cacheFs, freshJob)
  discardStage(cacheFs, sharedFirst)
  discardStage(cacheFs, sharedSecond)

  local freshReplies = runWorker(11, { freshJob })
  Assert.equal(freshReplies[1].status, "prepared", "the isolated cell job compiles")
  local freshDependencies = readStagedDependencies(cacheFs, freshJob)

  local sharedReplies = runWorker(12, { sharedFirst, sharedSecond })
  Assert.equal(sharedReplies[1].status, "prepared", "the first sequential cell job compiles")
  Assert.equal(sharedReplies[2].status, "prepared", "the second sequential cell job compiles")
  local sharedDependencies = readStagedDependencies(cacheFs, sharedSecond)

  Assert.deepEqual(
    sharedDependencies.terrainAnimation,
    freshDependencies.terrainAnimation,
    "a cell compiled after another same-map cell in one worker publishes the animation record of an isolated compile"
  )
  Assert.equal(
    sharedDependencies.marker,
    freshDependencies.marker,
    "a cell compiled after another same-map cell keeps its isolated marker"
  )

  discardStage(cacheFs, freshJob)
  discardStage(cacheFs, sharedFirst)
  discardStage(cacheFs, sharedSecond)
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.tags = { "producer", "terrain", "field-cell" }
return suite
