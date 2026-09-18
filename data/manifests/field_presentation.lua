-- Project-owned field presentation tuning. resizeCompensation controls how much
-- window-height growth becomes additional visible world instead of larger map
-- pixels: 0 keeps current framing, 1 keeps approximate pixel size. input is the
-- single bindings table for the semantic Action/Cancel/Menu buttons;
-- gamepad buttons are fixed by LÖVE convention (south "a" / east "b" / west
-- "x" maps to the menu button).

return {
  fieldScale = {
    baseCameraZoom = 1,
    minCameraZoom = 0.5,
    maxCameraZoom = 1.5,
    referenceHeight = 600,
    resizeCompensation = 0.7,
  },
  input = {
    action = { "z", "space", "return", "kpenter" },
    cancel = { "x", "backspace" },
    menu = { "m" },
  },
}
