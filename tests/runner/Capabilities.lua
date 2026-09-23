-- Detects the capabilities a test run has available. Three are owned here:
--
--   graphics      a preflight really built and released a Shader, Canvas, Mesh,
--                 and Image against the host's graphics namespace
--   rom_dump      at least one GameVersion is ready through RomImporter.isReady
--   derived_cache the incremental cache builder ran successfully for that dump
--
-- A host with no graphics module simply lacks the capability, and the graphics
-- suites skip explicitly. A host that has the module but cannot produce a
-- resource is an infrastructure failure and raises: silently downgrading it to
-- "skip everything" is how graphics coverage disappears unnoticed.
--
-- Readiness of the derived cache is not re-derived from markers: preparation is
-- the shell entrypoint's step (`scripts/test.sh` runs `love romdump/
-- --build-cache` before the ROM-gated layers) and it reports the outcome through
-- PORTEMON_DERIVED_CACHE_READY. A ready raw dump alone therefore never claims a
-- current derived cache.

local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")

local Capabilities = {}

Capabilities.DERIVED_CACHE_ENV = "PORTEMON_DERIVED_CACHE_READY"

-- The smallest shader that still goes through the real GLSL compiler.
local PREFLIGHT_SHADER = [[
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  return color * Texel(tex, texCoord);
}
]]

-- Builds one of every resource class the graphics suites depend on and releases
-- them in reverse acquisition order, including on its own failure path: the
-- preflight must not be the thing that leaks GPU memory into the suite.
---@param graphics table love.graphics-shaped namespace
---@param image table|nil love.image-shaped namespace
local function preflight(graphics, image)
  if not (image and image.newImageData) then
    error("graphics preflight needs an image namespace to build an Image from", 0)
  end

  local acquired = {}
  local function acquire(constructor, ...)
    local object = constructor(...)
    acquired[#acquired + 1] = object
    return object
  end

  local ok, err = pcall(function()
    acquire(graphics.newShader, PREFLIGHT_SHADER)
    acquire(graphics.newCanvas, 1, 1)
    acquire(graphics.newMesh, { { 0, 0, 0, 0, 1, 1, 1, 1 } }, "triangles", "static")
    acquire(graphics.newImage, acquire(image.newImageData, 1, 1))
  end)

  for index = #acquired, 1, -1 do
    acquired[index]:release()
  end
  if not ok then
    error("graphics preflight failed: " .. tostring(err), 0)
  end
end

---@class CapabilityOptions
---@field env table<string, string>|nil
---@field isReady (fun(versionId: string): boolean)|nil
---@field versions string[]|nil
---@field graphics table|false|nil love.graphics-shaped namespace; false means absent
---@field image table|false|nil love.image-shaped namespace; false means absent

-- `options.env` is supplied by the caller (see `tests/run.lua`) so detection
-- never depends on the ambient environment; `isReady`/`versions` are injected by
-- this module's own tests.
---@param options CapabilityOptions|nil
---@return table<string, boolean> capabilities, string[] readyVersions
function Capabilities.detect(options)
  options = options or {}
  local env = options.env or {}
  local isReady = options.isReady or RomImporter.isReady
  local versions = options.versions or GameVersion.ORDER

  local ready = {}
  for _, versionId in ipairs(versions) do
    if isReady(versionId) then
      ready[#ready + 1] = versionId
    end
  end

  local graphics = options.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  local image = options.image
  if image == nil then
    image = love and love.image
  end

  local capabilities = {}
  if graphics then
    preflight(graphics, image or nil)
    capabilities.graphics = true
  end
  if #ready > 0 then
    capabilities.rom_dump = true
    if env[Capabilities.DERIVED_CACHE_ENV] == "1" then
      capabilities.derived_cache = true
    end
  end
  return capabilities, ready
end

return Capabilities
