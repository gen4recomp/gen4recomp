-- RegistrySnapshot tests: the keyed registry-fingerprint snapshot persisted
-- into the script cache. The key covers the script-cache marker and the
-- override manifest plus every listed override file, so the stored fingerprint
-- is valid by construction when the key matches; load never raises (a miss
-- falls back to the slow validated build) and save never reports success after
-- a failed write.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local RegistrySnapshot = require("libs.script.src.RegistrySnapshot")
local BuiltinScripts = require("libs.hgss.src.script.BuiltinScripts")

local T = {}
local GENERATION = string.rep("a", 40)

local HEX = "^[0-9a-f]+$"

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  local errorObject = err --[[@as Errors.Error]]
  Assert.equal(errorObject.code, code)
end

-- A cache whose script class is complete: marker, index, and script files.
local function scriptCache(marker)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  marker = marker or "script-cache-v4:rom-sha:dep-sha"
  cache:write(ScriptCache.markerPath(), marker)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), marker)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = marker,
  })
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = marker,
    resources = { { id = "new_bark.lab_sign", member = 0, scriptIndex = 0 } },
  })
  cache:write(
    ScriptCache.scriptPath(GENERATION, 0, "new_bark.lab_sign"),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.stop() } }\n'
  )
  return cache
end

-- A read-shaped filesystem for the override tree: the manifest and the
-- override files. `manifestText` overrides the derived manifest when the
-- test needs a malformed one.
local function overrideFs(files, manifestText)
  files = files or {}
  if manifestText == nil then
    local manifest = {}
    for name in pairs(files) do
      local id = name:match("^(.*)%.lua$")
      if id ~= nil then
        manifest[#manifest + 1] = id
      end
    end
    table.sort(manifest)
    manifestText = "return {\n"
    for _, id in ipairs(manifest) do
      manifestText = manifestText .. "  " .. string.format("%q", id) .. ",\n"
    end
    manifestText = manifestText .. "}\n"
  end
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

local function snapshotText(key, fingerprint)
  return "return { schema = "
    .. string.format("%q", RegistrySnapshot.SCHEMA)
    .. ", key = "
    .. string.format("%q", key)
    .. ", fingerprint = "
    .. string.format("%q", fingerprint)
    .. " }\n"
end

local FP_A = ("a"):rep(64)
local FP_B = ("b"):rep(64)

-- load() for the fixtures where a marker exists, so a nil return is a
-- fixture fault rather than a silently dereferenced result.
local function loadedFingerprint(cache, fs)
  local loaded = RegistrySnapshot.load(cache, fs)
  Assert.notNil(loaded, "registry snapshot load returned nil")
  ---@cast loaded table
  return loaded.fingerprint
end

-- 1. The key is deterministic and covers the marker, the manifest, and every
-- override file.
T["key is deterministic over marker, manifest, and override files"] = function()
  local files = { ["new_bark.lab_sign.lua"] = "override-a", ["elms_lab.elm.lua"] = "override-b" }
  Assert.equal(
    RegistrySnapshot.key(scriptCache(), overrideFs(files)),
    RegistrySnapshot.key(scriptCache(), overrideFs(files))
  )
  Assert.isTrue(RegistrySnapshot.key(scriptCache(), overrideFs(files)):match(HEX) ~= nil)
  Assert.isTrue(
    RegistrySnapshot.key(scriptCache("other-marker"), overrideFs(files))
      ~= RegistrySnapshot.key(scriptCache(), overrideFs(files))
  )
  local changed = {}
  for name, content in pairs(files) do
    changed[name] = content
  end
  changed["new_bark.lab_sign.lua"] = "override-a-changed"
  Assert.isTrue(
    RegistrySnapshot.key(scriptCache(), overrideFs(changed)) ~= RegistrySnapshot.key(scriptCache(), overrideFs(files))
  )
  local grown = {}
  for name, content in pairs(files) do
    grown[name] = content
  end
  grown["extra.script.lua"] = "override-c"
  Assert.isTrue(
    RegistrySnapshot.key(scriptCache(), overrideFs(grown)) ~= RegistrySnapshot.key(scriptCache(), overrideFs(files))
  )
end

T["key changes when builtin executable content changes"] = function()
  local cache = scriptCache()
  local fs = overrideFs()
  local original = BuiltinScripts.all
  local baseline = assert(RegistrySnapshot.key(cache, fs, BuiltinScripts.contentHash))
  rawset(BuiltinScripts, "all", function()
    local scripts = original()
    scripts["runtime.inert_interaction"].steps[1] = { op = "noop" }
    return scripts
  end)
  local ok, changed = pcall(RegistrySnapshot.key, cache, fs, BuiltinScripts.contentHash)
  rawset(BuiltinScripts, "all", original)
  assert(ok, changed)
  changed = assert(changed)
  Assert.isTrue(changed ~= baseline, "builtin content must participate in snapshot identity")
end

-- 2. Without the script-cache marker there is nothing to snapshot: no key.
T["key returns nil without a script cache marker"] = function()
  local cache = scriptCache()
  cache:remove(ScriptCache.markerPath())
  Assert.isNil(RegistrySnapshot.key(cache, overrideFs()))
end

-- 2b. The manifest is evaluated in a restricted environment so the fast
-- path cannot diverge from the slow path: a manifest relying on a global
-- yields no key.
T["key rejects a manifest that relies on globals"] = function()
  local fs = overrideFs({ ["elms_lab.elm.lua"] = "override-a" }, 'return { string.lower("ELMS_LAB.ELM") }\n')
  Assert.isNil(RegistrySnapshot.key(scriptCache(), fs))
end

-- 3. Load returns nil when the script cache marker is absent.
T["load returns nil without a script cache marker"] = function()
  local cache = scriptCache()
  cache:remove(ScriptCache.markerPath())
  Assert.isNil(RegistrySnapshot.load(cache, overrideFs()))
end

-- 4. With a marker but no snapshot file, load reports the current key and no
-- fingerprint (a miss, not an error).
T["load reports a miss without a snapshot file"] = function()
  local loaded = RegistrySnapshot.load(scriptCache(), overrideFs())
  Assert.notNil(loaded, "registry snapshot load returned nil")
  ---@cast loaded table
  Assert.equal(loaded.fingerprint, nil)
  Assert.isTrue(loaded.key:match(HEX) ~= nil)
end

-- 5. An unknown schema is a miss.
T["load rejects an unknown schema"] = function()
  local cache = scriptCache()
  cache:write(
    RegistrySnapshot.FILE,
    'return { schema = "unknown-v9", key = '
      .. string.format("%q", FP_A)
      .. ", fingerprint = "
      .. string.format("%q", FP_A)
      .. " }\n"
  )
  Assert.isNil(loadedFingerprint(cache, overrideFs()))
end

-- 6. A snapshot whose key no longer matches the world is stale: a miss.
T["load rejects a stale snapshot"] = function()
  local cache = scriptCache()
  cache:write(RegistrySnapshot.FILE, snapshotText(FP_A, FP_B))
  Assert.isNil(loadedFingerprint(cache, overrideFs()))
end

-- 7. A corrupt snapshot file is a miss, never a raise.
T["load treats an unparsable snapshot as a miss"] = function()
  local cache = scriptCache()
  cache:write(RegistrySnapshot.FILE, "return { broken")
  Assert.isNil(loadedFingerprint(cache, overrideFs()))
end

-- 8. A snapshot whose fingerprint is not a hex digest is a miss.
T["load rejects a non-hex fingerprint"] = function()
  local cache = scriptCache()
  cache:write(RegistrySnapshot.FILE, snapshotText(RegistrySnapshot.key(cache, overrideFs()), "not-a-digest"))
  Assert.isNil(loadedFingerprint(cache, overrideFs()))
end

-- 9. A matching snapshot hands back its stored fingerprint (the anchor is
-- hand-written Lua, independent of save).
T["load returns the stored fingerprint for a matching snapshot"] = function()
  local cache = scriptCache()
  local key = RegistrySnapshot.key(cache, overrideFs())
  cache:write(RegistrySnapshot.FILE, snapshotText(key, FP_A))
  Assert.equal(loadedFingerprint(cache, overrideFs()), FP_A)
end

-- 10. Save writes a snapshot that loads back with the stored fingerprint.
T["save writes a loadable snapshot"] = function()
  local cache = scriptCache()
  local key = RegistrySnapshot.key(cache, overrideFs())
  Assert.isTrue(RegistrySnapshot.save(cache, overrideFs(), FP_A, key))
  local loaded = RegistrySnapshot.load(cache, overrideFs())
  Assert.notNil(loaded, "saved snapshot must load back")
  ---@cast loaded table
  Assert.equal(loaded.key, key)
  Assert.equal(loaded.fingerprint, FP_A)
end

-- 11. Save skips the write when the world no longer matches the key the
-- fingerprint was computed under.
T["save skips when the world changed since the expected key"] = function()
  local cache = scriptCache()
  local key = RegistrySnapshot.key(cache, overrideFs())
  local changed = overrideFs({ ["new_bark.lab_sign.lua"] = "edited-mid-session" })
  Assert.isFalse(RegistrySnapshot.save(cache, changed, FP_A, key))
  Assert.isNil(cache:read(RegistrySnapshot.FILE))
end

-- 12. Save does nothing without a script cache marker.
T["save does nothing without a marker"] = function()
  local cache = scriptCache()
  cache:remove(ScriptCache.markerPath())
  Assert.isFalse(RegistrySnapshot.save(cache, overrideFs(), FP_A, "any"))
  Assert.isNil(cache:read(RegistrySnapshot.FILE))
end

-- 13. A failed write reports failure and never reports success.
T["save returns false when the write fails"] = function()
  local cache = scriptCache()
  cache.backend.write = function()
    return false, "injected write failure"
  end
  local key = RegistrySnapshot.key(cache, overrideFs())
  Assert.isFalse(RegistrySnapshot.save(cache, overrideFs(), FP_A, key))
end

-- 14. The snapshot-restored fingerprint memo works on a sealed registry: the
-- fast path restores the digest as a read-only memo after buildRegistry
-- seals the registry.
T["restored fingerprint stays authoritative on a sealed registry"] = function()
  local cache = scriptCache()
  local fs = overrideFs()
  local key = RegistrySnapshot.key(cache, fs)
  cache:write(RegistrySnapshot.FILE, snapshotText(key, FP_A))
  local registry = ScriptLoader.buildRegistry(cache, fs, nil, { lazy = true })
  registry:restoreFingerprint(FP_A)
  Assert.equal(registry:fingerprint(), FP_A, "the restored memo is the digest")
  throwsCode("SCRIPT_REGISTRY_SEALED", function()
    registry:installBase("late.id", { id = "late.id" }, "generated")
  end)
end

return { tests = T }
