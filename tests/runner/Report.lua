-- Pure formatting of a run result into report lines. Says what actually ran:
-- pass/fail/skip counts per layer, durations, the slowest tests, and the
-- capabilities the run had available. Never derives an exit status — the caller
-- owns that.

local Selection = require("tests.runner.Selection")

local Report = {}

local SLOWEST_WHEN_GREEN = 5

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function seconds(value)
  return string.format("%.2fs", value)
end

local function byDurationDescending(results)
  local sorted = {}
  for _, entry in ipairs(results) do
    sorted[#sorted + 1] = entry
  end
  table.sort(sorted, function(a, b)
    if a.duration == b.duration then
      return Selection.qualify(a.module, a.test) < Selection.qualify(b.module, b.test)
    end
    return a.duration > b.duration
  end)
  return sorted
end

local function withStatus(results, status)
  local out = {}
  for _, entry in ipairs(results) do
    if entry.status == status then
      out[#out + 1] = entry
    end
  end
  return out
end

-- Report lines for a completed run, in print order.
---@param run RunnerRun
---@return string[]
function Report.lines(run)
  local lines = {}
  local function add(line)
    lines[#lines + 1] = line
  end

  local failures = withStatus(run.results, "fail")
  local skips = withStatus(run.results, "skip")

  for _, entry in ipairs(failures) do
    add("FAIL " .. Selection.qualify(entry.module, entry.test) .. "\n    " .. tostring(entry.message))
  end
  for _, entry in ipairs(skips) do
    add("SKIP " .. Selection.qualify(entry.module, entry.test) .. " (" .. tostring(entry.message) .. ")")
  end

  if run.workerCriticalPath ~= nil then
    add(
      string.format(
        "%d passed, %d failed, %d skipped; worker critical path %s",
        run.passed,
        run.failed,
        run.skipped,
        seconds(run.workerCriticalPath)
      )
    )
  else
    add(
      string.format(
        "%d passed, %d failed, %d skipped in %s",
        run.passed,
        run.failed,
        run.skipped,
        seconds(run.duration)
      )
    )
  end

  for _, layer in ipairs(sortedKeys(run.byLayer)) do
    local counts = run.byLayer[layer]
    add(
      string.format(
        "  %-12s %d passed, %d failed, %d skipped (%s)",
        layer,
        counts.passed,
        counts.failed,
        counts.skipped,
        seconds(counts.duration)
      )
    )
  end

  local capabilities = sortedKeys(run.capabilities or {})
  add("  capabilities: " .. (#capabilities > 0 and table.concat(capabilities, ", ") or "none"))
  if run.versions ~= nil then
    add("  versions: " .. (#run.versions > 0 and table.concat(run.versions, ", ") or "none"))
  end

  if #failures > 0 then
    local slowestFailure = byDurationDescending(failures)[1]
    add(
      string.format(
        "  slowest failing: %s (%s)",
        Selection.qualify(slowestFailure.module, slowestFailure.test),
        seconds(slowestFailure.duration)
      )
    )
  else
    local slowest = byDurationDescending(withStatus(run.results, "pass"))
    for index = 1, math.min(SLOWEST_WHEN_GREEN, #slowest) do
      local entry = slowest[index]
      add(
        string.format(
          "  slowest %d: %s (%s)",
          index,
          Selection.qualify(entry.module, entry.test),
          seconds(entry.duration)
        )
      )
    end
  end

  local timings = run.suiteTimings
  if timings ~= nil and #timings > 0 then
    local sorted = {}
    for _, entry in ipairs(timings) do
      sorted[#sorted + 1] = entry
    end
    table.sort(sorted, function(a, b)
      if a.total == b.total then
        return a.module < b.module
      end
      return a.total > b.total
    end)
    for index = 1, math.min(SLOWEST_WHEN_GREEN, #sorted) do
      local entry = sorted[index]
      add(string.format("  slowest suite %d: %s (%s)", index, entry.module, seconds(entry.total)))
    end
  end

  return lines
end

-- Report lines for `--list`: one line per discovered suite with the metadata a
-- reader needs to pick a layer or filter, plus the load error of any suite that
-- could not be read.
---@param listing { module: string, layer: string, capabilities: string[], tags: string[], slow: boolean|nil, tests: string[], error: string|nil }[]
---@return string[]
function Report.listingLines(listing)
  local lines = {}
  local tests = 0
  for _, suite in ipairs(listing) do
    tests = tests + #suite.tests
    local parts = { suite.layer, #suite.tests .. " tests" }
    if #suite.capabilities > 0 then
      parts[#parts + 1] = "needs " .. table.concat(suite.capabilities, "+")
    end
    if #suite.tags > 0 then
      parts[#parts + 1] = "tags " .. table.concat(suite.tags, ",")
    end
    if suite.slow == true then
      parts[#parts + 1] = "slow"
    end
    lines[#lines + 1] = string.format("%-56s %s", suite.module, table.concat(parts, "  "))
    if suite.error ~= nil then
      lines[#lines + 1] = "    LOAD ERROR " .. tostring(suite.error)
    end
  end
  lines[#lines + 1] = string.format("%d suites, %d tests", #listing, tests)
  return lines
end

return Report
