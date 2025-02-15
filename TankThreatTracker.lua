-- Create the main frame for the addon
local TankThreatTracker = CreateFrame("Frame", "TankThreatTrackerFrame", UIParent)
TankThreatTracker:SetSize(250, 50)
TankThreatTracker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
TankThreatTracker:SetMovable(true)
TankThreatTracker:EnableMouse(true)
TankThreatTracker:RegisterForDrag("LeftButton")
TankThreatTracker:SetScript("OnDragStart", TankThreatTracker.StartMoving)
TankThreatTracker:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Store all position information
    self.savedPosition = {self:GetPoint()}
end)

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
local activeUnits = {}
local threatCache = {}
local THREAT_CACHE_TIMEOUT = 5.0
local COMBAT_CHECK_INTERVAL = 0.2
local lastCombatCheck = 0
local THREAT_UNIT_TIMEOUT = 10  -- Keep units in the threat window for 10 seconds after last seen
local trackedUnits = {}

-- Create fixed-size header frame
local header = CreateFrame("Frame", nil, TankThreatTracker)
header:SetHeight(24)
header:SetPoint("TOP", TankThreatTracker, "TOP", 0, 0)
header:SetPoint("LEFT", TankThreatTracker, "LEFT", 0, 0)
header:SetPoint("RIGHT", TankThreatTracker, "RIGHT", 0, 0)
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")

-- Create content frame that will expand
local contentFrame = CreateFrame("Frame", nil, TankThreatTracker)
contentFrame:SetPoint("TOP", header, "BOTTOM", 0, 0)
contentFrame:SetPoint("LEFT", TankThreatTracker, "LEFT", 0, 0)
contentFrame:SetPoint("RIGHT", TankThreatTracker, "RIGHT", 0, 0)
contentFrame:SetHeight(26)  -- Initial minimum height

-- Add backgrounds
local bg = contentFrame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(contentFrame)
bg:SetColorTexture(0, 0, 0, 0.35)

local headerBg = header:CreateTexture(nil, "BACKGROUND")
headerBg:SetAllPoints(header)
headerBg:SetColorTexture(0, 0, 0, 0.7)

-- Create border function
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

-- Add borders to both frames
CreateBorderLine(header, "TOP")
CreateBorderLine(header, "LEFT")
CreateBorderLine(header, "RIGHT")
CreateBorderLine(contentFrame, "BOTTOM")
CreateBorderLine(contentFrame, "LEFT")
CreateBorderLine(contentFrame, "RIGHT")

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

-- Set up header scripts
header:SetScript("OnDragStart", function(self)
    TankThreatTracker:StartMoving()
end)

header:SetScript("OnDragStop", function(self)
    TankThreatTracker:StopMovingOrSizing()
end)

header:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
        UIDropDownMenu_Initialize(dropDown, InitializeDropDown)
        ToggleDropDownMenu(1, nil, dropDown, "cursor", 0, 0)
    end
end)

-- Add title to header
local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", header, "TOPLEFT", 8, -6)
title:SetText("Threat Watcher")
title:SetTextColor(1, 1, 1, 1)

local function UpdateFrameSize(width, height)
    local point, relativeTo, relativePoint, x, y = TankThreatTracker:GetPoint()
    
    -- Preserve the original anchoring method
    TankThreatTracker:ClearAllPoints()
    TankThreatTracker:SetSize(width, height)
    TankThreatTracker:SetPoint(point, relativeTo, relativePoint, x, y)
end

local function ResetTankThreatTrackerPosition()
    TankThreatTracker:ClearAllPoints()
    TankThreatTracker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    TankThreatTracker:SetSize(250, 50)
    
    -- Reset saved position
    if TankThreatTracker.savedPosition then
        TankThreatTracker.savedPosition = nil
    end
    
    -- Reset database position if it exists
    if TankThreatTrackerDB and TankThreatTrackerDB.position then
        TankThreatTrackerDB.position = nil
    end
    
    print("Tank Threat Tracker position reset to center of screen")
end

-- Function to check if a unit is actually in combat with us
local function IsActuallyInCombat(guid, unit)
    if lastCombatTime[guid] and (GetTime() - lastCombatTime[guid] < 5) then
        return true
    end
    
    if unit and UnitExists(unit) then
        return UnitAffectingCombat(unit) and UnitCanAttack("player", unit)
    end
    
    return false
end

-- Function to handle combat log events
local function HandleCombatLogEvent(...)
    local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags = ...
    
    if eventType:match("_DAMAGE") or eventType:match("_HEAL") or eventType:match("_AURA") or eventType:match("_THREAT") then
        local function TrackUnit(guid, name, flags)
            if guid and name and bit.band(flags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
                activeCombatUnits[guid] = true
                mobNames[guid] = name
                lastCombatTime[guid] = GetTime()
            end
        end
        
        if bit.band(sourceFlags or 0, COMBATLOG_OBJECT_TYPE_NPC) > 0 then
            TrackUnit(sourceGUID, sourceName, sourceFlags)
        end
        if bit.band(destFlags or 0, COMBATLOG_OBJECT_TYPE_NPC) > 0 then
            TrackUnit(destGUID, destName, destFlags)
        end
    end
end

-- Function to check if unit is valid for combat tracking
local function IsValidCombatUnit(guid)
    if not guid then return false end
    
    local currentTime = GetTime()
    
    -- Check if unit is in active threat cache
    if threatCache[guid] and (currentTime - threatCache[guid].time) < THREAT_CACHE_TIMEOUT then
        return true
    end
    
    -- Check tracked units with extended timeout
    local trackedUnit = trackedUnits[guid]
    if trackedUnit and (currentTime - trackedUnit.lastSeenTime) < THREAT_UNIT_TIMEOUT then
        return true
    end
    
    local function CheckUnit(unit)
        if UnitExists(unit) and UnitGUID(unit) == guid then
            return UnitAffectingCombat(unit) and UnitCanAttack("player", unit)
        end
        return false
    end
    
    if CheckUnit("target") or CheckUnit("mouseover") then
        return true
    end
    
    for i = 1, 40 do
        if CheckUnit("nameplate"..i) then
            return true
        end
    end
    
    return false
end

-- Function to update threat cache
local function UpdateThreatCache(guid, name, isTanking, status, threatPct)
    if not threatCache[guid] then
        threatCache[guid] = {}
    end
    
    local currentTime = GetTime()
    threatCache[guid] = {
        name = name,
        isTanking = isTanking,
        status = status,
        threatPct = threatPct,
        time = currentTime,
        lastCombatTime = currentTime
    }
    activeUnits[guid] = true
    
    -- Track when we last saw this unit
    if not trackedUnits[guid] then
        trackedUnits[guid] = {
            firstSeenTime = currentTime,
            name = name
        }
    end
    trackedUnits[guid].lastSeenTime = currentTime
end

-- Function to scan for hostile units
local function ScanForHostileUnits()
    local function CheckUnit(unit)
        if UnitExists(unit) then
            local canAttack = UnitCanAttack("player", unit)
            local inCombat = UnitAffectingCombat("player")
            local guid = UnitGUID(unit)
            local name = UnitName(unit)
            
            if canAttack and inCombat and guid and name then
                activeCombatUnits[guid] = true
                mobNames[guid] = name
                lastCombatTime[guid] = GetTime()
            end
        end
    end

    CheckUnit("target")
    CheckUnit("targettarget")
    CheckUnit("focus")
    CheckUnit("focustarget")
    
    for i = 1, 40 do
        CheckUnit("nameplate"..i)
    end
    
    if IsInGroup() then
        local prefix = IsInRaid() and "raid" or "party"
        local count = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
        for i = 1, count do
            CheckUnit(prefix..i.."target")
        end
    end
end

-- Modified UpdateThreatData function with new frame structure
local function UpdateThreatData()
    if not UnitAffectingCombat("player") then 
        -- When out of combat, clear units that are no longer relevant
        local currentTime = GetTime()
        for guid, unitInfo in pairs(trackedUnits) do
            -- Only remove if the unit was not seen in combat for a long time
            if (currentTime - unitInfo.lastSeenTime) >= 300 then  -- 5 minutes
                trackedUnits[guid] = nil
                threatCache[guid] = nil
            end
        end
        
        wipe(activeUnits)
        return 
    end
    
    local currentTime = GetTime()
    
    -- Update combat check timer
    if currentTime - lastCombatCheck >= COMBAT_CHECK_INTERVAL then
        lastCombatCheck = currentTime
        
        -- Process target
        if UnitExists("target") and UnitCanAttack("player", "target") then
            local guid = UnitGUID("target")
            local name = UnitName("target")
            local isTanking, status, threatPct = UnitDetailedThreatSituation("player", "target")
            
            if guid and name and threatPct then
                UpdateThreatCache(guid, name, isTanking, status, threatPct)
            end
        end
        
        -- Process mouseover
        if UnitExists("mouseover") and UnitCanAttack("player", "mouseover") then
            local guid = UnitGUID("mouseover")
            local name = UnitName("mouseover")
            local isTanking, status, threatPct = UnitDetailedThreatSituation("player", "mouseover")
            
            if guid and name and threatPct then
                UpdateThreatCache(guid, name, isTanking, status, threatPct)
            end
        end
    end
    
    -- Clear previous visual elements
    for i = 1, #mobThreatTable do
        if mobThreatTable[i] then
            mobThreatTable[i]:Hide()
        end
    end
    wipe(mobThreatTable)
    
    -- Find unit with 100% threat (excluding player)
    local hundredPercentUnit = nil
    for guid, data in pairs(threatCache) do
        if IsValidCombatUnit(guid) and data.threatPct == 100 and not UnitIsUnit(data.name, "player") then
            hundredPercentUnit = data
            break
        end
    end
    
    -- Display all active units
    local index = 0
    local totalHeight = 6  -- Start with padding
    
    -- Display 100% threat unit first if found
    if hundredPercentUnit then
        index = index + 1
        
        local mobText = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        table.insert(mobThreatTable, mobText)
        
        mobText:ClearAllPoints()
        mobText:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 8, -(6 + (20 * (index - 1))))
        mobText:SetWidth(300)
        
        local text = string.format("%s: 100%%", hundredPercentUnit.name)
        mobText:SetText(text)
        mobText:SetTextColor(1, 0.1, 0.1)  -- Red color for 100% threat
        mobText:Show()
        
        totalHeight = totalHeight + 20
    end
    
    -- Then display other units
    for guid, data in pairs(threatCache) do
        -- Skip the 100% threat unit we already displayed
        if IsValidCombatUnit(guid) and (not hundredPercentUnit or data ~= hundredPercentUnit) then
            index = index + 1
            
            -- Ensure mobText is created
            local mobText = mobThreatTable[index]
            if not mobText then
                mobText = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                table.insert(mobThreatTable, mobText)
            end
            
            -- Position from top of content frame
            mobText:ClearAllPoints()
            mobText:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 8, -(6 + (20 * (index - 1))))
            mobText:SetWidth(300)
            
            -- Color and text logic remains the same...
            local color = {1, 1, 1} -- default white
            if data.status == 3 then
                color = {1, 0.1, 0.1} -- red (tanking)
            elseif data.status == 2 then
                color = {1, 0.5, 0.25} -- orange (about to pull)
            elseif data.status == 1 then
                color = {1, 1, 0.5} -- yellow (getting there)
            end
            
            local text = string.format("%s: %.1f%%", data.name, data.threatPct)
            mobText:SetText(text)
            mobText:SetTextColor(unpack(color))
            mobText:Show()
            
            totalHeight = totalHeight + 20  -- Add height for each entry
        end
    end
    
    -- Add final padding
    totalHeight = totalHeight + 6
    
    -- Calculate maximum width needed
    local maxWidth = 250
    for i = 1, #mobThreatTable do
        if mobThreatTable[i] and mobThreatTable[i]:IsShown() then
            local width = mobThreatTable[i]:GetStringWidth()
            maxWidth = math.max(maxWidth, width + 20)
        end
    end
    
    -- Update content frame height
    local contentHeight = math.max(26, totalHeight)
    contentFrame:SetHeight(contentHeight)
    
    -- Update main frame size 
    local headerHeight = 24
    local totalFrameHeight = headerHeight + contentHeight
    
    -- Preserve current positioning
    local point, relativeTo, relativePoint, x, y = TankThreatTracker:GetPoint()
    
    -- Adjust y coordinate if necessary to maintain visual position
    if point:find("TOP") then
        -- If already top-anchored, keep the same point
        TankThreatTracker:SetSize(maxWidth, totalFrameHeight)
    else
        -- If not top-anchored, we need to adjust the y coordinate
        local currentHeight = TankThreatTracker:GetHeight()
        y = y + (currentHeight - totalFrameHeight) / 2
        
        TankThreatTracker:ClearAllPoints()
        TankThreatTracker:SetSize(maxWidth, totalFrameHeight)
        TankThreatTracker:SetPoint(point, relativeTo, relativePoint, x, y)
    end
end

-- Visibility handling
function UpdateVisibility()
    if TankThreatTrackerDB.hideOutOfCombat and not UnitAffectingCombat("player") then
        TankThreatTracker:Hide()
    else
        TankThreatTracker:Show()
    end
end

local function HandleUnitRemoval(guid)
    if trackedUnits[guid] then
        trackedUnits[guid] = nil
        threatCache[guid] = nil
    end
end


-- Event handler
TankThreatTracker:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, eventType, _, sourceGUID, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
        
        -- Handle enemy unit death or despawn
        if eventType == "UNIT_DIED" or eventType == "PARTY_KILL" or eventType == "SPELL_INSTAKILL" then
            HandleUnitRemoval(destGUID)
        end
        
        HandleCombatLogEvent(CombatLogGetCurrentEventInfo())
    end

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
        wipe(lastThreatData)
        UpdateVisibility()
    else
        UpdateThreatData()
    end
end)

-- Register all necessary events
TankThreatTracker:RegisterEvent("PLAYER_TARGET_CHANGED")
TankThreatTracker:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
TankThreatTracker:RegisterEvent("UNIT_TARGET")
TankThreatTracker:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
TankThreatTracker:RegisterEvent("PLAYER_REGEN_ENABLED")
TankThreatTracker:RegisterEvent("PLAYER_REGEN_DISABLED")
TankThreatTracker:RegisterEvent("GROUP_ROSTER_UPDATE")
TankThreatTracker:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
TankThreatTracker:RegisterEvent("PLAYER_LOGIN")

-- Slash command
SLASH_TANKTHREATTRACKER1 = "/ttt"
SlashCmdList["TANKTHREATTRACKER"] = function(msg)
    msg = msg:lower()
    if msg == "ooc" then
        TankThreatTrackerDB.hideOutOfCombat = not TankThreatTrackerDB.hideOutOfCombat
        print("Tank Threat Tracker: Out of combat hiding " .. (TankThreatTrackerDB.hideOutOfCombat and "enabled" or "disabled"))
        UpdateVisibility()
    elseif msg == "reset" then
        ResetTankThreatTrackerPosition()
    else
        if TankThreatTracker:IsShown() then
            TankThreatTracker:Hide()
        else
            TankThreatTracker:Show()
        end
        print("Tank Threat Tracker: " .. (TankThreatTracker:IsShown() and "Shown" or "Hidden"))
    end
end