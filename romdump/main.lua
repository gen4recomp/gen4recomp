-- ROM dump CLI entry point. This app is its own LÖVE root (`love romdump/`);
-- the repo root (the source base directory) is added to package.path first so
-- `require` resolves libs by their full repo-relative path (romdump.src.*,
-- libs.assets.*) independent of the working directory. Cli parses the argv into
-- an options table naming exactly one command; Runner executes the selected
-- headless command and exits with a status code (pumped across frames for the
-- async ROM import). Cli.parse owns strictness: unknown options, stray
-- arguments, missing option values, and conflicting commands are rejected with
-- a message on stderr and exit status 2.
local ROOT = love.filesystem.getSourceBaseDirectory()
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

local Cli = require("romdump.src.cli.Cli")
local Runner = require("romdump.src.cli.Runner")

function love.load(argv)
  local ok, parsed = pcall(Cli.parse, argv)
  if not ok then
    -- A raise from love.load would hang headless on the error screen; reject
    -- with the usage status instead. "romdump: " mirrors the test command's
    -- "test: " prefix.
    io.stderr:write("romdump: " .. tostring(parsed) .. "\n")
    love.event.quit(Cli.EXIT_USAGE)
    return
  end
  Runner.load(parsed)
end

function love.update()
  Runner.update()
end
