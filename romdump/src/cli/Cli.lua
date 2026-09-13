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

-- Every command flag maps to the command it selects; --import-rom,
-- --build-cache, and --forcedump have their own loop branches because they
-- consume a ROM path. --forcedump is a modifier, not a command flag: alone it
-- implies "import", alongside --build-cache it forces a re-import.
local COMMAND_FLAGS = {
  ["--import-rom"] = "import",
  ["--build-cache"] = "build-cache",
  ["--check-dump"] = "check-dump",
  ["--check-derived-cache"] = "check-derived-cache",
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

-- argv: the array LÖVE passes to love.load.
---@param argv string[]|nil
---@return { command: string|nil, romPath: string|nil, forceDump: boolean, allowCompileExclusions: boolean, dev: boolean }
function Cli.parse(argv)
  argv = argv or {}

  local opts = { command = nil, romPath = nil, forceDump = false, allowCompileExclusions = false, dev = false }
  local commandFlag = nil

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

  return opts
end

return Cli
