-- ProducerFingerprint: the deterministic content fingerprint of the romdump
-- producer source tree. Proves the identity rules on an injected fake tree:
-- an identical tree fingerprints identically, any content edit / addition /
-- removal / rename changes the fingerprint, enumeration order never matters,
-- and an mtime-only change does not.

local Assert = require("tests.support.Assert")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")

local T = {}

-- The fake source tree models files as { contents, mtime }: mtime is present
-- in the fixture only to prove the fingerprint never consults it.
local function tree(extra)
  local base = {
    ["CacheBuilder.lua"] = { contents = "return {} -- pipeline", mtime = 100 },
    ["config/FieldActors.lua"] = { contents = "return { avatars = {} }", mtime = 100 },
    ["digest/MapAssetCompiler.lua"] = { contents = "return {} -- v1", mtime = 100 },
  }
  if extra then
    for path, entry in pairs(extra) do
      base[path] = entry
    end
  end
  return base
end

local function fingerprint(t, order)
  local backend = {
    list = function()
      local paths = {}
      for path in pairs(t) do
        paths[#paths + 1] = path
      end
      return order or paths
    end,
    read = function(path)
      return t[path].contents
    end,
    getInfo = function()
      return nil
    end,
  }
  return ProducerFingerprint.compute(backend)
end

function T.identical_file_trees_produce_identical_fingerprints()
  Assert.equal(fingerprint(tree()), fingerprint(tree()))
end

function T.editing_a_file_content_changes_the_fingerprint()
  local edited = tree({ ["CacheBuilder.lua"] = { contents = "return {} -- v2", mtime = 100 } })
  Assert.isTrue(fingerprint(tree()) ~= fingerprint(edited), "content edit must invalidate")
end

function T.adding_a_file_changes_the_fingerprint()
  local added = tree({ ["digest/NewCompiler.lua"] = { contents = "return {}", mtime = 100 } })
  Assert.isTrue(fingerprint(tree()) ~= fingerprint(added), "file addition must invalidate")
end

function T.removing_a_file_changes_the_fingerprint()
  local removed = {}
  for path, entry in pairs(tree()) do
    if path ~= "config/FieldActors.lua" then
      removed[path] = entry
    end
  end
  Assert.isTrue(fingerprint(tree()) ~= fingerprint(removed), "file removal must invalidate")
end

function T.renaming_a_file_changes_the_fingerprint()
  local renamed = tree()
  renamed["config/FieldActors.lua"] = nil
  renamed["config/FieldActorsNew.lua"] = { contents = "return { avatars = {} }", mtime = 100 }
  Assert.isTrue(fingerprint(tree()) ~= fingerprint(renamed), "a rename moves the hashed path")
end

function T.enumeration_order_does_not_affect_the_fingerprint()
  local forwards = { "CacheBuilder.lua", "config/FieldActors.lua", "digest/MapAssetCompiler.lua" }
  local backwards = { "digest/MapAssetCompiler.lua", "config/FieldActors.lua", "CacheBuilder.lua" }
  Assert.equal(fingerprint(tree(), backwards), fingerprint(tree(), forwards))
end

function T.mtime_only_changes_do_not_affect_the_fingerprint()
  local touched = tree()
  touched["CacheBuilder.lua"].mtime = 999
  Assert.equal(fingerprint(tree()), fingerprint(touched), "mtime must never enter the fingerprint")
end

function T.explicit_source_root_hashes_paths_relative_to_that_root()
  local backend = {
    list = function(root)
      Assert.equal(root, "romdump/src")
      return { "a.lua" }
    end,
    read = function(path, root)
      Assert.equal(root, "romdump/src")
      Assert.equal(path, "a.lua")
      return "return 1"
    end,
    getInfo = function()
      return nil
    end,
  }
  Assert.equal(ProducerFingerprint.compute(backend, "romdump/src"), ProducerFingerprint.compute(backend, "romdump/src"))
end

function T.source_root_rejects_absolute_and_traversal_paths()
  local backend = {
    list = function()
      return {}
    end,
    read = function()
      return ""
    end,
    getInfo = function()
      return nil
    end,
  }
  Assert.throws(function()
    ProducerFingerprint.compute(backend, "/romdump/src")
  end)
  Assert.throws(function()
    ProducerFingerprint.compute(backend, "romdump/../src")
  end)
end

return { tests = T }
