local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Narc = require("libs.nds.src.nitro.Narc")
local NarcBuilder = require("tests.support.NarcBuilder")

local T = {}

local function openOrFail(members, opts)
  local narc, err = Narc.open(NarcBuilder.build(members, opts))
  Assert.notNil(narc, "expected open to succeed: " .. tostring(err))
  return assert(narc)
end

local function rejects(code, members, opts)
  local narc, err = Narc.open(NarcBuilder.build(members, opts))
  Assert.isNil(narc, "expected open to fail with " .. code)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(assert(err).code, code)
end

function T.reads_all_members_by_zero_based_id()
  local narc = openOrFail({ "AAAA", "BBBBBB", "CC" })
  Assert.equal(narc:memberCount(), 3)
  Assert.equal(narc:readMember(0), "AAAA")
  Assert.equal(narc:readMember(1), "BBBBBB")
  Assert.equal(narc:readMember(2), "CC")
end

function T.empty_archive_has_no_members()
  local narc = openOrFail({})
  Assert.equal(narc:memberCount(), 0)
end

function T.empty_member_exposes_an_empty_view()
  local narc = openOrFail({ "" })
  local view = assert(narc:memberView(0))
  Assert.equal(view:length(), 0)
  Assert.equal(view:toString(), "")
  Assert.equal(narc:readMember(0), "")
end

-- Non-4-byte member sizes force alignment padding between members; readMember
-- must return exact bytes and offsets must be GMIF-payload-relative and aligned.
function T.honors_gmif_relative_aligned_offsets()
  local narc = openOrFail({ "abc", "de", "f" })
  Assert.equal(narc:readMember(0), "abc")
  Assert.equal(narc:readMember(1), "de")
  Assert.equal(narc:readMember(2), "f")
  Assert.equal(narc:memberInfo(0).startOffset, 0)
  Assert.equal(narc:memberInfo(1).startOffset, 4)
  Assert.equal(narc:memberInfo(2).startOffset, 8)
end

function T.member_info_reports_zero_based_id_and_size()
  local info = assert(openOrFail({ "AAAA", "BBBBBB" }):memberInfo(1))
  Assert.equal(info.memberId, 1)
  Assert.equal(info.startOffset, 4)
  Assert.equal(info.endOffset, 10)
  Assert.equal(info.size, 6)
end

function T.member_views_share_archive_backing_and_survive_parent_locals()
  local function viewsFromArchive()
    local narc = openOrFail({ "\1\0\255\254", "AB\0CD" })
    local secondView = assert(narc:memberView(1))
    local firstView = assert(narc:memberView(0))
    return secondView, firstView, narc:readMember(1)
  end

  local secondView, firstView, secondBytes = viewsFromArchive()
  collectgarbage("collect")

  Assert.equal(secondView:length(), 5)
  Assert.equal(secondView:u16le(0), 0x4241)
  Assert.equal(secondView:toString(), secondBytes)
  Assert.equal(firstView:u32le(0), 0xFEFF0001)
  Assert.equal(firstView:toString(), "\1\0\255\254")
end

function T.block_info_lists_blocks_in_order()
  local blocks = openOrFail({ "AAAA" }):blockInfo()
  Assert.equal(#blocks, 3)
  Assert.equal(blocks[1].magic, "BTAF")
  Assert.equal(blocks[2].magic, "BTNF")
  Assert.equal(blocks[3].magic, "GMIF")
end

function T.rejects_member_id_out_of_range()
  local narc = openOrFail({ "AAAA" })
  local data, err = narc:readMember(1)
  Assert.isNil(data)
  Assert.equal(assert(err).code, "NARC_MEMBER_ID_OUT_OF_RANGE")

  ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid member ID
  local view, viewErr = narc:memberView(0.5)
  Assert.isNil(view)
  Assert.equal(assert(viewErr).code, "NARC_MEMBER_ID_OUT_OF_RANGE")
end

function T.rejects_bad_magic()
  local ok = NarcBuilder.build({ "AAAA" })
  local narc, err = Narc.open("XXXX" .. ok:sub(5))
  Assert.isNil(narc)
  Assert.equal(assert(err).code, "NARC_BAD_MAGIC")
end

function T.rejects_declared_size_past_supplied_bytes()
  rejects("NARC_TRUNCATED", { "AAAA" }, { declaredSizeTooLarge = true })
end

function T.rejects_missing_btaf()
  rejects("NARC_MISSING_BTAF", { "AAAA" }, { missingBtaf = true })
end

function T.rejects_missing_gmif()
  rejects("NARC_MISSING_GMIF", { "AAAA" }, { missingGmif = true })
end

function T.rejects_duplicate_block()
  rejects("NARC_DUPLICATE_BLOCK", { "AAAA" }, { duplicateBtaf = true })
end

function T.rejects_block_below_minimum_size()
  rejects("NARC_BLOCK_TOO_SMALL", { "AAAA" }, { tinyBlock = true })
end

function T.rejects_member_out_of_range()
  rejects("NARC_MEMBER_OUT_OF_RANGE", { "AAAA" }, { memberOutOfRange = true })
end

function T.detect_compression_is_non_destructive()
  Assert.equal(Narc.detectCompression("\16abcd"), "lz10")
  Assert.equal(Narc.detectCompression("\17abcd"), "lz11")
  Assert.isNil(Narc.detectCompression("NARCdata"))
  Assert.isNil(Narc.detectCompression(""))
end

return { tests = T }
