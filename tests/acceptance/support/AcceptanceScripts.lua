-- Script resources used only by acceptance composition. They are installed
-- through the normal validated override path and never live in production
-- data or the normal runtime registry.

return {
  ["acceptance.field_yes_no"] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "acceptance.field_yes_no",
  steps = {
    S.message({ message = "msg.hgss.0542.00034", waitForPrint = true }),
    S.askYesNo({ result = S.var("VAR_UNK_407C") }),
    S.askYesNo({ result = S.var("VAR_UNK_407D") }),
    S.closeMessage({ erase = true }),
    S.stop(),
  },
})
]],
  ["acceptance.script_runtime"] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "acceptance.script_runtime",
  steps = {
    S.setVar({ variable = "VAR_UNK_407C", value = 7 }),
    S.if_({
      condition = S.eq(S.var("VAR_UNK_407C"), 7),
      yes = { S.setFlag({ flag = "FLAG_UNK_8A1" }) },
      no = { S.setFlag({ flag = "FLAG_UNK_8A2" }) },
    }),
    S.setVar({ variable = "VAR_UNK_407D", value = S.var("VAR_UNK_407C") }),
    S.waitTicks({ ticks = 2 }),
    S.setVar({ variable = "VAR_UNK_407F", value = S.var("VAR_UNK_407D") }),
    S.stop(),
  },
})
]],
  ["demo.signpost"] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "demo.signpost",
  steps = {
    S.sign({
      message = "msg.hgss.0542.00034",
      appearance = "sign",
    }),
    S.trainerTip({
      message = "msg.hgss.0542.00036",
      appearance = "trainer_tip",
    }),
    S.stop(),
  },
})
]],
}
