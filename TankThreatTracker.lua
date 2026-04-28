-- =========================================================================
-- TankThreatTracker
-- =========================================================================
-- Threat-watcher window + nameplate glow.
--
-- Why no clickable rows: WoW Classic Era 11403 does not give addons any
-- usable click-to-target primitive. TargetUnit() from a non-secure click is
-- forbidden; SetAttribute() on secure buttons is blocked in combat (even
-- from PreClick); secure type="target" with unit="nameplateN" silently
-- fails; and "/target nameplateN" macros treat the token as a literal name.
--
-- Instead, we GLOW the nameplate of any at-risk mob in the threat cache.
-- The user clicks the actual nameplate in the world (native WoW input, no
-- addon protection issues) to switch target.
-- =========================================================================

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
    self.savedPosition = {self:GetPoint()}
end)

TankThreatTrackerDB = TankThreatTrackerDB or { hideOutOfCombat = false }

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
local THREAT_UNIT_TIMEOUT = 10
local trackedUnits = {}

-- Header frame
local header = CreateFrame("Frame", nil, TankThreatTracker)
header:SetHeight(24)
header:SetPoint("TOP", TankThreatTracker, "TOP", 0, 0)
header:SetPoint("LEFT", TankThreatTracker, "LEFT", 0, 0)
header:SetPoint("RIGHT", TankThreatTracker, "RIGHT", 0, 0)
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")

-- Content frame
local contentFrame = CreateFrame("Frame", nil, TankThreatTracker)
contentFrame:SetPoint("TOP", header, "BOTTOM", 0, 0)
contentFrame:SetPoint("LEFT", TankThreatTracker, "LEFT", 0, 0)
contentFrame:SetPoint("RIGHT", TankThreatTracker, "RIGHT", 0, 0)
contentFrame:SetHeight(26)

-- Backgrounds
local bg = contentFrame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(contentFrame)
bg:SetColorTexture(0, 0, 0, 0.35)

local headerBg = header:CreateTexture(nil, "BACKGROUND")
headerBg:SetAllPoints(header)
headerBg:SetColorTexture(0, 0, 0, 0.7)

-- Border helper
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

CreateBorderLine(header, "TOP")
CreateBorderLine(header, "LEFT")
CreateBorderLine(header, "RIGHT")
CreateBorderLine(contentFrame, "BOTTOM")
CreateBorderLine(contentFrame, "LEFT")
CreateBorderLine(contentFrame, "RIGHT")

-- =========================================================================
-- Nameplate glow
-- =========================================================================
-- We track every nameplate that's currently visible (NAME_PLATE_UNIT_ADDED /
-- _REMOVED), keep a glow texture parented to each plate, and toggle it on
-- per update if the plate's GUID matches a "risky" entry in threatCache.
-- =========================================================================

-- nameplateUnit token -> { frame = nameplateFrame, glow = Texture } map.
local glowByUnit = {}

-- When true, every visible enemy nameplate glows red regardless of threat
-- state. Toggled via "/ttt test". Lets us verify the glow is rendering at
-- all, separate from the threat-detection code path.
local forceGlowTest = false

-- Build a "glow" out of:
--   * a soft halo (UI-ActionButton-Border, additive, low alpha)
--   * four 2px outline bars (WHITE8X8) -- top / bottom / left / right
-- Both `Interface\Buttons\WHITE8X8` and `Interface\Buttons\UI-ActionButton-Border`
-- are known-good Classic Era textures, and the four-bar outline guarantees
-- something visible even if the halo asset doesn't render. The whole thing
-- is wrapped in a small "container" with Show/Hide/SetColor methods.
local function EnsureGlow(nameplate, unit)
    local entry = glowByUnit[unit]
    if entry and entry.frame == nameplate and entry.glow then
        return entry.glow
    end

    local pad      = 4   -- distance from nameplate edge to outline
    local thick    = 2   -- outline thickness
    local haloPad  = 10  -- outer halo extends a bit further out

    -- Soft halo (additive). If the texture asset fails, this just won't draw
    -- but the outline below still will.
    local halo = nameplate:CreateTexture(nil, "OVERLAY")
    halo:SetBlendMode("ADD")
    halo:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    halo:SetPoint("TOPLEFT",     nameplate, "TOPLEFT",     -haloPad,  haloPad)
    halo:SetPoint("BOTTOMRIGHT", nameplate, "BOTTOMRIGHT",   haloPad, -haloPad)

    -- Four outline bars.
    local function bar()
        local t = nameplate:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        return t
    end

    local top    = bar()
    top:SetPoint("TOPLEFT",     nameplate, "TOPLEFT",     -pad,        pad)
    top:SetPoint("TOPRIGHT",    nameplate, "TOPRIGHT",     pad,        pad)
    top:SetHeight(thick)

    local bottom = bar()
    bottom:SetPoint("BOTTOMLEFT",  nameplate, "BOTTOMLEFT",  -pad, -pad)
    bottom:SetPoint("BOTTOMRIGHT", nameplate, "BOTTOMRIGHT",  pad, -pad)
    bottom:SetHeight(thick)

    local left   = bar()
    left:SetPoint("TOPLEFT",    nameplate, "TOPLEFT",    -pad,  pad)
    left:SetPoint("BOTTOMLEFT", nameplate, "BOTTOMLEFT", -pad, -pad)
    left:SetWidth(thick)

    local right  = bar()
    right:SetPoint("TOPRIGHT",    nameplate, "TOPRIGHT",     pad,  pad)
    right:SetPoint("BOTTOMRIGHT", nameplate, "BOTTOMRIGHT",  pad, -pad)
    right:SetWidth(thick)

    local pieces = { halo, top, bottom, left, right }
    local glow = {
        Show = function(self)
            for _, p in ipairs(pieces) do p:Show() end
        end,
        Hide = function(self)
            for _, p in ipairs(pieces) do p:Hide() end
        end,
        SetVertexColor = function(self, r, g, b, a)
            -- Halo gets a softer alpha than the outline.
            halo:SetVertexColor(r, g, b, (a or 1) * 0.6)
            for i = 2, #pieces do
                pieces[i]:SetVertexColor(r, g, b, a or 1)
            end
        end,
    }
    glow:Hide()

    glowByUnit[unit] = { frame = nameplate, glow = glow }
    return glow
end

local function ClearGlow(unit)
    local entry = glowByUnit[unit]
    if entry and entry.glow then entry.glow:Hide() end
    glowByUnit[unit] = nil
end

-- Walk all currently active nameplates; show glow on those whose mob is
-- "risky" (lost-aggro / about-to-pull) per threatCache, hide glow otherwise.
local function UpdateNameplateGlows()
    for i = 1, 40 do
        local unit = "nameplate"..i
        local nameplate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
        if nameplate and UnitExists(unit) then
            local guid = UnitGUID(unit)
            local data = guid and threatCache[guid]
            local risky = false
            local r, g, b = 1, 0.1, 0.1
            if forceGlowTest and UnitCanAttack("player", unit) then
                risky = true
                r, g, b = 1, 0.1, 0.1
            elseif data and not data.isTanking then
                -- Glow only when the player is NOT tanking this mob.
                if data.status == 2 then
                    risky = true; r, g, b = 1, 0.5, 0.25  -- orange: about to pull
                elseif data.status == 1 then
                    risky = true; r, g, b = 1, 1, 0.4     -- yellow: catching up
                else
                    risky = true; r, g, b = 1, 0.1, 0.1   -- red: lost aggro
                end
            end
            local glow = EnsureGlow(nameplate, unit)
            if risky then
                glow:SetVertexColor(r, g, b, 0.9)
                glow:Show()
            else
                glow:Hide()
            end
        end
    end
end

-- Dropdown
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

-- Header drag/right-click
header:SetScript("OnDragStart", function(self) TankThreatTracker:StartMoving() end)
header:SetScript("OnDragStop", function(self) TankThreatTracker:StopMovingOrSizing() end)
header:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
        UIDropDownMenu_Initialize(dropDown, InitializeDropDown)
        ToggleDropDownMenu(1, nil, dropDown, "cursor", 0, 0)
    end
end)

-- Title
local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", header, "TOPLEFT", 8, -6)
title:SetText("Threat Watcher")
title:SetTextColor(1, 1, 1, 1)

local function ResetTankThreatTrackerPosition()
    TankThreatTracker:ClearAllPoints()
    TankThreatTracker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    TankThreatTracker:SetSize(250, 50)
    if TankThreatTracker.savedPosition then TankThreatTracker.savedPosition = nil end
    if TankThreatTrackerDB and TankThreatTrackerDB.position then TankThreatTrackerDB.position = nil end
    print("Tank Threat Tracker position reset to center of screen")
end

local function IsActuallyInCombat(guid, unit)
    if lastCombatTime[guid] and (GetTime() - lastCombatTime[guid] < 5) then return true end
    if unit and UnitExists(unit) then
        return UnitAffectingCombat(unit) and UnitCanAttack("player", unit)
    end
    return false
end

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

local function IsValidCombatUnit(guid)
    if not guid then return false end
    local currentTime = GetTime()
    if threatCache[guid] and (currentTime - threatCache[guid].time) < THREAT_CACHE_TIMEOUT then return true end
    local trackedUnit = trackedUnits[guid]
    if trackedUnit and (currentTime - trackedUnit.lastSeenTime) < THREAT_UNIT_TIMEOUT then return true end
    local function CheckUnit(unit)
        if UnitExists(unit) and UnitGUID(unit) == guid then
            return UnitAffectingCombat(unit) and UnitCanAttack("player", unit)
        end
        return false
    end
    if CheckUnit("target") or CheckUnit("mouseover") then return true end
    for i = 1, 40 do
        if CheckUnit("nameplate"..i) then return true end
    end
    return false
end

local function UpdateThreatCache(guid, name, isTanking, status, threatPct)
    if not threatCache[guid] then threatCache[guid] = {} end
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
    if not trackedUnits[guid] then
        trackedUnits[guid] = { firstSeenTime = currentTime, name = name }
    end
    trackedUnits[guid].lastSeenTime = currentTime
end

-- Main update: refreshes both the threat-watcher rows and nameplate glows.
local function UpdateThreatData()
    if not UnitAffectingCombat("player") then
        local currentTime = GetTime()
        for guid, unitInfo in pairs(trackedUnits) do
            if (currentTime - unitInfo.lastSeenTime) >= 300 then
                trackedUnits[guid] = nil
                threatCache[guid] = nil
            end
        end
        wipe(activeUnits)
        UpdateNameplateGlows()
        return
    end

    local currentTime = GetTime()
    if currentTime - lastCombatCheck >= COMBAT_CHECK_INTERVAL then
        lastCombatCheck = currentTime
        if UnitExists("target") and UnitCanAttack("player", "target") then
            local guid = UnitGUID("target")
            local name = UnitName("target")
            local isTanking, status, threatPct = UnitDetailedThreatSituation("player", "target")
            if guid and name and threatPct then
                UpdateThreatCache(guid, name, isTanking, status, threatPct)
            end
        end
        if UnitExists("mouseover") and UnitCanAttack("player", "mouseover") then
            local guid = UnitGUID("mouseover")
            local name = UnitName("mouseover")
            local isTanking, status, threatPct = UnitDetailedThreatSituation("player", "mouseover")
            if guid and name and threatPct then
                UpdateThreatCache(guid, name, isTanking, status, threatPct)
            end
        end
    end

    -- Hide all rows; we'll re-show as needed.
    for i = 1, #mobThreatTable do
        if mobThreatTable[i] then mobThreatTable[i]:Hide() end
    end

    -- Find unit with 100% threat (excluding player)
    local hundredPercentUnit, hundredPercentGUID
    for guid, data in pairs(threatCache) do
        if IsValidCombatUnit(guid) and data.threatPct == 100 and not UnitIsUnit(data.name, "player") then
            hundredPercentUnit = data
            hundredPercentGUID = guid
            break
        end
    end

    -- Get/create plain (non-secure) display rows. These are FontStrings on a
    -- minimal Frame -- not clickable (Classic doesn't permit it), but they
    -- live freely under contentFrame with no taint issues.
    local function GetRow(index)
        local row = mobThreatTable[index]
        if not row then
            row = CreateFrame("Frame", nil, contentFrame)
            row:SetHeight(18)
            row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 8, -(6 + (index - 1) * 20))
            row:SetPoint("RIGHT",   contentFrame, "RIGHT", -8, 0)
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetAllPoints(row)
            fs:SetJustifyH("LEFT")
            row.text = fs
            mobThreatTable[index] = row
        end
        return row
    end

    local index = 0
    local totalHeight = 6
    local shownRows = {}

    if hundredPercentUnit then
        index = index + 1
        local row = GetRow(index)
        row.text:SetText(string.format("%s: 100%%", hundredPercentUnit.name))
        row.text:SetTextColor(1, 0.1, 0.1)
        row:Show()
        shownRows[#shownRows + 1] = row
        totalHeight = totalHeight + 20
    end

    for guid, data in pairs(threatCache) do
        if IsValidCombatUnit(guid) and (not hundredPercentUnit or data ~= hundredPercentUnit) then
            index = index + 1

            local highestPlayer = nil
            local playerCount = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
            local prefix = IsInRaid() and "raid" or "party"
            local _, _, playerThreat = UnitDetailedThreatSituation("player", "target")
            if playerThreat then highestPlayer = UnitName("player") end
            for i = 1, playerCount do
                local unitID = prefix..i
                local _, _, threatPercent = UnitDetailedThreatSituation(unitID, "target")
                if threatPercent and (not highestPlayer or threatPercent > playerThreat) then
                    highestPlayer = UnitName(unitID)
                    playerThreat = threatPercent
                end
            end

            local color = {1, 1, 1}
            if data.status == 3 then
                color = {1, 0.1, 0.1}
            elseif data.status == 2 then
                color = {1, 0.5, 0.25}
            elseif data.status == 1 then
                color = {1, 1, 0.5}
            end

            local text
            if highestPlayer and highestPlayer ~= UnitName("player") then
                text = string.format("%s: %.1f%% (Top: %s)", data.name, data.threatPct, highestPlayer)
            else
                text = string.format("%s: %.1f%%", data.name, data.threatPct)
            end

            local row = GetRow(index)
            row.text:SetText(text)
            row.text:SetTextColor(color[1], color[2], color[3])
            row:Show()
            shownRows[#shownRows + 1] = row
            totalHeight = totalHeight + 20
        end
    end

    totalHeight = totalHeight + 6

    local maxWidth = 250
    for i = 1, #shownRows do
        local r = shownRows[i]
        if r and r.text then
            local width = r.text:GetStringWidth()
            maxWidth = math.max(maxWidth, width + 20)
        end
    end

    local contentHeight = math.max(26, totalHeight)
    contentFrame:SetHeight(contentHeight)
    local headerHeight = 24
    local totalFrameHeight = headerHeight + contentHeight

    local point, relativeTo, relativePoint, x, y = TankThreatTracker:GetPoint()
    if point and point:find("TOP") then
        TankThreatTracker:SetSize(maxWidth, totalFrameHeight)
    else
        local currentHeight = TankThreatTracker:GetHeight()
        y = (y or 0) + (currentHeight - totalFrameHeight) / 2
        TankThreatTracker:ClearAllPoints()
        TankThreatTracker:SetSize(maxWidth, totalFrameHeight)
        TankThreatTracker:SetPoint(point, relativeTo, relativePoint, x, y)
    end

    UpdateNameplateGlows()
end

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
        if eventType == "UNIT_DIED" or eventType == "PARTY_KILL" or eventType == "SPELL_INSTAKILL" then
            HandleUnitRemoval(destGUID)
        end
        HandleCombatLogEvent(CombatLogGetCurrentEventInfo())

    elseif event == "PLAYER_LOGIN" then
        TankThreatTrackerDB = TankThreatTrackerDB or { hideOutOfCombat = false }

    elseif event == "PLAYER_REGEN_DISABLED" then
        UpdateVisibility()
        self:SetScript("OnUpdate", function(self, elapsed)
            self.updateTimer = (self.updateTimer or 0) + elapsed
            if self.updateTimer >= 0.2 then
                UpdateThreatData()
                self.updateTimer = 0
            end
        end)

    elseif event == "PLAYER_REGEN_ENABLED" then
        self:SetScript("OnUpdate", nil)
        for i = 1, #mobThreatTable do mobThreatTable[i]:Hide() end
        wipe(activeCombatUnits)
        wipe(mobNames)
        wipe(lastCombatTime)
        wipe(lastThreatData)
        UpdateNameplateGlows()
        UpdateVisibility()

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local unit = ...
        local nameplate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
        if nameplate then EnsureGlow(nameplate, unit) end
        UpdateNameplateGlows()

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local unit = ...
        ClearGlow(unit)

    else
        UpdateThreatData()
    end
end)

-- Register events
TankThreatTracker:RegisterEvent("PLAYER_TARGET_CHANGED")
TankThreatTracker:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
TankThreatTracker:RegisterEvent("UNIT_TARGET")
TankThreatTracker:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
TankThreatTracker:RegisterEvent("PLAYER_REGEN_ENABLED")
TankThreatTracker:RegisterEvent("PLAYER_REGEN_DISABLED")
TankThreatTracker:RegisterEvent("GROUP_ROSTER_UPDATE")
TankThreatTracker:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
TankThreatTracker:RegisterEvent("PLAYER_LOGIN")
TankThreatTracker:RegisterEvent("NAME_PLATE_UNIT_ADDED")
TankThreatTracker:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

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
    elseif msg == "test" then
        forceGlowTest = not forceGlowTest
        print("Tank Threat Tracker: glow test mode " .. (forceGlowTest and "ON (every enemy nameplate glows red)" or "OFF"))
        UpdateNameplateGlows()
    else
        if TankThreatTracker:IsShown() then
            TankThreatTracker:Hide()
        else
            TankThreatTracker:Show()
        end
        print("Tank Threat Tracker: " .. (TankThreatTracker:IsShown() and "Shown" or "Hidden"))
    end
end
