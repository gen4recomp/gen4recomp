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

local Cli = {}

-- Usage failure exit status; the same convention as the game CLI and the test
-- command, so scripts agree on "bad invocation".
Cli.EXIT_USAGE = 2

Cli.USAGE = "usage: love romdump/ [--import-rom <path>] [--forcedump <path>] [--build-cache [path]]"
  .. " [--check-dump] [--check-derived-cache]"
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

-- argv: the array LÖVE passes to love.load.
---@param argv string[]|nil
---@return { command: string|nil, romPath: string|nil, forceDump: boolean, allowCompileExclusions: boolean, dev: boolean, overlayId: integer|nil, outputPath: string|nil, resourceDetails: { fileId: integer, memberId: integer }[] }
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

  return opts
end

return Cli
