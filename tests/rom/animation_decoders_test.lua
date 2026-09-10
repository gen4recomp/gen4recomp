-- Real-ROM validation of the animation decoders over explicitly named
-- members of the HGSS field animation archive (a/1/0/6): the door_op NSBCA
-- rotation sweep, the gym-door NSBTA texture animation, the pc_mb NSBTP
-- variant selection, and the psentry_rode NSBMA alpha fade. One member per
-- currently supported format, never a sweep: the whole-archive census lives
-- in the slow sibling.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local Nsbca = require("libs.nds.src.nitro.g3d.Nsbca")
local Nsbta = require("libs.nds.src.nitro.g3d.Nsbta")
local Nsbtp = require("libs.nds.src.nitro.g3d.Nsbtp")
local Nsbma = require("libs.nds.src.nitro.g3d.Nsbma")

local T = {}

-- The real door_op member: node 0, rotation animated through 8 pivot keys,
-- translation and scale from the model.
function T.door_op_rotation_sweeps(romFs)
  local narc = assert(romFs:openNarc("build_anim"))
  local bytes = assert(narc:readMember(1)) -- door_op
  local decoded = assert(NitroAnimation.decode(bytes))
  local res = decoded.animations[1].resource
  Assert.equal(res.numFrame, 8, "door_op frame count")
  Assert.equal(#res.targets, 1)
  local target = res.targets[1]
  Assert.equal(target.nodeIndex, 0)
  Assert.isTrue(target.channels.trans.x.source == "model", "door translation from model")
  Assert.isTrue(target.channels.rot.source == "curve", "door rotation animated")

  local r = BinaryReader.new(decoded.bytes, "sec")
  local s0 = Nsbca.sample(r, res, 0, 0)
  local s7 = Nsbca.sample(r, res, 0, 7 * 4096)
  -- Frame 0: pivot entry 0 (A=1, B=0) -- the closed pose.
  Assert.isTrue(math.abs(s0.rot[1] - 0x1000) < 0x40, "closed pose A = 1")
  -- Frame 7: the last pivot entry is {0x22, A=0, B=0x1000} (pivot 2, signC).
  Assert.isTrue(math.abs(s7.rot[1]) < 0x40, "open pose A = 0")
  Assert.isTrue(math.abs(s7.rot[5] - 0x1000) < 0x40, "open pose B = 1")
  Assert.isTrue(math.abs(s7.rot[7] + 0x1000) < 0x40, "open pose C = -B")
  Assert.isTrue(math.abs(s7.rot[3] - 0x1000) < 0x40, "pivot cell")
end

-- The real gym doors are NSBTA (texture-SRT): member 121/122 pair, and the
-- census's most-referenced BTP pair (pc_mb) must select variants by frame.
function T.material_animation_members(romFs)
  local narc = assert(romFs:openNarc("build_anim"))

  -- Member 121 = gym-door NSBTA: curve limits equal numFrame like NSBCA, and
  -- the middle-frame sample stays bounded.
  local bta = assert(NitroAnimation.decode(assert(narc:readMember(121))))
  Assert.equal(bta.format, "NSBTA", "gym-door member 121 is a texture animation")
  Assert.equal(#bta.animations, 1, "one animation in member 121")
  local btaRes = bta.animations[1].resource
  Assert.equal(btaRes.numFrame >= 2, true, "sane frame count")
  Assert.isTrue(#btaRes.targets > 0, "member 121 carries texture targets")
  for _, t in ipairs(btaRes.targets) do
    for _, name in ipairs({ "transS", "transT", "rot", "scaleS", "scaleT" }) do
      local c = t.channels[name]
      if c.source == "curve" then
        Assert.equal(c.limit, btaRes.numFrame, name .. " limit")
      end
    end
  end
  local btaReader = BinaryReader.new(bta.bytes, "sec")
  local mid = math.floor(btaRes.numFrame / 2) * 4096
  for i = 0, #btaRes.targets - 1 do
    local s = Nsbta.sample(btaReader, btaRes, i, mid)
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

  -- Member 7 = pc_mb (BTP): keys every 4 frames, 4 textures.
  local btp = assert(NitroAnimation.decode(assert(narc:readMember(7))))
  local res = btp.animations[1].resource
  Assert.equal(res.numFrame, 68)
  Assert.equal(#res.textureNames, 4)
  local k = Nsbtp.keyAt(res, 0, 67)
  Assert.equal(k.frame, 64)
  Assert.equal(k.texIdx, 0)

  -- A BMA member (member 119 = psentry_rode): constant colors + alpha curve.
  local bma = assert(NitroAnimation.decode(assert(narc:readMember(119))))
  local bmaRes = bma.animations[1].resource
  Assert.equal(bmaRes.numFrame, 60)
  local br = BinaryReader.new(bma.bytes, "sec")
  local s = Nsbma.sample(br, bmaRes, 0, 0)
  Assert.equal(s.alpha, 31, "alpha starts opaque")
  -- The alpha key array fades to 0 well before the 60-frame limit.
  local sMid = Nsbma.sample(br, bmaRes, 0, 30 * 4096)
  Assert.isTrue(sMid.alpha <= 1, "alpha faded by frame 30 (saw " .. tostring(sMid.alpha) .. ")")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
