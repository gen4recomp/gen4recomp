-- Read-only proof over the prepared complete corpus: every concrete
-- derived job carries final dependency membership, every edge resolves to
-- another concrete job, and the whole graph is acyclic. A cycle or a
-- dangling edge is a corpus defect caught here, never a runtime state.
-- Nothing is compiled or published here; the command tests own publication
-- and failure evidence.

local CacheFs = require("libs.storage.src.CacheFs")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")

local T = {}

function T.complete_derived_dependency_graph_is_closed_and_acyclic(romFs, versionId)
  local sha1 = assert(romFs:metadata().sha1, "the published dump carries the validated ROM hash")
  local sourceBase = love.filesystem.getSourceBaseDirectory()
  local identity = DerivedCacheState.currentForSelection({
    versionId = versionId,
    romSha1 = sha1,
    producerId = ProducerFingerprint.compute(ProducerFingerprint.checkoutBackend(sourceBase)),
    developmentRepositoryRoot = sourceBase,
  })
  local cacheFs = CacheFs.forVersion(versionId)
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local plans, plansReason = ArtifactJobs.publishedPlans(cacheFs, identity)
  assert(plans ~= nil, "the prepared corpus publishes its inventory: " .. tostring(plansReason))
  local completeJobs = ArtifactJobs.completeJobs(plans)
  assert(#completeJobs > 0, "the exhaustive inventory covers the real corpus")
  local nodes = {}
  for _, job in ipairs(completeJobs) do
    nodes[job.jobKey] = job
  end
  local color = {}
  local stack = {}
  local function visit(nodeKey)
    if color[nodeKey] == "black" then
      return
    end
    if color[nodeKey] == "gray" then
      local loop = {}
      for _, link in ipairs(stack) do
        loop[#loop + 1] = link
      end
      loop[#loop + 1] = nodeKey
      error("the derived dependency graph holds a cycle: " .. table.concat(loop, " -> "), 0)
    end
    local job = assert(nodes[nodeKey], "the traversal visits only concrete jobs: " .. tostring(nodeKey))
    color[nodeKey] = "gray"
    stack[#stack + 1] = nodeKey
    local ok, deps, complete = pcall(ArtifactJobs.dependencies, job.kind, job.key, plans)
    if not ok then
      error("dependency planning fails for concrete job " .. nodeKey .. ": " .. tostring(deps), 0)
    end
    assert(complete == true, "concrete job " .. nodeKey .. " carries final dependency membership")
    for _, dep in ipairs(deps) do
      local depKey = dep.kind .. ":" .. dep.key
      assert(nodes[depKey] ~= nil, "concrete job " .. nodeKey .. " depends on an absent job " .. depKey)
      visit(depKey)
    end
    stack[#stack] = nil
    color[nodeKey] = "black"
  end
  local ordered = {}
  for nodeKey in pairs(nodes) do
    ordered[#ordered + 1] = nodeKey
  end
  table.sort(ordered)
  for _, nodeKey in ipairs(ordered) do
    visit(nodeKey)
  end
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.slow = true
suite.metadata.capabilities = { "rom_dump", "complete_derived_cache" }
suite.metadata.derivedAssets = { "complete" }
suite.metadata.tags = { "cache", "corpus", "dependencies" }
return suite
