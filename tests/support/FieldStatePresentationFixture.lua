-- Complete presentation cache for real FieldState construction tests: the
-- base field-UI font/frames plus the Trainer Card front, one minimal mon
-- icon class, the minimal item icon manifest/atlas and bag manifest/images
-- the eager bag presentation resources require, and the minimal field-actor
-- index/visual/atlas FieldState presentation loaders currently require.

local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local ItemCache = require("libs.assets.src.ItemCache")
local MonCache = require("libs.assets.src.MonCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local FieldStatePresentationFixture = {}

local BAG_POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

---@param width integer
---@param height integer
---@return string
local function solidPng(width, height)
  local pixels = {}
  for _ = 1, width * height do
    pixels[#pixels + 1] = string.char(255, 255, 255, 255)
  end
  return PngWriter.encode(width, height, table.concat(pixels))
end

---@param path string
---@return table<string, unknown>
local function bagImageRef(path)
  return { image = path, width = 256, height = 192 }
end

---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@return table<string, integer>
local function bagRect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function bagConstantChannel()
  return { source = "constant", value = 0 }
end

---@param id string
---@param semanticName string
---@return table<string, unknown>
local function bagClip(id, semanticName)
  return {
    id = id,
    name = id,
    category = "joint",
    kind = "trs",
    frameCount = 4,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { semanticName },
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = { { 0, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = bagConstantChannel(), y = bagConstantChannel(), z = bagConstantChannel() },
            rot = bagConstantChannel(),
            scale = { x = bagConstantChannel(), y = bagConstantChannel(), z = bagConstantChannel() },
          },
        },
      },
    },
  }
end

---@return table<string, unknown>
local function bagDynamicMaterial()
  return {
    id = 0,
    name = "widget",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
    alphaMode = "opaque",
    polygonMode = "modulation",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

---@param gender string
---@return table<string, unknown>
local function bagHeroDescriptor(gender)
  local clips = {}
  for _, pocket in ipairs(BAG_POCKETS) do
    clips[#clips + 1] = bagClip(gender .. ".pose." .. pocket, "pocket." .. pocket .. ".pose")
    clips[#clips + 1] = bagClip(gender .. ".pattern." .. pocket, "pocket." .. pocket .. ".pattern")
  end
  clips[#clips + 1] = bagClip(gender .. ".material", "bag.material")
  return {
    schema = ModelAsset.SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { bagDynamicMaterial() },
    animations = clips,
  }
end

-- Minimal schema-valid bag manifest: the same shapes the asset contract
-- requires, with test-local image paths the fixture seeds below.
---@return table<string, unknown>
local function bagManifest()
  local states = {}
  for _, pocket in ipairs(BAG_POCKETS) do
    states[#states + 1] = {
      pocket = pocket,
      pose = "pocket." .. pocket .. ".pose",
      pattern = "pocket." .. pocket .. ".pattern",
    }
  end
  local tabs = {}
  for i = 0, 7 do
    tabs[#tabs + 1] = bagRect(i * 32, 0, 32, 32)
  end
  local slots = {}
  local index = 0
  for row = 0, 2 do
    for col = 0, 1 do
      index = index + 1
      local x = col == 0 and 32 or 160
      local y = 40 + row * 40
      slots[index] = {
        rect = bagRect(x, y, 88, 32),
        iconCenter = { x = x + 16, y = y + 16 },
      }
    end
  end
  return {
    schema = BagAssetSchema.SCHEMA,
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = bagImageRef("test/bag/hero-male.png"),
        female = bagImageRef("test/bag/hero-female.png"),
      },
      description = {
        frame = {
          image = "test/bag/description-frame.png",
          alternateImage = "test/bag/description-frame-alt.png",
          rect = bagRect(0, 144, 256, 48),
        },
        textRect = bagRect(20, 144, 228, 40),
      },
      model = { male = bagHeroDescriptor("male"), female = bagHeroDescriptor("female") },
      animations = {
        states = states,
        material = { male = "male.material", female = "female.material" },
      },
      presentation = {
        camera = {
          target = { x = 0, y = 0, z = 0 },
          distance = 339.9,
          angleXDegrees = 328.4,
          angleYDegrees = 28.3,
          perspectiveType = 0,
          perspectiveAngle = 256,
          clipNear = 123.0,
          clipFar = 1700.0,
        },
        transform = {
          translation = { x = 0, y = -45, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
        lights = {
          count = 4,
          color = { r = 31, g = 31, b = 31 },
          vectors = {
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
          },
        },
      },
    },
    interactive = {
      backgrounds = {
        browse = bagImageRef("test/bag/background-browse.png"),
        action = bagImageRef("test/bag/background-action.png"),
        quantity = bagImageRef("test/bag/background-quantity.png"),
        confirmation = bagImageRef("test/bag/background-confirmation.png"),
      },
      pocketTabs = {
        rects = tabs,
        normal = {
          bagImageRef("test/bag/tab-normal-1.png"),
          bagImageRef("test/bag/tab-normal-2.png"),
          bagImageRef("test/bag/tab-normal-3.png"),
          bagImageRef("test/bag/tab-normal-4.png"),
          bagImageRef("test/bag/tab-normal-5.png"),
          bagImageRef("test/bag/tab-normal-6.png"),
          bagImageRef("test/bag/tab-normal-7.png"),
          bagImageRef("test/bag/tab-normal-8.png"),
        },
        selected = bagImageRef("test/bag/tab-selected.png"),
      },
      itemSlots = {
        slots = slots,
        focus = bagImageRef("test/bag/focus.png"),
        registration = {
          slot1 = { image = "test/bag/registration-slot-1.png", width = 40, height = 16 },
          slot2 = { image = "test/bag/registration-slot-2.png", width = 40, height = 16 },
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = bagRect(80, 168, 56, 16), textAt = { x = 0, y = 0 } },
      cancel = bagRect(192, 168, 56, 16),
      text = {
        actions = {
          toss = "TOSS",
          move = "MOVE",
          register = "REGISTER",
          unregister = "DESELECT",
          cancel = "CANCEL",
          confirm = "YES",
        },
        movePrompt = {
          segments = { { kind = "text", value = "Move " }, { kind = "item" }, { kind = "text", value = "?" } },
        },
        tossQuantity = {
          segments = { { kind = "text", value = "Toss " }, { kind = "item" }, { kind = "text", value = "?" } },
        },
        tossConfirm = {
          segments = {
            { kind = "text", value = "Toss " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "?" },
          },
        },
      },
      overlays = {
        actionMenu = {
          buttons = {
            bagRect(8, 136, 80, 16),
            bagRect(104, 136, 80, 16),
            bagRect(8, 168, 80, 16),
            bagRect(104, 168, 80, 16),
          },
        },
        quantity = {
          digits = { bagRect(128, 112, 16, 24), bagRect(160, 112, 16, 24), bagRect(192, 112, 16, 24) },
        },
        descriptionFallback = { frame = bagRect(0, 144, 256, 48), textRect = bagRect(20, 144, 228, 40) },
      },
      widgets = {
        sourceStrip = {
          image = "test/bag/source-strip.png",
          width = 32,
          height = 32,
          placement = { x = 177, y = 14 },
          states = { browsing = false },
        },
      },
    },
  }
end

---@return CacheFs
function FieldStatePresentationFixture.cache()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:write(FieldUiFixture.TRAINER_CARD_PATH, FieldUiFixture.cardBytes())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    image = MonCache.iconImagePath(),
    entries = {
      ["TEST/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
      },
    },
    representative = { "TEST/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(255, 0, 0, 255)
  end
  cache:write(MonCache.iconImagePath(), PngWriter.encode(64, 64, table.concat(pixels)))
  -- Minimal item icon manifest/atlas and bag manifest/images so the eager
  -- bag presentation resources resolve during FieldState construction.
  cache:writeLua(ItemCache.iconManifestPath(), {
    schema = ItemCache.ICON_MANIFEST_SCHEMA,
    atlas = ItemCache.iconImagePath(),
    entries = {
      POTION = { x = 0, y = 0, width = 32, height = 32 },
    },
    representative = { "POTION" },
  })
  cache:write(ItemCache.iconImagePath(), solidPng(64, 64))
  cache:writeLua(BagCache.manifestPath(), bagManifest())
  cache:write("test/bag/hero-male.png", solidPng(32, 32))
  cache:write("test/bag/hero-female.png", solidPng(32, 32))
  cache:write("test/bag/description-frame.png", solidPng(32, 32))
  cache:write("test/bag/background-browse.png", solidPng(32, 32))
  cache:write("test/bag/background-action.png", solidPng(32, 32))
  cache:write("test/bag/background-quantity.png", solidPng(32, 32))
  cache:write("test/bag/background-confirmation.png", solidPng(32, 32))
  cache:write("test/bag/description-frame-alt.png", solidPng(32, 32))
  for index = 1, 8 do
    cache:write("test/bag/tab-normal-" .. index .. ".png", solidPng(32, 32))
  end
  cache:write("test/bag/tab-selected.png", solidPng(32, 32))
  cache:write("test/bag/focus.png", solidPng(32, 32))
  cache:write("test/bag/source-strip.png", solidPng(32, 32))
  cache:write("test/bag/registration-slot-1.png", solidPng(40, 16))
  cache:write("test/bag/registration-slot-2.png", solidPng(40, 16))
  cache:write(
    FieldActorCache.indexPath(),
    LuaWriter.encode({ schema = FieldActorCache.INDEX_SCHEMA, spriteIds = { 0 } })
  )
  cache:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0))
  cache:write(FieldActorCache.atlasPath(0), FieldDialogueFixture.atlasBytes())
  return cache
end

-- The terrain-effect bundle the real terrain renderer acquires during the
-- boot: one synthetic triangle mesh per effect kind, written into the same
-- presentation cache the boot reads through.
---@param cache CacheFs
---@return table<string, table<string, unknown>>
function FieldStatePresentationFixture.terrainEffects(cache)
  cache:write(
    "test/terrain-grass.mesh",
    MeshWriter.encode({
      vertices = {
        {
          x = 0,
          y = 0,
          z = 0,
          u = 0,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 1,
          y = 0,
          z = 0,
          u = 1,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 0,
          y = 0,
          z = 1,
          u = 0,
          v = 1,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
      },
      indices = { 0, 1, 2 },
    })
  )
  local function effect()
    return {
      model = {
        dynamic = {
          nodes = {
            { name = "root", translation = { 0, 0, 0 }, rotation = { 0, 0, 0 }, scale = { 1, 1, 1 } },
          },
          batches = {
            {
              id = "grass",
              nodeIndex = 0,
              materialIndex = 0,
              geometry = "test/terrain-grass.mesh",
              alphaClass = "cutout",
              cullMode = "back",
              polygonAlpha = 31,
              polygonMode = "modulation",
              polygonId = 0,
              translucentDepthWrite = false,
              depthEqual = false,
              lightMask = 15,
              fogEnabled = false,
            },
          },
        },
        materials = { { id = 0, name = "grass", wrap = { x = "clamp", y = "clamp" } } },
        animations = {},
      },
      placementOffset = { x = 0, y = 0, z = 0 },
    }
  end
  return {
    tall_grass = effect(),
    very_tall_grass = effect(),
    trainer_reveal = effect(),
  }
end

return FieldStatePresentationFixture
