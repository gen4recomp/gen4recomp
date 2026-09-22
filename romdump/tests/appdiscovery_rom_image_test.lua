-- Direct-from-ROM executable image access: NdsRom's source-direct overlay
-- primitives and the leaf-internal RomImage wrapper built on top of them,
-- entirely from a synthetic in-memory NdsRom (no cache, no dump).

local Assert = require("tests.support.Assert")
local NdsRom = require("romdump.src.source.NdsRom")
local RomSource = require("romdump.src.source.RomSource")
local NdsBuilder = require("tests.support.NdsBuilder")
local BackwardsLz = require("tests.support.BackwardsLz")
local RomImage = require("romdump.src.appdiscovery.RomImage")

local T = {}

local function matchingVersions(data, gameCode)
  local info = { sha1 = RomSource.fromString(data):sha1(), gameCode = gameCode, expectedSize = #data }
  return {
    forSha1 = function(h)
      return h == info.sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == gameCode and info or nil
    end,
  }
end

-- One uncompressed overlay (0), one compressed overlay (1) whose FAT bytes
-- are the smaller backwards-LZ stream and whose declared ramSize is the
-- larger decoded length, and a compressed main ARM9 image (bigger raw
-- length, so RomImage must prefer the decoded candidate).
local RAW_OVERLAY_CONTENT = "PLAIN-OVERLAY-BYTES"
local COMPRESSED_OVERLAY_BYTES, COMPRESSED_OVERLAY_DECODED_LEN = BackwardsLz.growing(string.byte("O"), 40)
local MAIN_ARM9_BYTES, MAIN_ARM9_DECODED_LEN = BackwardsLz.growing(string.byte("M"), 96)

local COMPRESSED_FLAG_BIT = 16777216 -- bit 24

local function buildFixture()
  local spec = {
    gameCode = "IPKE",
    title = "TESTHG",
    arm9 = MAIN_ARM9_BYTES,
    arm9Ram = 0x02000000,
    arm9Entry = 0x02000100,
    overlays9 = {
      { content = RAW_OVERLAY_CONTENT, ramAddress = 0x02100000, ramSize = #RAW_OVERLAY_CONTENT, flags = 0 },
      {
        content = COMPRESSED_OVERLAY_BYTES,
        ramAddress = 0x02200000,
        ramSize = COMPRESSED_OVERLAY_DECODED_LEN,
        flags = COMPRESSED_FLAG_BIT + #COMPRESSED_OVERLAY_BYTES,
      },
    },
  }
  local data = NdsBuilder.build(spec)
  local rom = assert(NdsRom.open(RomSource.fromString(data), matchingVersions(data, "IPKE")))
  return rom
end

function T.overlay_info_normalizes_flags_and_metadata()
  local rom = buildFixture()
  local raw = assert(rom:overlayInfo("arm9", 0))
  Assert.equal(raw.cpu, "arm9")
  Assert.equal(raw.overlayId, 0)
  Assert.equal(raw.fileId, 0)
  Assert.equal(raw.ramAddress, 0x02100000)
  Assert.equal(raw.ramSize, #RAW_OVERLAY_CONTENT)
  Assert.equal(raw.isCompressed, false)
  Assert.equal(raw.compressedSize, 0)

  local compressed = assert(rom:overlayInfo("arm9", 1))
  Assert.equal(compressed.ramAddress, 0x02200000)
  Assert.equal(compressed.ramSize, COMPRESSED_OVERLAY_DECODED_LEN)
  Assert.equal(compressed.isCompressed, true)
  Assert.equal(compressed.compressedSize, #COMPRESSED_OVERLAY_BYTES)
end

function T.overlay_info_rejects_unknown_cpu_or_id()
  local rom = buildFixture()
  local info, cpuErr = rom:overlayInfo("arm11", 0)
  Assert.isNil(info)
  Assert.equal(assert(cpuErr).code, "NDS_OVERLAY_UNKNOWN_CPU")

  local missing, idErr = rom:overlayInfo("arm9", 99)
  Assert.isNil(missing)
  Assert.equal(assert(idErr).code, "NDS_OVERLAY_UNKNOWN_ID")
end

function T.read_overlay_returns_raw_bytes_unchanged_when_uncompressed()
  local rom = buildFixture()
  local bytes, info = rom:readOverlay("arm9", 0)
  Assert.equal(bytes, RAW_OVERLAY_CONTENT)
  Assert.equal(assert(info).isCompressed, false)
end

function T.read_overlay_decodes_through_existing_codec_when_compressed()
  local rom = buildFixture()
  local bytes, info = rom:readOverlay("arm9", 1)
  Assert.equal(bytes, string.rep("O", COMPRESSED_OVERLAY_DECODED_LEN))
  Assert.equal(assert(info).ramSize, COMPRESSED_OVERLAY_DECODED_LEN)
end

function T.read_overlay_propagates_unknown_id_error()
  local rom = buildFixture()
  local bytes, err = rom:readOverlay("arm9", 99)
  Assert.isNil(bytes)
  Assert.equal(assert(err).code, "NDS_OVERLAY_UNKNOWN_ID")
end

function T.rom_image_main_arm9_decodes_compressed_footer_and_preserves_source_metadata()
  local rom = buildFixture()
  local image = RomImage.new(rom)
  local main = image:mainArm9()
  Assert.equal(main.kind, "arm9-main")
  Assert.equal(main.id, "arm9-main")
  Assert.equal(main.ramAddress, 0x02000000)
  Assert.equal(main.bytes, string.rep("M", MAIN_ARM9_DECODED_LEN))
  Assert.equal(main.rawSize, #MAIN_ARM9_BYTES)
  Assert.equal(main.decodedSize, MAIN_ARM9_DECODED_LEN)
  Assert.equal(main.normalization, "backwards-lz")
  Assert.isTrue(main.decodedSize > main.rawSize, "normalization must only accept strictly larger decodes")
end

function T.rom_image_main_arm9_keeps_raw_bytes_when_decode_does_not_grow()
  local equalBytes, equalLen = BackwardsLz.equalSized(string.byte("E"))
  local spec = {
    gameCode = "IPKE",
    title = "TESTHG",
    arm9 = equalBytes,
    arm9Ram = 0x02000000,
    unmapped = { "UNMAPPED" },
  }
  local data = NdsBuilder.build(spec)
  local rom = assert(NdsRom.open(RomSource.fromString(data), matchingVersions(data, "IPKE")))
  local image = RomImage.new(rom)
  local main = image:mainArm9()
  Assert.equal(main.bytes, equalBytes)
  Assert.equal(main.normalization, "raw")
  Assert.equal(main.rawSize, equalLen)
  Assert.equal(main.decodedSize, equalLen)
end

function T.rom_image_main_arm9_keeps_raw_bytes_when_footer_does_not_decode()
  local plainArm9 = "NOTCOMPRESSEDBYTES" .. BackwardsLz.invalidFooter()
  local spec = {
    gameCode = "IPKE",
    title = "TESTHG",
    arm9 = plainArm9,
    arm9Ram = 0x02000000,
    unmapped = { "UNMAPPED" },
  }
  local data = NdsBuilder.build(spec)
  local rom = assert(NdsRom.open(RomSource.fromString(data), matchingVersions(data, "IPKE")))
  local image = RomImage.new(rom)
  local main = image:mainArm9()
  Assert.equal(main.bytes, plainArm9)
  Assert.equal(main.normalization, "raw")
end

function T.rom_image_overlay_delegates_to_nds_rom_and_maps_ram_address()
  local rom = buildFixture()
  local image = RomImage.new(rom)
  local overlay = image:overlay("arm9", 1)
  Assert.equal(overlay.kind, "arm9-overlay")
  Assert.equal(overlay.id, "arm9-overlay:1")
  Assert.equal(overlay.ramAddress, 0x02200000)
  Assert.equal(overlay.bytes, string.rep("O", COMPRESSED_OVERLAY_DECODED_LEN))
  Assert.equal(overlay.rawSize, #COMPRESSED_OVERLAY_BYTES)
  Assert.equal(overlay.decodedSize, COMPRESSED_OVERLAY_DECODED_LEN)
  Assert.equal(overlay.normalization, "backwards-lz")
end

function T.rom_image_overlay_uncompressed_reports_raw_normalization()
  local rom = buildFixture()
  local image = RomImage.new(rom)
  local overlay = image:overlay("arm9", 0)
  Assert.equal(overlay.bytes, RAW_OVERLAY_CONTENT)
  Assert.equal(overlay.normalization, "raw")
  Assert.equal(overlay.rawSize, #RAW_OVERLAY_CONTENT)
  Assert.equal(overlay.decodedSize, #RAW_OVERLAY_CONTENT)
end

function T.rom_image_never_touches_cache_state()
  -- RomImage.new accepts only the ROM: there is no cache/backend parameter
  -- for it to read or mutate, and images are memoized purely in-memory.
  local rom = buildFixture()
  local image = RomImage.new(rom)
  Assert.isNil(rawget(image, "_cache"))
  local same = image:mainArm9()
  Assert.isTrue(same == image:mainArm9(), "mainArm9 must memoize the same immutable record")
end

function T.deterministic_hashes_for_identical_content()
  local rom = buildFixture()
  local image = RomImage.new(rom)
  local main = image:mainArm9()
  Assert.notNil(main.rawSha1)
  Assert.notNil(main.decodedSha1)
  Assert.isTrue(#main.rawSha1 > 0)
  Assert.isTrue(#main.decodedSha1 > 0)

  local rom2 = buildFixture()
  local image2 = RomImage.new(rom2)
  Assert.equal(image2:mainArm9().rawSha1, main.rawSha1)
  Assert.equal(image2:mainArm9().decodedSha1, main.decodedSha1)
end

return { tests = T }
