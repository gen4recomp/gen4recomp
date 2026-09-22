-- Exhaustive ROM resource evidence: every named NitroFS file and every valid
-- NARC member accounted for exactly once, independent per-format summaries
-- selected from existing decoders with no binary/userdata state retained,
-- and ROM-derived numeric NARC-ID pointer-run reconstruction from a
-- synthetic normalized main ARM9 image. Every fixture is hand-assembled
-- synthetic ROM/archive/resource bytes; none of it encodes any particular
-- game's resources or addresses.

local Assert = require("tests.support.Assert")
local Hashing = require("romdump.src.digest.Hashing")
local NdsRom = require("romdump.src.source.NdsRom")
local RomSource = require("romdump.src.source.RomSource")
local NdsBuilder = require("tests.support.NdsBuilder")
local NarcBuilder = require("tests.support.NarcBuilder")
local BackwardsLz = require("tests.support.BackwardsLz")
local RomImage = require("romdump.src.appdiscovery.RomImage")
local ResourceCatalog = require("romdump.src.appdiscovery.ResourceCatalog")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Tex0Fixture = require("tests.support.Tex0Fixture")
local AnimationFixture = require("tests.support.AnimationFixture")

local T = {}

--------------------------------------------------------------------------
-- Byte helpers
--------------------------------------------------------------------------

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  v = v % 4294967296
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function swap4(s)
  return s:reverse()
end

-- A generic G2D container (16-byte header + block table), magic given
-- literally (real ROM member bytes are byte-swapped container names, e.g.
-- "RGCN" for NCGR).
local function g2dContainer(magic, blocks)
  local body = {}
  local size = 0x10
  for _, blk in ipairs(blocks) do
    body[#body + 1] = blk
    size = size + #blk
  end
  return magic .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(size) .. u16(0x10) .. u16(#blocks) .. table.concat(body)
end

local function g2dBlock(magic, payload)
  return swap4(magic) .. u32(8 + #payload) .. payload
end

local function charBlock(tiles, depth)
  local payload = u16(8) .. u16(0x20) .. u32(depth) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return g2dBlock("CHAR", payload)
end

local function screenBlock(entries, width, height)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return g2dBlock("SCRN", u16(width) .. u16(height) .. u32(0) .. u32(#entries * 2) .. table.concat(body))
end

local function cellBlock(objs)
  local metatile = u16(#objs) .. u16(0) .. u32(0)
  local attr = {}
  for _, o in ipairs(objs) do
    attr[#attr + 1] = u16((o.y % 256) + (o.shape or 0) * 16384)
      .. u16((o.x % 512) + (o.flipH and 4096 or 0) + (o.flipV and 8192 or 0) + (o.size or 0) * 16384)
      .. u16(o.tile + o.pal * 4096)
  end
  return g2dBlock(
    "CEBK",
    u16(1) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. metatile .. table.concat(attr)
  )
end

local function animBlock(frames)
  local anims = u16(1)
    .. u16(#frames)
    .. u32(0x18)
    .. u32(0x18 + 16)
    .. u32(0x18 + 16 + 8 * #frames)
    .. string.rep("\0", 8)
  local anim = u32(#frames) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frameBlocks, frameData = {}, {}
  for i, f in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(f.duration) .. u16(0)
    frameData[#frameData + 1] = u16(f.cell)
  end
  return g2dBlock("ABNK", anims .. anim .. table.concat(frameBlocks) .. table.concat(frameData))
end

local function twoTiles()
  return string.rep(string.char(0x11), 32) .. string.rep(string.char(0x22), 32)
end

local function ncgrMember()
  return g2dContainer("RGCN", { charBlock(twoTiles(), 3) })
end

local function corruptedNcgrMember()
  -- Declared depth 9 is neither 3 (4bpp) nor 4 (8bpp): the CHAR chunk is
  -- structurally present under the recognized NCGR magic but fails to
  -- decode, so it must become a decode-failed member, not a reclassified
  -- unknown one.
  return g2dContainer("RGCN", { charBlock(twoTiles(), 9) })
end

local function nscrMember()
  return g2dContainer("RCSN", { screenBlock({ 0, 1 }, 16, 8) })
end

local function ncerMember()
  return g2dContainer("RECN", { cellBlock({ { x = 0, y = 0, tile = 0, pal = 0 } }) })
end

local function nanrMember()
  return g2dContainer("RNAN", { animBlock({ { duration = 4, cell = 0 } }) })
end

-- Real HGSS NCLR members carry an "RLCN"-wrapped TTLP chunk rather than the
-- generic block table used by CHAR/SCRN/CEBK/ABNK.
local function nclrMember(colors)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = u16(c)
  end
  local bodyBytes = table.concat(body)
  local ttlp = "TTLP" .. u32(24 + #bodyBytes) .. u32(3) .. u32(0) .. u32(#colors * 2) .. u32(16) .. bodyBytes
  return "RLCN" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x10 + #ttlp) .. u16(0x10) .. u16(1) .. ttlp
end

-- All-literal LZ10 stream: valid, trivially reversible, decodes to exactly
-- `payload`.
local function literalLz10(payload)
  local parts = {}
  for i = 1, #payload, 8 do
    parts[#parts + 1] = string.char(0x00) .. payload:sub(i, math.min(i + 7, #payload))
  end
  local size = #payload
  return string.char(0x10, size % 256, math.floor(size / 256) % 256, math.floor(size / 65536) % 256)
    .. table.concat(parts)
end

--------------------------------------------------------------------------
-- ROM assembly
--------------------------------------------------------------------------

local function matchingVersions(data, gameCode)
  local info = { sha1 = RomSource.fromString(data):sha1(), gameCode = gameCode, expectedSize = #data }
  return {
    forSha1 = function(h)
      return h == info.sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == gameCode and info or nil
    end,
  }
end

local function buildRom(spec)
  spec.gameCode = spec.gameCode or "IPKE"
  spec.title = spec.title or "TESTHG"
  local data = NdsBuilder.build(spec)
  local rom = assert(NdsRom.open(RomSource.fromString(data), matchingVersions(data, spec.gameCode)))
  return rom
end

local function byPath(evidence, path)
  for _, f in ipairs(evidence.files) do
    if f.path == path then
      return f
    end
  end
  return nil
end

local function byMemberId(members)
  local out = {}
  for _, m in ipairs(members) do
    out[m.memberId] = m
  end
  return out
end

--------------------------------------------------------------------------
-- Every named file / NARC member accounted for exactly once
--------------------------------------------------------------------------

function T.every_named_file_and_narc_member_is_accounted_for_exactly_once()
  local ncgrBytes = ncgrMember()
  local nclrPayload = nclrMember({ 0x7FFF, 0x0000, 0x001F })
  local lz10Bytes = literalLz10(nclrPayload)
  local unknownBytes = "ZZZZ-not-a-recognized-resource-format"
  local lz11Bytes = string.char(0x11) .. "junk-lz11-payload"

  local narcBytes = NarcBuilder.build({ ncgrBytes, unknownBytes, lz10Bytes, lz11Bytes })

  local rom = buildRom({
    tree = {
      files = {
        { name = "archive.narc", content = narcBytes },
        { name = "plain.bin", content = "hello" },
        { name = "broken.narc", content = "NARC" },
      },
    },
  })
  local image = RomImage.new(rom)
  local evidence = ResourceCatalog.scan(rom, image)

  Assert.equal(evidence.schema, "g4-resource-evidence-1")
  Assert.equal(#evidence.files, 3)
  Assert.equal(evidence.coverage.namedFileCount, 3)
  Assert.equal(evidence.coverage.scannedFileCount, 3)
  Assert.isFalse(evidence.coverage.complete, "a malformed NARC must mark coverage incomplete")

  local narcFile = assert(byPath(evidence, "archive.narc"))
  Assert.equal(narcFile.kind, "narc")
  local plainFile = assert(byPath(evidence, "plain.bin"))
  Assert.equal(plainFile.kind, "file")
  Assert.equal(plainFile.size, 5)
  Assert.equal(plainFile.sha1, Hashing.sha1hex("hello"))
  local brokenFile = assert(byPath(evidence, "broken.narc"))
  Assert.equal(brokenFile.kind, "malformed-narc")

  Assert.equal(#evidence.narcs, 1)
  local narc = evidence.narcs[1]
  Assert.equal(narc.path, "archive.narc")
  Assert.equal(narc.fileId, narcFile.fileId)
  Assert.equal(narc.memberCount, 4)
  Assert.equal(#narc.members, 4)

  local members = byMemberId(narc.members)
  for id = 0, 3 do
    Assert.notNil(members[id], "missing member " .. id)
  end

  local m0 = members[0]
  Assert.equal(m0.compression, "none")
  Assert.equal(m0.kind, "ncgr")
  Assert.equal(m0.status, "decoded")
  Assert.equal(m0.rawSize, #ncgrBytes)
  Assert.equal(m0.rawSha1, Hashing.sha1hex(ncgrBytes))
  Assert.notNil(m0.summary)
  Assert.equal(m0.summary.depth, 3)
  Assert.equal(m0.previewKey, "narc-" .. narcFile.fileId .. "-member-0-ncgr")

  local m1 = members[1]
  Assert.equal(m1.compression, "none")
  Assert.equal(m1.kind, "unknown")
  Assert.equal(m1.status, "unknown")
  Assert.equal(m1.rawSize, #unknownBytes)
  Assert.equal(m1.rawSha1, Hashing.sha1hex(unknownBytes))
  Assert.isNil(m1.previewKey)

  local m2 = members[2]
  Assert.equal(m2.compression, "lz10")
  Assert.equal(m2.rawSize, #lz10Bytes)
  Assert.equal(m2.rawSha1, Hashing.sha1hex(lz10Bytes))
  Assert.equal(m2.decodedSize, #nclrPayload)
  Assert.equal(m2.decodedSha1, Hashing.sha1hex(nclrPayload))
  Assert.equal(m2.kind, "nclr")
  Assert.equal(m2.status, "decoded")
  Assert.notNil(m2.summary)
  Assert.equal(#m2.summary.colors, 3)
  Assert.equal(m2.previewKey, "narc-" .. narcFile.fileId .. "-member-2-nclr")

  local m3 = members[3]
  Assert.equal(m3.compression, "lz11")
  Assert.equal(m3.kind, "unknown")
  Assert.equal(m3.rawSize, #lz11Bytes)
  Assert.equal(m3.rawSha1, Hashing.sha1hex(lz11Bytes))
  Assert.isNil(m3.decodedSize)
  Assert.isNil(m3.decodedSha1)
  Assert.isNil(m3.previewKey)

  -- Coverage member counters reconcile with the members array itself, so
  -- this stays true regardless of which bucket an unsupported-compression
  -- member is folded into.
  local decoded, unknown, failed = 0, 0, 0
  for _, m in ipairs(narc.members) do
    if m.status == "decoded" then
      decoded = decoded + 1
    elseif m.status == "unknown" then
      unknown = unknown + 1
    elseif m.status == "decode-failed" then
      failed = failed + 1
    end
  end
  Assert.equal(evidence.coverage.narcCount, 1)
  Assert.equal(evidence.coverage.narcMemberCount, 4)
  Assert.equal(evidence.coverage.decodedMemberCount, decoded)
  Assert.equal(evidence.coverage.unknownMemberCount, unknown)
  Assert.equal(evidence.coverage.failedMemberCount, failed)
  Assert.equal(decoded, 2)
  Assert.equal(unknown, 1)

  local lz11Gap = nil
  for _, g in ipairs(evidence.gaps) do
    if g.kind == "unsupported_lz11" then
      lz11Gap = g
    end
  end
  Assert.notNil(lz11Gap, "expected an unsupported_lz11 gap for the LZ11 member")
  Assert.isTrue(#evidence.gaps >= 2, "expected gaps for both the LZ11 member and the malformed NARC")

  Assert.equal(#evidence.previews, 2)
  local previewKeys = {}
  for _, p in ipairs(evidence.previews) do
    previewKeys[p.key] = p
    Assert.isTrue(#p.png > 0)
    Assert.isTrue(p.width > 0)
    Assert.isTrue(p.height > 0)
  end
  Assert.notNil(previewKeys["narc-" .. narcFile.fileId .. "-member-0-ncgr"])
  Assert.notNil(previewKeys["narc-" .. narcFile.fileId .. "-member-2-nclr"])
end

--------------------------------------------------------------------------
-- Lower-level: decoder dispatch for every supported exact magic, plus the
-- decoder-failure path, with a recursive check that summaries never retain
-- binary/userdata/function state.
--------------------------------------------------------------------------

local function assertNoOpaqueState(value, path)
  local t = type(value)
  if t == "table" then
    for k, v in pairs(value) do
      assertNoOpaqueState(v, path .. "." .. tostring(k))
    end
  elseif t == "function" or t == "userdata" or t == "thread" or t == "cdata" then
    error("summary retains a " .. t .. " value at " .. path, 0)
  end
end

function T.every_supported_format_is_classified_with_a_closed_summary()
  local bmd0 = NsbmdFixture.build()
  local btx0 = Tex0Fixture.btx0({ textures = { "tex0" } })
  local bca0 = AnimationFixture.jntDoor(0)
  local bta0 = AnimationFixture.srtWater()
  local btp0 = AnimationFixture.patPcMb()
  local bma0 = AnimationFixture.matFade()

  local members = {
    ncgrMember(),
    nclrMember({ 0x7FFF, 0x0000 }),
    nscrMember(),
    ncerMember(),
    nanrMember(),
    bmd0,
    btx0,
    bca0,
    bta0,
    btp0,
    bma0,
    corruptedNcgrMember(),
  }
  local narcBytes = NarcBuilder.build(members)
  local rom = buildRom({ tree = { files = { { name = "formats.narc", content = narcBytes } } } })
  local image = RomImage.new(rom)
  local evidence = ResourceCatalog.scan(rom, image)

  Assert.equal(#evidence.narcs, 1)
  local narcMembers = byMemberId(evidence.narcs[1].members)

  local expectedKinds = {
    [0] = "ncgr",
    [1] = "nclr",
    [2] = "nscr",
    [3] = "ncer",
    [4] = "nanr",
    [5] = "nsbmd",
    [6] = "nsbtx",
    [7] = "nsbca",
    [8] = "nsbta",
    [9] = "nsbtp",
    [10] = "nsbma",
    [11] = "ncgr",
  }
  for id, kind in pairs(expectedKinds) do
    Assert.equal(narcMembers[id].kind, kind, "member " .. id .. " kind")
  end

  for id = 0, 10 do
    Assert.equal(narcMembers[id].status, "decoded", "member " .. id .. " must decode")
    Assert.notNil(narcMembers[id].summary, "member " .. id .. " must carry a summary")
  end

  local corrupted = narcMembers[11]
  Assert.equal(corrupted.status, "decode-failed")
  Assert.isNil(corrupted.previewKey)

  local expectedAnimationCounts = {
    [7] = { frameCount = 8, targetCount = 1 },
    [8] = { frameCount = 8, targetCount = 1 },
    [9] = { frameCount = 68, targetCount = 1 },
    [10] = { frameCount = 60, targetCount = 1 },
  }
  for id, expected in pairs(expectedAnimationCounts) do
    local counts = narcMembers[id].summary.animationCounts[1]
    Assert.equal(counts.frameCount, expected.frameCount, "member " .. id .. " frameCount")
    Assert.equal(counts.targetCount, expected.targetCount, "member " .. id .. " targetCount")
  end

  for id, member in pairs(narcMembers) do
    if member.summary ~= nil then
      assertNoOpaqueState(member.summary, "member" .. id)
    end
  end
end

--------------------------------------------------------------------------
-- Determinism
--------------------------------------------------------------------------

function T.scan_is_deterministic_for_identical_input()
  local narcBytes = NarcBuilder.build({ ncgrMember(), nclrMember({ 0x7FFF, 0x0000, 0x001F }) })
  local spec = { tree = { files = { { name = "archive.narc", content = narcBytes } } } }

  local rom1 = buildRom(spec)
  local evidence1 = ResourceCatalog.scan(rom1, RomImage.new(rom1))
  local rom2 = buildRom(spec)
  local evidence2 = ResourceCatalog.scan(rom2, RomImage.new(rom2))

  Assert.deepEqual(evidence1, evidence2)
end

--------------------------------------------------------------------------
-- Numeric NARC-ID candidates from ROM strings and pointers only
--------------------------------------------------------------------------

local ARM9_RAM = 0x02000000

local function pointerArm9(path, runLengths)
  local parts = {}
  local cursor = 0
  local function push(bytes)
    parts[#parts + 1] = bytes
    cursor = cursor + #bytes
  end
  local function padTo4()
    local rem = cursor % 4
    if rem ~= 0 then
      push(string.rep("\0", 4 - rem))
    end
  end

  push(path .. "\0")
  padTo4()
  push("noise\0")
  padTo4()
  local breaker = u32(0xDEADBEEF)
  push(breaker) -- dangling pointer to nothing known

  local stringAddress = ARM9_RAM + 0
  local runs = {}
  for _, length in ipairs(runLengths) do
    local startOffset = cursor
    for _ = 1, length do
      push(u32(stringAddress))
    end
    push(breaker)
    runs[#runs + 1] = { offset = startOffset, length = length }
  end

  push(BackwardsLz.invalidFooter())
  return table.concat(parts), stringAddress, runs
end

local function buildCandidateRom(path, runLengths)
  local arm9, stringAddress, runs = pointerArm9(path, runLengths)
  local narcBytes = NarcBuilder.build({})
  local rom = buildRom({
    arm9 = arm9,
    arm9Ram = ARM9_RAM,
    tree = { files = { { name = path, content = narcBytes } } },
  })
  return rom, stringAddress, runs
end

local function findCandidate(candidates, address)
  for _, c in ipairs(candidates) do
    if c.address == address then
      return c
    end
  end
  return nil
end

function T.candidate_recovery_marks_the_unique_longest_run_at_least_16_as_primary()
  local path = "archive.narc"
  local rom, stringAddress, runs = buildCandidateRom(path, { 20, 5, 5, 3 })
  local evidence = ResourceCatalog.scan(rom, RomImage.new(rom))

  -- The 3-entry run is below the four-entry minimum and must not surface.
  Assert.equal(#evidence.narcIdCandidates, 3)

  local primaryOffset = runs[1].offset
  local shortOffset1 = runs[2].offset
  local shortOffset2 = runs[3].offset

  local primary = assert(findCandidate(evidence.narcIdCandidates, ARM9_RAM + primaryOffset))
  Assert.equal(primary.entryCount, 20)
  Assert.isTrue(primary.primaryCandidate)
  Assert.equal(#primary.entries, 20)
  for i, e in ipairs(primary.entries) do
    Assert.equal(e.index, i - 1)
    Assert.equal(e.pointerAddress, ARM9_RAM + primaryOffset + (i - 1) * 4)
    Assert.equal(e.stringAddress, stringAddress)
    Assert.equal(e.path, path)
  end

  local short1 = assert(findCandidate(evidence.narcIdCandidates, ARM9_RAM + shortOffset1))
  Assert.equal(short1.entryCount, 5)
  Assert.isFalse(short1.primaryCandidate)

  local short2 = assert(findCandidate(evidence.narcIdCandidates, ARM9_RAM + shortOffset2))
  Assert.equal(short2.entryCount, 5)
  Assert.isFalse(short2.primaryCandidate)

  -- Sorted longest-first, then by lowest RAM address among equal lengths.
  Assert.equal(evidence.narcIdCandidates[1].address, primary.address)
  Assert.isTrue(evidence.narcIdCandidates[2].address < evidence.narcIdCandidates[3].address)
end

function T.candidate_recovery_marks_no_primary_when_the_longest_run_ties()
  local rom = buildCandidateRom("archive.narc", { 20, 20 })
  local evidence = ResourceCatalog.scan(rom, RomImage.new(rom))

  Assert.equal(#evidence.narcIdCandidates, 2)
  for _, c in ipairs(evidence.narcIdCandidates) do
    Assert.equal(c.entryCount, 20)
    Assert.isFalse(c.primaryCandidate)
  end
  Assert.isTrue(evidence.narcIdCandidates[1].address < evidence.narcIdCandidates[2].address)
end

function T.candidate_recovery_marks_no_primary_when_the_unique_longest_run_is_under_16()
  local rom = buildCandidateRom("archive.narc", { 10, 5 })
  local evidence = ResourceCatalog.scan(rom, RomImage.new(rom))

  Assert.equal(#evidence.narcIdCandidates, 2)
  for _, c in ipairs(evidence.narcIdCandidates) do
    Assert.isFalse(c.primaryCandidate)
  end
end

-- The same NARC path string occurring more than once in ARM9 must retain
-- every occurrence and its own pointer-run candidate, with no address
-- preference between them.
function T.candidate_recovery_retains_every_occurrence_of_a_repeated_path_string()
  local path = "archive.narc"
  local parts = {}
  local cursor = 0
  local function push(bytes)
    parts[#parts + 1] = bytes
    cursor = cursor + #bytes
  end
  local function padTo4()
    local rem = cursor % 4
    if rem ~= 0 then
      push(string.rep("\0", 4 - rem))
    end
  end

  push(path .. "\0")
  padTo4()
  local firstStringAddress = ARM9_RAM + 0
  local firstRunOffset = cursor
  for _ = 1, 4 do
    push(u32(firstStringAddress))
  end
  push(u32(0xDEADBEEF))
  padTo4()

  local secondStringOffset = cursor
  push(path .. "\0")
  padTo4()
  local secondStringAddress = ARM9_RAM + secondStringOffset
  local secondRunOffset = cursor
  for _ = 1, 4 do
    push(u32(secondStringAddress))
  end
  push(BackwardsLz.invalidFooter())

  local arm9 = table.concat(parts)
  local narcBytes = NarcBuilder.build({})
  local rom = buildRom({
    arm9 = arm9,
    arm9Ram = ARM9_RAM,
    tree = { files = { { name = path, content = narcBytes } } },
  })
  local evidence = ResourceCatalog.scan(rom, RomImage.new(rom))

  Assert.equal(#evidence.narcIdCandidates, 2)
  local first = assert(findCandidate(evidence.narcIdCandidates, ARM9_RAM + firstRunOffset))
  local second = assert(findCandidate(evidence.narcIdCandidates, ARM9_RAM + secondRunOffset))
  Assert.equal(first.entries[1].stringAddress, firstStringAddress)
  Assert.equal(second.entries[1].stringAddress, secondStringAddress)
  Assert.equal(first.entries[1].path, path)
  Assert.equal(second.entries[1].path, path)
end

-- Pointer words that only match a known string address when read starting at
-- a byte offset that is not a multiple of four must never surface as
-- candidates: the scanner reads only 4-byte-aligned words.
function T.candidate_recovery_ignores_pointer_words_at_unaligned_offsets()
  local path = "archive.narc"
  local parts = {}
  local cursor = 0
  local function push(bytes)
    parts[#parts + 1] = bytes
    cursor = cursor + #bytes
  end
  local function padTo4()
    local rem = cursor % 4
    if rem ~= 0 then
      push(string.rep("\0", 4 - rem))
    end
  end

  push(path .. "\0")
  padTo4()
  local stringAddress = ARM9_RAM + 0

  -- Shift by one byte so every pointer-sized encoding of stringAddress below
  -- straddles two aligned words; no 4-byte-aligned read recovers it.
  push(string.char(0))
  for _ = 1, 4 do
    push(u32(stringAddress))
  end
  padTo4()
  push(BackwardsLz.invalidFooter())

  local arm9 = table.concat(parts)
  local narcBytes = NarcBuilder.build({})
  local rom = buildRom({
    arm9 = arm9,
    arm9Ram = ARM9_RAM,
    tree = { files = { { name = path, content = narcBytes } } },
  })
  local evidence = ResourceCatalog.scan(rom, RomImage.new(rom))

  Assert.equal(#evidence.narcIdCandidates, 0)
end

return { tests = T }
