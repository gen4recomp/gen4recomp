-- ScriptLoader tests (the script override system): generated bases load from
-- the compiled script cache, checked-in overrides under
-- `data/scripts/overrides/<id>.lua` override the script with the same id (or
-- introduce it when no base exists), the override layer beats the generated
-- base, and malformed override files fail loudly instead of silently keeping
-- the base.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local ScriptSave = require("libs.script.src.ScriptSave")
local Sha256 = require("libs.script.src.Sha256")

local T = {}
local GENERATION = string.rep("a", 40)
local MARKER = "script-cache-v4:rom-sha:dep-sha"

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  local errorObject = err --[[@as Errors.Error]]
  Assert.equal(errorObject.code, code)
end

-- A fake cache carrying a two-resource script class (the index schema and
-- script file shapes match the compiled cache writer).
local function scriptCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local resources = {
    { id = "vanilla.hgss.scr_seq.0842.script_001", member = 0, scriptIndex = 0 },
    { id = "new_bark.lab_sign", member = 0, scriptIndex = 1 },
  }
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = {
      resources[1],
      resources[2],
    },
  })
  cache:write(
    ScriptCache.scriptPath(GENERATION, 0, resources[1].id),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "vanilla.hgss.scr_seq.0842.script_001", steps = { S.stop() } }\n'
  )
  cache:write(
    ScriptCache.scriptPath(GENERATION, 0, resources[2].id),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.say { message = "msg.hgss.0543.00097" }, S.stop() } }\n'
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

local function requireShim(name)
  if name == "gen4.script" then
    return require("gen4.script")
  end
  error("unexpected require in override chunk: " .. name)
end

-- 1. Generated bases install from the cache index and files.
T["generated bases load from the script cache"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.notNil(registry:base("vanilla.hgss.scr_seq.0842.script_001"))
  Assert.isNil(registry:base("vanilla.hgss.scr_seq.0842.script_002"))
end

-- 2. An override file replaces the script with the same id, and beats the
-- generated base.
T["override replaces the base script with the same id"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  local fs = overrideFs({
    ["new_bark.lab_sign.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n',
  })
  local ids = ScriptLoader.installOverrides(registry, fs, requireShim)
  Assert.deepEqual(ids, { "new_bark.lab_sign" })
  local base = assert(registry:base("new_bark.lab_sign"))
  Assert.equal(base.steps[1].op, "noop", "the override wins over the generated base")
end

-- 2b. The override manifest is evaluated in the same restricted environment
-- as resource chunks: a manifest relying on a global must fail loudly
-- instead of loading through the ordinary global environment.
T["override manifest runs in the restricted environment"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.stop() } }\n',
  }, 'return { string.lower("ELMS_LAB.ELM") }\n')
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.installOverrides(registry, fs, requireShim)
  end)
end

-- 3. An override may introduce an id with no generated base (the curated
-- Elm replacement pattern).
T["override introduces an id without a base"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.stop() } }\n',
  })
  ScriptLoader.installOverrides(registry, fs, requireShim)
  Assert.notNil(registry:base("elms_lab.elm"))
end

-- 4. An override whose file id disagrees with the resource id fails loudly.
T["override id mismatch is a hard error"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "other.id", steps = { S.stop() } }\n',
  })
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.installOverrides(registry, fs, requireShim)
  end)
end

-- 5. An override that fails validation fails loudly.
T["invalid override fails loudly"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.setVar {  } } }\n',
  })
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    ScriptLoader.installOverrides(registry, fs, requireShim)
  end)
end

-- 6. buildRegistry composes the full pipeline and the effective composition
-- resolves the override.
T["buildRegistry composes the override"] = function()
  local Composition = require("libs.script.src.Composition")
  local registry = ScriptLoader.buildRegistry(
    scriptCache(),
    overrideFs({
      ["new_bark.lab_sign.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n',
    }),
    requireShim
  ) --[[@as Registry]]
  local composition = Composition.new(registry)
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(effective.entries[1].operation, "base")
  Assert.equal(effective.entries[1].graph.nodes[effective.entries[1].graph.entry].op, "noop")
end

-- 7. buildRegistry passes the injected require through to the generated
-- cache files too: a require the allowlist would reject is observable.
T["buildRegistry injects require for generated files"] = function()
  local calls = {}
  local injected = function(name)
    calls[#calls + 1] = name
    return requireShim(name)
  end
  local registry = ScriptLoader.buildRegistry(scriptCache(), overrideFs({}), injected)
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.isTrue(#calls > 0, "the injected require ran for the generated files")
end

-- A cache whose generated script fails validation (the shape the compiled
-- cache writer can never emit, but a hand-tampered file could).
local function invalidScriptCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = { { id = "invalid.script", member = 0, scriptIndex = 0 } },
  })
  cache:write(
    ScriptCache.scriptPath(GENERATION, 0, "invalid.script"),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "invalid.script", steps = { S.setVar { } } }\n'
  )
  return cache
end

-- 8. A lazy build decodes nothing until first use: no script file is read
-- at build time, and base() reads exactly its own file.
T["lazy build reads no script files until first use"] = function()
  local cache = scriptCache()
  local originalRead = cache.backend.read
  local scriptReads = 0
  cache.backend.read = function(self, path)
    if path:find("/scripts/", 1, true) then
      scriptReads = scriptReads + 1
    end
    return originalRead(self, path)
  end
  local registry = ScriptLoader.buildRegistry(cache, overrideFs({}), requireShim, { lazy = true })
  Assert.equal(scriptReads, 0, "a lazy build must not read any script file")
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.equal(scriptReads, 1, "base() reads exactly its own file")
end

-- 8b. The lazy per-use validation policy: by default a generated script is
-- validated on first use, so invalid content fails at the access point.
T["lazy build validates generated content on first use"] = function()
  local registry = ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim, { lazy = true })
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    registry:base("invalid.script")
  end)
end

-- 8c. validateGenerated=false skips validation on the lazy path (a keyed
-- snapshot already proved the corpus unchanged since the cache build
-- validated it); the identity check still applies.
T["lazy build without validation accepts invalid generated content"] = function()
  local registry = ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim, {
    lazy = true,
    validateGenerated = false,
  })
  Assert.notNil(registry:base("invalid.script"))
end

-- 8d. The eager path still validates generated content by default.
T["eager build validates generated content by default"] = function()
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim)
  end)
end

-- 8e. The lazy path never skips the checked-in override layer: overrides are
-- fully validated eagerly on every boot.
T["lazy build does not skip override validation"] = function()
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    ScriptLoader.buildRegistry(
      scriptCache(),
      overrideFs({
        ["bad.override.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "bad.override", steps = { S.setVar { } } }\n',
      }),
      requireShim,
      { lazy = true }
    )
  end)
end

-- 9. An index without the resources array is malformed generated data, never
-- an empty registry: installGenerated fails before installing anything.
T["index without resources fails before any install"] = function()
  local Registry = require("libs.script.src.Registry")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), { schema = ScriptCache.INDEX_SCHEMA })
  local registry = Registry.new()
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.installGenerated(registry, cache, requireShim)
  end)
  Assert.deepEqual(registry:ids(), {}, "no bases are installed from a malformed index")
end

-- 9b. The lazy build path applies the same strict index rule.
T["lazy build rejects an index without resources"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), { schema = ScriptCache.INDEX_SCHEMA })
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.buildRegistry(cache, overrideFs({}), requireShim, { lazy = true })
  end)
end

-- A generated cache whose index entries carry the published canonical hash
-- of each decoded resource: the hash is exactly what the registry
-- fingerprint would compute by decoding the body itself.
local HASHED_FILES = {
  ["vanilla.hgss.scr_seq.0842.script_001"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "vanilla.hgss.scr_seq.0842.script_001", steps = { S.stop() } }\n',
  ["new_bark.lab_sign"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.say { message = "msg.hgss.0543.00097" }, S.stop() } }\n',
}

local HASHED_OVERRIDE =
  'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n'

local function builtinScripts()
  local S = require("gen4.script")
  return {
    all = function()
      return {
        ["test.builtin.ping"] = S.script({ api = 1, id = "test.builtin.ping", steps = { S.stop() } }),
      }
    end,
  }
end

-- `order` optionally reorders the index entries to prove the registry
-- identity does not depend on index enumeration order.
local function hashedCache(order)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ids = {}
  for id in pairs(HASHED_FILES) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    cache:write(ScriptCache.scriptPath(GENERATION, 0, id), HASHED_FILES[id])
  end
  local entries = {}
  for index, id in ipairs(ids) do
    local resource = assert(ScriptLoader.loadGeneratedFrom(cache, GENERATION, 0, id, requireShim, { validate = false }))
    entries[#entries + 1] = {
      id = id,
      member = 0,
      scriptIndex = index - 1,
      resourceHash = Sha256.hex(LuaWriter.encode(resource)),
    }
  end
  if order == "reversed" then
    local reversed = {}
    for index = #entries, 1, -1 do
      reversed[#reversed + 1] = entries[index]
    end
    entries = reversed
  end
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = entries,
  })
  return cache
end

local function hashedOverrideFs()
  return overrideFs({ ["new_bark.lab_sign.lua"] = HASHED_OVERRIDE })
end

-- Count generated body reads through the cache backend from here on.
local function countScriptReads(cache)
  local reads = 0
  local originalRead = cache.backend.read
  cache.backend.read = function(self, path)
    if path:find("/scripts/", 1, true) then
      reads = reads + 1
    end
    return originalRead(self, path)
  end
  return function()
    return reads
  end
end

-- The decoded oracle: an eager registry that loads and hashes every body.
local function decodedOracleFingerprint(order)
  local registry = ScriptLoader.buildRegistry(hashedCache(order), hashedOverrideFs(), requireShim, {
    builtins = builtinScripts(),
  })
  return registry:fingerprint()
end

-- 10. A registry built from published index hashes carries the exact
-- decoded identity without decoding any generated body.
T["published index hashes identify the registry without decoding generated bodies"] = function()
  local oracle = decodedOracleFingerprint()
  local cache = hashedCache()
  local scriptReads = countScriptReads(cache)
  local registry = ScriptLoader.buildRegistry(cache, hashedOverrideFs(), requireShim, {
    lazy = true,
    builtins = builtinScripts(),
  })
  Assert.equal(scriptReads(), 0, "building from published hashes must not read generated bodies")
  Assert.equal(registry:fingerprint(), oracle)
  Assert.equal(scriptReads(), 0, "fingerprint acquisition must not decode generated bodies")
end

-- 10b. The published-hash identity is stable under index enumeration order.
T["published index hashes identify the registry regardless of index order"] = function()
  local oracle = decodedOracleFingerprint()
  local cache = hashedCache("reversed")
  local scriptReads = countScriptReads(cache)
  local registry = ScriptLoader.buildRegistry(cache, hashedOverrideFs(), requireShim, {
    lazy = true,
    builtins = builtinScripts(),
  })
  Assert.equal(registry:fingerprint(), oracle)
  Assert.equal(scriptReads(), 0, "fingerprint acquisition must not decode generated bodies")
end

-- 10c. A save captured under the decoded registry validates unchanged under
-- the published hashes, and content drift still mismatches.
T["a save captured under decoded content validates under published hashes"] = function()
  local oracle = decodedOracleFingerprint()
  local cache = hashedCache()
  local registry = ScriptLoader.buildRegistry(cache, hashedOverrideFs(), requireShim, {
    lazy = true,
    builtins = builtinScripts(),
  })
  local seeded = registry:fingerprint()
  Assert.equal(seeded, oracle)
  local bucket = {
    schema = ScriptSave.SCHEMA_NAME,
    registryFingerprint = oracle,
    taskFingerprint = "test-tasks",
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
  }
  Assert.isNil(ScriptSave.validate(bucket, { expectedRegistryFingerprint = seeded }))
  local mismatch = assert(
    ScriptSave.validate(bucket, { expectedRegistryFingerprint = seeded .. "00" }),
    "drifted content must mismatch the saved fingerprint"
  )
  Assert.isTrue(Errors.is(mismatch))
  Assert.equal(mismatch.code, "SCRIPT_REGISTRY_FINGERPRINT_MISMATCH")
end

-- 9c. An explicitly empty resources array is schema-legal and installs
-- nothing: an empty script corpus must not fail the load.
T["empty resources array installs zero bases"] = function()
  local Registry = require("libs.script.src.Registry")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = {},
  })
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, cache, requireShim)
  Assert.deepEqual(registry:ids(), {})
end

return { tests = T }
