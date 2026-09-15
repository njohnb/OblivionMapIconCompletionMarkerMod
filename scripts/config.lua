-- This file is part of MapIconCompletionMarkerMod.

return {
    -- The amount of time to delay before rendering icons.
    delaySeconds = 0.5,

    -- The controller button that toggles the hovered icon on/off, as an
    -- Unreal FKey name. This is the controller equivalent of holding Shift.
    -- NOTE: avoid "Gamepad_FaceButton_Bottom" (A / Cross) -- the world map
    -- consumes A for "travel/select", so it never reaches this poll. Buttons
    -- confirmed to register on the map: D-pad (Up/Down/Left/Right),
    -- "Gamepad_FaceButton_Left" (X), "Gamepad_FaceButton_Top" (Y),
    -- "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
    -- "Gamepad_LeftTrigger", "Gamepad_RightTrigger".
    controllerButton = "Gamepad_DPad_Down",
}
