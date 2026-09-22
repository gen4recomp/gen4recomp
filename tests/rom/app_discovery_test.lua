-- Real-ROM Bag/overlay-15 calibration: the independent production discovery
-- pipeline recovers the pinned structural facts directly from a canonical
-- HeartGold/SoulSilver ROM opened through RomSource/NdsRom -- never through
-- the imported derived cache, RomFs, or curated Bag source tables. The
-- expected structural facts (three Thumb application callbacks, a 38-case
-- main dispatch, archive index 15 mapping to NitroFS a/0/1/5 with 95
-- members, and representative member formats) are independently pinned
-- calibration evidence, not values read from this repository's own Bag
-- asset compiler.

local Assert = require("tests.support.Assert")
local RomSource = require("romdump.src.source.RomSource")
local NdsRom = require("romdump.src.source.NdsRom")
local AppDiscovery = require("romdump.src.appdiscovery.AppDiscovery")
local EvidenceArchive = require("romdump.src.appdiscovery.EvidenceArchive")
local RomSourcePath = require("tests.rom.support.RomSourcePath")

local T = {}

local OVERLAY_ID = 15
local NARC_INDEX = 15
local EXPECTED_NARC_PATH = "a/0/1/5"
local EXPECTED_MEMBER_COUNT = 95
local EXPECTED_SWITCH_CASE_COUNT = 38
local EXPECTED_MEMBER_KINDS = {
  [7] = "ncgr",
  [8] = "nclr",
  [9] = "nscr",
  [49] = "ncer",
  [50] = "nanr",
  [55] = "nsbmd",
}
local DETAIL_SELECTIONS = {
  { fileId = 144, memberId = 7 },
  { fileId = 144, memberId = 8 },
  { fileId = 144, memberId = 9 },
  { fileId = 144, memberId = 49 },
  { fileId = 144, memberId = 50 },
  { fileId = 144, memberId = 55 },
}

local MOUNT_POINT = "g4-app-evidence-calibration"
local MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
local MAX_MEMBER_COUNT = 2048
local MAX_MANIFEST_BYTES = 512 * 1024
local MAX_ANALYSIS_BYTES = 2 * 1024 * 1024

---@type table|nil
local rom
---@type AppDiscovery.Collected|nil
local collected
---@type AppDiscovery.BuildResult|nil
local built
local archiveBytes

local function openRom()
  local path = RomSourcePath.find()
  assert(path, "the rom_source capability was available but no --rom-source path was found on the command line")
  local source, sourceErr = RomSource.fromPath(path)
  if not source then
    error("cannot open ROM source " .. tostring(path) .. ": " .. tostring(sourceErr), 0)
  end
  local opened, romErr = NdsRom.open(source)
  if not opened then
    source:release()
    error("cannot validate ROM " .. tostring(path) .. ": " .. tostring(romErr), 0)
  end
  return opened
end

local function findThumbEntrypointCandidate(application)
  for _, candidate in ipairs(application.entrypointCandidates) do
    if candidate.initState == "thumb" and candidate.mainState == "thumb" and candidate.exitState == "thumb" then
      return candidate
    end
  end
  return nil
end

local function findPrimaryNarcIdCandidate(resources)
  for _, candidate in ipairs(resources.narcIdCandidates) do
    if candidate.primaryCandidate then
      return candidate
    end
  end
  return nil
end

local function findNarc(resources, path)
  for _, narc in ipairs(resources.narcs) do
    if narc.path == path then
      return narc
    end
  end
  return nil
end

local function findDetail(resources, memberId)
  for _, detail in ipairs(resources.details) do
    if detail.fileId == 144 and detail.memberId == memberId then
      return detail
    end
  end
  return nil
end

function T.overlay_15_exposes_a_three_thumb_pointer_entrypoint_candidate()
  local evidence = assert(collected)
  local candidate = findThumbEntrypointCandidate(evidence.application)
  Assert.notNil(candidate, "expected at least one Thumb entrypoint candidate for overlay 15")
  ---@cast candidate table
  Assert.notNil(candidate.initTarget)
  Assert.notNil(candidate.mainTarget)
  Assert.notNil(candidate.exitTarget)
  Assert.equal(candidate.initState, "thumb")
  Assert.equal(candidate.mainState, "thumb")
  Assert.equal(candidate.exitState, "thumb")
end

function T.overlay_15_recovers_the_thirty_eight_case_main_dispatch_switch()
  local evidence = assert(collected)
  local found = nil
  for _, switch in ipairs(evidence.application.switches) do
    if switch.caseCount == EXPECTED_SWITCH_CASE_COUNT then
      found = switch
    end
  end
  Assert.notNil(found, "expected a recovered switch with exactly " .. EXPECTED_SWITCH_CASE_COUNT .. " cases")
  ---@cast found { cases: table[] }
  Assert.equal(#found.cases, EXPECTED_SWITCH_CASE_COUNT)
end

function T.narc_index_fifteen_maps_to_the_expected_nitro_fs_path_and_member_census()
  local evidence = assert(collected)
  local primary = findPrimaryNarcIdCandidate(evidence.resources)
  Assert.notNil(primary, "expected a primary NARC-ID pointer-run candidate")
  ---@cast primary { entries: table[] }

  local entry
  for _, e in ipairs(primary.entries) do
    if e.index == NARC_INDEX then
      entry = e
    end
  end
  Assert.notNil(entry, "expected zero-based index " .. NARC_INDEX .. " in the primary candidate run")
  ---@cast entry table
  Assert.equal(entry.path, EXPECTED_NARC_PATH)

  local narc = findNarc(evidence.resources, EXPECTED_NARC_PATH)
  Assert.notNil(narc, "expected the " .. EXPECTED_NARC_PATH .. " NARC to be scanned")
  ---@cast narc { memberCount: integer, members: table[] }
  Assert.equal(narc.memberCount, EXPECTED_MEMBER_COUNT)
  Assert.equal(#narc.members, EXPECTED_MEMBER_COUNT)

  for memberId, kind in pairs(EXPECTED_MEMBER_KINDS) do
    local member = narc.members[memberId + 1]
    Assert.notNil(member, "missing member " .. memberId)
    Assert.equal(member.kind, kind, "member " .. memberId .. " kind")
  end
end

function T.build_is_byte_identical_from_one_collection()
  local primary = assert(built)
  local repeated = AppDiscovery.build(assert(collected))
  Assert.deepEqual(repeated.files, primary.files)
  Assert.deepEqual(repeated.manifest, primary.manifest)
  Assert.deepEqual(repeated.summary, primary.summary)
end

function T.bundle_is_usable_and_mounts_the_locked_members()
  local primary = assert(built)
  local bytes = assert(archiveBytes)

  local memberCount = 0
  local hasNarcFile = false
  local hasDisassemblyFile = false
  local hasPreviewPath = false
  for path in pairs(primary.files) do
    memberCount = memberCount + 1
    if path:match("^resources/narcs/file%-%d+%.lua$") then
      hasNarcFile = true
    end
    if path:match("^application/disassembly/fn%-%x%x%x%x%x%x%x%x%.md$") then
      hasDisassemblyFile = true
    end
    if path:sub(1, #"resources/previews/") == "resources/previews/" then
      hasPreviewPath = true
    end
  end

  Assert.isTrue(#bytes <= MAX_ARCHIVE_BYTES, "encoded ZIP exceeds the Bag usability ceiling")
  Assert.isTrue(memberCount <= MAX_MEMBER_COUNT, "bundle member count exceeds the Bag usability ceiling")
  Assert.isTrue(#primary.files["manifest.lua"] <= MAX_MANIFEST_BYTES, "manifest exceeds the Bag usability ceiling")
  Assert.isTrue(
    #primary.files["application/analysis.lua"] <= MAX_ANALYSIS_BYTES,
    "application analysis exceeds the Bag usability ceiling"
  )

  local fd = love.filesystem.newFileData(bytes, "app-evidence-calibration.zip")
  love.filesystem.unmount(fd:getFilename())
  local mounted = love.filesystem.mount(fd, MOUNT_POINT)
  Assert.isTrue(mounted, "could not mount the produced evidence archive")

  local ok, err = pcall(function()
    local requiredPaths = {
      "manifest.lua",
      "README.md",
      "application/analysis.lua",
      "application/gaps.lua",
      "application/disassembly-index.lua",
      "application/overlay.hex",
      "resources/catalog.lua",
      "resources/narc-id-candidates.lua",
      "resources/gaps.lua",
      "resources/detail-index.lua",
    }
    for _, path in ipairs(requiredPaths) do
      Assert.notNil(love.filesystem.getInfo(MOUNT_POINT .. "/" .. path), "missing bundle member " .. path)
    end

    Assert.isTrue(hasNarcFile, "expected at least one resources/narcs/file-<fileId>.lua member")
    Assert.isTrue(hasDisassemblyFile, "expected at least one per-function disassembly member")
    Assert.isFalse(hasPreviewPath, "default bundle must not emit resource preview members")
    Assert.isNil(primary.files["application/disassembly.md"], "monolithic disassembly must be absent")
  end)
  love.filesystem.unmount(fd:getFilename())
  if not ok then
    error(err, 0)
  end
end

function T.selected_bag_resources_expose_structural_detail_and_exact_payloads()
  local evidence = assert(collected)
  Assert.notNil(evidence.resources.details)
  Assert.equal(#evidence.resources.details, #DETAIL_SELECTIONS)

  local ncgr = assert(findDetail(evidence.resources, 7))
  Assert.equal(ncgr.kind, "ncgr")
  Assert.notNil(ncgr.payload)
  Assert.isTrue(#ncgr.payload > 0)
  Assert.notNil(ncgr.structure)
  Assert.equal(ncgr.structure.depth, 3)
  Assert.equal(ncgr.structure.tileCount, 64)
  Assert.equal(ncgr.structure.tileByteCount, 2048)
  Assert.equal(ncgr.structure.tileByteCount, ncgr.structure.tileCount * 32)

  local nclr = assert(findDetail(evidence.resources, 8))
  Assert.equal(nclr.kind, "nclr")
  Assert.notNil(nclr.structure)
  Assert.equal(nclr.structure.colorCount, #nclr.structure.colors)
  Assert.isTrue(nclr.structure.colorCount > 0)
  Assert.notNil(nclr.structure.colors[1].r)
  Assert.notNil(nclr.structure.colors[1].g)
  Assert.notNil(nclr.structure.colors[1].b)

  local nscr = assert(findDetail(evidence.resources, 9))
  Assert.equal(nscr.kind, "nscr")
  Assert.equal(#nscr.structure.entries, 1024)
  Assert.notNil(nscr.structure.entries[1].tile)
  Assert.notNil(nscr.structure.entries[1].palette)
  Assert.notNil(nscr.structure.entries[1].flipH)
  Assert.notNil(nscr.structure.entries[1].flipV)

  local ncer = assert(findDetail(evidence.resources, 49))
  Assert.equal(ncer.structure.cellCount, 42)
  local objectCount = 0
  for _, cell in ipairs(ncer.structure.cells) do
    Assert.equal(cell.objectCount, #cell.objects)
    objectCount = objectCount + cell.objectCount
    if cell.objectCount > 0 then
      local object = cell.objects[1]
      Assert.notNil(object.x)
      Assert.notNil(object.y)
      Assert.notNil(object.tile)
      Assert.notNil(object.width)
      Assert.notNil(object.height)
    end
  end
  Assert.equal(objectCount, 139)

  local nanr = assert(findDetail(evidence.resources, 50))
  Assert.equal(nanr.structure.animationCount, 43)
  local frameCount, totalDuration = 0, 0
  for _, animation in ipairs(nanr.structure.animations) do
    Assert.equal(animation.frameCount, #animation.frames)
    frameCount = frameCount + animation.frameCount
    totalDuration = totalDuration + animation.totalDuration
    if animation.frameCount > 0 then
      local frame = animation.frames[1]
      Assert.notNil(frame.cell)
      Assert.notNil(frame.duration)
      Assert.notNil(frame.translateX)
      Assert.notNil(frame.translateY)
      Assert.notNil(frame.scaleX)
      Assert.notNil(frame.scaleY)
      Assert.notNil(frame.rotation)
    end
  end
  Assert.equal(frameCount, 51)
  Assert.equal(totalDuration, 188)

  local nsbmd = assert(findDetail(evidence.resources, 55))
  Assert.equal(nsbmd.structure.modelCount, 1)
  local model = assert(nsbmd.structure.models[1])
  Assert.equal(#model.nodeNames, 10)
  Assert.equal(#model.materials, 13)
  Assert.equal(#model.shapes, 20)
  local vertices, triangles = 0, 0
  for _, shape in ipairs(model.shapes) do
    vertices = vertices + shape.vertexCount
    triangles = triangles + shape.triangleCount
    Assert.notNil(shape.name)
    Assert.notNil(shape.index)
  end
  Assert.equal(vertices, 3170)
  Assert.equal(triangles, 1906)

  Assert.isTrue(#assert(built).files["resources/detail-index.lua"] > 0)
  for _, detail in ipairs(evidence.resources.details) do
    Assert.notNil(detail.payloadSize)
    Assert.notNil(detail.payloadSha1)
  end
end

local function beforeAll()
  rom = openRom()
  collected = AppDiscovery.collect(rom, OVERLAY_ID, DETAIL_SELECTIONS)
  built = AppDiscovery.build(collected)
  archiveBytes = assert(EvidenceArchive.encode(built.files))
end

local function afterAll()
  archiveBytes = nil
  built = nil
  collected = nil
  if rom then
    rom:release()
    rom = nil
  end
end

return {
  tests = T,
  metadata = { capabilities = { "rom_source" } },
  beforeAll = beforeAll,
  afterAll = afterAll,
}
