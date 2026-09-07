-- Starter-choice producer dependency coverage through the production
-- compiler. Every read source must be stamped into the dependency record and
-- the completion marker must be the hash of that record, so a changed source
-- member invalidates the family. Requires a ready user-owned dump
-- (rom_dump capability); skips otherwise.

local Assert = require("tests.support.Assert")
local Hashing = require("romdump.src.digest.Hashing")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.StarterChoiceAssetCompiler")
  if not ok then
    error("the ROM-derived starter-choice compiler is missing: " .. tostring(module), 0)
  end
  return module
end

local function cache()
  local ok, module = pcall(require, "libs.assets.src.StarterChoiceAssetCache")
  if not ok then
    error("the starter-choice cache contract is missing: " .. tostring(module), 0)
  end
  return module
end

function T.source_hashes_cover_both_chooser_archives_and_the_message_bank(romFs)
  local bundle = assert(compiler().compile(romFs))
  local dependencies = assert(bundle.dependencies, "compilation returns source dependencies")
  local stamped = assert(dependencies.dependencies, "dependencies list source hashes")
  Assert.isTrue(#stamped > 0, "every read source is stamped into dependencies")
  local archives = {}
  for _, entry in ipairs(stamped) do
    Assert.isTrue(type(entry.sha1) == "string" and #entry.sha1 == 40, "each source entry carries a sha1")
    archives[entry.archive] = true
  end
  Assert.isTrue(
    archives["NARC_application_choose_starter_choose_starter_main_res"] == true,
    "the main chooser archive is stamped"
  )
  Assert.isTrue(
    archives["NARC_application_choose_starter_choose_starter_sub_res"] == true,
    "the sub chooser archive is stamped"
  )
  Assert.isTrue(archives["messages"] == true, "the message archive is stamped")
end

function T.marker_is_the_hash_of_the_dependency_record(romFs)
  local bundle = assert(compiler().compile(romFs))
  local expected = cache().marker(romFs:metadata().sha1, Hashing.hashLua(bundle.dependencies))
  Assert.equal(bundle.marker, expected, "the marker covers the full dependency record")
  local altered = {}
  for key, value in pairs(bundle.dependencies) do
    altered[key] = value
  end
  altered.dependencies = {}
  for index, entry in ipairs(bundle.dependencies.dependencies) do
    local copy = {}
    for key, value in pairs(entry) do
      copy[key] = value
    end
    if index == 1 then
      copy.sha1 = string.rep("0", 40)
    end
    altered.dependencies[index] = copy
  end
  local rotated = cache().marker(romFs:metadata().sha1, Hashing.hashLua(altered))
  Assert.isTrue(rotated ~= bundle.marker, "a changed source hash invalidates the marker")
end

return RomSuite.fromFacts(T)
