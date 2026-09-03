-- Package error codes for the mon domain. Production code raises these
-- through Errors.raise; tests match on the code. Record validation owns the
-- semantic record shape, native projection owns representability, the codec
-- owns boxed bytes, and the save bucket owns persistence and fingerprints.

local Errors = require("libs.errors.src.Errors")

---@class MonsErrors
local MonsErrors = {}

MonsErrors.RECORD_INVALID = "MON_RECORD_INVALID"
MonsErrors.LEGALITY_INVALID = "MON_LEGALITY_INVALID"
MonsErrors.CODEC_INVALID = "MON_CODEC_INVALID"
MonsErrors.SAVE_INVALID = "MONS_SAVE_INVALID"
MonsErrors.SAVE_FINGERPRINT_MISMATCH = "MONS_SAVE_FINGERPRINT_MISMATCH"

---@param code string
---@param message string
---@param context table<string, Errors.Value>?
function MonsErrors.raise(code, message, context)
  Errors.raise(code, message, context or {})
end

return MonsErrors
