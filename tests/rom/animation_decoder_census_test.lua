-- Whole-archive census of the HGSS field animation archive (a/1/0/6): every
-- member must decode through NitroAnimation and satisfy the archive facts
-- (member count, per-format curve/key invariants, format census). This sweep
-- is the exhaustive counterpart to the targeted per-member decoder checks,
-- which stay in the default tier; the sweep itself runs only when the slow
-- tier is selected.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local Nsbca = require("libs.nds.src.nitro.g3d.Nsbca")
local Nsbta = require("libs.nds.src.nitro.g3d.Nsbta")

local T = {}

-- Every animation resource decodes; every sampled curve limit equals the
-- animation's numFrame (verified pattern across all 85 NSBCA members).
function T.all_animation_members_decode(romFs)
  local narc = assert(romFs:openNarc("build_anim"))
  local count = narc:memberCount()
  Assert.equal(count, 273, "field animation archive member count")
  local formats = { NSBCA = 0, NSBTA = 0, NSBTP = 0, NSBMA = 0 }
  for memberId = 0, count - 1 do
    local bytes = assert(narc:readMember(memberId))
    local decoded, err = NitroAnimation.decode(bytes, { alias = "build_anim", memberId = memberId })
    assert(decoded, "member " .. memberId .. ": " .. tostring(err and err.message))
    formats[decoded.format] = formats[decoded.format] + 1
    Assert.equal(#decoded.animations, 1, "one animation per member")
    local r = BinaryReader.new(decoded.bytes, "sec")
    for _, anim in ipairs(decoded.animations) do
      local res = anim.resource
      Assert.equal(res.numFrame >= 2, true, "sane frame count")
      if decoded.format == "NSBCA" then
        -- Curve limits match numFrame; sampling any frame stays in bounds.
        for _, t in ipairs(res.targets) do
          for _, axis in ipairs({ "x", "y", "z" }) do
            local c = t.channels.trans[axis]
            if c.source == "curve" then
              Assert.equal(c.curve.limit, res.numFrame, "trans limit")
            end
            c = t.channels.scale[axis]
            if c.source == "curve" then
              Assert.equal(c.curve.limit, res.numFrame, "scale limit")
            end
          end
          local rot = t.channels.rot
          if rot.source == "curve" then
            Assert.equal(rot.curve.limit, res.numFrame, "rot limit")
          end
        end
        -- Sample the middle frame of every target (all field members use the
        -- integer sampler; this exercises every channel type in the corpus).
        local mid = math.floor(res.numFrame / 2) * 4096
        for i = 0, #res.targets - 1 do
          local s = Nsbca.sample(r, res, i, mid)
          if s.rot then
            for _, v in ipairs(s.rot) do
              Assert.isTrue(math.abs(v) < 0x80000000, "rotation cell bounded")
            end
          end
        end
      elseif decoded.format == "NSBTA" then
        -- NSBTA curve limits equal numFrame like NSBCA (census: 217/217
        -- curve channels across the 99 members), so the compile path may
        -- assert the same invariant.
        for _, t in ipairs(res.targets) do
          for _, name in ipairs({ "transS", "transT", "rot", "scaleS", "scaleT" }) do
            local c = t.channels[name]
            if c.source == "curve" then
              Assert.equal(c.limit, res.numFrame, name .. " limit")
            end
          end
        end
        -- Sample the middle frame of every target: exercises the constant
        -- channels (including non-identity packed rotations), the sampled
        -- fx16/fx32 vector channels, and the packed rotation pairs.
        local mid = math.floor(res.numFrame / 2) * 4096
        for i = 0, #res.targets - 1 do
          local s = Nsbta.sample(r, res, i, mid)
          for _, name in ipairs({ "transS", "transT", "scaleS", "scaleT" }) do
            local v = s[name]
            if v ~= nil and v >= 0x80000000 then
              v = v - 4294967296
            end
            Assert.isTrue(v == nil or math.abs(v) < 0x10000000, "texture SRT cell bounded")
          end
          if s.rot then
            Assert.isTrue(math.abs(s.rot.sin) < 0x10000, "rotation pair bounded")
            Assert.isTrue(math.abs(s.rot.cos) < 0x10000, "rotation pair bounded")
          end
        end
      elseif decoded.format == "NSBTP" then
        for _, t in ipairs(res.targets) do
          Assert.equal(t.keyCount, #t.keys, "key count matches array")
          for _, k in ipairs(t.keys) do
            Assert.isTrue(k.texIdx < res.numTextures, "texture index in range")
            Assert.isTrue(k.plttIdx == 0xFF or k.plttIdx < res.numPalettes, "palette index in range")
          end
          -- The last key's frame is within the animation.
          Assert.isTrue(t.keys[#t.keys].frame < res.numFrame, "last key frame < numFrame")
        end
      end
    end
  end
  Assert.equal(formats.NSBCA, 85, "NSBCA count")
  Assert.equal(formats.NSBTA, 99, "NSBTA count")
  Assert.equal(formats.NSBTP, 79, "NSBTP count")
  Assert.equal(formats.NSBMA, 10, "NSBMA count")
  -- No NSBVA pin: a VIS0 member would fail the decode above
  -- (ANM_UNKNOWN_FILE_MAGIC) and fail this test on its own.
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.slow = true
suite.metadata.tags = { "animation", "census" }
return suite
