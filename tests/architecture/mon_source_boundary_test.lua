-- Architecture guard for the mon asset boundary: the generated mon class is
-- a registered derived-cache contract, the runtime cache module loads without
-- source knowledge, the producer inventory stays producer-side, and asset
-- sources never reach into producer or platform packages.

local Assert = require("tests.support.Assert")

local T = {}

local BASE = love.filesystem.getSourceBaseDirectory()

local function readFile(path)
  local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
  local content = handle:read("*a")
  handle:close()
  return content
end

local function assetSources()
  local command = "find '" .. BASE .. "/libs/assets/src' -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list libs/assets/src")
  local out = {}
  for line in pipe:lines() do
    out[#out + 1] = line:sub(#BASE + 2)
  end
  pipe:close()
  return out
end

-- The derived asset contract registers the mons generated class, so cache
-- readiness and fingerprinting cover it.
function T.derived_contract_registers_the_mons_generated_class()
  local Contract = require("libs.assets.src.DerivedAssetContract")
  Assert.notNil(Contract.mons, "contract must register the mons class")
  Assert.equal(type(Contract.mons.cacheFormat), "string")
  Assert.equal(type(Contract.mons.catalogSchema), "string")
  Assert.equal(type(Contract.mons.indexSchema), "string")
end

-- The runtime cache module loads and exposes canonical paths plus
-- source-independent validation entrypoints.
function T.mon_cache_module_loads_without_source_knowledge()
  local ok, MonCache = pcall(require, "libs.assets.src.MonCache")
  Assert.isTrue(ok, "MonCache must be loadable: " .. tostring(MonCache))
  local Cache = assert(MonCache)
  Assert.equal(type(Cache.dir()), "string")
  Assert.equal(type(Cache.indexPath()), "string")
  Assert.equal(type(Cache.catalogPath()), "string")
  Assert.equal(type(Cache.iconManifestPath()), "string")
  Assert.equal(type(Cache.portraitManifestPath()), "string")
  Assert.equal(type(Cache.markerPath()), "string")
end

-- The producer-side source inventory exists exactly once, under romdump, and
-- is never imported by runtime asset code.
function T.producer_source_inventory_stays_producer_side()
  local ok, _ = pcall(require, "romdump.src.config.MonSources")
  Assert.isTrue(ok, "MonSources must exist under romdump")
  local offenders = {}
  for _, file in ipairs(assetSources()) do
    local content = readFile(file)
    if content:find('require%s*%(%s*"romdump%.src%.config%.MonSources"', 1) ~= nil then
      offenders[#offenders + 1] = file
    end
    if content:find('require%s*%(%s*"libs%.nds', 1) ~= nil then
      offenders[#offenders + 1] = file
    end
  end
  Assert.equal(#offenders, 0, "asset sources must not import producer/platform modules")
end

return { tests = T }
