-- Converts collected application/resource/image evidence into the stable evidence file
-- layout: a self-describing manifest, prose README, compact application analysis
-- split from its gaps, indexed per-function disassembly and hexdump, and a
-- resource catalog with externalized NARC members. No semantic
-- enrichment: every fact is copied or mechanically reformatted from the
-- collected evidence.

local Errors = require("libs.errors.src.Errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Hashing = require("romdump.src.digest.Hashing")

local EvidenceBundle = {}

local MANIFEST_SCHEMA = "g4-app-evidence-1"
local APPLICATION_SCHEMA = "g4-app-analysis-1"
local DISASSEMBLY_INDEX_SCHEMA = "g4-app-disassembly-index-1"
local RESOURCE_SCHEMA = "g4-resource-evidence-1"
local RESOURCE_DETAIL_INDEX_SCHEMA = "g4-resource-detail-index-1"
local RESOURCE_DETAIL_SCHEMA = "g4-resource-detail-1"

local MEDIA_TYPES = {
  lua = "text/x-lua",
  md = "text/markdown",
  hex = "text/plain",
}

local README_TEXT = [[
# Application evidence bundle

This bundle was derived only from the supplied ROM's own bytes plus generic
Nintendo DS/Nitro decoders. It contains no decompiled source and no
implementation prescription.

- All source IDs, member indices, and addresses in this bundle are
  zero-based.
- Entrypoint and resource candidates are structural evidence, not confirmed
  semantics. Cross-reference against a decomp is required before treating a
  candidate as a confirmed application root, callback, or resource
  composition.
- Every gap record is intentional evidence of an unresolved instruction,
  control-flow target, or resource decode, not an omission to be silently
  filled in.
- Application behavior is recovered as conservative, ROM-derived structural
  evidence in `application/analysis.lua`: reachable functions, blocks, direct
  calls, and validated switch tables. Use `application/disassembly-index.lua`
  to locate verbose instruction evidence for one function at a time.
- For resources, first inspect `resources/narc-id-candidates.lua` for structural
  zero-based NARC-index/path candidates. Resolve path and file identity through
  `resources/catalog.lua` and its NARC index, then open only the selected
  `resources/narcs/file-<fileId>.lua` census. Inspect `resources/gaps.lua` for
  resource gap evidence and `resources/detail-index.lua` for any requested
  rich evidence.
- If the needed detail is absent, rerun discovery with repeatable
  `--resource-detail <fileId>:<memberId>` options. These are physical,
  zero-based IDs and do not assert semantic relevance; select them only after
  correlating the compact evidence with other research.
]]

local function shallowCopyExcluding(t, excludedKey)
  local out = {}
  for k, v in pairs(t) do
    if k ~= excludedKey then
      out[k] = v
    end
  end
  return out
end

local function encodeLua(value, description)
  local ok, result = pcall(LuaWriter.encode, value)
  if not ok then
    Errors.raise(
      "APPDISCOVERY_BUNDLE_NOT_SERIALIZABLE",
      "cannot serialize " .. description .. ": " .. tostring(result),
      { member = description }
    )
  end
  return result
end

local function mediaTypeFor(path)
  local ext = path:match("%.([%w]+)$")
  return (ext and MEDIA_TYPES[ext]) or "application/octet-stream"
end

local function targetOverlayIdFromImage(image)
  if image.kind ~= "arm9-overlay" then
    Errors.raise(
      "APPDISCOVERY_BUNDLE_TARGET_INVALID",
      "target image is not an arm9 overlay image",
      { kind = image.kind }
    )
  end
  local overlayId = image.id:match("^arm9%-overlay:(%d+)$")
  if not overlayId then
    Errors.raise("APPDISCOVERY_BUNDLE_TARGET_INVALID", "unrecognized target image id: " .. tostring(image.id), {})
  end
  return tonumber(overlayId)
end

local function buildOverlayHex(image)
  local bytes = image.bytes
  local length = #bytes
  local lines = {}
  local offset = 0
  while offset < length do
    local lineLength = math.min(16, length - offset)
    local tokens = {}
    for i = 0, lineLength - 1 do
      tokens[#tokens + 1] = string.format("%02X", string.byte(bytes, offset + i + 1))
    end
    lines[#lines + 1] = string.format("%08X: %s", image.ramAddress + offset, table.concat(tokens, " "))
    offset = offset + 16
  end
  return table.concat(lines, "\n") .. (length > 0 and "\n" or "")
end

local function formatOperands(operands)
  local keys = {}
  for k in pairs(operands or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. tostring(operands[k])
  end
  return table.concat(parts, " ")
end

local function formatRaw(raw)
  local parts = {}
  for _, word in ipairs(raw or {}) do
    parts[#parts + 1] = string.format("%04X", word)
  end
  return table.concat(parts, " ")
end

local function flowAnnotation(instr)
  local flow = instr.flow
  if not flow then
    return ""
  end
  if flow.kind == "call" and flow.target then
    return string.format(" ; call 0x%08X", flow.target)
  elseif flow.kind == "branch" and flow.target then
    return string.format(" ; branch 0x%08X", flow.target)
  elseif flow.kind == "return" then
    return " ; return"
  elseif flow.kind == "indirect" then
    return " ; indirect"
  end
  return ""
end

local function formatMnemonic(instr)
  local flow = instr.flow
  if flow and flow.kind == "branch" and flow.conditional then
    assert(type(flow.condition) == "string")
    return "b" .. flow.condition
  end
  return instr.mnemonic
end

local function buildFunctionDisassembly(fn)
  local instructions = {}
  for i, instr in ipairs(fn.instructions) do
    instructions[i] = instr
  end
  table.sort(instructions, function(a, b)
    return a.address < b.address
  end)

  local lines = { string.format("# fn_%08X", fn.entry), "" }
  for _, instr in ipairs(instructions) do
    lines[#lines + 1] = string.format(
      "%08X  %-9s %-4s %s%s",
      instr.address,
      formatRaw(instr.raw),
      formatMnemonic(instr),
      formatOperands(instr.operands),
      flowAnnotation(instr)
    )
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local function buildDisassemblyFiles(disassembly, addFile)
  local functions = {}
  for i, fn in ipairs(disassembly.functions) do
    functions[i] = fn
  end
  table.sort(functions, function(a, b)
    return a.entry < b.entry
  end)

  local index = { schema = DISASSEMBLY_INDEX_SCHEMA, functions = {} }
  for _, fn in ipairs(functions) do
    local path = string.format("application/disassembly/fn-%08X.md", fn.entry)
    addFile(path, buildFunctionDisassembly(fn))
    index.functions[#index.functions + 1] = {
      entry = fn.entry,
      instructionCount = #fn.instructions,
      path = path,
    }
  end
  addFile("application/disassembly-index.lua", encodeLua(index, "application/disassembly-index.lua"))
end

local function buildResourceDetailFiles(resources, addFile)
  local details = {}
  for _, detail in ipairs(resources.details) do
    details[#details + 1] = detail
  end
  table.sort(details, function(a, b)
    return a.fileId < b.fileId or (a.fileId == b.fileId and a.memberId < b.memberId)
  end)

  local index = { schema = RESOURCE_DETAIL_INDEX_SCHEMA, details = {} }
  for _, detail in ipairs(details) do
    local stem = "resources/details/file-" .. detail.fileId .. "-member-" .. detail.memberId
    local detailPath = stem .. ".lua"
    local payloadPath = stem .. ".bin"
    assert(type(detail.payload) == "string", "resource detail payload must be bytes")
    assert(detail.payloadSize == #detail.payload, "resource detail payload size mismatch")
    assert(detail.payloadSha1 == Hashing.sha1hex(detail.payload), "resource detail payload hash mismatch")

    addFile(payloadPath, detail.payload)
    local classification = {
      kind = detail.kind,
      status = detail.status,
      compression = detail.compression,
      compressionCandidate = detail.compressionCandidate,
    }
    local record = {
      schema = RESOURCE_DETAIL_SCHEMA,
      source = { fileId = detail.fileId, memberId = detail.memberId, narcPath = detail.narcPath },
      classification = classification,
      raw = { size = detail.rawSize, sha1 = detail.rawSha1 },
      payload = {
        basis = detail.payloadBasis,
        size = detail.payloadSize,
        sha1 = detail.payloadSha1,
        path = payloadPath,
      },
      structure = detail.structure,
    }
    if detail.decodedSize ~= nil then
      assert(detail.decodedSha1 ~= nil, "decoded resource detail is missing its hash")
      record.decoded = { size = detail.decodedSize, sha1 = detail.decodedSha1 }
    end
    addFile(detailPath, encodeLua(record, detailPath))
    index.details[#index.details + 1] = {
      fileId = detail.fileId,
      memberId = detail.memberId,
      narcPath = detail.narcPath,
      kind = detail.kind,
      detailPath = detailPath,
      payloadPath = payloadPath,
    }
  end
  addFile("resources/detail-index.lua", encodeLua(index, "resources/detail-index.lua"))
end

local function buildFiles(collected, addFile)
  local application, disassembly, resources, targetImage =
    collected.application, collected.applicationDisassembly, collected.resources, collected.targetImage

  addFile("README.md", README_TEXT)

  addFile("application/analysis.lua", encodeLua(shallowCopyExcluding(application, "gaps"), "application/analysis.lua"))
  addFile("application/gaps.lua", encodeLua(application.gaps, "application/gaps.lua"))
  buildDisassemblyFiles(disassembly, addFile)
  addFile("application/overlay.hex", buildOverlayHex(targetImage))

  local narcIndex = {}
  for _, narc in ipairs(resources.narcs) do
    local narcPath = "resources/narcs/file-" .. narc.fileId .. ".lua"
    addFile(
      narcPath,
      encodeLua({
        fileId = narc.fileId,
        path = narc.path,
        size = narc.size,
        sha1 = narc.sha1,
        memberCount = narc.memberCount,
        members = narc.members,
      }, narcPath)
    )
    narcIndex[#narcIndex + 1] =
      { fileId = narc.fileId, path = narc.path, memberCount = narc.memberCount, file = narcPath }
  end
  table.sort(narcIndex, function(a, b)
    return a.fileId < b.fileId
  end)

  addFile(
    "resources/catalog.lua",
    encodeLua(
      { schema = resources.schema, files = resources.files, narcIndex = narcIndex, coverage = resources.coverage },
      "resources/catalog.lua"
    )
  )
  addFile("resources/narc-id-candidates.lua", encodeLua(resources.narcIdCandidates, "resources/narc-id-candidates.lua"))
  addFile("resources/gaps.lua", encodeLua(resources.gaps, "resources/gaps.lua"))
  buildResourceDetailFiles(resources, addFile)
end

---@param collected AppDiscovery.Collected
---@return AppDiscovery.BuildResult
function EvidenceBundle.build(collected)
  assert(type(collected) == "table", "EvidenceBundle.build requires a collected aggregate")
  local source, targetImage, application, resources =
    collected.source, collected.targetImage, collected.application, collected.resources

  if application.schema ~= APPLICATION_SCHEMA then
    Errors.raise(
      "APPDISCOVERY_BUNDLE_SCHEMA_MISMATCH",
      "unexpected application evidence schema: " .. tostring(application.schema),
      { schema = application.schema }
    )
  end
  if resources.schema ~= RESOURCE_SCHEMA then
    Errors.raise(
      "APPDISCOVERY_BUNDLE_SCHEMA_MISMATCH",
      "unexpected resource evidence schema: " .. tostring(resources.schema),
      { schema = resources.schema }
    )
  end

  local imageOverlayId = targetOverlayIdFromImage(targetImage)
  if imageOverlayId ~= application.target.overlayId then
    Errors.raise(
      "APPDISCOVERY_BUNDLE_TARGET_INCONSISTENT",
      "target overlay id mismatch between target image and application evidence",
      { imageOverlayId = imageOverlayId, applicationOverlayId = application.target.overlayId }
    )
  end

  local files = {}
  local function addFile(path, content)
    if files[path] ~= nil then
      Errors.raise("APPDISCOVERY_BUNDLE_DUPLICATE_PATH", "duplicate bundle member path: " .. path, { path = path })
    end
    files[path] = content
  end

  buildFiles(collected, addFile)

  local manifestFiles = {}
  local paths = {}
  for path in pairs(files) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local content = files[path]
    manifestFiles[#manifestFiles + 1] =
      { path = path, size = #content, sha1 = Hashing.sha1hex(content), mediaType = mediaTypeFor(path) }
  end

  local overlaySource = targetImage.source
  --[[@as { fileId: integer, ramAddress: integer, ramSize: integer, bssSize: integer, isCompressed: boolean }]]
  local manifest = {
    schema = MANIFEST_SCHEMA,
    source = source,
    target = {
      cpu = "arm9",
      overlayId = application.target.overlayId,
      fileId = overlaySource.fileId,
      ramAddress = targetImage.ramAddress,
      ramSize = overlaySource.ramSize,
      bssSize = overlaySource.bssSize,
      normalization = targetImage.normalization,
      rawSize = targetImage.rawSize,
      decodedSize = targetImage.decodedSize,
      rawSha1 = targetImage.rawSha1,
      decodedSha1 = targetImage.decodedSha1,
    },
    applicationSchema = application.schema,
    disassemblySchema = DISASSEMBLY_INDEX_SCHEMA,
    resourceSchema = resources.schema,
    resourceDetailIndexSchema = RESOURCE_DETAIL_INDEX_SCHEMA,
    resourceDetailSchema = RESOURCE_DETAIL_SCHEMA,
    coverage = { application = application.coverage, resources = resources.coverage },
    files = manifestFiles,
  }

  files["manifest.lua"] = encodeLua(manifest, "manifest.lua")

  local summary = {
    versionId = source.versionId,
    overlayId = application.target.overlayId,
    entrypointCandidateCount = application.coverage.candidateCount,
    functionCount = application.coverage.functionCount,
    resourceFileCount = resources.coverage.namedFileCount,
    narcCount = resources.coverage.narcCount,
    narcMemberCount = resources.coverage.narcMemberCount,
    applicationGapCount = #application.gaps,
    resourceGapCount = #resources.gaps,
  }

  return { files = files, manifest = manifest, summary = summary }
end

return EvidenceBundle
