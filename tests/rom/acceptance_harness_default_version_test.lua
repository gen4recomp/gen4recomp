-- Ready-dump default version contract. The harness resolves its default
-- version from the ready dump set; this check pins that ordering while the
-- synthetic harness mechanics stay in the component suite.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = { tags = { "acceptance-harness" }, capabilities = { "rom_dump" } },
  tests = {},
}

function T.tests.default_version_comes_from_the_ready_dump_set()
  Assert.equal(AcceptanceHarness.defaultVersion(), AcceptanceHarness.new():primaryVersion())
end

return T
