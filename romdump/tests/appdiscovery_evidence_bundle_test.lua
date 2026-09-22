-- Stable evidence file layout: the exact locked member paths, a manifest
-- inventory whose hash/size matches every other archived member, compact
-- application/gap splitting, an exhaustive compact resource census, indexed
-- per-function disassembly, an address-ordered hexdump, and structured rejection of duplicate
-- paths, schema mismatches, inconsistent overlay identity, and
-- non-serializable evidence. The
-- collected application/resource/image evidence below is entirely synthetic and shaped
-- like the locked ApplicationAnalyzer/ResourceCatalog/RomImage records; it
-- encodes no particular game's addresses or resources.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local EvidenceBundle = require("romdump.src.appdiscovery.EvidenceBundle")

local T = {}

local OVERLAY_ID = 15
local OVERLAY_RAM = 0x02100000
-- 20 bytes: not a multiple of 16, so the hexdump must render one partial
-- trailing line rather than padding or truncating.
local OVERLAY_BYTES = "ABCDEFGHIJKLMNOPQRST"

local function instr(address, mnemonic, flowKind)
  return {
    address = address,
    size = 2,
    raw = { 0x4770 },
    mnemonic = mnemonic,
    operands = {},
    flow = { kind = flowKind },
  }
end

-- A fresh, independent copy of one minimal but representative collected
-- aggregate every call, so determinism/mutation tests never share state.
local function buildCollected()
  local functionA = {
    entry = OVERLAY_RAM + 0x10,
    instructionCount = 2,
    blocks = {
      { start = OVERLAY_RAM + 0x10, endExclusive = OVERLAY_RAM + 0x14, instructionCount = 2 },
    },
  }
  local functionB = {
    entry = OVERLAY_RAM,
    instructionCount = 1,
    blocks = { { start = OVERLAY_RAM, endExclusive = OVERLAY_RAM + 2, instructionCount = 1 } },
  }

  return {
    source = {
      basis = "rom-only",
      versionId = "heartgold",
      displayName = "HeartGold",
      sha1 = string.rep("a", 40),
      gameCode = "IPKE",
      size = 1000,
    },
    targetImage = {
      kind = "arm9-overlay",
      id = "arm9-overlay:" .. OVERLAY_ID,
      ramAddress = OVERLAY_RAM,
      bytes = OVERLAY_BYTES,
      rawSize = #OVERLAY_BYTES,
      decodedSize = #OVERLAY_BYTES,
      normalization = "raw",
      rawSha1 = Hashing.sha1hex(OVERLAY_BYTES),
      decodedSha1 = Hashing.sha1hex(OVERLAY_BYTES),
      source = { fileId = 5, ramAddress = OVERLAY_RAM, isCompressed = false },
    },
    application = {
      schema = "g4-app-analysis-1",
      target = { overlayId = OVERLAY_ID, ramAddress = OVERLAY_RAM, size = #OVERLAY_BYTES },
      entrypointCandidates = {},
      -- Intentionally out of address order: the bundle must sort by entry
      -- address, not assume the input already is.
      functions = { functionA, functionB },
      switches = {},
      calls = {},
      literals = {},
      pointers = {},
      gaps = { { kind = "unknown_instruction", address = OVERLAY_RAM + 4 } },
      coverage = {
        candidateCount = 0,
        thumbRootCount = 0,
        armRootCount = 0,
        functionCount = 2,
        blockCount = 2,
        instructionCount = 3,
        unknownInstructionCount = 1,
        computedFlowGapCount = 0,
      },
    },
    applicationDisassembly = {
      functions = {
        {
          entry = functionA.entry,
          instructions = {
            instr(functionA.entry, "bx", "return"),
            instr(functionA.entry + 2, "nop", "sequential"),
          },
        },
        { entry = functionB.entry, instructions = { instr(functionB.entry, "mov", "sequential") } },
      },
    },
    resources = {
      schema = "g4-resource-evidence-1",
      files = {
        { fileId = 5, path = "archive.narc", size = 40, sha1 = Hashing.sha1hex("x"), magic = "NARC", kind = "narc" },
      },
      narcs = {
        {
          fileId = 5,
          path = "archive.narc",
          size = 40,
          sha1 = Hashing.sha1hex("x"),
          memberCount = 2,
          members = {
            {
              memberId = 0,
              rawSize = 10,
              rawSha1 = Hashing.sha1hex("0123456789"),
              compression = "none",
              decodedSize = 10,
              decodedSha1 = Hashing.sha1hex("0123456789"),
              kind = "ncgr",
              status = "decoded",
              summary = { depth = 3, tileCount = 1 },
            },
            {
              memberId = 1,
              rawSize = 5,
              rawSha1 = Hashing.sha1hex("lz11!"),
              compression = "lz11",
              decodedSize = nil,
              decodedSha1 = nil,
              kind = "unknown",
              status = "compression-unsupported",
              summary = nil,
            },
          },
        },
      },
      narcIdCandidates = {},
      gaps = { { kind = "unsupported_lz11", fileId = 5, memberId = 1 } },
      details = {},
      coverage = {
        enumerationComplete = true,
        namedFileCount = 1,
        scannedFileCount = 1,
        narcCount = 1,
        narcMemberCount = 2,
        decodedMemberCount = 1,
        unknownMemberCount = 0,
        failedMemberCount = 0,
        unsupportedMemberCount = 1,
      },
    },
  }
end

local LOCKED_PATHS = {
  "manifest.lua",
  "README.md",
  "application/analysis.lua",
  "application/gaps.lua",
  "application/disassembly-index.lua",
  "application/disassembly/fn-02100000.md",
  "application/disassembly/fn-02100010.md",
  "application/overlay.hex",
  "resources/catalog.lua",
  "resources/narc-id-candidates.lua",
  "resources/gaps.lua",
  "resources/narcs/file-5.lua",
  "resources/detail-index.lua",
}

local function buildCollectedWithDetails(reverse)
  local collected = buildCollected()
  local rawNcgr = "0123456789"
  local rawLz11 = "lz11!"
  local details = {
    {
      fileId = 5,
      memberId = 0,
      narcPath = "archive.narc",
      kind = "ncgr",
      status = "decoded",
      compression = "none",
      rawSize = #rawNcgr,
      rawSha1 = Hashing.sha1hex(rawNcgr),
      decodedSize = #rawNcgr,
      decodedSha1 = Hashing.sha1hex(rawNcgr),
      payloadBasis = "raw",
      payload = rawNcgr,
      payloadSize = #rawNcgr,
      payloadSha1 = Hashing.sha1hex(rawNcgr),
      structure = { depth = 3, tileByteCount = 32, tileCount = 1 },
    },
    {
      fileId = 5,
      memberId = 1,
      narcPath = "archive.narc",
      kind = "unknown",
      status = "compression-unsupported",
      compression = "lz11",
      rawSize = #rawLz11,
      rawSha1 = Hashing.sha1hex(rawLz11),
      payloadBasis = "raw",
      payload = rawLz11,
      payloadSize = #rawLz11,
      payloadSha1 = Hashing.sha1hex(rawLz11),
      structure = nil,
    },
  }
  if reverse then
    details[1], details[2] = details[2], details[1]
  end
  collected.resources.details = details
  return collected
end

local function loadLua(bytes, path)
  local chunk = assert(load(bytes, path))
  return chunk()
end

function T.build_produces_exactly_the_locked_bundle_member_paths()
  local built = EvidenceBundle.build(buildCollected())
  local seen = {}
  for path in pairs(built.files) do
    seen[path] = true
  end
  for _, path in ipairs(LOCKED_PATHS) do
    Assert.isTrue(seen[path], "missing locked bundle member " .. path)
    seen[path] = nil
  end
  local extra = {}
  for path in pairs(seen) do
    extra[#extra + 1] = path
  end
  Assert.equal(#extra, 0, "unexpected extra bundle members: " .. table.concat(extra, ", "))
end

function T.empty_detail_index_is_present_without_detail_payload_members()
  local built = EvidenceBundle.build(buildCollected())
  local index = loadLua(built.files["resources/detail-index.lua"], "resources/detail-index.lua")
  Assert.equal(index.schema, "g4-resource-detail-index-1")
  Assert.deepEqual(index.details, {})
  for path in pairs(built.files) do
    Assert.isFalse(path:match("^resources/details/") ~= nil, "empty detail selection must not emit " .. path)
  end
end

function T.selected_details_are_externalized_and_indexed_deterministically()
  local built = EvidenceBundle.build(buildCollectedWithDetails(true))
  local repeated = EvidenceBundle.build(buildCollectedWithDetails(false))
  Assert.deepEqual(built.files, repeated.files)
  Assert.deepEqual(built.manifest, repeated.manifest)

  local index = loadLua(built.files["resources/detail-index.lua"], "resources/detail-index.lua")
  Assert.equal(index.schema, "g4-resource-detail-index-1")
  Assert.equal(#index.details, 2)
  Assert.equal(index.details[1].memberId, 0)
  Assert.equal(index.details[2].memberId, 1)

  for _, entry in ipairs(index.details) do
    local detailPath = assert(entry.detailPath)
    local payloadPath = assert(entry.payloadPath)
    local detail = loadLua(built.files[detailPath], detailPath)
    local payload = assert(built.files[payloadPath])
    Assert.equal(detail.schema, "g4-resource-detail-1")
    Assert.equal(detail.source.fileId, entry.fileId)
    Assert.equal(detail.source.memberId, entry.memberId)
    Assert.equal(detail.source.narcPath, entry.narcPath)
    Assert.equal(detail.payload.path, payloadPath)
    Assert.equal(detail.payload.size, #payload)
    Assert.equal(detail.payload.sha1, Hashing.sha1hex(payload))
    Assert.isNil(detail.payload.bytes)
    Assert.isNil(detail.payload.data)
    Assert.notNil(detail.classification)
    Assert.notNil(detail.raw)
    Assert.notNil(detail.payload)
  end

  local ncgr = loadLua(built.files[index.details[1].detailPath], index.details[1].detailPath)
  Assert.deepEqual(ncgr.structure, { depth = 3, tileByteCount = 32, tileCount = 1 })
  Assert.equal(ncgr.payload.basis, "raw")
  local unsupported = loadLua(built.files[index.details[2].detailPath], index.details[2].detailPath)
  Assert.isNil(unsupported.structure)
  Assert.equal(unsupported.classification.status, "compression-unsupported")

  local manifest = loadLua(built.files["manifest.lua"], "manifest.lua")
  Assert.equal(manifest.resourceDetailIndexSchema, "g4-resource-detail-index-1")
  Assert.equal(manifest.resourceDetailSchema, "g4-resource-detail-1")
  local manifestPaths = {}
  for _, entry in ipairs(manifest.files) do
    manifestPaths[entry.path] = entry
  end
  for _, entry in ipairs(index.details) do
    Assert.notNil(manifestPaths[entry.detailPath])
    Assert.notNil(manifestPaths[entry.payloadPath])
  end
  for path in pairs(built.files) do
    Assert.isFalse(path:match("^resources/previews/") ~= nil, "selected details must remain preview-free")
  end
end

function T.manifest_schema_and_inventory_match_every_non_manifest_member()
  local built = EvidenceBundle.build(buildCollected())
  local manifest = loadLua(built.files["manifest.lua"], "manifest.lua")

  Assert.equal(manifest.schema, "g4-app-evidence-1")
  Assert.equal(manifest.applicationSchema, "g4-app-analysis-1")
  Assert.equal(manifest.disassemblySchema, "g4-app-disassembly-index-1")
  Assert.equal(manifest.resourceSchema, "g4-resource-evidence-1")
  Assert.equal(manifest.source.sha1, string.rep("a", 40))
  Assert.equal(manifest.target.overlayId, OVERLAY_ID)

  local inventoried = {}
  for _, entry in ipairs(manifest.files) do
    inventoried[entry.path] = entry
    Assert.notNil(built.files[entry.path], "manifest references unknown member " .. entry.path)
    Assert.equal(entry.size, #built.files[entry.path], "size mismatch for " .. entry.path)
    Assert.equal(entry.sha1, Hashing.sha1hex(built.files[entry.path]), "sha1 mismatch for " .. entry.path)
    Assert.notNil(entry.mediaType, "missing media type for " .. entry.path)
  end
  Assert.isNil(inventoried["manifest.lua"], "manifest.lua must not list itself")

  local nonManifestCount = 0
  for path in pairs(built.files) do
    if path ~= "manifest.lua" then
      nonManifestCount = nonManifestCount + 1
      Assert.notNil(inventoried[path], "manifest omits member " .. path)
    end
  end
  Assert.equal(#manifest.files, nonManifestCount, "manifest inventory must list every non-manifest member exactly once")

  -- path-sorted
  for i = 2, #manifest.files do
    Assert.isTrue(manifest.files[i - 1].path < manifest.files[i].path, "manifest.files must be path-sorted")
  end
end

function T.application_analysis_is_a_compact_structural_index_and_excludes_gaps()
  local built = EvidenceBundle.build(buildCollected())
  local analysis = loadLua(built.files["application/analysis.lua"], "application/analysis.lua")
  Assert.isNil(analysis.gaps, "application/analysis.lua must exclude the gaps field")
  Assert.equal(analysis.schema, "g4-app-analysis-1")
  Assert.equal(analysis.target.overlayId, OVERLAY_ID)
  Assert.equal(#analysis.functions, 2)
  for _, fn in ipairs(analysis.functions) do
    local expectedInstructionCount = fn.entry == OVERLAY_RAM and 1 or 2
    Assert.isNil(fn.instructions, "analysis function must not contain disassembly records")
    Assert.equal(fn.instructionCount, expectedInstructionCount)
    for _, block in ipairs(fn.blocks) do
      Assert.isNil(block.instructions, "analysis block must not contain disassembly records")
      Assert.equal(block.instructionCount, expectedInstructionCount)
      Assert.equal(block.endExclusive, block.start + expectedInstructionCount * 2)
    end
  end

  local gaps = loadLua(built.files["application/gaps.lua"], "application/gaps.lua")
  Assert.equal(#gaps, 1)
  Assert.equal(gaps[1].kind, "unknown_instruction")
  Assert.equal(gaps[1].address, OVERLAY_RAM + 4)
end

function T.resource_catalog_splits_narcs_without_a_preview_surface()
  local built = EvidenceBundle.build(buildCollected())

  local catalog = loadLua(built.files["resources/catalog.lua"], "resources/catalog.lua")
  Assert.equal(catalog.schema, "g4-resource-evidence-1")
  Assert.isNil(catalog.narcs, "resources/catalog.lua must not inline full NARC member data")

  local narcFile = loadLua(built.files["resources/narcs/file-5.lua"], "resources/narcs/file-5.lua")
  Assert.equal(narcFile.fileId, 5)
  Assert.equal(narcFile.path, "archive.narc")
  local member = narcFile.members[1]
  Assert.isNil(member.previewKey)
  Assert.isNil(member.previewPath)
  for path in pairs(built.files) do
    Assert.isFalse(path:match("^resources/previews/") ~= nil, "bundle must not emit preview members")
  end

  local candidates = loadLua(built.files["resources/narc-id-candidates.lua"], "resources/narc-id-candidates.lua")
  Assert.equal(#candidates, 0)

  local resourceGaps = loadLua(built.files["resources/gaps.lua"], "resources/gaps.lua")
  Assert.equal(#resourceGaps, 1)
  Assert.equal(resourceGaps[1].kind, "unsupported_lz11")
end

-- Address-labelled 16-byte-per-line hexdump: parse the emitted text back
-- into address/byte tokens and check it spans the target bytes exactly once,
-- in ascending order, without assuming exact prose beyond that contract.
function T.overlay_hex_covers_target_bytes_exactly_once_in_ascending_address_order()
  local built = EvidenceBundle.build(buildCollected())
  local text = built.files["application/overlay.hex"]
  Assert.notNil(text)

  local addresses = {}
  local reconstructed = {}
  for line in text:gmatch("[^\n]+") do
    local addrHex, rest = line:match("^%s*(%x+)%s*[:%s]%s*(.*)$")
    Assert.notNil(addrHex, "hexdump line missing an address label: " .. line)
    addresses[#addresses + 1] = tonumber(addrHex, 16)
    for byteHex in rest:gmatch("%x%x") do
      reconstructed[#reconstructed + 1] = string.char(tonumber(byteHex, 16))
    end
  end

  Assert.isTrue(#addresses > 0, "hexdump produced no lines")
  Assert.equal(addresses[1], OVERLAY_RAM)
  for i = 2, #addresses do
    Assert.equal(addresses[i], addresses[i - 1] + 16, "hexdump lines must advance by exactly 16 bytes")
  end
  Assert.equal(table.concat(reconstructed), OVERLAY_BYTES)
end

function T.disassembly_index_addresses_each_function_member_in_ascending_entry_order()
  local built = EvidenceBundle.build(buildCollected())
  local index = loadLua(built.files["application/disassembly-index.lua"], "application/disassembly-index.lua")
  Assert.equal(index.schema, "g4-app-disassembly-index-1")
  Assert.equal(#index.functions, 2)

  local lowAddress = string.format("%08X", OVERLAY_RAM)
  local highAddress = string.format("%08X", OVERLAY_RAM + 0x10)
  Assert.equal(index.functions[1].entry, OVERLAY_RAM)
  Assert.equal(index.functions[1].instructionCount, 1)
  Assert.equal(index.functions[1].path, "application/disassembly/fn-" .. lowAddress .. ".md")
  Assert.equal(index.functions[2].entry, OVERLAY_RAM + 0x10)
  Assert.equal(index.functions[2].instructionCount, 2)
  Assert.equal(index.functions[2].path, "application/disassembly/fn-" .. highAddress .. ".md")

  local lowText = assert(built.files[index.functions[1].path])
  local highText = assert(built.files[index.functions[2].path])
  Assert.isTrue(lowText:find("# fn_" .. lowAddress, 1, true) == 1)
  Assert.isTrue(highText:find("# fn_" .. highAddress, 1, true) == 1)
  Assert.isTrue(lowText:find("mov", 1, true) ~= nil)
  Assert.isTrue(highText:find("bx", 1, true) ~= nil)
  local firstInstruction = highText:find(highAddress .. "  ", 1, true)
  local secondInstruction = highText:find(string.format("%08X  ", OVERLAY_RAM + 0x12), 1, true)
  Assert.notNil(firstInstruction)
  Assert.notNil(secondInstruction)
  Assert.isTrue(firstInstruction < secondInstruction, "function instructions must be address-sorted")
  Assert.isTrue(highText:find("nop", 1, true) ~= nil)
  Assert.isNil(lowText:find(highAddress, 1, true), "a function file must contain only its function")
  Assert.isNil(highText:find(lowAddress, 1, true), "a function file must contain only its function")
  Assert.isNil(built.files["application/disassembly.md"], "monolithic disassembly must be absent")
end

function T.disassembly_preserves_conditional_branch_mnemonics()
  local collected = buildCollected()
  local conditional = instr(OVERLAY_RAM, "b", "branch")
  conditional.flow.conditional = true
  conditional.flow.condition = "eq"
  conditional.flow.target = OVERLAY_RAM + 6
  local unconditional = instr(OVERLAY_RAM + 2, "b", "branch")
  unconditional.flow.conditional = false
  unconditional.flow.target = OVERLAY_RAM + 8
  collected.applicationDisassembly.functions[2].instructions = { conditional, unconditional }

  local built = EvidenceBundle.build(collected)
  local index = loadLua(built.files["application/disassembly-index.lua"], "application/disassembly-index.lua")
  local text = assert(built.files[index.functions[1].path])

  Assert.isTrue(text:find("beq", 1, true) ~= nil, "conditional branches must include their decoded condition")
  Assert.isTrue(
    text:find("b     ; branch 0x02100008", 1, true) ~= nil,
    "unconditional branches must retain the plain mnemonic"
  )
  Assert.isTrue(text:find("; branch 0x02100006", 1, true) ~= nil)
  Assert.isTrue(text:find("; branch 0x02100008", 1, true) ~= nil)
end

function T.manifest_and_readme_navigate_to_selective_application_evidence()
  local built = EvidenceBundle.build(buildCollected())
  local manifest = loadLua(built.files["manifest.lua"], "manifest.lua")
  local filesByPath = {}
  for _, entry in ipairs(manifest.files) do
    filesByPath[entry.path] = entry
  end
  Assert.equal(manifest.disassemblySchema, "g4-app-disassembly-index-1")
  for _, path in ipairs({
    "application/analysis.lua",
    "application/disassembly-index.lua",
    "application/disassembly/fn-02100000.md",
    "application/disassembly/fn-02100010.md",
  }) do
    Assert.notNil(filesByPath[path], "manifest must navigate to " .. path)
  end

  local text = built.files["README.md"]:lower()
  for _, fact in ipairs({ "zero-based", "gap", "structural", "rom" }) do
    Assert.isTrue(text:find(fact, 1, true) ~= nil, "README.md must mention '" .. fact .. "'")
  end
  for _, path in ipairs({
    "resources/narc-id-candidates.lua",
    "resources/catalog.lua",
    "resources/narcs/file-<fileId>.lua",
    "resources/gaps.lua",
    "resources/detail-index.lua",
    "--resource-detail <fileId>:<memberId>",
  }) do
    Assert.isTrue(text:find(path:lower(), 1, true) ~= nil, "README.md must navigate to " .. path)
  end
  Assert.isTrue(text:find("physical", 1, true) ~= nil)
  Assert.isTrue(text:find("semantic relevance", 1, true) ~= nil)
  for _, path in ipairs({ "application/analysis.lua", "application/disassembly-index.lua" }) do
    Assert.isTrue(text:find(path, 1, true) ~= nil, "README.md must link consumers to " .. path)
  end
  Assert.isNil(text:find("/home/", 1, true), "README.md must not leak a local filesystem path")
end

function T.build_is_deterministic_for_equivalent_independently_constructed_input()
  local built1 = EvidenceBundle.build(buildCollected())
  local built2 = EvidenceBundle.build(buildCollected())
  Assert.deepEqual(built1.files, built2.files)
  Assert.deepEqual(built1.manifest, built2.manifest)
  Assert.deepEqual(built1.summary, built2.summary)
end

function T.summary_reports_the_locked_counters()
  local built = EvidenceBundle.build(buildCollected())
  Assert.equal(built.summary.versionId, "heartgold")
  Assert.equal(built.summary.overlayId, OVERLAY_ID)
  Assert.equal(built.summary.functionCount, 2)
  Assert.equal(built.summary.resourceFileCount, 1)
  Assert.equal(built.summary.narcCount, 1)
  Assert.equal(built.summary.narcMemberCount, 2)
  Assert.equal(built.summary.applicationGapCount, 1)
  Assert.equal(built.summary.resourceGapCount, 1)
end

function T.application_schema_mismatch_is_rejected()
  local collected = buildCollected()
  collected.application.schema = "not-the-locked-schema"

  local err = Assert.throws(function()
    EvidenceBundle.build(collected)
  end)
  Assert.isTrue(Errors.is(err), "expected a structured bundle error")
end

function T.resource_schema_mismatch_is_rejected()
  local collected = buildCollected()
  collected.resources.schema = "not-the-locked-schema"

  local err = Assert.throws(function()
    EvidenceBundle.build(collected)
  end)
  Assert.isTrue(Errors.is(err), "expected a structured bundle error")
end

function T.inconsistent_overlay_id_between_target_image_and_application_is_rejected()
  local collected = buildCollected()
  collected.application.target.overlayId = OVERLAY_ID + 1

  local err = Assert.throws(function()
    EvidenceBundle.build(collected)
  end)
  Assert.isTrue(Errors.is(err), "expected a structured bundle error")
end

function T.non_serializable_evidence_is_rejected()
  local collected = buildCollected()
  collected.application.gaps[1].culprit = function() end

  local err = Assert.throws(function()
    EvidenceBundle.build(collected)
  end)
  Assert.isTrue(Errors.is(err), "expected a structured bundle error")
end

return { tests = T }
