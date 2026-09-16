-- The romdump CLI parses strictly: unknown options, stray arguments, missing
-- option values, and more than one command are rejected; opts.command names
-- exactly one action and opts.romPath is the import payload. Runner.load
-- switches on the parsed command.

local Assert = require("tests.support.Assert")
local Cli = require("romdump.src.cli.Cli")

local T = {}

local COMMANDS = {
  { flag = "--import-rom", argv = { "--import-rom", "/tmp/hg.nds" }, command = "import" },
  { flag = "--build-cache", argv = { "--build-cache" }, command = "build-cache" },
  { flag = "--check-dump", argv = { "--check-dump" }, command = "check-dump" },
  { flag = "--check-derived-cache", argv = { "--check-derived-cache" }, command = "check-derived-cache" },
}

function T.defaults_are_all_off()
  local o = Cli.parse({})
  -- test/importRom are deleted fields; the casts make the absence probes
  -- deliberate reads of the removed surface.
  Assert.isFalse(o.test --[[@as any]])
  Assert.isNil(o.command)
  Assert.isNil(o.romPath)
  Assert.isNil(o.importRom --[[@as any]])
  Assert.isFalse(o.forceDump)
  Assert.isFalse(o.allowCompileExclusions)
  Assert.isFalse(o.dev)
end

-- Every command flag resolves to exactly one named command; the enum is the
-- dispatch contract Runner.load switches on.
function T.each_command_flag_maps_to_exactly_one_command()
  for _, entry in ipairs(COMMANDS) do
    local o = Cli.parse(entry.argv)
    Assert.equal(o.command, entry.command, entry.flag .. " must select " .. entry.command)
  end
end

function T.import_rom_maps_to_the_import_command()
  local o = Cli.parse({ "--import-rom", "/tmp/hg.nds" })
  Assert.equal(o.command, "import")
  Assert.equal(o.romPath, "/tmp/hg.nds")
  Assert.isNil(o.importRom --[[@as any]], "the multiplexed importRom field must be gone")
  Assert.isFalse(o.forceDump)
end

function T.forcedump_alone_maps_to_the_import_command()
  local o = Cli.parse({ "--forcedump", "/tmp/hg.nds" })
  Assert.equal(o.command, "import")
  Assert.equal(o.romPath, "/tmp/hg.nds")
  Assert.isTrue(o.forceDump)
end

function T.parses_build_cache_with_optional_rom()
  local withoutRom = Cli.parse({ "--build-cache" })
  Assert.equal(withoutRom.command, "build-cache")
  Assert.isNil(withoutRom.romPath)

  local withRom = Cli.parse({ "--build-cache", "/tmp/hg.nds" })
  Assert.equal(withRom.command, "build-cache")
  Assert.equal(withRom.romPath, "/tmp/hg.nds")

  local withFlags = Cli.parse({ "--build-cache", "/tmp/hg.nds", "--allow-compile-exclusions" })
  Assert.equal(withFlags.command, "build-cache")
  Assert.equal(withFlags.romPath, "/tmp/hg.nds")
  Assert.isTrue(withFlags.allowCompileExclusions)

  local flagOnly = Cli.parse({ "--build-cache", "--allow-compile-exclusions" })
  Assert.equal(flagOnly.command, "build-cache")
  Assert.isTrue(flagOnly.allowCompileExclusions)
  Assert.isNil(flagOnly.romPath, "a flag after --build-cache must not be taken as a path")
end

function T.parses_forcedump_with_required_rom()
  local o = Cli.parse({ "--build-cache", "--forcedump", "/tmp/hg.nds" })
  Assert.equal(o.command, "build-cache")
  Assert.isTrue(o.forceDump)
  Assert.equal(o.romPath, "/tmp/hg.nds")
end

function T.dev_flag_selects_the_development_identity_with_release_default()
  Assert.isFalse(Cli.parse({ "--build-cache" }).dev, "direct CLI mode defaults to release")
  local dev = Cli.parse({ "--build-cache", "--dev" })
  Assert.equal(dev.command, "build-cache")
  Assert.isTrue(dev.dev)
  local withRom = Cli.parse({ "--dev", "--build-cache", "/tmp/hg.nds" })
  Assert.isTrue(withRom.dev)
  Assert.equal(withRom.romPath, "/tmp/hg.nds")
end

function T.unknown_tokens_are_rejected()
  Assert.throws(function()
    Cli.parse({ "--fused", "--console" })
  end)
  Assert.throws(function()
    Cli.parse({ "--build-cache", "--fused" })
  end)
end

function T.dead_import_only_flag_is_rejected()
  Assert.throws(function()
    Cli.parse({ "--import-only" })
  end)
end

function T.removed_inspection_flags_are_rejected_as_unknown_options()
  for _, flag in ipairs({ "--" .. "inspect", "--" .. "inspect-sbc", "--" .. "inspect-actors" }) do
    local err = Assert.throws(function()
      Cli.parse({ flag })
    end)
    Assert.isTrue(string.find(err, "unknown option '" .. flag .. "'", 1, true) ~= nil, flag)
  end
end

function T.conflicting_commands_are_rejected()
  Assert.throws(function()
    Cli.parse({ "--check-dump", "--import-rom", "/tmp/hg.nds" })
  end)
  Assert.throws(function()
    Cli.parse({ "--check-dump", "--build-cache" })
  end)
  Assert.throws(function()
    Cli.parse({ "--import-rom", "/tmp/hg.nds", "--import-rom", "/tmp/ss.nds" })
  end)
end

function T.build_cache_rejects_a_second_positional_argument()
  Assert.throws(function()
    Cli.parse({ "--build-cache", "/tmp/hg.nds", "/tmp/ss.nds" })
  end)
end

function T.missing_value_for_import_rom_errors()
  Assert.throws(function()
    Cli.parse({ "--import-rom" })
  end)
end

function T.forcedump_requires_rom()
  Assert.throws(function()
    Cli.parse({ "--build-cache", "--forcedump" })
  end)
  Assert.throws(function()
    Cli.parse({ "--forcedump", "--build-cache" })
  end)
end

function T.forcedump_only_applies_to_import_or_build_cache()
  Assert.throws(function()
    Cli.parse({ "--check-dump", "--forcedump", "/tmp/hg.nds" })
  end)
  Assert.throws(function()
    Cli.parse({ "--forcedump", "/tmp/hg.nds", "--check-dump" })
  end)
end

function T.probe_rom_selects_a_probe_command_with_its_path()
  local o = Cli.parse({ "--probe-rom", "/tmp/hg.nds" })
  Assert.equal(o.command, "probe-rom")
  Assert.equal(o.romPath, "/tmp/hg.nds")
end

function T.probe_rom_requires_a_path()
  Assert.throws(function()
    Cli.parse({ "--probe-rom" })
  end)
end

function T.prepare_cache_requires_a_version_and_at_least_one_requirement()
  local o = Cli.parse({ "--prepare-cache", "--version", "heartgold", "--require", "bootstrap" })
  Assert.equal(o.command, "prepare-cache")
  Assert.equal(o.version, "heartgold")
  Assert.deepEqual(o.requirements, { "bootstrap" })
  Assert.throws(function()
    Cli.parse({ "--prepare-cache", "--require", "bootstrap" })
  end)
  Assert.throws(function()
    Cli.parse({ "--prepare-cache", "--version", "heartgold" })
  end)
end

function T.prepare_cache_accepts_repeated_requirements_and_observation_flags()
  local o = Cli.parse({
    "--prepare-cache",
    "--version",
    "heartgold",
    "--require",
    "bootstrap",
    "--require",
    "map:7",
    "--dev",
    "--profile",
    "/tmp/cache-profile.jsonl",
  })
  Assert.equal(o.command, "prepare-cache")
  Assert.deepEqual(o.requirements, { "bootstrap", "map:7" })
  Assert.isTrue(o.dev)
  Assert.equal(o.profile, "/tmp/cache-profile.jsonl")
  local rebuild = Cli.parse({
    "--prepare-cache",
    "--version",
    "heartgold",
    "--require",
    "map:7",
    "--rebuild",
    "map:7",
    "--dev",
  })
  Assert.deepEqual(rebuild.rebuild, { "map:7" })
end

function T.probe_and_prepare_conflict_with_other_commands()
  Assert.throws(function()
    Cli.parse({ "--build-cache", "--probe-rom", "/tmp/hg.nds" })
  end)
  Assert.throws(function()
    Cli.parse({ "--probe-rom", "/tmp/hg.nds", "--prepare-cache", "--version", "heartgold", "--require", "bootstrap" })
  end)
  Assert.throws(function()
    Cli.parse({ "--check-dump", "--prepare-cache", "--version", "heartgold", "--require", "bootstrap" })
  end)
end

function T.prepare_cache_rejects_malformed_requirements_and_paths()
  for _, argv in ipairs({
    { "--prepare-cache", "--version", "heartgold", "--require", "maps/7/complete" },
    { "--prepare-cache", "--version", "heartgold", "--require", "plan.lua" },
    { "--prepare-cache", "--version", "heartgold", "--require", "map: 7" },
    { "--prepare-cache", "--version", "heartgold", "--require", "fused:7" },
    { "--prepare-cache", "--version", "heartgold", "--require", "bootstrap", "--rebuild", "map:7" },
  }) do
    Assert.throws(function()
      Cli.parse(argv)
    end)
  end
end

function T.prepare_cache_accepts_an_invocation_receipt_output()
  local o = Cli.parse({
    "--prepare-cache",
    "--version",
    "heartgold",
    "--require",
    "map:7",
    "--dev",
    "--preparation-record",
    "/tmp/preparation.lua",
  })
  Assert.equal(o.command, "prepare-cache")
  Assert.equal(o.preparationRecord, "/tmp/preparation.lua")
  Assert.isNil(Cli.parse({ "--prepare-cache", "--version", "heartgold", "--require", "map:7" }).preparationRecord)
end

function T.preparation_record_is_rejected_outside_preparation()
  Assert.throws(function()
    Cli.parse({ "--build-cache", "--preparation-record", "/tmp/preparation.lua" })
  end)
  Assert.throws(function()
    Cli.parse({ "--preparation-record", "/tmp/preparation.lua" })
  end)
  Assert.throws(function()
    Cli.parse({ "--probe-rom", "/tmp/hg.nds", "--preparation-record", "/tmp/preparation.lua" })
  end)
  Assert.throws(function()
    Cli.parse({
      "--prepare-cache",
      "--version",
      "heartgold",
      "--require",
      "map:7",
      "--preparation-record",
      "/tmp/one.lua",
      "--preparation-record",
      "/tmp/two.lua",
    })
  end)
  Assert.throws(function()
    Cli.parse({ "--prepare-cache", "--version", "heartgold", "--require", "map:7", "--preparation-record" })
  end)
end

return { tests = T }
