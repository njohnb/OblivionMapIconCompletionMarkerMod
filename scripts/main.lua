-- This file is part of MapIconCompletionMarkerMod.

print("[MapIconCompletionMarkerMod] MapIconCompletionMarkerMod: script loaded")

-- Includes
local json = require("json")
local Enums = require("enums")
local HookManager = require("hook_manager")
local Config = require("config")

-- State tracking
local wasInWorldMap = false
local wasShiftDown = false
local wasButtonDown = false
local pollingLoopHandle = nil
local hoveredIcon = nil
local loaded = false
local OnFadeToGameBeginEventReceived_Hook = nil

-- Whether we have already warned that controller polling failed (avoids log spam)
local controllerPollWarned = false

-- A list of the keys for all icons that have been toggled off
local toggledIconKeys = {}

-- The directory where the toggled icon list is saved
local saveFileDir = "ue4ss/Mods/MapIconCompletionMarkerMod/"

-- The cached map icons and materials
local cachedMapIconsByKey = {}
local cachedMaterialsByKey = {}

-- The player subsystem, used for input polling
local navInput = FindFirstOf("VUINavigationPlayerSubsystem")

-- The player controller, used for polling controller (gamepad) input
local playerController = FindFirstOf("PlayerController")

--- Checks if the given UObject is valid
local function IsValidObject(obj)
    return obj and obj:IsValid()
end

--- Delays execution of the given callback by a number of seconds
local function Delay(seconds, callback)
    local startTime = os.clock()
    LoopAsync(50, function()
        if os.clock() - startTime >= seconds then
            callback()
            return true
        end
        return false
    end)
end

--- Gets the player name
local function GetPlayerName()
    local subsystem = FindFirstOf("VAltarUISubsystem")
    if not IsValidObject(subsystem) then
        return nil
    end

    local playerName = subsystem:GetPlayerNameTextFromLastLoadedSave()
    return playerName:ToString()
end

--- Gets the file path where the toggled icon list is saved
local function GetJsonFilePath()
    local playerName = GetPlayerName()
    local path = saveFileDir .. playerName .. "_toggled_icons.json"
    return path
end

--- Retrieves the saved list of toggled icons from the json file
local function LoadToggledIcons()
    local path = GetJsonFilePath()
    local file = io.open(GetJsonFilePath(), "r")
    if not file then
        print("[MapIconCompletionMarkerMod] [DEBUG] Toggled icon file not found, creating new one: " .. path)
        local newFile = io.open(path, "w")
        if newFile then
            newFile:write("{}")
            newFile:close()
        else
            print("[MapIconCompletionMarkerMod] [ERROR] Failed to create file: " .. path)
        end
        return
    end

    local contents = file:read("*a")
    file:close()

    -- Ignore the file contents if empty
    if not contents or contents:match("^%s*$") then return end

    local success, data = pcall(json.decode, contents)
    if success and type(data) == "table" then
        toggledIconKeys = data
    end
end

--- Saves current list of toggled icons to json
local function SaveToggledIcons()
    local file = io.open(GetJsonFilePath(), "w")
    if not file then return end

    local contents = json.encode(toggledIconKeys)
    file:write(contents)
    file:close()
end

--- Caches materials into a table indexed by their key
local function GetMaterial(materialPath)
    if not cachedMaterialsByKey[materialPath] then
        local material = StaticFindObject(materialPath)
        if not material then
            print("[MapIconCompletionMarkerMod] [ERROR] Material not found: " .. tostring(materialPath))
        end
        cachedMaterialsByKey[materialPath] = material
    end
    return cachedMaterialsByKey[materialPath]
end

--- Caches map icons into a table indexed by their key
local function CacheMapIcons()
    cachedMapIconsByKey = {}
    local mapIcons = FindAllOf("WBP_Modern_MapIcon_C")
    for _, mapIcon in ipairs(mapIcons) do
        if IsValidObject(mapIcon) then
            local key = mapIcon.Properties.Key:ToString()
            if key ~= "None" then
                cachedMapIconsByKey[key] = mapIcon
            end
        end
    end
end

--- Hook into map icon hovered event
local function HookIconHovered()
    HookManager.Register("IconHovered", "/Game/UI/Original/GameMenuLayer/Map/WBP_Modern_MapWidget.WBP_Modern_MapWidget_C:OnIconHovered", function(_, params)
        local mapIcon = params[1]
        if IsValidObject(mapIcon) then
            hoveredIcon = mapIcon
        end
    end)
end

--- Hook into map icon unhovered event
local function HookIconUnhovered()
    HookManager.Register("IconUnhovered", "/Game/UI/Original/GameMenuLayer/Map/WBP_Modern_MapWidget.WBP_Modern_MapWidget_C:OnIconUnhovered", function(_, params)
        hoveredIcon = nil
    end)
end

--- Hook into the controller virtual-cursor hover event.
--- When navigating the map with a controller, the game drives a virtual
--- cursor and fires OnCursorHoverIcon instead of the mouse OnIconHovered.
--- Wrapped in pcall so a missing/renamed function never breaks mouse support.
local function HookCursorHoverIcon()
    local ok = pcall(function()
        HookManager.Register("CursorHoverIcon", "/Game/UI/Original/GameMenuLayer/Map/WBP_Modern_MapWidget.WBP_Modern_MapWidget_C:OnCursorHoverIcon", function(_, params)
            local mapIcon = params[1]
            if IsValidObject(mapIcon) then
                hoveredIcon = mapIcon
            end
        end)
    end)
    if not ok then
        print("[MapIconCompletionMarkerMod] [WARN] Could not hook OnCursorHoverIcon; controller hover may be unavailable")
    end
end

--- Hook into the controller virtual-cursor unhover event.
local function HookCursorUnhoverIcon()
    local ok = pcall(function()
        HookManager.Register("CursorUnhoverIcon", "/Game/UI/Original/GameMenuLayer/Map/WBP_Modern_MapWidget.WBP_Modern_MapWidget_C:OnCursorUnhoverIcon", function(_, params)
            hoveredIcon = nil
        end)
    end)
    if not ok then
        print("[MapIconCompletionMarkerMod] [WARN] Could not hook OnCursorUnhoverIcon; controller hover may be unavailable")
    end
end

--- Toggles the map icon's material between "on" and "off" state
local function ToggleIconState(mapIcon)
    if not IsValidObject(mapIcon) then return end

    local mapIconKey = mapIcon.Properties.Key:ToString()
    local mapIconType = mapIcon.Properties.Type

    local newMaterialPath
    if toggledIconKeys[mapIconKey] then
        -- The icon is toggled off, set it back to on
        newMaterialPath = Enums.iconMaterialsOn[mapIconType]
    else
        -- The icon is on, toggle it off
        newMaterialPath = Enums.iconMaterialsOff[mapIconType]
    end

    local newMaterial = GetMaterial(newMaterialPath)
    if newMaterial then
        if toggledIconKeys[mapIconKey] then
            toggledIconKeys[mapIconKey] = nil
        else
            toggledIconKeys[mapIconKey] = true
        end

        mapIcon.Icon:SetBrushFromMaterial(newMaterial)
        SaveToggledIcons()
    else
        print("[MapIconCompletionMarkerMod] [ERROR] Material not found for type: " .. tostring(mapIconType))
    end
end

--- Checks whether the configured controller button is currently held.
--- Uses UObject reflection to call the PlayerController's reflected
--- IsInputKeyDown UFUNCTION with a gamepad FKey. Verified to work on the
--- world map for D-pad, X, B, Y, shoulders and triggers. Note that the map
--- consumes A (Gamepad_FaceButton_Bottom) for "travel/select", so that button
--- never reaches this poll -- see config.lua. Fully guarded so a lookup or
--- reflection failure can never break Shift/mouse support.
local function IsControllerButtonDown()
    if not IsValidObject(playerController) then
        playerController = FindFirstOf("PlayerController")
        if not IsValidObject(playerController) then return false end
    end

    local ok, result = pcall(function()
        return playerController:IsInputKeyDown({ KeyName = FName(Config.controllerButton) })
    end)

    if not ok then
        if not controllerPollWarned then
            controllerPollWarned = true
            print("[MapIconCompletionMarkerMod] [WARN] Controller input poll failed (IsInputKeyDown): " .. tostring(result))
        end
        return false
    end

    return result == true
end

--- Starts polling for user input (Shift/controller button + Hover)
local function StartInputPollingLoop()
    if pollingLoopHandle then return end

    pollingLoopHandle = LoopAsync(30, function()
        local success, err = pcall(function()
            -- Keyboard: Shift key
            if not IsValidObject(navInput) then
                navInput = FindFirstOf("VUINavigationPlayerSubsystem")
            end
            local shiftDown = IsValidObject(navInput) and navInput:IsShiftKeyDown() or false

            -- Controller: configured gamepad button
            local buttonDown = IsControllerButtonDown()

            -- Rising-edge detection for each input source
            local shiftPressed = shiftDown and not wasShiftDown
            local buttonPressed = buttonDown and not wasButtonDown

            if (shiftPressed or buttonPressed) and hoveredIcon then
                ToggleIconState(hoveredIcon)
            end

            wasShiftDown = shiftDown
            wasButtonDown = buttonDown
        end)

        return false
    end)
end

--- Stops polling for user input
local function StopInputPollingLoop()
    if pollingLoopHandle then
        pollingLoopHandle:Cancel()
        pollingLoopHandle = nil
    end
    wasShiftDown = false
    wasButtonDown = false
end

--- Determines whether the player is currently viewing the world map
local function IsOnWorldMapPage()
    local playerMenu = FindFirstOf("VLegacyPlayerMenu")
    if not IsValidObject(playerMenu) then return false end

    local playerMenuViewModel = playerMenu:GetViewModelRef()
    if not IsValidObject(playerMenuViewModel) then return false end

    if not playerMenuViewModel:IsVisible() then return false end

    -- Check if the player is on the map page
    local currentPage = playerMenuViewModel:GetCurrentPage()
    if currentPage ~= Enums.ELegacyPlayerMenuPage.Map then return false end

    -- Check if the player is on the world map page
    local VMapMenuViewModel = FindFirstOf("VMapMenuViewModel")
    if not IsValidObject(VMapMenuViewModel) then return false end

    return VMapMenuViewModel.CurrentPage == Enums.ELegacyMapMenuPage.WorldMap
end

--- Updates the material of all cached icons based on toggled state
local function ApplyToggledIcons()
    local keysPending = {}
    local count = 0
    for key, _ in pairs(toggledIconKeys) do
        count = count + 1
        local mapIcon = cachedMapIconsByKey[key]

        if not IsValidObject(mapIcon) then
            table.insert(keysPending, key)
        else
            local mapIconType = mapIcon.Properties.Type
            local materialPath = Enums.iconMaterialsOff[mapIconType]
            local material = GetMaterial(materialPath)
            if material then
                mapIcon.Icon:SetBrushFromMaterial(material)
                mapIcon.Icon:InvalidateLayoutAndVolatility()
            else
                print("[MapIconCompletionMarkerMod] [ERROR] Material not found for type: " .. tostring(mapIconType))
                table.insert(keysPending, key)
            end
        end
    end

    -- Retry once after a short delay if any icons were missing
    if #keysPending > 0 then
        Delay(Config.delaySeconds, function()
            if not IsOnWorldMapPage() then return end
            CacheMapIcons()
            for _, key in ipairs(keysPending) do
                local mapIcon = cachedMapIconsByKey[key]
                if IsValidObject(mapIcon) then
                    local mapIconType = mapIcon.Properties.Type
                    local materialPath = Enums.iconMaterialsOff[mapIconType]
                    local material = StaticFindObject(materialPath, nil)
                    if material then
                        mapIcon.Icon:SetBrushFromMaterial(material)
                        print("[MapIconCompletionMarkerMod] [DEBUG] (Retry) Applied off material to " .. key)
                    else
                        print("[MapIconCompletionMarkerMod] [ERROR] (Retry) Material not found for type: " .. tostring(mapIconType))
                    end
                else
                    print("[MapIconCompletionMarkerMod] [ERROR] Still missing map icon with key: " .. key)
                end
            end
        end)
    end
end

-- Main map page watcher loop
LoopAsync(200, function()
    if not loaded then
        local playerName = GetPlayerName()
        if playerName == nil or playerName == "" then
            return false
        else
            LoadToggledIcons()
            HookIconHovered()
            HookIconUnhovered()
            HookCursorHoverIcon()
            HookCursorUnhoverIcon()
            loaded = true
        end
    end

    local isInWorldMap = IsOnWorldMapPage()
    if isInWorldMap and not wasInWorldMap then
        Delay(Config.delaySeconds, function()
            if IsOnWorldMapPage() then
                cachedMapIconsByKey = {}
                cachedMaterialsByKey = {}
                CacheMapIcons()
                ApplyToggledIcons()
                StartInputPollingLoop()
            end
        end)
    end

    if not isInWorldMap and wasInWorldMap then
        StopInputPollingLoop()
    end

    wasInWorldMap = isInWorldMap
    return false
end)