-- Coarse derived-cache generation identity: development identity follows the
-- actual producer working-tree bytes (one SHA-256 manifest over a fixed broad
-- source-root set), release identity uses an explicit per-game counter and
-- performs no producer I/O, and the generation token never substitutes for
-- the semantic script/mon fingerprints that guard saves. Old attestations go
-- cold without touching raw dumps, saves, or artifact roots, and any
-- enumeration/read/validation fault aborts selection instead of falling back
-- to another key.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("romdump.src.source.GameVersion")
local MonCatalog = require("libs.mons.src.MonCatalog")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local Registry = require("libs.script.src.Registry")
local Schema = require("libs.script.src.Schema")
local Sha256 = require("libs.script.src.Sha256")

local T = {}

local HEARTGOLD_SHA1 = GameVersion.VERSIONS.heartgold.sha1

-- Multi-root fake producer tree: trees[root][path] = contents. Every list
-- and read call is recorded so tests can prove release selection touches
-- nothing. Unknown roots read as empty, so a caller that enumerates the
-- wrong roots gets a wrong digest rather than a harness error.
local function fakeBackend(trees, onError)
  local calls = { list = {}, read = {} }
  local files = trees or {}
  local function fail(message)
    if onError == "raise" then
      error(message, 0)
    end
    return nil
  end
  local backend = {}
  function backend.list(root)
    calls.list[#calls.list + 1] = root
    local tree = files[root]
    if tree == nil then
      return {}
    end
    if tree == false then
      error("source root is missing: " .. tostring(root), 0)
    end
    local paths = {}
    for path in pairs(tree) do
      paths[#paths + 1] = path
    end
    return paths
  end
  function backend.read(path, root)
    calls.read[#calls.read + 1] = tostring(root) .. "/" .. tostring(path)
    local tree = files[root]
    if type(tree) ~= "table" or tree[path] == nil then
      fail("cannot read source file: " .. tostring(root) .. "/" .. tostring(path))
      error("cannot read source file: " .. tostring(root) .. "/" .. tostring(path), 0)
    end
    return tree[path]
  end
  function backend.getInfo(_)
    return nil
  end
  backend.calls = calls
  return backend
end

local function devTrees(byteMarker)
  return {
    ["romdump/src"] = {
      ["CacheBuilder.lua"] = "return {} -- pipeline " .. byteMarker,
      ["DerivedCacheState.lua"] = "return {} -- state",
    },
    ["libs/script/src"] = {
      ["Sha256.lua"] = "return {} -- wrapper",
    },
  }
end

local function developDigest(trees, roots)
  return ProducerFingerprint.compute(fakeBackend(trees), roots)
end

local function devIdentity(producerId, overrides)
  local base = {
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "development",
    producerId = producerId,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return DerivedCacheState.current(base)
end

local function releaseIdentity(overrides)
  local base = {
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "release",
    producerId = "r1",
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return DerivedCacheState.current(base)
end

local function registryWith(payload)
  local registry = Registry.new()
  registry:installBase("example.script", { id = "example.script", body = payload }, "generated")
  return registry
end

function T.dirty_bytes_determine_the_development_digest()
  local first = developDigest(devTrees("v1"))
  local dirty = developDigest(devTrees("v2"))
  Assert.isTrue(first ~= dirty, "changed producer bytes must change the development digest")

  local moved = {
    ["romdump/src"] = devTrees("v1")["romdump/src"],
    ["libs/script/src"] = devTrees("v1")["libs/script/src"],
  }
  Assert.equal(
    developDigest(devTrees("v1")),
    developDigest(moved),
    "identical bytes must match regardless of checkout path"
  )
end

function T.development_digest_is_a_versioned_sha256_token()
  local digest = developDigest(devTrees("v1"))
  Assert.isTrue(
    digest:match("^d[0-9a-f]*$") ~= nil,
    "development digest must be d + lowercase hex, got " .. tostring(digest)
  )
  Assert.equal(#digest, 65, "development digest must carry a full SHA-256 hex payload")
end

function T.tiny_tree_matches_the_documented_manifest_hash()
  local trees = {
    ["romdump/src"] = {
      ["b.lua"] = "second",
      ["a.lua"] = "first",
    },
  }
  local manifest = "romdump/src/a.lua\t"
    .. Sha256.hex("first")
    .. "\n"
    .. "romdump/src/b.lua\t"
    .. Sha256.hex("second")
    .. "\n"
  Assert.equal(
    developDigest(trees),
    "d" .. Sha256.hex(manifest),
    "manifest must sort paths and join path + TAB + hex + LF"
  )
end

function T.file_set_and_path_identity_matter_but_mtimes_do_not()
  local base = developDigest(devTrees("v1"))

  local added = devTrees("v1")
  added["romdump/src"]["NewCompiler.lua"] = "return {}"
  Assert.isTrue(developDigest(added) ~= base, "a file addition must change the digest")

  local removed = devTrees("v1")
  removed["libs/script/src"] = {}
  Assert.isTrue(developDigest(removed) ~= base, "a file deletion must change the digest")

  local renamed = devTrees("v1")
  renamed["romdump/src"]["State.lua"] = renamed["romdump/src"]["DerivedCacheState.lua"]
  renamed["romdump/src"]["DerivedCacheState.lua"] = nil
  Assert.isTrue(developDigest(renamed) ~= base, "a rename must change the digest even when bytes are identical")

  local crlf = devTrees("v1")
  crlf["romdump/src"]["CacheBuilder.lua"] = "return {}\r\n"
  local lf = devTrees("v1")
  lf["romdump/src"]["CacheBuilder.lua"] = "return {}\n"
  Assert.isTrue(developDigest(crlf) ~= developDigest(lf), "CRLF and LF bytes must hash differently")

  local empty = { ["romdump/src"] = {}, ["libs/script/src"] = {} }
  local withEmptyFile = { ["romdump/src"] = { ["Empty.lua"] = "" }, ["libs/script/src"] = {} }
  Assert.isTrue(developDigest(empty) ~= developDigest(withEmptyFile), "empty files must participate in the digest")
end

function T.release_selection_reads_no_producer_files()
  local backend = fakeBackend(devTrees("v1"))
  local identity = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "release",
    producerId = "r1",
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  Assert.equal(#backend.calls.list, 0, "release selection must not enumerate producer sources")
  Assert.equal(#backend.calls.read, 0, "release selection must not read producer sources")
  Assert.equal(
    identity.generationId,
    "g4:heartgold:"
      .. HEARTGOLD_SHA1
      .. ":r1:a"
      .. tostring(DerivedAssetContract.revision)
      .. ":s"
      .. tostring(Schema.API_VERSION),
    "release generation token must carry the explicit per-game counter"
  )

  local failing = {
    list = function()
      error("release must never enumerate sources", 0)
    end,
    read = function()
      error("release must never read sources", 0)
    end,
    getInfo = function()
      return nil
    end,
  }
  local again = DerivedCacheState.current({
    versionId = "soulsilver",
    romSha1 = GameVersion.VERSIONS.soulsilver.sha1,
    mode = "release",
    producerId = "r1",
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  Assert.isTrue(
    failing ~= nil and again.generationId:match("^g4:soulsilver:") ~= nil,
    "release identity must not depend on any source backend"
  )
end

function T.generation_differs_while_semantic_fingerprints_still_match()
  local first = devIdentity("d" .. Sha256.hex("producer tree one"))
  local second = devIdentity("d" .. Sha256.hex("producer tree two"))
  Assert.isTrue(
    first.generationId ~= second.generationId,
    "different producer bytes must yield different generation tokens"
  )

  local left = registryWith("same payload")
  local right = registryWith("same payload")
  Assert.equal(
    left:fingerprint(),
    right:fingerprint(),
    "identical script content must keep the save-compatibility fingerprint"
  )

  local leftCatalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), CatalogFixture.makeItemCatalog())
  local rightCatalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), CatalogFixture.makeItemCatalog())
  Assert.equal(
    leftCatalog:fingerprint(),
    rightCatalog:fingerprint(),
    "identical mon content must keep the save-compatibility fingerprint"
  )
end

function T.previous_attestation_is_cold_and_leaves_raw_and_saves_alone()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:write("data/raw/heartgold.nds", "raw dump bytes")
  cache:write("saves/heartgold/save1.lua", "save payload bytes")

  local oldIdentity = DerivedCacheState.current({
    dump = "g4-rom-dump-v1:heartgold:" .. HEARTGOLD_SHA1,
    producer = "old-producer-fingerprint",
    assetContract = { revision = DerivedAssetContract.revision },
    scriptApi = Schema.API_VERSION,
  })
  DerivedCacheState.publish(cache, oldIdentity)

  local rotated = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "development",
    producerId = "d" .. Sha256.hex("new producer tree"),
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  local stored = cache:loadLua(DerivedCacheState.path)
  Assert.isFalse(DerivedCacheState.matches(stored, rotated), "an attestation from another generation must read as cold")
  Assert.equal(cache:read("data/raw/heartgold.nds"), "raw dump bytes", "invalidation must preserve the raw dump")
  Assert.equal(cache:read("saves/heartgold/save1.lua"), "save payload bytes", "invalidation must preserve saves")

  DerivedCacheState.invalidate(cache)
  Assert.isNil(cache:read(DerivedCacheState.path), "invalidate must remove the completion attestation")
  Assert.equal(cache:read("data/raw/heartgold.nds"), "raw dump bytes", "invalidate must not delete the raw dump")
  Assert.equal(cache:read("saves/heartgold/save1.lua"), "save payload bytes", "invalidate must not delete saves")
end

function T.faults_abort_selection_without_a_fallback_key()
  local missing = fakeBackend({ ["romdump/src"] = false })
  local missingErr = Assert.throws(function()
    ProducerFingerprint.compute(missing)
  end)
  Assert.equal(type(missingErr), "table", "a missing source root must raise a structured error")
  Assert.equal(missingErr.code, "PRODUCER_SOURCE_UNAVAILABLE", "a missing source root must name its failure")

  local unreadable = fakeBackend({ ["romdump/src"] = { ["CacheBuilder.lua"] = "return {}" } })
  function unreadable.read(_, _)
    error("injected read failure", 0)
  end
  local readErr = Assert.throws(function()
    ProducerFingerprint.compute(unreadable)
  end)
  Assert.equal(type(readErr), "table", "an unreadable source file must raise a structured error")

  local emptyManifest = ProducerFingerprint.compute(fakeBackend({}))
  Assert.equal(
    emptyManifest,
    "d" .. Sha256.hex(""),
    "an empty source selection must hash the empty manifest, never a fallback constant"
  )
end

function T.sha256_reference_vectors_hold_through_the_native_wrapper()
  Assert.equal(Sha256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  Assert.equal(Sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end

function T.source_paths_with_tabs_or_newlines_are_rejected()
  for _, bad in ipairs({ "ta\tb.lua", "new\nline.lua" }) do
    local backend = fakeBackend({ ["romdump/src"] = { [bad] = "return {}" } })
    local err = Assert.throws(function()
      ProducerFingerprint.compute(backend)
    end, "a source path containing tab or newline must be rejected: " .. string.format("%q", bad))
    Assert.equal(type(err), "table", "a malformed source path must raise a structured error")
  end
end

function T.malformed_identity_inputs_are_rejected()
  local badModes = { "debug", "", "Development" }
  for _, mode in ipairs(badModes) do
    Assert.throws(function()
      devIdentity("d" .. Sha256.hex("x"), { mode = mode })
    end, "mode must be development or release, got " .. string.format("%q", mode))
  end
  Assert.throws(function()
    devIdentity("not-a-producer-id")
  end, "a malformed development producer id must be rejected")
  Assert.throws(function()
    devIdentity("d" .. Sha256.hex("x"), { romSha1 = "short" })
  end, "a malformed ROM identity must be rejected")
  Assert.throws(function()
    devIdentity("d" .. Sha256.hex("x"), { versionId = "platinum" })
  end, "an unsupported version must be rejected without a default counter")
  Assert.throws(function()
    releaseIdentity({ producerId = "r0" })
  end, "a non-positive release counter must be rejected")
  Assert.throws(function()
    devIdentity("d" .. Sha256.hex("x"), { assetRevision = "ten" })
  end, "a non-numeric contract revision must be rejected")
end

function T.identity_matching_is_strict_about_schema_and_extra_fields()
  local identity = devIdentity("d" .. Sha256.hex("producer tree"))
  Assert.isTrue(DerivedCacheState.matches(identity, identity), "an identical strict record must match")
  Assert.keySet(identity, "assetRevision,generationId,mode,producerId,romSha1,schema,scriptApi,versionId")

  local legacy = {
    schema = 1,
    dump = "g4-rom-dump-v1:heartgold:" .. HEARTGOLD_SHA1,
    producer = "old-producer-fingerprint",
  }
  Assert.isFalse(
    DerivedCacheState.matches(legacy, identity),
    "a previous-schema attestation must read as cold, not as a match"
  )

  local widened = {}
  for key, value in pairs(identity) do
    widened[key] = value
  end
  widened.extraField = "unbudgeted metadata"
  Assert.isFalse(DerivedCacheState.matches(widened, identity), "extra identity fields must not compare equal")
end

-- Drive the real headless preparation command the way production invokes it:
-- stub only the host boundaries (ready dump, ROM identity, build session,
-- process exit), while producer selection stays real. Every stub is restored
-- and the dirty-probe scratch file is removed on every path.
---@param stubs { isReady?: fun(versionId: string): boolean }
---@param fn fun(select: (fun(dev: boolean): string), exits: integer[])
local function withPreparationCommand(stubs, fn)
  local Runner = require("romdump.src.cli.Runner")
  local RomImporter = require("romdump.src.source.RomImporter")
  local realIsReady = RomImporter.isReady
  local realRomFs = package.loaded["romdump.src.source.RomFs"]
  local realBuilder = package.loaded["romdump.src.CacheBuilder"]
  local realQuit = love.event.quit
  local realOpts = Runner.opts
  local identities = {}
  local exits = {}
  RomImporter.isReady = stubs.isReady or function()
    return true
  end
  package.loaded["romdump.src.source.RomFs"] = {
    open = function()
      return {
        metadata = function()
          return { sha1 = HEARTGOLD_SHA1 }
        end,
        close = function() end,
      }
    end,
  }
  package.loaded["romdump.src.CacheBuilder"] = {
    prepareVersion = function(version, options)
      identities[#identities + 1] = { version = version, identity = options.identity }
      return {
        requestedReady = true,
        complete = true,
        counts = { planned = 0, successful = 0, failed = 0, cancelled = 0, excluded = 0 },
      }
    end,
  }
  love.event.quit = function(code)
    exits[#exits + 1] = code
  end
  local function select(dev)
    Runner.opts = { version = "heartgold", requirements = { "bootstrap" }, dev = dev }
    Runner._runPrepareCache()
    local selected = identities[#identities]
    assert(selected ~= nil, "preparation must forward an identity to the build session")
    assert(selected.version == "heartgold", "preparation must prepare the requested version")
    return assert(selected.identity).producerId
  end
  local ok, err = pcall(fn, select, exits)
  RomImporter.isReady = realIsReady
  package.loaded["romdump.src.source.RomFs"] = realRomFs
  package.loaded["romdump.src.CacheBuilder"] = realBuilder
  love.event.quit = realQuit
  Runner.opts = realOpts
  if not ok then
    error(err, 0)
  end
end

-- Production development selection must hash the real working tree resolved
-- against the repository root the app runs from: the digest is non-empty, a
-- changed producer byte changes it, and removing the byte restores it. The
-- dirty probe is a single scratch file inside a resolved root, removed
-- before the test ends.
function T.production_development_selection_follows_working_tree_bytes()
  local repositoryRoot = love.filesystem.getSourceBaseDirectory()
  local scratchPath = repositoryRoot .. "/romdump/src/__dirty_probe_tmp.lua"
  assert(scratchPath:find("%.%.") == nil, "the dirty probe must stay inside the resolved root")
  withPreparationCommand({}, function(select, exits)
    local clean = select(true)
    Assert.isTrue(
      clean:match("^d[0-9a-f]+$") ~= nil and #clean == 65,
      "development selection must be a d-prefixed SHA-256 token, got " .. tostring(clean)
    )
    Assert.isTrue(
      clean ~= "d" .. Sha256.hex(""),
      "development selection must hash working-tree bytes, never the empty manifest"
    )
    local probe = assert(io.open(scratchPath, "w"), "the dirty probe must open inside the resolved root")
    probe:write("return {} -- dirty working-tree probe\n")
    probe:close()
    local probeOk, dirtyOrErr = pcall(select, true)
    local removeOk = os.remove(scratchPath)
    assert(removeOk, "the dirty probe must be removed from the working tree")
    Assert.isTrue(probeOk, "selection with a dirty byte must succeed: " .. tostring(dirtyOrErr))
    ---@cast dirtyOrErr string
    Assert.isTrue(dirtyOrErr ~= clean, "a changed producer byte must change the development digest")
    Assert.equal(select(true), clean, "removing the dirty byte must restore the digest")
    Assert.deepEqual(exits, { 0, 0, 0 }, "every development selection must report success")
  end)
  Assert.isNil(io.open(scratchPath, "r"), "the dirty probe must not survive the test")
end

-- Production release selection uses the explicit per-game counter and never
-- enumerates or reads producer sources, even when every source backend fails.
function T.production_release_selection_reads_no_producer_sources()
  local realCompute = ProducerFingerprint.compute
  local realAppBackend = ProducerFingerprint.appBackend
  local realCheckoutBackend = ProducerFingerprint.checkoutBackend
  local touches = 0
  local function touch()
    touches = touches + 1
    error("release selection must not touch producer sources", 0)
  end
  ProducerFingerprint.compute = touch
  ProducerFingerprint.appBackend = touch
  ProducerFingerprint.checkoutBackend = touch
  local ok, err = pcall(function()
    withPreparationCommand({}, function(select, exits)
      Assert.equal(select(false), "r2", "release selection must carry the explicit per-game counter")
      Assert.deepEqual(exits, { 0 }, "release selection must report success")
    end)
  end)
  ProducerFingerprint.compute = realCompute
  ProducerFingerprint.appBackend = realAppBackend
  ProducerFingerprint.checkoutBackend = realCheckoutBackend
  if not ok then
    error(err, 0)
  end
  Assert.equal(touches, 0, "release selection must perform zero producer-source reads")
end

-- Release identity rotates through the explicit per-game counter for both
-- supported games when producer semantics change without a shared
-- asset-contract revision.
function T.production_release_counters_rotate_for_both_supported_games()
  Assert.equal(DerivedCacheVersions.heartgold, 2, "the HeartGold release counter rotates with the producer change")
  Assert.equal(DerivedCacheVersions.soulsilver, 2, "the SoulSilver release counter rotates with the producer change")
end

return { tests = T }
