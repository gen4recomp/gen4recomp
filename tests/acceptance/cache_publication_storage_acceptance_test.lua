-- Production-composed cache publication smoke: the real LÖVE filesystem writes,
-- renames, removes, and recovers one isolated cache namespace without rendering.

local Assert = require("tests.support.Assert")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local CacheFs = require("libs.storage.src.CacheFs")

local VERSION = "storage-publication-acceptance"
local ARTIFACT = "publication"
local ROOT = "data/generated/publication"
local STAGE_ROOT = "staging/" .. VERSION .. "/" .. ARTIFACT

local T = {
  metadata = {
    slow = true,
    tags = { "storage", "publication" },
  },
  tests = {},
}

local function removeTree(path)
  local fs = love.filesystem
  local info = fs.getInfo(path)
  if info == nil then
    return
  end
  if info.type == "directory" then
    for _, item in ipairs(fs.getDirectoryItems(path)) do
      removeTree(path .. "/" .. item)
    end
  end
  Assert.isTrue(fs.remove(path), "cleanup must remove " .. path)
end

local function cleanupNamespace()
  removeTree(VERSION)
  removeTree(VERSION .. ".__g4next")
  removeTree(VERSION .. ".__g4old")
  removeTree(VERSION .. ".__g4publish.lua")
  removeTree(VERSION .. ".__g4published")
  removeTree("staging/" .. VERSION)
end

local function namespaceResidue()
  local fs = love.filesystem
  local residue = {}
  for _, name in ipairs(fs.getDirectoryItems("")) do
    if
      name == VERSION .. ".__g4next"
      or name == VERSION .. ".__g4old"
      or name == VERSION .. ".__g4publish.lua"
      or name == VERSION .. ".__g4published"
      or (
        name:sub(1, #(VERSION .. ".__g4publish.")) == VERSION .. ".__g4publish."
        and name:sub(-#".__g4next") == ".__g4next"
      )
    then
      residue[#residue + 1] = name
    end
  end
  local generatedRoot = VERSION .. "/data/generated"
  if fs.getInfo(generatedRoot) ~= nil then
    for _, name in ipairs(fs.getDirectoryItems(generatedRoot)) do
      if
        name:sub(1, #(ARTIFACT .. ".__g4next.")) == ARTIFACT .. ".__g4next."
        or name:sub(1, #(ARTIFACT .. ".__g4old.")) == ARTIFACT .. ".__g4old."
      then
        residue[#residue + 1] = generatedRoot .. "/" .. name
      end
    end
  end
  if fs.getInfo(STAGE_ROOT) ~= nil then
    residue[#residue + 1] = STAGE_ROOT
  end
  return residue
end

function T.tests.real_filesystem_publication_cleans_its_recovery_material()
  local cache = CacheFs.forVersion(VERSION)
  local ok, err = xpcall(function()
    cache:recoverPublication()
    cleanupNamespace()

    cache:write(ROOT .. "/value", "old")
    local tx = ArtifactPublisher.begin(cache, ARTIFACT, { ROOT })
    tx.stage:write(ROOT .. "/value", "new")
    Assert.isTrue(tx:publish(), "publication must succeed")
    Assert.equal(cache:read(ROOT .. "/value"), "new")
    Assert.isTrue(cache:recoverPublication(), "recovery after commit must be idempotent")
    Assert.equal(#namespaceResidue(), 0, "publication must leave no namespace residue")
  end, debug.traceback)
  local cleanupOk, cleanupErr = pcall(cleanupNamespace)
  if not cleanupOk then
    error("namespace cleanup failed: " .. tostring(cleanupErr), 0)
  end
  if not ok then
    error(err, 0)
  end
end

return T
