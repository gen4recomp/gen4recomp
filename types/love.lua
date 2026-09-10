-- Minimal LÖVE type declarations for LuaLS. The annotations reference these
-- names and the runtime uses these entry points; the runtime never requires
-- this file. Keep this in sync with the love.* and lg.* calls in the repo.
--
-- LÖVE module functions (love.graphics.*, love.filesystem.*) are plain
-- functions and are called dot-style with no self; object methods
-- (love.Image:setFilter, love.Quad) are called colon-style and declare self.

---@class love.Joystick
---@field getID fun(self: love.Joystick): integer

---@class love.Quad

---@class love.Image
---@field setFilter fun(self: love.Image, minFilter: string, magFilter: string)
---@field setWrap fun(self: love.Image, wrapS: string, wrapT: string)
---@field getWrap fun(self: love.Image): string, string
---@field release fun(self: love.Image)
---@field getWidth fun(self: love.Image): integer
---@field getHeight fun(self: love.Image): integer

---@class love.Canvas
---@field newImageData fun(self: love.Canvas): love.ImageData
---@field setFilter fun(self: love.Canvas, minFilter: string, magFilter: string)
---@field release fun(self: love.Canvas)

---@class love.Shader
---@field send fun(self: love.Shader, name: string, ...: any)
---@field release fun(self: love.Shader)

---@class love.Mesh
---@field getVertex fun(self: love.Mesh, index: integer): ...number
--  getVertex returns the attribute components as multiple values on this
--  build (no Mesh:getVertices bulk read in love 11.5).
---@field getVertexCount fun(self: love.Mesh): integer
---@field getVertexMap fun(self: love.Mesh): table|nil
---@field setVertexMap fun(self: love.Mesh, map: table)
---@field setTexture fun(self: love.Mesh, image: love.Image?)
---@field release fun(self: love.Mesh)

---@class love.ImageData
---@field getPixel fun(self: love.ImageData, x: integer, y: integer): number, number, number, number
---@field setPixel fun(self: love.ImageData, x: integer, y: integer, r: number, g: number, b: number, a: number)

---@class love.Graphics
---@field newImage fun(data: unknown): love.Image
---@field newQuad fun(x: number, y: number, w: number, h: number, imageWidth: number, imageHeight: number): love.Quad
---@field newMesh fun(layout: table, vertices: table, mode: string, usage: string): love.Mesh
---@field newCanvas fun(...: any): love.Canvas
---@field newShader fun(...: any): love.Shader
---@field newImageData fun(...: any): love.ImageData
---@field setColor fun(...: number)
---@field setBackgroundColor fun(...: number)
---@field setShader fun(shader: love.Shader?)
---@field setCanvas fun(canvas?: love.Canvas, ...: love.Canvas?)
---@field setBlendMode fun(mode: string, alpha?: string)
---@field setDepthMode fun(mode: string?, write: boolean?)
---@field setMeshCullMode fun(mode: string?)
---@field setScissor fun(...: number?)
---@field setWireframe fun(enabled: boolean)
---@field getDimensions fun(): integer, integer
---@field getWidth fun(): integer
---@field getCanvas fun(): love.Canvas?
---@field getShader fun(): love.Shader?
---@field getBlendMode fun(): string, string?
---@field getDepthMode fun(): string?, boolean?
---@field getMeshCullMode fun(): string?
---@field getScissor fun(): number?, number?, number?, number?
---@field getColor fun(): number, number, number, number
---@field clear fun(...: any)
---@field isWireframe fun(): boolean
---@field draw fun(object: unknown, ...: any)
---@field print fun(text: string, x: number, y: number)
---@field printf fun(text: string, x: number, y: number, limit: number)
---@field rectangle fun(mode: string, x: number, y: number, w: number, h: number)
---@field polygon fun(mode: string, ...: number)
---@field line fun(...: number)
---@field push fun()
---@field pop fun()
---@field translate fun(x: number, y: number)
---@field scale fun(x: number, y: number)

---@class love.Filesystem
---@field getSourceBaseDirectory fun(): string
---@field getSaveDirectory fun(): string
---@field newFileData fun(data: string, name: string): unknown
---@field read fun(path: string): string?, number?
---@field write fun(path: string, data: string|love.Data): boolean
---@field getInfo fun(path: string): table?
---@field exists fun(path: string): boolean
---@field createDirectory fun(path: string): boolean
---@field remove fun(path: string): boolean
---@field mount fun(path: string, mountPoint: string): boolean
---@field unmount fun(path: string): boolean
---@field getDirectoryItems fun(path: string): string[]

---@class love.Event
---@field quit fun(code?: integer)

---@class love.ImageModule
---@field newImageData fun(...: any): love.ImageData

---@class love.Timer
---@field getTime fun(): number

---@class love.DataModule
---@field newByteData fun(size: integer): love.Data
---@field hash fun(algorithm: string, data: string|love.Data): string

---@class love.Data
---@field getSize fun(self: love.Data): integer
---@field getString fun(self: love.Data): string
---@field getFFIPointer fun(self: love.Data): ffi.cdata*

---@class love
---@field graphics love.Graphics
---@field filesystem love.Filesystem
---@field event love.Event
---@field image love.ImageModule
---@field timer love.Timer
---@field data love.DataModule
---@field conf fun(t: table)?
---@field load fun(argv: string[])?
---@field update fun(dt: number)?
---@field draw fun()?
---@field filedropped fun(file: unknown)?
---@field keypressed fun(key: string, scancode: string, isrepeat: boolean)?
---@field keyreleased fun(key: string, scancode: string)?
---@field gamepadpressed fun(joystick: love.Joystick, button: string)?
---@field gamepadreleased fun(joystick: love.Joystick, button: string)?
---@field focus fun(focused: boolean)?
---@field quit fun()?
