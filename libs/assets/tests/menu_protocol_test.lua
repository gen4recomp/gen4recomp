-- Tests for MenuProtocol: the project-owned list-menu protocol constants.
-- Script lowering (romdump), the script menu host, and menu layout all
-- consume this contract, so the source-bound values live in one place.

local Assert = require("tests.support.Assert")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

local T = {}

function T.protocol_constants_are_stable()
  Assert.equal(MenuProtocol.STANDARD_MESSAGE_BANK, 191)
  Assert.equal(MenuProtocol.START_MENU_MESSAGE_BANK, 196)
  Assert.equal(MenuProtocol.CANCEL_RESULT, 0xFFFE)
  Assert.equal(MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT, "hgss_bottom_screen_tiles")
end

return { tests = T }
