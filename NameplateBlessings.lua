local _, ns = ...

-- Customizes friendly player nameplates with three independent parts:
--   * Blessing row: paladin blessings above the plate. Blessings from other
--     casters are plain; yours come first with the pink "mine" border.
--   * Name: Blizzard's own name text (kept visible over a hidden body), or
--     our own label if the client doesn't expose it.
--   * Health bar: the plate body. Hiding it fades the unit frame to alpha 0;
--     the row and name ignore parent alpha so they stay visible, and the
--     plate still takes clicks for targeting.
--
-- The row is one native AuraContainer per unit frame with two groups limited
-- to blessing spell IDs: "Mine" (HELPFUL|PLAYER) then "Others"
-- (HELPFUL|!PLAYER). The client fills it itself, so it keeps working in
-- combat. While the row shows, Blizzard's own nameplate buff icons (which only
-- show buffs you cast) are hidden so your blessings don't appear twice.
--
-- All state is keyed by the plate's UnitFrame object, not the plate: on this
-- client a removed plate drops its UnitFrame (plate.UnitFrame becomes nil)
-- and unit frames are pooled, so cleanup must reach the exact frame we
-- modified. Our row and name label are children of that unit frame.
--
-- Rows are created only while aura data isn't secret; frames that appear in
-- combat get their row when combat ends.

local FEATURE_KEY = "nameplateBlessings"
ns.NAMEPLATE_FEATURE_KEY = FEATURE_KEY  -- toggled by the minimap button
local OPTION_SHOW_ROW = "nameplateShowBlessingRow"
local OPTION_SHOW_NAME = "nameplateShowName"
local OPTION_SHOW_HEALTH = "nameplateShowHealthBar"
local OPTION_ICON_SIZE = "nameplateBlessingsIconSize"
local OPTION_ROW_OFFSET = "nameplateBlessingsRowOffset"
local OPTION_ROW_RANGE = "nameplateBlessingsRowRange"
-- Replaced by the three show toggles; migrated once on enable.
local LEGACY_OPTION_HIDE_PLATE = "nameplateBlessingsHidePlate"
local LEGACY_OPTION_NAME_ONLY = "nameplateBlessingsNameOnly"

local GROUP_MINE, GROUP_OTHERS = "Mine", "Others"
local FILTER_MINE, FILTER_OTHERS = "HELPFUL|PLAYER", "HELPFUL|!PLAYER"
local DEFAULT_ICON_SIZE = 18
local MIN_ICON_SIZE, MAX_ICON_SIZE = 10, 36
local ICON_SPACING = 2
local MAX_PER_GROUP = 8
local BORDER_THICKNESS = 2
local DEFAULT_ROW_OFFSET = 4   -- pixels above whatever the row sits on
local MIN_ROW_OFFSET, MAX_ROW_OFFSET = -30, 60
local OTHERS_BORDER_COLOR = { r = 0, g = 0, b = 0, a = 0.8 }
local NAME_FONT_OBJECT = "SystemFont_NamePlate"
local NAME_FALLBACK_FONT_OBJECT = "GameFontHighlightSmall"
local NAME_LABEL_WIDTH, NAME_LABEL_HEIGHT = 200, 14
local MAX_NAMEPLATES = 40
local BLIZZARD_AURA_SEARCH_DEPTH = 5
-- Blizzard lays out nameplate aura buttons after UNIT_AURA and may reset
-- alphas; refresh again shortly after.
local FOLLOW_UP_REFRESH_DELAY = 0.25

-- Distance limits for showing the row. There's no exact distance API for
-- arbitrary players, so each step is a fixed-range check: an interaction
-- range (CheckInteractDistance index) or one of your spells' range.
local RANGE_STEPS = {
    { label = "Any distance" },
    { label = "10 yd", interactIndex = 3 },   -- duel range
    { label = "28 yd", interactIndex = 4 },   -- follow range
    { label = "30 yd", spellId = 19740 },     -- Blessing of Might
    { label = "40 yd", spellId = 635 },       -- Holy Light
}
local DEFAULT_RANGE_STEP = 1
local RANGE_POLL_INTERVAL = 0.25

-- Aura spell ID of every rank, from the Forever beta rank data bundled with
-- ForeverAuras (SecretAuraRanks.lua). Forever has no Blessing of Sanctuary.
local BLESSING_SPELL_IDS = {
    1044,                                               -- Blessing of Freedom
    20217,                                              -- Blessing of Kings
    19977, 19978, 19979,                                -- Blessing of Light
    19740, 19834, 19835, 19836, 19837, 19838, 25291,    -- Blessing of Might
    1022, 5599, 10278,                                  -- Blessing of Protection
    6940, 20729,                                        -- Blessing of Sacrifice
    1038,                                               -- Blessing of Salvation
    19742, 19850, 19852, 19853, 19854, 25290,           -- Blessing of Wisdom
    25898,                                              -- Greater Blessing of Kings
    25890,                                              -- Greater Blessing of Light
    25782, 25916,                                       -- Greater Blessing of Might
    25895,                                              -- Greater Blessing of Salvation
    25894, 25918,                                       -- Greater Blessing of Wisdom
}

local BLESSING_FILTERS = { includeSpellIDs = {} }
for _, spellId in ipairs(BLESSING_SPELL_IDS) do BLESSING_FILTERS.includeSpellIDs[spellId] = true end

local NAMEPLATE_UNITS = {}
for i = 1, MAX_NAMEPLATES do NAMEPLATE_UNITS[i] = "nameplate" .. i end

local GROUPS = {
    { key = GROUP_MINE, filter = FILTER_MINE, layoutIndex = 1 },
    { key = GROUP_OTHERS, filter = FILTER_OTHERS, layoutIndex = 2 },
}

-- All keyed by the nameplate's UnitFrame ("frame" below).
local frameUnits = {}        -- [frame] = unit; friendly player frames we manage
local unitFrames = {}        -- [unit] = frame; reverse lookup (plates drop UnitFrame on removal)
local rows = {}              -- [frame] = blessing row container
local rowUnits = {}          -- [frame] = unit the row container is bound to
local pendingRows = {}       -- [frame] = unit; row waiting for combat to end
local hiddenBlizzard = {}    -- [blizzard aura frame] = frame; set to alpha 0
local hiddenBodies = {}      -- [frame] = frame alpha before we faded it
local hiddenNames = {}       -- [frame] = Blizzard name alpha before we hid it
local keptNames = {}         -- [frame] = true; Blizzard name kept visible over a hidden body
local nameLabels = {}        -- [frame] = our name label (fallback name)
local rangeTicker
local reportedErrors = {}

local function Report(context, err)
    local message = context .. ": " .. tostring(err)
    if reportedErrors[message] then return end
    reportedErrors[message] = true
    ns.Print("nameplates: " .. message)
end

local function ShowRow() return ns.GetOption(OPTION_SHOW_ROW) == true end
local function ShowName() return ns.GetOption(OPTION_SHOW_NAME) == true end
local function ShowHealth() return ns.GetOption(OPTION_SHOW_HEALTH) == true end
local function GetIconSize() return ns.GetOption(OPTION_ICON_SIZE) end

local function GetPlateUnit(plate)
    return plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
end

-- Friendly players only: spell-ID filtering of helpful auras is only allowed
-- on units you can assist.
local function IsEligibleUnit(unit)
    if not unit or not UnitExists(unit) then return false end
    local isPlayer = UnitIsPlayer(unit)
    local canAssist = UnitCanAssist("player", unit)
    if ns.IsSecret(isPlayer) or ns.IsSecret(canAssist) then return false end
    return isPlayer and canAssist and true or false
end

-- Regions can only stay visible inside a faded unit frame if they ignore
-- their parents' alpha.
local function CanIgnoreParentAlpha(region)
    return region ~= nil and type(region.SetIgnoreParentAlpha) == "function"
end

---------------------------------------------------------------------------
-- Name: always Blizzard's own name text when the client exposes it (kept
-- visible over a hidden body by ignoring parent alpha); our label is only a
-- fallback. The far-away "vanilla" name is drawn by the game world itself,
-- only when no nameplate exists, so addons can't show that one.
---------------------------------------------------------------------------

-- Blizzard's name text, if this client exposes it where retail does
-- (UnitFrame.name). Reported by /ptools platedebug.
local function GetBlizzardNameText(frame)
    local name = frame.name
    if type(name) == "table" and type(name.GetObjectType) == "function" and name:GetObjectType() == "FontString" then
        return name
    end
end

local function GetNameLabel(frame)
    local label = nameLabels[frame]
    if label then return label end

    label = CreateFrame("Frame", nil, frame)
    label:SetSize(NAME_LABEL_WIDTH, NAME_LABEL_HEIGHT)
    label:SetPoint("CENTER", frame, "CENTER")
    label:EnableMouse(false)
    if CanIgnoreParentAlpha(label) then label:SetIgnoreParentAlpha(true) end

    local fontObject = _G[NAME_FONT_OBJECT] and NAME_FONT_OBJECT or NAME_FALLBACK_FONT_OBJECT
    label.text = label:CreateFontString(nil, "OVERLAY", fontObject)
    label.text:SetAllPoints()
    label.text:SetJustifyH("CENTER")
    label.text:SetWordWrap(false)

    label:Hide()
    nameLabels[frame] = label
    return label
end

local function GetClassColor(unit)
    local _, classToken = UnitClass(unit)
    if classToken == nil or ns.IsSecret(classToken) then return 1, 1, 1 end
    local color = (C_ClassColor and C_ClassColor.GetClassColor(classToken)) or RAID_CLASS_COLORS[classToken]
    if not color then return 1, 1, 1 end
    return color.r, color.g, color.b
end

-- Names may be secret (e.g. in instances); SetText accepts secrets.
local function UpdateNameText(frame)
    local label, unit = nameLabels[frame], frameUnits[frame]
    if not label or not unit then return end
    local name = UnitName(unit)
    label.text:SetText(name)
    label.text:SetTextColor(GetClassColor(unit))
end

local function SetNameLabelShown(frame, shown)
    if shown then
        GetNameLabel(frame):Show()
        UpdateNameText(frame)
    elseif nameLabels[frame] then
        nameLabels[frame]:Hide()
    end
end

-- Keeps Blizzard's name visible while the unit frame is faded out.
-- Returns false if the client doesn't expose a usable name text.
local function SetBlizzardNameKept(frame, keep)
    local blizzardName = GetBlizzardNameText(frame)
    if not blizzardName or not CanIgnoreParentAlpha(blizzardName) then return false end
    if keep or keptNames[frame] then
        blizzardName:SetIgnoreParentAlpha(keep)
        keptNames[frame] = keep or nil
    end
    return true
end

local function SetBlizzardNameHidden(frame, hidden)
    local blizzardName = GetBlizzardNameText(frame)
    if not blizzardName then return end
    if hidden then
        if hiddenNames[frame] == nil then
            local alpha = blizzardName:GetAlpha()
            hiddenNames[frame] = (alpha ~= nil and not ns.IsSecret(alpha)) and alpha or 1
        end
        blizzardName:SetAlpha(0)
    elseif hiddenNames[frame] ~= nil then
        blizzardName:SetAlpha(hiddenNames[frame])
        hiddenNames[frame] = nil
    end
end

---------------------------------------------------------------------------
-- Body (health bar)
---------------------------------------------------------------------------

local function SetBodyHidden(frame, hidden)
    if hidden then
        if hiddenBodies[frame] == nil then
            local alpha = frame:GetAlpha()
            hiddenBodies[frame] = (alpha ~= nil and not ns.IsSecret(alpha)) and alpha or 1
        end
        frame:SetAlpha(0)  -- re-applied each refresh in case Blizzard resets it
    elseif hiddenBodies[frame] ~= nil then
        frame:SetAlpha(hiddenBodies[frame])
        hiddenBodies[frame] = nil
    end
    if CanIgnoreParentAlpha(rows[frame]) then rows[frame]:SetIgnoreParentAlpha(hidden) end
end

-- The body can only be hidden if what should stay visible can ignore its alpha.
local function CanHideBody(frame)
    return CanIgnoreParentAlpha(frame) and (rows[frame] == nil or CanIgnoreParentAlpha(rows[frame]))
end

---------------------------------------------------------------------------
-- Blessing row
---------------------------------------------------------------------------

-- What the row sits on top of: whichever name is visible, else the frame.
local function GetRowAnchor(frame)
    if ShowName() then
        local blizzardName = GetBlizzardNameText(frame)
        if blizzardName and (ShowHealth() or CanIgnoreParentAlpha(blizzardName)) then return blizzardName end
        if not ShowHealth() then return GetNameLabel(frame) end
    end
    return frame
end

-- Position and icon size from settings. Container descendants are restricted
-- while auras are secret, so callers only do this out of combat.
local function ApplyRowLayout(frame, container)
    container:ClearAllPoints()
    container:SetPoint("BOTTOM", GetRowAnchor(frame), "TOP", 0, ns.GetOption(OPTION_ROW_OFFSET))
    ns.AuraContainerUtil.ResizeGroups(container, GROUPS, GetIconSize(), ICON_SPACING)
end

local function BuildRow(frame)
    local container = ns.AuraContainerUtil.Create(frame, false)
    local colors = { [GROUP_MINE] = ns.OWN_BUFF_BORDER_COLOR, [GROUP_OTHERS] = OTHERS_BORDER_COLOR }
    for _, group in ipairs(GROUPS) do
        container:AddAuraGroup(group.key, group.filter, {
            maxFrameCount = MAX_PER_GROUP,
            candidateFilters = BLESSING_FILTERS,
            -- Size is read when each pooled button is created, so buttons made
            -- after a settings change pick up the new size.
            initializeFrame = ns.AuraContainerUtil.BorderedButtonInitializer(GetIconSize, colors[group.key], BORDER_THICKNESS),
        })
    end
    ApplyRowLayout(frame, container)
    return container
end

-- Applies position/size settings to existing rows; deferred while restricted.
local layoutPending = false

local function ApplyLayoutToAllRows()
    if ns.AurasAreSecret() then
        layoutPending = true
        return
    end
    layoutPending = false
    for frame, container in pairs(rows) do
        local ok, err = pcall(ApplyRowLayout, frame, container)
        if not ok then Report("layout", err) end
    end
end

-- Returns the frame's row, creating it if allowed right now.
local function EnsureRow(frame)
    if rows[frame] then return rows[frame] end
    if ns.AurasAreSecret() then return nil end

    local supported, reason = ns.AuraContainerUtil.EnsureSupport()
    if not supported then
        Report("load Blizzard_AuraContainer", reason)
        return nil
    end

    local ok, result = pcall(BuildRow, frame)
    if not ok then
        Report("create row", result)
        return nil
    end
    rows[frame] = result
    return result
end

-- Shows the row bound to unit. Returns false if it has to wait for combat.
local function ShowRowFor(frame, unit)
    local container = EnsureRow(frame)
    if not container then return false end
    if rowUnits[frame] == unit then return true end

    local ok, err = pcall(function()
        container:SetEnabled(false)
        container:SetUnit(unit)
        container:Show()
        container:SetEnabled(true)
        container:UpdateAllAuras()
    end)
    if not ok then
        Report("bind row", err)
        return false
    end
    rowUnits[frame] = unit
    return true
end

local function HideRow(frame)
    pendingRows[frame] = nil
    local container = rows[frame]
    if not container or rowUnits[frame] == nil then return end
    rowUnits[frame] = nil
    local ok, err = pcall(function()
        container:SetEnabled(false)
        container:SetUnit("none")
        container:Hide()
    end)
    if not ok then Report("unbind row", err) end
end

---------------------------------------------------------------------------
-- Blizzard nameplate buff icons (duplicates of the row)
---------------------------------------------------------------------------

-- Visits Blizzard aura buttons under a unit frame (frames carrying an
-- auraInstanceID), skipping forbidden frames and aura containers (ours).
local function ForEachBlizzardAuraButton(parent, depth, visit)
    if depth > BLIZZARD_AURA_SEARCH_DEPTH then return end
    for _, child in ipairs({ parent:GetChildren() }) do
        local forbidden = child.IsForbidden and child:IsForbidden()
        if not forbidden and not ns.AuraContainerUtil.IsAuraContainer(child) then
            if child.auraInstanceID ~= nil then
                visit(child)
            else
                ForEachBlizzardAuraButton(child, depth + 1, visit)
            end
        end
    end
end

-- Hides the frame holding the buttons, or the button itself if Blizzard
-- parents buttons straight to the unit frame or plate (hiding that would
-- hide everything).
local function HideBlizzardAuras(frame)
    local plate = frame:GetParent()
    ForEachBlizzardAuraButton(frame, 1, function(button)
        local parent = button:GetParent()
        local target = (parent and parent ~= frame and parent ~= plate) and parent or button
        if hiddenBlizzard[target] ~= frame then
            target:SetAlpha(0)
            hiddenBlizzard[target] = frame
        end
    end)
end

-- frame == nil restores everything.
local function RestoreBlizzardAuras(frame)
    for auraFrame, owner in pairs(hiddenBlizzard) do
        if frame == nil or owner == frame then
            auraFrame:SetAlpha(1)
            hiddenBlizzard[auraFrame] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Distance limit for the row
---------------------------------------------------------------------------

local function GetRangeStep()
    return RANGE_STEPS[ns.GetOption(OPTION_ROW_RANGE)] or RANGE_STEPS[DEFAULT_RANGE_STEP]
end

-- true/false, a secret boolean (combat), or nil when the check can't answer
-- (e.g. spell not known, or the client refuses the check right now).
local function CheckRange(step, unit)
    -- No "x and y or nil" here: false must survive, and a secret result can't
    -- be tested for truthiness.
    local ok, inRange
    if step.interactIndex then
        ok, inRange = pcall(CheckInteractDistance, unit, step.interactIndex)
    elseif step.spellId then
        local spellName = ns.GetSpellName(step.spellId)
        if not spellName or not (C_Spell and C_Spell.IsSpellInRange) then return nil end
        ok, inRange = pcall(C_Spell.IsSpellInRange, spellName, unit)
    end
    if not ok then return nil end
    return inRange
end

-- Shows the row only while the unit is within the chosen range. Unknown
-- results show the row; secret results are handed to SetAlphaFromBoolean.
local function ApplyRange(frame)
    local container, unit = rows[frame], rowUnits[frame]
    if not container or not unit then return end

    local step = GetRangeStep()
    if not step.interactIndex and not step.spellId then
        container:SetAlpha(1)
        return
    end

    local inRange = CheckRange(step, unit)
    if ns.IsSecret(inRange) then
        if container.SetAlphaFromBoolean then container:SetAlphaFromBoolean(inRange, 1, 0) end
    elseif inRange == nil then
        container:SetAlpha(1)
    else
        container:SetAlpha(inRange and 1 or 0)
    end
end

local function ApplyRangeToAllRows()
    for frame in pairs(rowUnits) do
        local ok, err = pcall(ApplyRange, frame)
        if not ok then Report("range", err) end
    end
end

-- Polls only while a distance limit is set (there's no range-change event).
local function UpdateRangeTicker()
    local step = GetRangeStep()
    local limited = step.interactIndex ~= nil or step.spellId ~= nil
    if limited and not rangeTicker then
        rangeTicker = C_Timer.NewTicker(RANGE_POLL_INTERVAL, ApplyRangeToAllRows)
    elseif not limited and rangeTicker then
        rangeTicker:Cancel()
        rangeTicker = nil
    end
    ApplyRangeToAllRows()
end

local function StopRangeTicker()
    if rangeTicker then
        rangeTicker:Cancel()
        rangeTicker = nil
    end
end

---------------------------------------------------------------------------
-- Appearance
---------------------------------------------------------------------------

-- Applies the three show toggles to one managed frame.
local function UpdateAppearance(frame)
    local unit = frameUnits[frame]
    if not unit then return end

    if ShowRow() then
        if ShowRowFor(frame, unit) then
            pendingRows[frame] = nil
            ApplyRange(frame)
        else
            pendingRows[frame] = unit
        end
        HideBlizzardAuras(frame)
    else
        HideRow(frame)
        RestoreBlizzardAuras(frame)
    end

    local hideBody = not ShowHealth() and CanHideBody(frame)
    SetBodyHidden(frame, hideBody)

    if hideBody and ShowName() then
        -- Keep Blizzard's own name over the faded body; our label only if
        -- the client doesn't expose it.
        SetBlizzardNameHidden(frame, false)
        local kept = SetBlizzardNameKept(frame, true)
        SetNameLabelShown(frame, not kept and CanIgnoreParentAlpha(GetNameLabel(frame)))
    else
        SetBlizzardNameKept(frame, false)
        SetNameLabelShown(frame, false)
        SetBlizzardNameHidden(frame, not ShowName())
    end
end

local function SafeUpdateAppearance(frame)
    local ok, err = pcall(UpdateAppearance, frame)
    if not ok then Report("update", err) end
end

local function UpdateAllAppearances()
    for frame in pairs(frameUnits) do SafeUpdateAppearance(frame) end
end

-- Coalesced refresh: once on the next frame, once after Blizzard's late layout.
local refreshQueue = {}
local refreshPending = false

local function RunRefreshPass(isFinal)
    for frame in pairs(refreshQueue) do SafeUpdateAppearance(frame) end
    if isFinal then
        wipe(refreshQueue)
        refreshPending = false
    end
end

local function FirstRefreshPass() RunRefreshPass(false) end
local function FinalRefreshPass() RunRefreshPass(true) end

local function QueueRefresh(frame)
    refreshQueue[frame] = true
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0, FirstRefreshPass)
    C_Timer.After(FOLLOW_UP_REFRESH_DELAY, FinalRefreshPass)
end

---------------------------------------------------------------------------
-- Nameplate lifecycle
---------------------------------------------------------------------------

-- Returns a unit frame to Blizzard's normal look. Each step is isolated so a
-- failure can't leave the rest of the frame modified.
local RELEASE_STEPS = {
    HideRow,
    RestoreBlizzardAuras,
    function(frame) SetBodyHidden(frame, false) end,
    function(frame) SetBlizzardNameKept(frame, false) end,
    function(frame) SetBlizzardNameHidden(frame, false) end,
    function(frame) SetNameLabelShown(frame, false) end,
}

local function ReleaseFrame(frame)
    local unit = frameUnits[frame]
    frameUnits[frame] = nil
    refreshQueue[frame] = nil
    if unit and unitFrames[unit] == frame then unitFrames[unit] = nil end

    for _, step in ipairs(RELEASE_STEPS) do
        local ok, err = pcall(step, frame)
        if not ok then Report("restore", err) end
    end
end

local function OnPlateUnit(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    local frame = plate and plate.UnitFrame
    if not frame then return end

    -- The token or the frame may have been reassigned since we last saw them.
    local previousFrame = unitFrames[unit]
    if previousFrame and previousFrame ~= frame then ReleaseFrame(previousFrame) end
    local previousUnit = frameUnits[frame]
    if previousUnit and previousUnit ~= unit and unitFrames[previousUnit] == frame then
        unitFrames[previousUnit] = nil
    end

    if not IsEligibleUnit(unit) then
        ReleaseFrame(frame)
        return
    end
    frameUnits[frame] = unit
    unitFrames[unit] = frame
    SafeUpdateAppearance(frame)
    QueueRefresh(frame)
end

-- The plate may already have dropped its UnitFrame, so use our own record.
local function OnPlateRemoved(unit)
    local frame = unitFrames[unit]
    if frame then ReleaseFrame(frame) end
end

local function RefreshAllPlates()
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local unit = GetPlateUnit(plate)
        if unit then OnPlateUnit(unit) end
    end
end

local handlers = {}

handlers.NAME_PLATE_UNIT_ADDED = OnPlateUnit
handlers.NAME_PLATE_UNIT_REMOVED = OnPlateRemoved
handlers.PLAYER_ENTERING_WORLD = RefreshAllPlates

function handlers.UNIT_AURA(unit)
    local frame = unitFrames[unit]
    if frame then QueueRefresh(frame) end
end

function handlers.UNIT_NAME_UPDATE(unit)
    local frame = unitFrames[unit]
    if frame then UpdateNameText(frame) end
end

-- Blizzard may re-fade plates when the target changes; re-apply.
function handlers.PLAYER_TARGET_CHANGED()
    for frame in pairs(frameUnits) do QueueRefresh(frame) end
end

-- Rows that had to wait for combat, and layout changes made in combat.
function handlers.PLAYER_REGEN_ENABLED()
    if layoutPending then ApplyLayoutToAllRows() end

    -- Snapshot: UpdateAppearance may re-queue frames while we iterate.
    local waiting = pendingRows
    pendingRows = {}
    for frame, unit in pairs(waiting) do
        if frameUnits[frame] == unit then SafeUpdateAppearance(frame) end
    end
end

local UNITS = {
    UNIT_AURA = NAMEPLATE_UNITS,
    UNIT_NAME_UPDATE = NAMEPLATE_UNITS,
}

-- Converts the old "hide nameplates" / "name only" checkboxes once.
local function MigrateLegacyOptions()
    local hidePlate, nameOnly = ns.GetOption(LEGACY_OPTION_HIDE_PLATE), ns.GetOption(LEGACY_OPTION_NAME_ONLY)
    if hidePlate == nil and nameOnly == nil then return end
    if nameOnly then
        ns.SetOption(OPTION_SHOW_HEALTH, false)
        ns.SetOption(OPTION_SHOW_NAME, true)
    elseif hidePlate then
        ns.SetOption(OPTION_SHOW_HEALTH, false)
        ns.SetOption(OPTION_SHOW_NAME, false)
    end
    ns.SetOption(LEGACY_OPTION_HIDE_PLATE, nil)
    ns.SetOption(LEGACY_OPTION_NAME_ONLY, nil)
end

---------------------------------------------------------------------------
-- Diagnostics (/ptools platedebug) - target a friendly player first
---------------------------------------------------------------------------

local MAX_DEBUG_AURAS = 40

local function Describe(value)
    if ns.IsSecret(value) then return "<secret>" end
    return tostring(value)
end

-- The target's helpful auras with spell ID, caster, and whether the blessing
-- list matches them (verifies the spell IDs against the live client).
local function DescribeTargetBuffs(lines)
    if ns.AurasAreSecret() then
        table.insert(lines, "target buffs: secret right now (leave combat)")
        return
    end
    for i = 1, MAX_DEBUG_AURAS do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "target", i, "HELPFUL")
        if not ok or not aura then break end
        local spellId = aura.spellId
        local matches = not ns.IsSecret(spellId) and BLESSING_FILTERS.includeSpellIDs[spellId] == true
        table.insert(lines, ("  buff %s id=%s source=%s inBlessingList=%s"):format(
            Describe(aura.name), Describe(spellId), Describe(aura.sourceUnit), Describe(matches)))
    end
end

local function DescribeAnchor(frame)
    local anchor = GetRowAnchor(frame)
    if anchor == frame then return "plate" end
    if anchor == nameLabels[frame] then return "nameLabel" end
    return "blizzardName"
end

local function CountKeys(map)
    local count = 0
    for _ in pairs(map) do count = count + 1 end
    return count
end

ns.RegisterSlashCommand("platedebug", "friendly nameplate status for your target", function()
    local lines = {}
    local plate = C_NamePlate.GetNamePlateForUnit("target")
    local frame = plate and plate.UnitFrame
    local unit = plate and GetPlateUnit(plate)

    local hiddenCount = 0
    for _, owner in pairs(hiddenBlizzard) do
        if owner == frame then hiddenCount = hiddenCount + 1 end
    end

    table.insert(lines, ("enabled=%s showRow=%s showName=%s showHealth=%s range=%s inRange=%s managedFrames=%d"):format(
        Describe(ns.IsFeatureEnabled(FEATURE_KEY)), Describe(ShowRow()), Describe(ShowName()), Describe(ShowHealth()),
        GetRangeStep().label, unit and Describe(CheckRange(GetRangeStep(), unit)) or "n/a", CountKeys(frameUnits)))
    table.insert(lines, ("plate=%s unitFrame=%s forbidden=%s unit=%s eligible=%s managed=%s row=%s rowUnit=%s pendingRow=%s hiddenBlizzardFrames=%d bodyHidden=%s"):format(
        Describe(plate ~= nil), Describe(frame ~= nil), Describe(plate and plate.IsForbidden and plate:IsForbidden()),
        Describe(unit), Describe(unit and IsEligibleUnit(unit)), Describe(frame and frameUnits[frame]),
        Describe(frame and rows[frame] ~= nil), Describe(frame and rowUnits[frame]),
        Describe(frame and pendingRows[frame]), hiddenCount, Describe(frame and hiddenBodies[frame] ~= nil)))

    if frame then
        local nameField = frame.name
        table.insert(lines, ("UnitFrame.name=%s rowAnchor=%s"):format(
            type(nameField) == "table" and type(nameField.GetObjectType) == "function" and nameField:GetObjectType() or type(nameField),
            DescribeAnchor(frame)))
        if rows[frame] then
            for _, line in ipairs(ns.AuraContainerUtil.DescribeContainer(rows[frame], { GROUP_MINE, GROUP_OTHERS })) do
                table.insert(lines, line)
            end
        end
    end
    DescribeTargetBuffs(lines)

    for _, line in ipairs(lines) do ns.Print(line) end
    ns.SaveDebugOutput("platedebug", lines)
end)

---------------------------------------------------------------------------
-- Feature registration
---------------------------------------------------------------------------

local function OnLayoutOptionChanged()
    UpdateAllAppearances()
    ApplyLayoutToAllRows()  -- the row's anchor depends on what's visible
end

ns.RegisterFeature({
    key = FEATURE_KEY,
    label = "Customize friendly player nameplates",
    tooltip = "Choose what friendly player nameplates show: a row of paladin blessings (yours first with the pink border), the player's name, and the health bar. Works in combat.",
    default = true,

    options = {
        {
            type = "checkbox",
            key = OPTION_SHOW_ROW,
            label = "Show blessing row",
            tooltip = "Paladin blessings above the nameplate. Yours come first with the pink border; other paladins' are plain. Blizzard's own icons for your buffs are hidden while this is on so they don't show twice.",
            default = true,
            OnChanged = OnLayoutOptionChanged,
        },
        {
            type = "checkbox",
            key = OPTION_SHOW_NAME,
            label = "Show player name",
            tooltip = "The player's name (Blizzard's own nameplate name, kept visible when the health bar is hidden).",
            default = true,
            OnChanged = OnLayoutOptionChanged,
        },
        {
            type = "checkbox",
            key = OPTION_SHOW_HEALTH,
            label = "Show health bar",
            tooltip = "The nameplate's health bar. When hidden, you can still click where the nameplate is to target the player.",
            default = true,
            OnChanged = OnLayoutOptionChanged,
        },
        {
            type = "slider",
            key = OPTION_ICON_SIZE,
            label = "Blessing icon size",
            tooltip = "Size of the blessing icons. Changes made in combat apply when combat ends.",
            min = MIN_ICON_SIZE,
            max = MAX_ICON_SIZE,
            step = 1,
            default = DEFAULT_ICON_SIZE,
            format = "%d px",
            OnChanged = ApplyLayoutToAllRows,
        },
        {
            type = "slider",
            key = OPTION_ROW_OFFSET,
            label = "Blessing row height",
            tooltip = "How far above the name (or the nameplate, if no name shows) the blessing row sits. Negative values move it down. Changes made in combat apply when combat ends.",
            min = MIN_ROW_OFFSET,
            max = MAX_ROW_OFFSET,
            step = 1,
            default = DEFAULT_ROW_OFFSET,
            format = "%d px",
            OnChanged = ApplyLayoutToAllRows,
        },
        {
            type = "slider",
            key = OPTION_ROW_RANGE,
            label = "Show blessing row within",
            tooltip = "Only show a player's blessing row while they're within this distance. Uses fixed range checks: 10 and 28 yd interaction ranges, Blessing of Might (30 yd) and Holy Light (40 yd).",
            min = 1,
            max = #RANGE_STEPS,
            step = 1,
            default = DEFAULT_RANGE_STEP,
            formatValue = function(value) return (RANGE_STEPS[value] or RANGE_STEPS[DEFAULT_RANGE_STEP]).label end,
            OnChanged = UpdateRangeTicker,
        },
    },

    Enable = function()
        MigrateLegacyOptions()
        ns.Events.RegisterAll(FEATURE_KEY, handlers, UNITS)
        RefreshAllPlates()
        UpdateRangeTicker()
    end,

    Disable = function()
        ns.Events.UnregisterAll(FEATURE_KEY)
        StopRangeTicker()

        local known = {}
        for frame in pairs(frameUnits) do known[frame] = true end
        for frame in pairs(rows) do known[frame] = true end
        for frame in pairs(known) do ReleaseFrame(frame) end

        wipe(pendingRows)
        wipe(unitFrames)
        RestoreBlizzardAuras(nil)
    end,
})
