-- Renders the reusable two-row choice prompt through the generated button
-- artwork: both rows draw every active frame at the controller status
-- rectangles, the selected row through its selected visual while the
-- controller reports it highlighted and through its normal visual otherwise.
-- The runtime-validated manifest is injected
-- explicitly; this renderer never reloads it from the cache. Construction is
-- failure-safe: a missing section or asset is a loud error, a later
-- image/quad failure releases every image acquired so far before rethrowing,
-- and release() is idempotent with draw-after-release a no-op.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class YesNoPromptRenderer
---@field _graphics love.graphics
---@field _images love.Image[] every acquired image, released exactly once
---@field _imageByAsset table<string, love.Image> acquired images by manifest asset id
---@field _quads table<string, love.Quad> quads by asset id plus rect
---@field _visuals table<string, { asset: string, rect: { x: integer, y: integer, width: integer, height: integer } }>
local YesNoPromptRenderer = {}
YesNoPromptRenderer.__index = YesNoPromptRenderer

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (prompt button PNGs); opts.manifest: the already-validated
-- generated field-UI manifest the runtime loaded once;
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData).

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, graphics?: unknown }
---@return YesNoPromptRenderer
function YesNoPromptRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "YesNoPromptRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "YesNoPromptRenderer requires love.graphics")
  ---@cast graphics love.graphics
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "YesNoPromptRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the four compact button visuals. The runtime boot already
  -- validated the full manifest; the renderer resolves what it draws.
  local prompt = assert(manifest.yesNoPrompt, "the field-UI manifest must carry the two-row prompt section")
  assert(type(prompt) == "table", "the two-row prompt section must be a table")
  local shapes = assert(prompt.shapes, "the two-row prompt section must carry its shape map")
  local compact = assert(shapes.compact, "the field-UI manifest must carry the compact prompt shape")
  local visuals = {}
  for _, row in ipairs({ "yes", "no" }) do
    local states = assert(compact[row], "the compact prompt shape must carry the " .. row .. " row")
    for _, state in ipairs({ "normal", "selected" }) do
      local visual = assert(states[state], "the compact prompt " .. row .. " row must carry its " .. state .. " visual")
      assert(type(visual.asset) == "string", "a prompt visual must name its atlas")
      assert(type(visual.rect) == "table", "a prompt visual must carry its atlas rect")
      visuals[row .. "." .. state] = visual
    end
  end

  local self = setmetatable({
    _graphics = graphics,
    _images = {},
    _imageByAsset = {},
    _quads = {},
    _visuals = visuals,
  }, YesNoPromptRenderer)

  local ok, err = pcall(function()
    self:_acquire(cacheFs, manifest)
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- Acquires the button images and builds every visual quad. Images are owned
-- once per manifest asset id while quads are cached per asset plus rect, so
-- several button states may share one atlas image. Any failure releases
-- everything acquired so far before the constructor rethrows.
---@param cacheFs CacheFs
---@param manifest table<string, unknown>
function YesNoPromptRenderer:_acquire(cacheFs, manifest)
  local graphics = assert(self._graphics)
  local function acquire(assetId)
    local known = self._imageByAsset[assetId]
    if known ~= nil then
      return known
    end
    local entry = assert(manifest.assets[assetId], "the field-UI manifest must carry the prompt button asset")
    local path = assert(entry.image, "a prompt button asset must name an image path")
    local data = cacheFs:read(path)
    if not data then
      Errors.raise(
        FieldErrors.FIELD_UI_YES_NO_PROMPT_MISSING,
        "the prompt button art is missing at " .. path,
        { path = path }
      )
    end
    data = assert(data)
    local image = graphics.newImage(love.filesystem.newFileData(data, path))
    image:setFilter("nearest", "nearest")
    self._images[#self._images + 1] = image
    self._imageByAsset[assetId] = image
    return image
  end
  local function quadFor(assetId, rect)
    local key = assetId .. "\0" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "," .. rect.height
    local quad = self._quads[key]
    if quad == nil then
      local image = acquire(assetId)
      quad = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, image:getWidth(), image:getHeight())
      self._quads[key] = quad
    end
    return quad
  end
  for _, key in ipairs({ "yes.normal", "yes.selected", "no.normal", "no.selected" }) do
    local visual = assert(self._visuals[key], "the compact prompt must carry the " .. key .. " visual")
    quadFor(assert(visual.asset), assert(visual.rect))
  end
end

---@param assetId string
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@return love.Quad
function YesNoPromptRenderer:_quadFor(assetId, rect)
  local key = assetId .. "\0" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "," .. rect.height
  return assert(self._quads[key], "a prompt button visual must have a built quad")
end

-- Draws the active prompt: the YES row then the NO row at the status button
-- rectangles. While the selection is highlighted the selected row draws
-- through its selected visual; otherwise both rows draw through their
-- normal visuals. A nil, inactive, or post-release status draws nothing.
---@param status { active: boolean, selected: string?, selectionHighlighted: boolean?, buttons: { yes: { x: integer, y: integer, width: integer, height: integer }, no: { x: integer, y: integer, width: integer, height: integer } }? }?
function YesNoPromptRenderer:draw(status)
  if type(status) ~= "table" or status.active ~= true then
    return
  end
  if #self._images == 0 then
    return
  end
  local selected = assert(status.selected, "an active prompt has a selection")
  assert(selected == "yes" or selected == "no", "an active prompt has a selection")
  assert(type(status.selectionHighlighted) == "boolean", "an active prompt carries its selection highlight phase")
  local buttons = assert(status.buttons, "an active prompt carries its button rows")
  assert(type(buttons) == "table", "an active prompt carries its button rows")
  local yesRow = assert(buttons.yes, "an active prompt carries the YES row")
  local noRow = assert(buttons.no, "an active prompt carries the NO row")
  local highlighted = status.selectionHighlighted
  local yesVisual = assert(self._visuals[selected == "yes" and highlighted and "yes.selected" or "yes.normal"])
  local noVisual = assert(self._visuals[selected == "no" and highlighted and "no.selected" or "no.normal"])
  local graphics = assert(self._graphics)
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(
    assert(self._imageByAsset[assert(yesVisual.asset)]),
    self:_quadFor(assert(yesVisual.asset), assert(yesVisual.rect)),
    yesRow.x,
    yesRow.y
  )
  graphics.draw(
    assert(self._imageByAsset[assert(noVisual.asset)]),
    self:_quadFor(assert(noVisual.asset), assert(noVisual.rect)),
    noRow.x,
    noRow.y
  )
end

function YesNoPromptRenderer:release()
  for _, image in ipairs(self._images) do
    if image.release then
      image:release()
    end
  end
  self._images = {}
  self._imageByAsset = {}
  self._quads = {}
end

return YesNoPromptRenderer
