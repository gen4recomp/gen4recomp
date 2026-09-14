-- Producer ownership contracts for the cache stages and digest helpers.

local Assert = require("tests.support.Assert")

local T = {}

function T.new_domain_builders_are_concrete_modules()
  local modules = {
    "romdump.src.digest.model.DynamicModelCompiler",
    "romdump.src.digest.map.BuildingModelCompiler",
    "romdump.src.digest.newgame.IntroRasterizer",
  }
  for _, name in ipairs(modules) do
    local module = require(name)
    Assert.notNil(module, name .. " must load")
    Assert.isTrue(
      type(module.build or module.compile or module.render or module.renderChar) == "function",
      name .. " needs a focused seam"
    )
  end
  -- The common generation session owns all batch orchestration: one session,
  -- one closed handler table, one process-owned pool.
  local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
  Assert.isTrue(type(InteractiveCacheBuild.new) == "function", "the generation session needs its constructor")
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  Assert.isTrue(type(ArtifactJobs.execute) == "function", "the handler table needs its worker entrypoint")
  local CompilerPool = require("romdump.src.build.CompilerPool")
  Assert.isTrue(type(CompilerPool.new) == "function", "the compiler pool needs its constructor")
end

return { tests = T }
