-- Lazy registry tests: deferred base layers decode through the registry's
-- resource loader on first access, presence semantics (ids/duplicates) work
-- without decoding, the fingerprint consumes pre-stashed per-resource hashes
-- without touching the loader, and the RegistryWarmup background pass slices
-- decode+hash work, records failures, and publishes the snapshot on
-- completion.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local Registry = require("libs.script.src.Registry")
local RegistrySnapshot = require("libs.script.src.RegistrySnapshot")
local RegistryWarmup = require("libs.script.src.RegistryWarmup")
local Sha256 = require("libs.script.src.Sha256")

local T = {}
local GENERATION = string.rep("a", 40)
local MARKER = "script-cache-v4:rom-sha:dep-sha"

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  Assert.equal((err --[[@as Errors.Error]]).code, code)
end

-- A cache whose script class is complete: marker, index, and script files.
local function scriptCache(files)
  files = files
    or {
      ["new_bark.lab_sign"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.stop() } }\n',
      ["vanilla.hgss.scr_seq.0842.script_001"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "vanilla.hgss.scr_seq.0842.script_001", steps = { S.stop() } }\n',
    }
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local resources = {}
  for id in pairs(files) do
    resources[#resources + 1] = { id = id }
  end
  table.sort(resources, function(a, b)
    return a.id < b.id
  end)
  for index, entry in ipairs(resources) do
    entry.member = 0
    entry.scriptIndex = index - 1
  end
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = resources,
  })
  for id, content in pairs(files) do
    cache:write(ScriptCache.scriptPath(GENERATION, 0, id), content)
  end
  return cache
end

-- A read-shaped filesystem for the override tree: the manifest and the
-- override files.
local function overrideFs(files)
  files = files or {}
  local manifest = {}
  for name in pairs(files) do
    local id = name:match("^(.*)%.lua$")
    if id ~= nil then
      manifest[#manifest + 1] = id
    end
  end
  table.sort(manifest)
  local manifestText = "return {\n"
  for _, id in ipairs(manifest) do
    manifestText = manifestText .. "  " .. string.format("%q", id) .. ",\n"
  end
  manifestText = manifestText .. "}\n"
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return manifestText
      end
      for name, content in pairs(files) do
        if path == "data/scripts/overrides/" .. name then
          return content
        end
      end
      return nil
    end,
  }
end

local function requireShim(name)
  if name == "gen4.script" then
    return require("gen4.script")
  end
  error("unexpected require in script chunk: " .. name)
end

-- A registry with two deferred generated layers over a fixture cache and a
-- recording loader.
local function lazyRegistry(cache)
  local calls = {}
  local registry = Registry.new({
    loadResource = function(id)
      calls[#calls + 1] = id
      local resource =
        assert(ScriptLoader.loadGeneratedFrom(cache, GENERATION, 0, id, requireShim, { validate = false }))
      return resource
    end,
  })
  registry:installBaseDeferred("new_bark.lab_sign", "generated")
  registry:installBaseDeferred("vanilla.hgss.scr_seq.0842.script_001", "generated")
  return registry, calls
end

-- 1. A deferred base decodes through the loader on first access and is
-- memoized: the loader runs once per id.
T["deferred base decodes through the loader once"] = function()
  local registry, calls = lazyRegistry(scriptCache())
  Assert.isNil(registry:base("unknown.id"))
  local resource = assert(registry:base("new_bark.lab_sign"))
  Assert.equal(resource.id, "new_bark.lab_sign")
  Assert.deepEqual(calls, { "new_bark.lab_sign" })
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.deepEqual(calls, { "new_bark.lab_sign" }, "the decoded base is memoized")
end

T["builtin base is available without generated data"] = function()
  local registry = Registry.new()
  local builtin = { id = "runtime.inert_interaction" }
  registry:installBuiltin(builtin.id, builtin)
  Assert.equal(registry:base(builtin.id), builtin)
end

-- 2. Presence works without decoding: ids never touch the loader.
T["presence semantics never decode"] = function()
  local registry, calls = lazyRegistry(scriptCache())
  Assert.deepEqual(registry:ids(), { "new_bark.lab_sign", "vanilla.hgss.scr_seq.0842.script_001" })
  Assert.isNil(registry:base("unknown.id"))
  Assert.deepEqual(calls, {})
end

-- 3. Deferred layers obey the same duplicate rules as installBase.
T["deferred layers detect duplicates"] = function()
  local registry = Registry.new()
  registry:installBaseDeferred("dup.id", "generated")
  throwsCode("SCRIPT_DUPLICATE_ID", function()
    registry:installBaseDeferred("dup.id", "generated")
  end)
  throwsCode("SCRIPT_DUPLICATE_ID", function()
    registry:installBase("dup.id", {}, "generated")
  end)
end

-- 4. A resolved layer beats a pending generated layer without decoding.
T["resolved layers beat a pending generated layer"] = function()
  local registry, calls = lazyRegistry(scriptCache())
  registry:installBase("new_bark.lab_sign", { id = "new_bark.lab_sign", override = true }, "override")
  local resource = assert(registry:base("new_bark.lab_sign"))
  Assert.isTrue(resource.override == true)
  Assert.deepEqual(calls, {}, "the override wins without touching the loader")
end

-- 5. A failing loader surfaces as a load error at first access.
T["loader failure raises a load error"] = function()
  local registry = Registry.new({
    loadResource = function()
      return nil
    end,
  })
  registry:installBaseDeferred("broken.id", "generated")
  throwsCode("SCRIPT_LOAD_FAILED", function()
    registry:base("broken.id")
  end)
end

-- 6. A lazy registry's fingerprint matches the eager registry's for the same
-- content.
T["lazy fingerprint matches the eager registry"] = function()
  local eager = ScriptLoader.buildRegistry(scriptCache(), overrideFs(), requireShim)
  local lazy = ScriptLoader.buildRegistry(scriptCache(), overrideFs(), requireShim, { lazy = true })
  Assert.equal(lazy:fingerprint(), eager:fingerprint())
end

-- 7. Stashed per-resource hashes let the fingerprint run without decoding:
-- the loader is never called, and the pending bases still decode on demand
-- afterwards.
T["fingerprint uses stashed hashes without decoding"] = function()
  local cache = scriptCache()
  local registry, calls = lazyRegistry(cache)
  for _, id in ipairs(registry:ids()) do
    local resource = assert(ScriptLoader.loadGeneratedFrom(cache, GENERATION, 0, id, requireShim, { validate = false }))
    registry:cacheScriptHash(id, "generated", Sha256.hex(LuaWriter.encode(resource)))
  end
  local fingerprint = registry:fingerprint()
  Assert.deepEqual(calls, {}, "the stashed hashes avoided the loader")
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.deepEqual(calls, { "new_bark.lab_sign" }, "pending bases still decode on demand")
  Assert.equal(fingerprint, registry:fingerprint(), "the memoized digest stays stable")
end

-- 8. A mutation invalidates the stashed hashes: the fingerprint recomputes
-- through the loader.
T["stashed hashes are invalidated on mutation"] = function()
  local registry, calls = lazyRegistry(scriptCache())
  local resource = assert(
    ScriptLoader.loadGeneratedFrom(scriptCache(), GENERATION, 0, "new_bark.lab_sign", requireShim, { validate = false })
  )
  registry:cacheScriptHash("new_bark.lab_sign", "generated", Sha256.hex(LuaWriter.encode(resource)))
  registry:installBase("new_bark.lab_sign", { id = "new_bark.lab_sign", override = true }, "override")
  local fingerprint = registry:fingerprint()
  Assert.isTrue(#calls > 0, "the mutation forces a live recompute")
  Assert.equal(fingerprint, registry:fingerprint())
end

-- 9. The warm-up completes, restores the memo, and publishes a loadable
-- snapshot; the digest equals an eager build's.
T["warmup completes and writes a loadable snapshot"] = function()
  local cache = scriptCache()
  local fs = overrideFs({})
  local key = RegistrySnapshot.key(cache, fs)
  Assert.notNil(key)
  local publicationCount = 0
  local originalWriteLua = cache.writeLua
  cache.writeLua = function(self, path, value)
    publicationCount = publicationCount + 1
    return originalWriteLua(self, path, value)
  end
  local registry, selection = ScriptLoader.buildRegistry(cache, fs, requireShim, { lazy = true })
  local warmup = RegistryWarmup.new({
    registry = registry,
    cacheFs = cache,
    overrideFs = fs,
    snapshotKey = key,
    selection = selection,
  })
  Assert.isFalse(warmup:isComplete())
  local failure = warmup:finish()
  Assert.isNil(failure, tostring(failure and failure.message))
  Assert.isTrue(warmup:isComplete())
  Assert.equal(publicationCount, 1, "warm-up publishes one snapshot artifact")
  local snapshot = cache:loadLua(RegistrySnapshot.FILE)
  Assert.notNil(snapshot, "warm-up must publish a loadable snapshot")
  ---@cast snapshot table
  Assert.equal(snapshot.schema, "g4-registry-snapshot-v1")
  Assert.equal(snapshot.key, key)
  Assert.equal(snapshot.fingerprint, registry:fingerprint())
  local eager = ScriptLoader.buildRegistry(cache, fs, requireShim)
  Assert.equal(snapshot.fingerprint, eager:fingerprint(), "the warm-up digest matches a fresh eager build")
end

-- 10. A zero-budget update processes nothing: the pass is sliced, and the
-- blocking finish completes the remainder.
T["warmup slices by time budget and finish completes the remainder"] = function()
  local cache = scriptCache()
  local fs = overrideFs({})
  local registry, selection = ScriptLoader.buildRegistry(cache, fs, requireShim, { lazy = true })
  local warmup = RegistryWarmup.new({
    registry = registry,
    cacheFs = cache,
    overrideFs = fs,
    snapshotKey = assert(RegistrySnapshot.key(cache, fs)),
    selection = selection,
    budget = 0,
  })
  warmup:update()
  Assert.isFalse(warmup:isComplete(), "a zero-budget update must not complete the pass")
  Assert.isNil(warmup:finish())
  Assert.isTrue(warmup:isComplete())
end

T["warmup uses the two millisecond default budget"] = function()
  local files = {}
  for index = 1, 3 do
    local id = string.format("warmup.default.%d", index)
    files[id] = string.format(
      'local S = require("gen4.script")\nreturn S.script { api = 1, id = %q, steps = { S.stop() } }\n',
      id
    )
  end
  local cache = scriptCache(files)
  local fs = overrideFs({})
  local clock = 0
  local processed = 0
  local registry = {
    cacheScriptHash = function()
      processed = processed + 1
    end,
    fingerprint = function()
      return ("0"):rep(64)
    end,
    restoreFingerprint = function() end,
  }
  local warmup = RegistryWarmup.new({
    registry = registry,
    cacheFs = cache,
    overrideFs = fs,
    snapshotKey = assert(RegistrySnapshot.key(cache, fs)),
    selection = ScriptCache.loadActive(cache),
    clock = function()
      clock = clock + 0.001
      return clock
    end,
  })
  warmup:update()
  Assert.equal(processed, 2, "the default budget must process two 1 ms work units")
  Assert.isFalse(warmup:isComplete(), "the default budget must leave remaining work for a later update")
end

-- 11. An unparsable generated file fails the warm-up loudly: no snapshot is
-- written and the failure is returned.
T["warmup records a failure on unparsable content"] = function()
  local cache = scriptCache({ ["new_bark.lab_sign"] = "return { broken" })
  local fs = overrideFs({})
  local key = assert(RegistrySnapshot.key(cache, fs))
  local registry, selection = ScriptLoader.buildRegistry(cache, fs, requireShim, { lazy = true })
  local warmup = RegistryWarmup.new({
    registry = registry,
    cacheFs = cache,
    overrideFs = fs,
    snapshotKey = key,
    selection = selection,
  })
  local failure = assert(warmup:finish())
  Assert.equal(failure.code, "SCRIPT_LOAD_FAILED")
  Assert.isNil(cache:read(RegistrySnapshot.FILE), "a failed warm-up must not publish a snapshot")
end

-- A failed snapshot publication must remain visible and must not mark the
-- warm-up complete.
T["warmup raises and remains incomplete when snapshot publication fails"] = function()
  local cache = scriptCache()
  local fs = overrideFs({})
  local key = assert(RegistrySnapshot.key(cache, fs))
  cache.backend.write = function()
    return false, "injected write failure"
  end
  local registry, selection = ScriptLoader.buildRegistry(cache, fs, requireShim, { lazy = true })
  local warmup = RegistryWarmup.new({
    registry = registry,
    cacheFs = cache,
    overrideFs = fs,
    snapshotKey = key,
    selection = selection,
  })

  local err = Assert.throws(function()
    warmup:finish()
  end)

  Assert.notNil(err)
  Assert.isFalse(warmup:isComplete())
end

-- 12. Finish is idempotent: the second call returns nil and the digest is
-- unchanged.
T["warmup finish is idempotent"] = function()
  local cache = scriptCache()
  local fs = overrideFs({})
  local registry, selection = ScriptLoader.buildRegistry(cache, fs, requireShim, { lazy = true })
  local warmup = RegistryWarmup.new({
    registry = registry,
    cacheFs = cache,
    overrideFs = fs,
    snapshotKey = assert(RegistrySnapshot.key(cache, fs)),
    selection = selection,
  })
  Assert.isNil(warmup:finish())
  local fingerprint = registry:fingerprint()
  Assert.isNil(warmup:finish())
  Assert.equal(registry:fingerprint(), fingerprint)
end

-- 13. buildRegistry returns a sealed registry: the post-load registry is
-- immutable during gameplay.
T["buildRegistry returns a sealed registry"] = function()
  local registry = ScriptLoader.buildRegistry(scriptCache(), overrideFs(), requireShim, { lazy = true })
  throwsCode("SCRIPT_REGISTRY_SEALED", function()
    registry:installBase("late.id", { id = "late.id" }, "generated")
  end)
end

-- 14. The seal exempts the post-load machinery: per-resource hash stashing,
-- the restored fingerprint memo, and on-demand decode all keep working on a
-- sealed registry, while the install surface stays shut.
T["seal exempts the post-load machinery"] = function()
  local cache = scriptCache()
  local registry, calls = lazyRegistry(cache)
  registry:seal()
  local resource =
    assert(ScriptLoader.loadGeneratedFrom(cache, GENERATION, 0, "new_bark.lab_sign", requireShim, { validate = false }))
  registry:cacheScriptHash("new_bark.lab_sign", "generated", Sha256.hex(LuaWriter.encode(resource)))
  registry:fingerprint()
  Assert.deepEqual(calls, { "vanilla.hgss.scr_seq.0842.script_001" }, "the stashed hash avoids the loader for its id")
  registry:restoreFingerprint(("0"):rep(64))
  Assert.equal(registry:fingerprint(), ("0"):rep(64), "the restored memo must stay authoritative")
  Assert.equal(assert(registry:base("new_bark.lab_sign")).id, "new_bark.lab_sign")
  throwsCode("SCRIPT_REGISTRY_SEALED", function()
    registry:installBase("late.id", { id = "late.id" }, "generated")
  end)
end

return { tests = T }
