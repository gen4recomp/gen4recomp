-- CPU-only entry point for the presentation preparation worker. Reads
-- confined cache bytes, decodes/packs mesh upload buffers or decodes image
-- data, and replies with flat records carrying love Data/ImageData. Never
-- touches love.graphics: GPU realization stays on the main thread.
--
-- The request/reply channels arrive as the thread start arguments (love
-- shares one worker state per queue, and the queue starts it with its own
-- channel pair). The worker state does not inherit the main state's
-- package.path, so the repo root is installed here first.

local requestChannel, replyChannel = ...
assert(requestChannel and replyChannel, "preparation worker requires its request/reply channels")

local ROOT = love.filesystem.getSourceBaseDirectory()
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

pcall(require, "love.image")

local Errors = require("libs.errors.src.Errors")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")

local function fail(token, kind, path, cause)
  local text = Errors.is(cause) and Errors.format(cause) or tostring(cause)
  replyChannel:push({ token = token, ok = false, kind = kind, path = path, error = text })
end

local function prepareMesh(token, path)
  local bytes, readError = love.filesystem.read(path)
  if bytes == nil then
    fail(token, "mesh", path, "unreadable cache file: " .. tostring(readError))
    return
  end
  local ok, prepared = pcall(SceneMesh.prepareUpload, bytes, path)
  if not ok then
    fail(token, "mesh", path, prepared)
    return
  end
  replyChannel:push({
    token = token,
    ok = true,
    kind = "mesh",
    path = path,
    vertexData = prepared.vertexData,
    indexData = prepared.indexData,
    vertexCount = prepared.vertexCount,
    indexCount = prepared.indexCount,
    indexType = prepared.indexType,
    centerX = prepared.centerX,
    centerY = prepared.centerY,
    centerZ = prepared.centerZ,
    minX = prepared.minX,
    maxX = prepared.maxX,
    minY = prepared.minY,
    maxY = prepared.maxY,
    minZ = prepared.minZ,
    maxZ = prepared.maxZ,
  })
end

local function prepareImage(token, path)
  local bytes, readError = love.filesystem.read(path)
  if bytes == nil then
    fail(token, "image", path, "unreadable cache file: " .. tostring(readError))
    return
  end
  local fileData, fileError = love.filesystem.newFileData(bytes, "prepared.png")
  if fileData == nil then
    fail(token, "image", path, fileError)
    return
  end
  local imageData, imageError = love.image.newImageData(fileData)
  if imageData == nil then
    fail(token, "image", path, imageError)
    return
  end
  replyChannel:push({ token = token, ok = true, kind = "image", path = path, imageData = imageData })
end

while true do
  local job = requestChannel:demand()
  if type(job) ~= "table" or job.op == "shutdown" then
    break
  end
  if job.op == "prepare" and job.kind == "mesh" then
    local ok, err = pcall(prepareMesh, job.token, job.path)
    if not ok then
      fail(job.token, job.kind, job.path, err)
    end
  elseif job.op == "prepare" and job.kind == "image" then
    local ok, err = pcall(prepareImage, job.token, job.path)
    if not ok then
      fail(job.token, job.kind, job.path, err)
    end
  else
    fail(job.token, job.kind, job.path, "unknown preparation request")
  end
end
