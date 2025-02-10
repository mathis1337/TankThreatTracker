-- Create the main frame for the addon
local TankThreatTracker = CreateFrame("Frame", "TankThreatTrackerFrame", UIParent)
TankThreatTracker:SetSize(250, 50)
TankThreatTracker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
TankThreatTracker:SetMovable(true)
TankThreatTracker:EnableMouse(true)
TankThreatTracker:RegisterForDrag("LeftButton")
TankThreatTracker:SetScript("OnDragStart", TankThreatTracker.StartMoving)
TankThreatTracker:SetScript("OnDragStop", TankThreatTracker.StopMovingOrSizing)

-- Settings DB (saved between sessions)
TankThreatTrackerDB = TankThreatTrackerDB or {
    hideOutOfCombat = false,
}

-- Tables to store combat information
local activeCombatUnits = {}
local mobNames = {}
local lastCombatTime = {}
local mobThreatTable = {}
local lastThreatData = {}

-- Add a clean semi-transparent background
local bg = TankThreatTracker:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(TankThreatTracker)
bg:SetColorTexture(0, 0, 0, 0.35)

-- Create a thin border using a single pixel texture
local function CreateBorderLine(parent, edge, size, r, g, b, a)
    local line = parent:CreateTexture(nil, "BORDER")
    line:SetColorTexture(r or 0, g or 0, b or 0, a or 0.8)
    
    if edge == "TOP" then
        line:SetPoint("TOPLEFT", parent, "TOPLEFT", -1, 1)
        line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 1, 1)
        line:SetHeight(size or 1)
    elseif edge == "BOTTOM" then
        line:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -1, -1)
        line:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 1, -1)
        line:SetHeight(size or 1)
    elseif edge == "LEFT" then
        line:SetPoint("TOPLEFT", parent, "TOPLEFT", -1, 1)
        line:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -1, -1)
        line:SetWidth(size or 1)
    elseif edge == "RIGHT" then
        line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 1, 1)
        line:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 1, -1)
        line:SetWidth(size or 1)
    end
    return line
end

-- Add subtle borders
CreateBorderLine(TankThreatTracker, "TOP")
CreateBorderLine(TankThreatTracker, "BOTTOM")
CreateBorderLine(TankThreatTracker, "LEFT")
CreateBorderLine(TankThreatTracker, "RIGHT")

-- Create the dropdown frame
local dropDown = CreateFrame("Frame", "TankThreatTrackerDropDown", UIParent, "UIDropDownMenuTemplate")

local function InitializeDropDown(frame, level, menuList)
    local info = {
        text = "Hide Out of Combat",
        isNotRadio = true,
        checked = TankThreatTrackerDB.hideOutOfCombat,
        func = function()
            TankThreatTrackerDB.hideOutOfCombat = not TankThreatTrackerDB.hideOutOfCombat
            UpdateVisibility()
        end,
    }
    UIDropDownMenu_AddButton(info)
end

-- Create Header Container (for click handling)
local header = CreateFrame("Frame", nil, TankThreatTracker)
header:SetHeight(20)
header:SetPoint("TOPLEFT", TankThreatTracker, "TOPLEFT", 0, 0)
header:SetPoint("TOPRIGHT", TankThreatTracker, "TOPRIGHT", 0, 0)
header:EnableMouse(true)

header:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
        UIDropDownMenu_Initialize(dropDown, InitializeDropDown)
        ToggleDropDownMenu(1, nil, dropDown, "cursor", 0, 0)
    end
end)

-- Add a title to the frame
local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", header, "TOPLEFT", 8, -6)
title:SetText("Threat Watcher")
title:SetTextColor(1, 1, 1, 1)

-- Function to clean up old combat entries
local function CleanupCombatUnits()
    -- Only clean up if we're in combat
    if not UnitAffectingCombat("player") then
        return
    end

    -- Check each unit
    for guid, _ in pairs(activeCombatUnits) do
        local found = false
        
        -- Check if unit exists in any form
        local function CheckUnit(unit)
            if UnitExists(unit) and UnitGUID(unit) == guid then
                if not UnitIsDead(unit) then
                    found = true
                    return true
                end
            end
            return false
        end
        
        -- Check all possible unit references
        if CheckUnit("target") then
            -- Unit found, do nothing
        elseif CheckUnit("targettarget") then
            -- Unit found, do nothing
        elseif CheckUnit("focus") then
            -- Unit found, do nothing
        elseif CheckUnit("focustarget") then
            -- Unit found, do nothing
        else
            -- Check nameplates
            local nameplateFound = false
            for i = 1, 40 do
                if CheckUnit("nameplate"..i) then
                    nameplateFound = true
                    break
                end
            end
            
            -- If not found in nameplates, check party/raid targets
            if not nameplateFound and not found and IsInGroup() then
                local prefix = IsInRaid() and "raid" or "party"
                local count = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
                for i = 1, count do
                    if CheckUnit(prefix..i.."target") then
                        break
                    end
                end
            end
        end
        
        -- Only remove if unit is actually dead or not found
        if not found then
            activeCombatUnits[guid] = nil
            lastCombatTime[guid] = nil
            mobNames[guid] = nil
        end
    end
end

-- Helper function to find unit by GUID
local function FindUnitByGUID(guid)
    -- Check target
    if UnitExists("target") and UnitGUID("target") == guid then
        return "target"
    end
    
    -- Check party/raid targets
    if IsInGroup() then
        local prefix = IsInRaid() and "raid" or "party"
        local count = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
        for i = 1, count do
            local unit = prefix..i.."target"
            if UnitExists(unit) and UnitGUID(unit) == guid then
                return unit
            end
        end
    end
    
    return nil
end

-- Function to check if a unit is actually in combat with us
local function IsActuallyInCombat(guid, unit)
    -- Check if we've seen combat activity recently
    if lastCombatTime[guid] and (GetTime() - lastCombatTime[guid] < 5) then
        return true
    end
    
    -- Check if the unit exists and is in combat
    if unit and UnitExists(unit) then
        return UnitAffectingCombat(unit) and UnitCanAttack("player", unit)
    end
    
    return false
end

-- First, add a function to get threat info for all group members
local function GetGroupThreatInfo(unit)
    local highestThreat = 0
    local highestPlayer = nil
    local playerCount = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
    local prefix = IsInRaid() and "raid" or "party"
    
    -- Check player first
    local _, _, playerThreat = UnitDetailedThreatSituation("player", unit)
    if playerThreat then
        highestThreat = playerThreat
        highestPlayer = UnitName("player")
    end
    
    -- Check all group members
    for i = 1, playerCount do
        local unitID = prefix..i
        local _, _, threatPercent = UnitDetailedThreatSituation(unitID, unit)
        if threatPercent and threatPercent > highestThreat then
            highestThreat = threatPercent
            highestPlayer = UnitName(unitID)
        end
    end
    
    -- Also check player's pet if exists
    if UnitExists("pet") then
        local _, _, petThreat = UnitDetailedThreatSituation("pet", unit)
        if petThreat and petThreat > highestThreat then
            highestThreat = petThreat
            highestPlayer = UnitName("pet").." (Pet)"
        end
    end
    
    return highestPlayer, highestThreat
end

-- Function to check if we have valid threat data for a GUID
local function GetThreatInfoByGUID(guid)
    local function GetCurrentThreatData(unit)
        if UnitExists(unit) then
            local isTanking, status, threatPercent = UnitDetailedThreatSituation("player", unit)
            if threatPercent then
                -- Get highest threat info before caching
                local highestThreatPlayer, highestThreatPercent = GetGroupThreatInfo(unit)
                
                -- Cache all the data
                lastThreatData[guid] = {
                    isTanking = isTanking,
                    status = status,
                    threatPercent = threatPercent,
                    highestThreatPlayer = highestThreatPlayer,
                    highestThreatPercent = highestThreatPercent,
                    time = GetTime()
                }
                return isTanking, status, threatPercent, unit, highestThreatPlayer, highestThreatPercent
            end
        end
        return nil
    end

    -- Try to get current data from nameplates first
    for i = 1, 40 do
        local unit = "nameplate"..i
        if UnitExists(unit) and UnitGUID(unit) == guid then
            local result = {GetCurrentThreatData(unit)}
            if result[1] then 
                return unpack(result)
            end
        end
    end
    
    -- Check target and other direct references
    local unitTypes = {"target", "targettarget", "focus", "focustarget"}
    for _, unit in ipairs(unitTypes) do
        if UnitExists(unit) and UnitGUID(unit) == guid then
            local result = {GetCurrentThreatData(unit)}
            if result[1] then 
                return unpack(result)
            end
        end
    end
    
    -- Check group targets
    if IsInGroup() then
        local prefix = IsInRaid() and "raid" or "party"
        local count = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
        for i = 1, count do
            local unit = prefix..i.."target"
            if UnitExists(unit) and UnitGUID(unit) == guid then
                local result = {GetCurrentThreatData(unit)}
                if result[1] then 
                    return unpack(result)
                end
            end
        end
    end
    
    -- If we couldn't get current data, use cached data if it's recent enough
    if lastThreatData[guid] then
        local cachedData = lastThreatData[guid]
        if GetTime() - cachedData.time < 2 then  -- Use cached data for up to 2 seconds
            return cachedData.isTanking, cachedData.status, cachedData.threatPercent, nil,
                   cachedData.highestThreatPlayer, cachedData.highestThreatPercent
        end
    end
    
    return nil
end




-- Function to handle combat log events
local function HandleCombatLogEvent(...)
    local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags = ...
    
    -- Track any combat event
    if eventType:match("_DAMAGE") or eventType:match("_HEAL") or eventType:match("_AURA") or eventType:match("_THREAT") then
        -- Function to track hostile units
        local function TrackUnit(guid, name, flags)
            if guid and name and bit.band(flags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
                activeCombatUnits[guid] = true
                mobNames[guid] = name
                lastCombatTime[guid] = GetTime()
            end
        end
        
        -- Track source and destination
        if bit.band(sourceFlags or 0, COMBATLOG_OBJECT_TYPE_NPC) > 0 then
            TrackUnit(sourceGUID, sourceName, sourceFlags)
        end
        if bit.band(destFlags or 0, COMBATLOG_OBJECT_TYPE_NPC) > 0 then
            TrackUnit(destGUID, destName, destFlags)
        end
    end
end

-- Function to handle visibility based on combat state
function UpdateVisibility()
    if TankThreatTrackerDB.hideOutOfCombat and not UnitAffectingCombat("player") then
        TankThreatTracker:Hide()
    else
        TankThreatTracker:Show()
    end
end

-- Function to scan for hostile units
local function ScanForHostileUnits()
    local function CheckUnit(unit)
        if UnitExists(unit) and 
           UnitCanAttack("player", unit) and 
           UnitAffectingCombat("player") then  -- Only check if we're in combat
            local guid = UnitGUID(unit)
            local name = UnitName(unit)
            if guid and name then
                activeCombatUnits[guid] = true
                mobNames[guid] = name
                lastCombatTime[guid] = GetTime()
            end
        end
    end

    -- Check target and target of target
    CheckUnit("target")
    CheckUnit("targettarget")
    CheckUnit("focus")
    CheckUnit("focustarget")
    
    -- Check nameplates (most reliable for multiple targets)
    for i = 1, 40 do
        CheckUnit("nameplate"..i)
    end
    
    -- Check party/raid targets
    if IsInGroup() then
        local prefix = IsInRaid() and "raid" or "party"
        local count = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
        for i = 1, count do
            CheckUnit(prefix..i.."target")
        end
    end
end

-- UpdateThreatData function to include the highest threat info
local function UpdateThreatData()
    -- Only update if we're in combat
    if not UnitAffectingCombat("player") then
        return
    end

    -- Scan for any new hostile units
    ScanForHostileUnits()
    
    -- Clean up old combat entries first
    CleanupCombatUnits()

    -- Clear previous visual elements
    for i = 1, #mobThreatTable do
        mobThreatTable[i]:Hide()
    end
    wipe(mobThreatTable)

    -- Process all known combat units
    local index = 0
    for guid, _ in pairs(activeCombatUnits) do
        -- Get threat data specifically for this unit
        local isTanking, status, threatPercent, foundUnit, highestPlayer, highestPercent = GetThreatInfoByGUID(guid)
        
        if (threatPercent or (lastThreatData[guid] and GetTime() - lastThreatData[guid].time < 2)) and mobNames[guid] then
            index = index + 1
            
            -- If we don't have current threat data, use cached data
            if not threatPercent and lastThreatData[guid] then
                isTanking = lastThreatData[guid].isTanking
                status = lastThreatData[guid].status
                threatPercent = lastThreatData[guid].threatPercent
                highestPlayer = lastThreatData[guid].highestThreatPlayer
                highestPercent = lastThreatData[guid].highestThreatPercent
            end
            
            -- Create or reuse a line for the mob
            local mobText = mobThreatTable[index]
            if not mobText then
                mobText = TankThreatTracker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                mobText:SetPoint("TOPLEFT", TankThreatTracker, "TOPLEFT", 8, -(24 + (20 * (index - 1))))
                mobText:SetWidth(300)
                table.insert(mobThreatTable, mobText)
            end
            
            -- Color code based on threat situation
            local color = {1, 1, 1} -- default white
            if status == 3 then
                color = {1, 0.1, 0.1} -- red (tanking)
            elseif status == 2 then
                color = {1, 0.5, 0.25} -- orange (about to pull)
            elseif status == 1 then
                color = {1, 1, 0.5} -- yellow (getting there)
            end
            
            -- Format text with colored player name using WoW color codes
            local text = string.format("%s: %.1f%% ", mobNames[guid], threatPercent or 0)
            if highestPlayer and highestPlayer ~= UnitName("player") then
                text = text .. string.format("(Top: |cffA335EE%s|r - %.1f%%)", highestPlayer, highestPercent)
            end
            
            mobText:SetText(text)
            mobText:SetTextColor(unpack(color))
            mobText:Show()
        end
    end
    
    -- Adjust frame size based on content
    local height = math.max(50, 30 + (index * 20))
    local maxWidth = 250
    for i = 1, #mobThreatTable do
        if mobThreatTable[i]:IsShown() then
            local width = mobThreatTable[i]:GetStringWidth()
            maxWidth = math.max(maxWidth, width + 20)
        end
    end
    
    TankThreatTracker:SetWidth(maxWidth)
    TankThreatTracker:SetHeight(height)
    
    if bg then
        bg:SetAllPoints(TankThreatTracker)
    end
end

-- Register events
TankThreatTracker:RegisterEvent("PLAYER_TARGET_CHANGED")
TankThreatTracker:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
TankThreatTracker:RegisterEvent("PLAYER_REGEN_ENABLED")
TankThreatTracker:RegisterEvent("PLAYER_REGEN_DISABLED")
TankThreatTracker:RegisterEvent("GROUP_ROSTER_UPDATE")
TankThreatTracker:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
TankThreatTracker:RegisterEvent("PLAYER_LOGIN")

-- Event handler
TankThreatTracker:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        TankThreatTrackerDB = TankThreatTrackerDB or {
            hideOutOfCombat = false,
        }
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        HandleCombatLogEvent(CombatLogGetCurrentEventInfo())
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat
        UpdateVisibility()
        self:SetScript("OnUpdate", function(self, elapsed)
            self.updateTimer = (self.updateTimer or 0) + elapsed
            if self.updateTimer >= 0.2 then
                UpdateThreatData()
                self.updateTimer = 0
            end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat - clear everything
        self:SetScript("OnUpdate", nil)
        for i = 1, #mobThreatTable do
            mobThreatTable[i]:Hide()
        end
        wipe(mobThreatTable)
        wipe(activeCombatUnits)
        wipe(mobNames)
        wipe(lastCombatTime)
        wipe(lastThreatData)  -- Clear cached threat data
        UpdateVisibility()
    else
        UpdateThreatData()
    end
end)

-- Slash command to toggle the window and handle out-of-combat visibility
SLASH_TANKTHREATTRACKER1 = "/ttt"
SlashCmdList["TANKTHREATTRACKER"] = function(msg)
    msg = msg:lower()
    if msg == "ooc" then
        TankThreatTrackerDB.hideOutOfCombat = not TankThreatTrackerDB.hideOutOfCombat
        print("Tank Threat Tracker: Out of combat hiding " .. (TankThreatTrackerDB.hideOutOfCombat and "enabled" or "disabled"))
        UpdateVisibility()
    else
        if TankThreatTracker:IsShown() then
            TankThreatTracker:Hide()
        else
            TankThreatTracker:Show()
        end
        print("Tank Threat Tracker: " .. (TankThreatTracker:IsShown() and "Shown" or "Hidden"))
    end
end