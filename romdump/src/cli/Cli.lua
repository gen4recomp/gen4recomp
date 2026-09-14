-- Pure command-line option parsing. Turns the LÖVE argv into a normalized
-- options table naming exactly one command (`opts.command`), or nil when no
-- command flag appears. Unknown options, stray arguments, missing option
-- values, and a second command flag are rejected with a raise that main.lua
-- turns into a usage message and exit status 2. `opts.dev` selects the
-- development cache identity (hash of the producer working-tree bytes) for
-- the build commands; without it the packaged CLI uses the release cache
-- identity (the explicit per-game counter, no source reads). It holds no
-- state and never touches love, so main.lua can dispatch and the parser can
-- be unit tested off-runtime.

local ArtifactState = require("romdump.src.build.ArtifactState")
local GameVersion = require("romdump.src.source.GameVersion")

local Cli = {}

-- Usage failure exit status; the same convention as the game CLI and the test
-- command, so scripts agree on "bad invocation".
Cli.EXIT_USAGE = 2

Cli.USAGE = "usage: love romdump/ [--import-rom <path>] [--forcedump <path>] [--build-cache [path]]"
  .. " [--check-dump] [--check-derived-cache] [--probe-rom <path>]"
  .. " [--prepare-cache --version <version> --require <request> [--require <request> ...] [--dev] [--profile <path>] [--rebuild <job> ...]]"
  .. " [--allow-compile-exclusions] [--dev]"
  .. " [--discover-app <overlay-id> --rom-source <path> [--output <path>]"
  .. " [--resource-detail <fileId>:<memberId>]...]"

-- Every command flag maps to the command it selects; --import-rom,
-- --build-cache, and --forcedump have their own loop branches because they
-- consume a ROM path. --forcedump is a modifier, not a command flag: alone it
-- implies "import", alongside --build-cache it forces a re-import.
local COMMAND_FLAGS = {
  ["--import-rom"] = "import",
  ["--build-cache"] = "build-cache",
  ["--check-dump"] = "check-dump",
  ["--check-derived-cache"] = "check-derived-cache",
  ["--discover-app"] = "discover-app",
  ["--probe-rom"] = "probe-rom",
  ["--prepare-cache"] = "prepare-cache",
}

-- Closed preparation scopes: the fixed milestones plus the exhaustive scope.
-- Anything else must be a canonical kind:key pair owned by ArtifactState.
local SCOPES = {
  bootstrap = true,
  ["field-core"] = true,
  complete = true,
}

-- The value-taking flags require the next token to be a path, not another
-- option.
local function takePath(argv, i, flag)
  local path = argv[i + 1]
  if not path or path:sub(1, 2) == "--" then
    error(flag .. " requires a ROM path\n" .. Cli.USAGE)
  end
  return path
end

-- Generic value-taking flag, for discovery flags whose value is not
-- necessarily a ROM path (e.g. an output path).
local function takeValue(argv, i, flag)
  local value = argv[i + 1]
  if not value or value:sub(1, 2) == "--" then
    error(flag .. " requires a value\n" .. Cli.USAGE)
  end
  return value
end

local function parseOverlayId(argv, i, flag)
  local raw = argv[i + 1]
  if not raw or raw:sub(1, 2) == "--" then
    error(flag .. " requires an overlay id\n" .. Cli.USAGE)
  end
  if not raw:match("^%d+$") then
    error(flag .. " requires a non-negative decimal overlay id, got '" .. raw .. "'\n" .. Cli.USAGE)
  end
  return tonumber(raw)
end

-- Strict closed requirement grammar: a fixed scope word or a canonical
-- kind:key pair validated through the kind/key owner. Signs, whitespace
-- padding, paths, plan files, and unknown kinds are rejected here so a
-- malformed request never reaches the cache.
---@param text string
---@param flag string cli flag naming the option under validation, used in diagnostics
local function checkRequirement(text, flag)
  if SCOPES[text] then
    return
  end
  local kind, key = text:match("^([^:]+):(.+)$")
  local valid = kind ~= nil and pcall(ArtifactState.path, kind, key)
  if not valid then
    error("invalid " .. flag .. " '" .. text .. "'\n" .. Cli.USAGE)
  end
end

-- A rebuild selector is always one canonical job, never a scope word.
---@param text string
local function checkRebuild(text)
  local kind, key = text:match("^([^:]+):(.+)$")
  local valid = kind ~= nil and pcall(ArtifactState.path, kind, key)
  if not valid then
    error("invalid --rebuild '" .. text .. "'\n" .. Cli.USAGE)
  end
end

-- argv: the array LÖVE passes to love.load.
---@param argv string[]|nil
---@return { command: string|nil, romPath: string|nil, forceDump: boolean, allowCompileExclusions: boolean, dev: boolean, overlayId: integer|nil, outputPath: string|nil, resourceDetails: { fileId: integer, memberId: integer }[], version: string|nil, requirements: string[], rebuild: string[], profile: string|nil }
function Cli.parse(argv)
  argv = argv or {}

  local opts = {
    command = nil,
    romPath = nil,
    forceDump = false,
    allowCompileExclusions = false,
    dev = false,
    overlayId = nil,
    outputPath = nil,
    resourceDetails = {},
    version = nil,
    requirements = {},
    rebuild = {},
    profile = nil,
  }
  local commandFlag = nil
  local sawRomSourceFlag = false
  local sawOutputFlag = false
  local seenResourceDetails = {}

  local function setCommand(flag)
    if commandFlag then
      error("conflicting commands: " .. commandFlag .. " and " .. flag .. "\n" .. Cli.USAGE)
    end
    commandFlag = flag
    opts.command = COMMAND_FLAGS[flag]
  end

  local function setPath(path)
    if opts.romPath then
      error("duplicate ROM path: " .. opts.romPath .. " and " .. path .. "\n" .. Cli.USAGE)
    end
    opts.romPath = path
  end

  local i = 1
  while i <= #argv do
    local token = argv[i]
    if token == "--import-rom" then
      setCommand(token)
      setPath(takePath(argv, i, token))
      i = i + 1
    elseif token == "--forcedump" then
      opts.forceDump = true
      setPath(takePath(argv, i, token))
      i = i + 1
    elseif token == "--build-cache" then
      setCommand(token)
      local path = argv[i + 1]
      if path and path:sub(1, 2) ~= "--" then
        setPath(path)
        i = i + 1
      end
    elseif token == "--probe-rom" then
      setCommand(token)
      setPath(takePath(argv, i, token))
      i = i + 1
    elseif token == "--prepare-cache" then
      setCommand(token)
    elseif token == "--version" then
      if opts.version then
        error("duplicate --version: " .. opts.version .. "\n" .. Cli.USAGE)
      end
      opts.version = takeValue(argv, i, token)
      i = i + 1
    elseif token == "--require" then
      opts.requirements[#opts.requirements + 1] = takeValue(argv, i, token)
      i = i + 1
    elseif token == "--rebuild" then
      opts.rebuild[#opts.rebuild + 1] = takeValue(argv, i, token)
      i = i + 1
    elseif token == "--profile" then
      if opts.profile then
        error("duplicate --profile: " .. opts.profile .. "\n" .. Cli.USAGE)
      end
      opts.profile = takeValue(argv, i, token)
      i = i + 1
    elseif token == "--allow-compile-exclusions" then
      opts.allowCompileExclusions = true
    elseif token == "--dev" then
      opts.dev = true
    elseif token == "--discover-app" then
      setCommand(token)
      opts.overlayId = parseOverlayId(argv, i, token)
      i = i + 1
    elseif token == "--rom-source" then
      setPath(takePath(argv, i, token))
      sawRomSourceFlag = true
      i = i + 1
    elseif token == "--output" then
      if opts.outputPath then
        error("duplicate --output value: " .. opts.outputPath .. "\n" .. Cli.USAGE)
      end
      opts.outputPath = takeValue(argv, i, token)
      sawOutputFlag = true
      i = i + 1
    elseif token == "--resource-detail" then
      local raw = takeValue(argv, i, token)
      local fileId, memberId = raw:match("^(%d+):(%d+)$")
      if not fileId then
        error(token .. " requires <fileId>:<memberId> with non-negative decimal integers\n" .. Cli.USAGE)
      end
      local parsedFileId, parsedMemberId = tonumber(fileId), tonumber(memberId)
      assert(parsedFileId and parsedMemberId, "resource detail ids must be numeric")
      local key = parsedFileId .. ":" .. parsedMemberId
      if seenResourceDetails[key] then
        error("duplicate --resource-detail " .. raw .. "\n" .. Cli.USAGE)
      end
      seenResourceDetails[key] = true
      opts.resourceDetails[#opts.resourceDetails + 1] = { fileId = parsedFileId, memberId = parsedMemberId }
      i = i + 1
    elseif COMMAND_FLAGS[token] then
      setCommand(token)
    elseif token:sub(1, 2) == "--" then
      error("unknown option '" .. token .. "'\n" .. Cli.USAGE)
    else
      error("unexpected argument '" .. token .. "'\n" .. Cli.USAGE)
    end
    i = i + 1
  end

  if opts.command == nil and opts.forceDump then
    opts.command = "import"
  end
  if opts.forceDump and opts.command ~= "import" and opts.command ~= "build-cache" then
    error("--forcedump only applies to --import-rom or --build-cache\n" .. Cli.USAGE)
  end

  if opts.command == "discover-app" then
    if not opts.romPath then
      error("--discover-app requires --rom-source <path>\n" .. Cli.USAGE)
    end
    if opts.allowCompileExclusions then
      error("--discover-app does not accept --allow-compile-exclusions\n" .. Cli.USAGE)
    end
    table.sort(opts.resourceDetails, function(a, b)
      return a.fileId < b.fileId or (a.fileId == b.fileId and a.memberId < b.memberId)
    end)
  elseif sawRomSourceFlag or sawOutputFlag or #opts.resourceDetails > 0 then
    error("--rom-source/--output/--resource-detail require --discover-app\n" .. Cli.USAGE)
  end

  if opts.command == "prepare-cache" then
    if opts.version == nil then
      error("--prepare-cache requires --version\n" .. Cli.USAGE)
    end
    if GameVersion.VERSIONS[opts.version] == nil then
      error("unsupported version '" .. opts.version .. "'\n" .. Cli.USAGE)
    end
    if #opts.requirements == 0 then
      error("--prepare-cache requires at least one --require\n" .. Cli.USAGE)
    end
    for _, requirement in ipairs(opts.requirements) do
      checkRequirement(requirement, "--require")
    end
    local allowsAnyJob = false
    for _, requirement in ipairs(opts.requirements) do
      if requirement == "complete" then
        allowsAnyJob = true
      end
    end
    for _, job in ipairs(opts.rebuild) do
      checkRebuild(job)
      if not opts.dev then
        error("--rebuild requires --dev\n" .. Cli.USAGE)
      end
      local included = allowsAnyJob
      if not included then
        for _, requirement in ipairs(opts.requirements) do
          if requirement == job then
            included = true
            break
          end
        end
      end
      if not included then
        error("--rebuild '" .. job .. "' is not in --require\n" .. Cli.USAGE)
      end
    end
  else
    if opts.version ~= nil then
      error("--version only applies to --prepare-cache\n" .. Cli.USAGE)
    end
    if #opts.requirements > 0 then
      error("--require only applies to --prepare-cache\n" .. Cli.USAGE)
    end
    if #opts.rebuild > 0 then
      error("--rebuild only applies to --prepare-cache\n" .. Cli.USAGE)
    end
    if opts.profile ~= nil and opts.command ~= "build-cache" then
      error("--profile only applies to --build-cache or --prepare-cache\n" .. Cli.USAGE)
    end
  end

  return opts
end

return Cli
