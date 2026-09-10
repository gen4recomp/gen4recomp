-- Pure command surface of the single test entrypoint: argument parsing, the
-- capabilities a selection makes mandatory, the combined exit status, the
-- loud missing-ROM warning, and the strict graphics execution guarantee. It
-- holds no state and touches neither love nor the filesystem beyond the
-- injected readability probe, so the whole policy is unit testable.
--
-- Exit codes: 2 usage, 1 failures, an unavailable required capability, or a
-- strict selection that executed no graphics test, 0 green. A missing
-- *optional* capability warns and stays green; a run that executed nothing at
-- all never does.

local Cli = {}

Cli.EXIT_USAGE = 2

Cli.LAYERS = { "unit", "component", "graphics", "rom", "acceptance" }

-- Layers whose data comes from a user-owned dump: selecting one makes the
-- selected ROM capabilities mandatory instead of optional, and cache
-- preparation follows the selected suites' declared capabilities.
local ROM_GATED = { rom = true, acceptance = true }

local ROM_CAPABILITIES = { "rom_dump", "derived_cache" }

local STRICT_ENV = "G4RECOMP_REQUIRE_ROM_TESTS"
local GRAPHICS_STRICT_ENV = "G4RECOMP_REQUIRE_GRAPHICS_TESTS"

local BUILD_COMMAND = "scripts/buildcache.sh /path/to/rom.nds"
local STRICT_COMMAND = STRICT_ENV .. "=1 scripts/test.sh"

Cli.USAGE = table.concat({
  "usage: scripts/test.sh [--plan] [--list] [--layer <" .. table.concat(Cli.LAYERS, "|") .. ">]",
  "                      [--filter <substring>] [--tag <tag>] [--slow] [--rom-source <path-to-nds-or-zip>]",
}, "\n")

local function isLayer(value)
  for _, layer in ipairs(Cli.LAYERS) do
    if layer == value then
      return true
    end
  end
  return false
end

local function realFileExists(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return false
  end
  handle:close()
  return true
end

-- The value of an option, or nil when it is missing or is itself an option.
local function value(argv, index)
  local argument = argv[index]
  if argument == nil or argument:sub(1, 2) == "--" then
    return nil
  end
  return argument
end

---@class TestPlan
---@field planMode boolean
---@field list boolean
---@field layer string|nil
---@field filter string|nil
---@field tag string|nil
---@field slow boolean
---@field romSource string|nil
---@field strict boolean
---@field graphicsStrict boolean
---@field requiredCapabilities string[]

-- Parses the LÖVE argv. `--test` is accepted and ignored so the raw argv can be
-- forwarded unchanged. The environment is supplied by the caller rather than
-- read here, so a parse never depends on the ambient environment of the process
-- that happens to be running the suite.
---@param argv string[]
---@param context { env: table<string, string>|nil, fileExists: fun(path: string): boolean|nil }|nil
---@return TestPlan|nil plan, string|nil message
function Cli.parse(argv, context)
  context = context or {}
  local env = context.env or {}
  local fileExists = context.fileExists or realFileExists

  local plan = {
    planMode = false,
    list = false,
    slow = false,
    strict = env[STRICT_ENV] == "1",
    graphicsStrict = env[GRAPHICS_STRICT_ENV] == "1",
    requiredCapabilities = {},
  }

  local index = 1
  while index <= #(argv or {}) do
    local option = argv[index]
    if option == "--test" then
      index = index + 1
    elseif option == "--plan" then
      plan.planMode = true
      index = index + 1
    elseif option == "--list" then
      plan.list = true
      index = index + 1
    elseif option == "--layer" then
      local layer = value(argv, index + 1)
      if layer == nil then
        return nil, "--layer needs a layer name (" .. table.concat(Cli.LAYERS, ", ") .. ")"
      end
      if not isLayer(layer) then
        return nil, "unknown layer '" .. layer .. "' (expected " .. table.concat(Cli.LAYERS, ", ") .. ")"
      end
      plan.layer = layer
      index = index + 2
    elseif option == "--filter" then
      local filter = value(argv, index + 1)
      if filter == nil or filter == "" then
        return nil, "--filter needs a non-empty substring"
      end
      plan.filter = filter
      index = index + 2
    elseif option == "--tag" then
      local tag = value(argv, index + 1)
      if tag == nil or tag == "" then
        return nil, "--tag needs a non-empty tag"
      end
      plan.tag = tag
      index = index + 2
    elseif option == "--slow" then
      plan.slow = true
      index = index + 1
    elseif option == "--rom-source" then
      local path = value(argv, index + 1)
      if path == nil then
        return nil, "--rom-source needs a path to a .nds or .zip file"
      end
      if not fileExists(path) then
        return nil, "--rom-source is not readable: " .. path
      end
      plan.romSource = path
      index = index + 2
    elseif option:sub(1, 2) == "--" then
      return nil, "unknown option '" .. option .. "'\n" .. Cli.USAGE
    else
      return nil, "unexpected argument '" .. option .. "'\n" .. Cli.USAGE
    end
  end

  -- ROM capability requirements are not fixed here: they follow the suites
  -- actually selected, so `outcome` intersects the selected capability union
  -- with the ROM capabilities whenever the selection requires ROM evidence
  -- (an explicit ROM-gated layer or strict mode). Graphics strictness and an
  -- explicit source are selection-independent and stay on the plan.
  if plan.graphicsStrict and (plan.layer == nil or plan.layer == "graphics") then
    plan.requiredCapabilities[#plan.requiredCapabilities + 1] = "graphics"
  end
  if plan.romSource ~= nil then
    plan.requiredCapabilities[#plan.requiredCapabilities + 1] = "rom_source"
  end

  return plan
end

-- The machine-readable `key=value` response the shell entrypoint consumes in
-- place of its own option scanning: whether the derived cache must be
-- prepared before the run (a listing executes nothing, and a selection needs
-- it exactly when at least one selected test belongs to a suite declaring
-- `derived_cache`; a supplied source is always imported, whatever the
-- selection) and the source path to import.
---@param plan TestPlan
---@param selectedCapabilities table<string, boolean>|nil union of declared capabilities of suites with selected tests
---@return string[]
function Cli.renderPlan(plan, selectedCapabilities)
  local selected = selectedCapabilities or {}
  local prepare = not plan.list and (plan.romSource ~= nil or selected.derived_cache == true)
  local lines = { "prepare=" .. (prepare and "1" or "0") }
  if plan.romSource ~= nil then
    lines[#lines + 1] = "rom_source=" .. plan.romSource
  end
  return lines
end

local function missingCapabilities(plan, capabilities)
  local missing = {}
  for _, name in ipairs(plan.requiredCapabilities) do
    if capabilities[name] ~= true then
      missing[#missing + 1] = name
    end
  end
  return missing
end

local function skippedIn(run, layer)
  local counts = run.byLayer[layer]
  return counts ~= nil and counts.skipped or 0
end

local RULE = string.rep("=", 80)

-- A human-readable name for the selection a run was asked to execute, used by
-- the empty-run and empty-graphics-run failures.
local function selectionLabel(plan)
  local parts = {}
  if plan.layer ~= nil then
    parts[#parts + 1] = "layer '" .. plan.layer .. "'"
  end
  if plan.tag ~= nil then
    parts[#parts + 1] = "tag '" .. plan.tag .. "'"
  end
  if plan.filter ~= nil then
    parts[#parts + 1] = "filter '" .. plan.filter .. "'"
  end
  if #parts > 0 then
    return table.concat(parts, ", ")
  end
  return "the current selection"
end

local function warningBanner(run)
  return table.concat({
    RULE,
    "WARNING: ROM-GATED TESTS WERE NOT RUN",
    "No ready HeartGold/SoulSilver dump was found.",
    string.format(
      "Skipped: %d ROM-conformance tests and %d acceptance tests.",
      skippedIn(run, "rom"),
      skippedIn(run, "acceptance")
    ),
    "Prepare one with: " .. BUILD_COMMAND,
    "Require these tests with: " .. STRICT_COMMAND,
    RULE,
  }, "\n")
end

-- The ROM capabilities a selection makes mandatory. An explicit ROM-gated
-- layer or strict mode requires ROM evidence, but only for the ROM
-- capabilities the selection actually uses: a raw-dump-only focus must not
-- fail for an unselected derived cache.
---@param plan TestPlan
---@param run RunnerRun
---@return string[]
local function selectedRomRequirements(plan, run)
  if not (plan.strict or ROM_GATED[plan.layer or ""]) then
    return {}
  end
  local selected = run.selectedCapabilities or {}
  local required = {}
  for _, name in ipairs(ROM_CAPABILITIES) do
    if selected[name] == true then
      required[#required + 1] = name
    end
  end
  return required
end

---@class TestOutcome
---@field exitCode integer
---@field failure string|nil
---@field warning string|nil

-- The combined result of a finished run: one exit status, an actionable failure
-- message when the run could not do what was asked, and the loud warning when a
-- ROM-gated layer was skipped because the capability was merely optional.
---@param plan TestPlan
---@param capabilities table<string, boolean>
---@param run RunnerRun
---@return TestOutcome
function Cli.outcome(plan, capabilities, run)
  local missing = missingCapabilities(plan, capabilities)
  for _, name in ipairs(selectedRomRequirements(plan, run)) do
    if capabilities[name] ~= true then
      missing[#missing + 1] = name
    end
  end
  if #missing > 0 then
    return {
      exitCode = 1,
      failure = table.concat({
        "required capability unavailable: " .. table.concat(missing, ", "),
        "Prepare a dump with: " .. BUILD_COMMAND,
      }, "\n"),
    }
  end

  -- Strict graphics mode requires the graphics layer to actually have run, not
  -- merely be available: a selection that reaches no graphics suite (suites
  -- dropped, discovery broken) or runs only skips is a regression that must
  -- fail. A filter is an explicit narrowing and disables the counter; the
  -- generic empty-run failure below still guards a filter that matched
  -- nothing at all. Partial-layer selections never reach the counter.
  if plan.graphicsStrict and (plan.layer == nil or plan.layer == "graphics") and plan.filter == nil then
    local graphics = run.byLayer.graphics
    if graphics == nil or graphics.passed + graphics.failed == 0 then
      return {
        exitCode = 1,
        failure = "no graphics test was executed: " .. selectionLabel(plan) .. " matched nothing",
      }
    end
  end

  -- Only when a ROM-gated layer actually skipped for the absent dump: a
  -- selection that never reached those layers has nothing to warn about, and a
  -- skip under a ready dump has some other cause than the one named here.
  local warning = nil
  if capabilities.rom_dump ~= true and skippedIn(run, "rom") + skippedIn(run, "acceptance") > 0 then
    warning = warningBanner(run)
  end

  if run.failed > 0 then
    return { exitCode = 1, warning = warning }
  end

  -- A focus that only matches excluded slow tests names the gate instead of
  -- claiming nothing matched: the tests exist and run under `--slow`.
  if #run.results == 0 and (run.excludedSlow or 0) > 0 then
    return {
      exitCode = 1,
      failure = "no test was executed: "
        .. selectionLabel(plan)
        .. " matched only slow tests; run again with --slow to include them",
      warning = warning,
    }
  end

  if run.passed == 0 then
    return {
      exitCode = 1,
      failure = "no test was executed: " .. selectionLabel(plan) .. " matched nothing",
      warning = warning,
    }
  end

  return { exitCode = 0, warning = warning }
end

return Cli
