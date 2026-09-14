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
  Assert.isNil(o.overlayId)
  Assert.isNil(o.outputPath)
  Assert.deepEqual(o.resourceDetails, {})
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
  Assert.isNil(o.overlayId, "legacy commands must not gain a discovery overlay id")
  Assert.isNil(o.outputPath, "legacy commands must not gain a discovery output path")
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

--------------------------------------------------------------------------
-- --discover-app: strict parsing, argument order, conflicts, and backward
-- compatibility with every existing command/modifier.
--------------------------------------------------------------------------

function T.discover_app_parses_overlay_id_and_rom_source_in_either_order()
  local o = Cli.parse({ "--discover-app", "15", "--rom-source", "/tmp/hg.nds" })
  Assert.equal(o.command, "discover-app")
  Assert.equal(o.overlayId, 15)
  Assert.equal(o.romPath, "/tmp/hg.nds")
  Assert.isNil(o.outputPath)
  Assert.isFalse(o.forceDump)
  Assert.isFalse(o.allowCompileExclusions)

  local reordered = Cli.parse({ "--rom-source", "/tmp/hg.nds", "--discover-app", "15" })
  Assert.equal(reordered.command, "discover-app")
  Assert.equal(reordered.overlayId, 15)
  Assert.equal(reordered.romPath, "/tmp/hg.nds")
end

function T.discover_app_parses_an_optional_output_path_in_any_position()
  local trailing = Cli.parse({ "--discover-app", "15", "--rom-source", "/tmp/hg.nds", "--output", "/tmp/out.zip" })
  Assert.equal(trailing.command, "discover-app")
  Assert.equal(trailing.outputPath, "/tmp/out.zip")

  local leading = Cli.parse({ "--output", "/tmp/out.zip", "--rom-source", "/tmp/hg.nds", "--discover-app", "15" })
  Assert.equal(leading.command, "discover-app")
  Assert.equal(leading.overlayId, 15)
  Assert.equal(leading.romPath, "/tmp/hg.nds")
  Assert.equal(leading.outputPath, "/tmp/out.zip")
end

function T.discover_app_accepts_overlay_id_zero()
  local o = Cli.parse({ "--discover-app", "0", "--rom-source", "/tmp/hg.nds" })
  Assert.equal(o.overlayId, 0)
end

function T.discover_app_requires_an_overlay_id_value()
  Assert.throws(function()
    Cli.parse({ "--discover-app" })
  end)
  Assert.throws(function()
    Cli.parse({ "--discover-app", "--rom-source", "/tmp/hg.nds" })
  end)
end

function T.discover_app_rejects_negative_or_nondecimal_overlay_ids()
  for _, bad in ipairs({ "-1", "1.5", "0x0F", "abc", "15,", " 15" }) do
    Assert.throws(function()
      Cli.parse({ "--discover-app", bad, "--rom-source", "/tmp/hg.nds" })
    end, "overlay id " .. bad .. " must be rejected")
  end
end

function T.discover_app_requires_rom_source()
  Assert.throws(function()
    Cli.parse({ "--discover-app", "15" })
  end)
end

function T.discover_app_rejects_missing_rom_source_value()
  Assert.throws(function()
    Cli.parse({ "--discover-app", "15", "--rom-source" })
  end)
end

function T.discover_app_rejects_missing_output_value()
  Assert.throws(function()
    Cli.parse({ "--discover-app", "15", "--rom-source", "/tmp/hg.nds", "--output" })
  end)
end

function T.discover_app_rejects_duplicate_rom_source()
  Assert.throws(function()
    Cli.parse({ "--discover-app", "15", "--rom-source", "/tmp/hg.nds", "--rom-source", "/tmp/ss.nds" })
  end)
end

function T.discover_app_rejects_duplicate_output()
  Assert.throws(function()
    Cli.parse({
      "--discover-app",
      "15",
      "--rom-source",
      "/tmp/hg.nds",
      "--output",
      "/tmp/a.zip",
      "--output",
      "/tmp/b.zip",
    })
  end)
end

function T.discover_app_rejects_duplicate_discover_app_flag()
  Assert.throws(function()
    Cli.parse({ "--discover-app", "15", "--discover-app", "16", "--rom-source", "/tmp/hg.nds" })
  end)
end

function T.discover_app_parses_repeatable_resource_details_in_sorted_order()
  local o = Cli.parse({
    "--resource-detail",
    "144:49",
    "--output",
    "/tmp/out.zip",
    "--resource-detail",
    "12:3",
    "--rom-source",
    "/tmp/hg.nds",
    "--discover-app",
    "15",
  })

  Assert.equal(o.command, "discover-app")
  Assert.equal(o.overlayId, 15)
  Assert.equal(o.romPath, "/tmp/hg.nds")
  Assert.equal(o.outputPath, "/tmp/out.zip")
  Assert.deepEqual(o.resourceDetails, {
    { fileId = 12, memberId = 3 },
    { fileId = 144, memberId = 49 },
  })
end

function T.resource_detail_rejects_ambiguous_ids_duplicates_and_sibling_commands()
  local base = { "--discover-app", "15", "--rom-source", "/tmp/hg.nds" }
  for _, value in ipairs({ "144", ":49", "144:", "144:49:1", "-1:49", "0x90:49", " 144:49" }) do
    local argv = { base[1], base[2], base[3], base[4], "--resource-detail", value }
    Assert.throws(function()
      Cli.parse(argv)
    end, "invalid resource detail " .. value .. " must be rejected")
  end

  Assert.throws(function()
    Cli.parse({
      "--discover-app",
      "15",
      "--rom-source",
      "/tmp/hg.nds",
      "--resource-detail",
      "144:49",
      "--resource-detail",
      "144:49",
    })
  end, "duplicate resource details must be rejected")

  local zero = Cli.parse({
    "--resource-detail",
    "0:0",
    "--discover-app",
    "15",
    "--rom-source",
    "/tmp/hg.nds",
  })
  Assert.deepEqual(zero.resourceDetails, { { fileId = 0, memberId = 0 } })

  for _, command in ipairs({
    { "--check-dump" },
    { "--build-cache" },
    { "--import-rom", "/tmp/hg.nds" },
  }) do
    local argv = {}
    for _, token in ipairs(command) do
      argv[#argv + 1] = token
    end
    argv[#argv + 1] = "--resource-detail"
    argv[#argv + 1] = "0:0"
    Assert.throws(function()
      Cli.parse(argv)
    end, "resource detail must remain scoped to discover-app")
  end
end

function T.discover_app_rejects_forcedump_and_allow_compile_exclusions()
  Assert.throws(function()
    Cli.parse({ "--discover-app", "15", "--rom-source", "/tmp/hg.nds", "--forcedump", "/tmp/hg.nds" })
  end)
  Assert.throws(function()
    Cli.parse({ "--discover-app", "15", "--rom-source", "/tmp/hg.nds", "--allow-compile-exclusions" })
  end)
end

function T.discover_app_conflicts_with_every_existing_command()
  for _, entry in ipairs(COMMANDS) do
    Assert.throws(function()
      local argv = { "--discover-app", "15", "--rom-source", "/tmp/hg.nds" }
      for _, tok in ipairs(entry.argv) do
        argv[#argv + 1] = tok
      end
      Cli.parse(argv)
    end, entry.flag .. " must conflict with --discover-app")
  end
end

function T.discovery_only_flags_are_usage_errors_without_discover_app()
  Assert.throws(function()
    Cli.parse({ "--rom-source", "/tmp/hg.nds" })
  end)
  Assert.throws(function()
    Cli.parse({ "--output", "/tmp/out.zip" })
  end)
  Assert.throws(function()
    Cli.parse({ "--import-rom", "/tmp/hg.nds", "--rom-source", "/tmp/hg.nds" })
  end)
  Assert.throws(function()
    Cli.parse({ "--build-cache", "--output", "/tmp/out.zip" })
  end)
  Assert.throws(function()
    Cli.parse({ "--check-dump", "--rom-source", "/tmp/hg.nds" })
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

return { tests = T }
