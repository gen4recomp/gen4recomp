-- Capability detection for a test run. A ready raw dump is only
-- `rom_dump`; the derived cache is a separate capability the shell entrypoint
-- establishes by running the incremental builder before the suite, so an
-- unprepared dump can never claim `derived_cache`. The graphics namespaces are
-- declared absent here so these stay pure ROM-capability cases; the graphics
-- preflight has its own suite.

local Assert = require("tests.support.Assert")
local Capabilities = require("tests.runner.Capabilities")

local T = {}

local function detect(ready, env)
  return Capabilities.detect({
    versions = { "heartgold", "soulsilver" },
    isReady = function(versionId)
      return ready[versionId] == true
    end,
    env = env or {},
    graphics = false,
    image = false,
  })
end

-- The same detection with an injected invocation record: the selected source
-- the run is proving and the preparation receipt the shell verified for it.
-- A receipt names the generation it prepared, the selected version and ROM
-- hash, the requested closure, whether that closure is ready, and whether an
-- exhaustive audit additionally proved the whole corpus.
local ROM_SHA = string.rep("a", 40)
local GENERATION = "g4:heartgold:" .. ROM_SHA .. ":r1:a1:s1"
local SOURCE = { versionId = "heartgold", romSha1 = ROM_SHA, generationId = GENERATION }

---@param overrides table? receipt fields to replace
---@return table preparation receipt
local function preparation(overrides)
  local receipt = {
    generationId = GENERATION,
    versionId = "heartgold",
    romSha1 = ROM_SHA,
    requested = { "map:7" },
    requestedReady = true,
    complete = false,
  }
  for key, value in pairs(overrides or {}) do
    receipt[key] = value
  end
  return receipt
end

local function detectWithReceipt(ready, env, receipt, source)
  return Capabilities.detect({
    versions = { "heartgold", "soulsilver" },
    isReady = function(versionId)
      return ready[versionId] == true
    end,
    env = env or {},
    graphics = false,
    image = false,
    source = source or SOURCE,
    preparation = receipt,
  })
end

-- A host that offers Shader/Canvas/Mesh but no way to build an Image cannot
-- support the graphics suites, and pretending otherwise would let the atlas
-- smoke tests fail deep inside a renderer instead of at detection.
function T.a_graphics_host_without_image_tooling_fails_the_preflight()
  local err = Assert.throws(function()
    Capabilities.detect({
      versions = {},
      env = {},
      graphics = { newShader = function() end },
      image = false,
    })
  end)

  Assert.isTrue(tostring(err):find("image", 1, true) ~= nil, "the failure must name the missing image namespace")
end

function T.no_ready_dump_offers_no_rom_capabilities()
  local capabilities, versions = detect({}, { [Capabilities.DERIVED_CACHE_ENV] = "1" })

  Assert.isNil(capabilities.rom_dump)
  Assert.isNil(capabilities.derived_cache)
  Assert.deepEqual(versions, {})
end

function T.a_ready_dump_without_preparation_is_not_a_derived_cache()
  local capabilities, versions = detect({ heartgold = true })

  Assert.isTrue(capabilities.rom_dump)
  Assert.isNil(capabilities.derived_cache, "an unprepared cache must not claim derived_cache")
  Assert.deepEqual(versions, { "heartgold" })
end

function T.a_prepared_ready_dump_offers_both_capabilities_and_names_versions()
  local capabilities, versions = detect(
    { heartgold = true, soulsilver = true },
    { [Capabilities.DERIVED_CACHE_ENV] = "1" }
  )

  Assert.isTrue(capabilities.rom_dump)
  Assert.isTrue(capabilities.derived_cache)
  Assert.deepEqual(versions, { "heartgold", "soulsilver" }, "versions follow the declared order")
end

-- The old single environment flag is not invocation proof: without a
-- verified preparation receipt it grants neither the partial nor the
-- complete scoped capability, even beside a ready dump.
function T.an_inherited_ready_flag_alone_grants_no_scoped_capability()
  local capabilities, _ = detect({ heartgold = true }, { [Capabilities.DERIVED_CACHE_ENV] = "1" })

  Assert.isTrue(capabilities.rom_dump, "the ready dump still offers its raw capability")
  Assert.isNil(capabilities.derived_assets, "a bare flag must not prove a partial closure")
  Assert.isNil(capabilities.complete_derived_cache, "a bare flag must not prove a complete corpus")
end

-- A verified receipt for exactly the selected generation and closure grants
-- the partial capability while the complete corpus stays unproven.
function T.a_verified_partial_preparation_grants_only_the_partial_capability()
  local capabilities, _ = detectWithReceipt({ heartgold = true }, {}, preparation())

  Assert.isTrue(capabilities.rom_dump, "the ready dump still offers its raw capability")
  Assert.isTrue(capabilities.derived_assets, "a verified receipt proves the requested closure")
  Assert.isNil(capabilities.complete_derived_cache, "a partial receipt must not prove the complete corpus")
end

-- An exhaustive audit for the selected generation grants both: the complete
-- corpus implies every partial closure it contains.
function T.a_verified_complete_preparation_grants_both_capabilities()
  local capabilities, _ = detectWithReceipt({ heartgold = true }, {}, preparation({ complete = true }))

  Assert.isTrue(capabilities.derived_assets, "a complete corpus contains every partial closure")
  Assert.isTrue(capabilities.complete_derived_cache, "an exhaustive receipt proves the complete corpus")
end

-- A failed preparation and a receipt for another generation prove nothing: a
-- real preparation failure must never downgrade into an optional skip, and a
-- stale receipt must never authorize the current selection.
function T.a_failed_or_generation_mismatched_preparation_grants_neither_capability()
  local failed, _ = detectWithReceipt({ heartgold = true }, {}, preparation({ requestedReady = false }))

  Assert.isNil(failed.derived_assets, "a failed preparation proves no partial closure")
  Assert.isNil(failed.complete_derived_cache, "a failed preparation proves no complete corpus")

  local staleSource = { versionId = "heartgold", romSha1 = ROM_SHA, generationId = GENERATION .. ":next" }
  local stale, _ = detectWithReceipt({ heartgold = true }, {}, preparation(), staleSource)

  Assert.isNil(stale.derived_assets, "a receipt for another generation proves no partial closure")
  Assert.isNil(stale.complete_derived_cache, "a receipt for another generation proves no complete corpus")
  Assert.isTrue(stale.rom_dump, "the ready dump still offers its raw capability")
end

return { tests = T }
