local Assert = require("tests.support.Assert")
local Controller = require("libs.hgss.src.ui.FieldYesNoController")

local T = {}

local function open()
  local controller = Controller.new()
  controller:open({ yesText = "sim", noText = "nao", frameIndex = 2 })
  return controller
end

function T.initial_selection_and_no_wrap()
  local controller = open()
  Assert.equal(controller:status().selectedIndex, 0)
  controller:handleInput({ pressedDirection = "up" })
  Assert.equal(controller:status().selectedIndex, 0)
  controller:handleInput({ pressedDirection = "down" })
  controller:handleInput({ pressedDirection = "down" })
  Assert.equal(controller:status().selectedIndex, 1)
  controller:handleInput({ pressedDirection = "left" })
  Assert.equal(controller:status().selectedIndex, 1)
end

function T.action_and_cancel_return_the_selected_semantics()
  local controller = open()
  controller:handleInput({ pressedAction = true })
  Assert.deepEqual(controller:takeResult(), { accepted = true })
  Assert.isNil(controller:takeResult())
  controller:close()
  controller:open({ yesText = "sim", noText = "nao" })
  controller:handleInput({ pressedDirection = "down", pressedAction = true })
  Assert.deepEqual(controller:takeResult(), { accepted = false })
  controller:close()
  controller:open({ yesText = "sim", noText = "nao" })
  controller:handleInput({ pressedCancel = true })
  Assert.deepEqual(controller:takeResult(), { accepted = false })
end

return { tests = T }
