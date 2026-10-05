local _, ns = ...

-- Draws a thin border around buff icons the player cast on the player's own
-- buff frame (and on legacy-style target/focus frames, where the client still
-- exposes them). On this client the target frame's buttons are forbidden (no
-- addon can mark them), and nameplates are covered by NameplateBlessings.
--
-- Blizzard's aura frames are re-laid out whenever auras change, so this
-- re-scans them one frame after any relevant update (post-hooks plus events
-- as a fallback).
--
-- Aura data is secret in combat, so ownership is resolved in layers:
--   1. Cache by aura instance ID. Instance IDs are stable for an aura's
--      lifetime, so anything learned while readable survives into combat.
--   2. Secret-safe "cast by player" filter check by instance ID, if the
--      client has one.
--   3. Direct read of that one aura (some auras may stay readable in combat).
--   4. If still unknown but the button shows the same aura as last scan
--      (same instance ID, or same icon when no ID is exposed), keep the
--      previous result.

local FEATURE_KEY = "ownBuffHighlight"
local PLAYER_BUFF_FILTER = "HELPFUL|PLAYER"
local BORDER_COLOR = { r = 0.96, g = 0.55, b = 0.73 }  -- paladin pink
ns.OWN_BUFF_BORDER_COLOR = BORDER_COLOR  -- shared with NameplateBlessings
local BORDER_THICKNESS = 2
local BORDER_OUTSET = 1
local FALLBACK_MAX_BUFFS = 32
local MAX_AURAS = 40
local TRACKED_UNITS = { "player", "target", "focus" }  -- caches primed every scan
-- Blizzard frames may lay out their aura buttons after the event that
-- triggered our first scan, so every request also queues a later re-scan.
local FOLLOW_UP_SCAN_DELAY = 0.25
local DEBUG_BUTTONS_PER_FRAME = 4

local enabled = false
local scanPending = false
local followUpPending = false
local hooksInstalled = false
local borders = {}     -- [auraButton] = border frame
local mine = {}        -- [auraButton] = true, rebuilt each scan
local visited = {}     -- [auraButton] = true, rebuilt each scan
local lastResult = {}  -- [auraButton] = { unit, key, mine }
local ownerCache = {}  -- [unit] = { [auraInstanceID] = isMine }

---------------------------------------------------------------------------
-- Border
---------------------------------------------------------------------------

local function GetIconRegion(button)
    if button.Icon or button.icon then return button.Icon or button.icon end
    local name = button:GetName()
    return name and _G[name .. "Icon"]
end

local function CreateBorder(button)
    local anchor = GetIconRegion(button) or button
    local border = CreateFrame("Frame", nil, button)
    border:SetPoint("TOPLEFT", anchor, "TOPLEFT", -BORDER_OUTSET, BORDER_OUTSET)
    border:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", BORDER_OUTSET, -BORDER_OUTSET)
    border:SetFrameLevel(button:GetFrameLevel() + 2)

    local function AddEdge(pointA, pointB, isHorizontal)
        local edge = border:CreateTexture(nil, "OVERLAY")
        edge:SetColorTexture(BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b, 1)
        edge:SetPoint(pointA)
        edge:SetPoint(pointB)
        if isHorizontal then edge:SetHeight(BORDER_THICKNESS) else edge:SetWidth(BORDER_THICKNESS) end
    end
    AddEdge("TOPLEFT", "TOPRIGHT", true)
    AddEdge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    AddEdge("TOPLEFT", "BOTTOMLEFT", false)
    AddEdge("TOPRIGHT", "BOTTOMRIGHT", false)

    border:Hide()
    borders[button] = border
    return border
end

---------------------------------------------------------------------------
-- Ownership
---------------------------------------------------------------------------

local function UsableID(auraInstanceID)
    return auraInstanceID ~= nil and not ns.IsSecret(auraInstanceID)
end

local function CacheFor(unit)
    local cache = ownerCache[unit]
    if not cache then
        cache = {}
        ownerCache[unit] = cache
    end
    return cache
end

-- Ownership from an aura data table; nil if the table or its fields are secret.
-- Note: isFromPlayerOrPlayerPet means "cast by any player character", not
-- "cast by me", so only sourceUnit is used.
local function OwnershipFromAura(aura)
    if not aura or ns.IsSecret(aura) then return nil end

    local isHelpful, sourceUnit = aura.isHelpful, aura.sourceUnit
    if ns.IsSecret(isHelpful) or ns.IsSecret(sourceUnit) then return nil end

    if isHelpful == false or sourceUnit == nil then return false end
    if sourceUnit == "player" then return true end

    local ok, isMe = pcall(UnitIsUnit, sourceUnit, "player")
    if not ok or ns.IsSecret(isMe) then return nil end
    return isMe == true
end

-- Secret-safe filter check. Returns isMine, or nil if unavailable.
local function FilterCheck(unit, auraInstanceID)
    if not C_UnitAuras.IsAuraFilteredOutByInstanceID then return nil end
    local ok, filteredOut = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, auraInstanceID, PLAYER_BUFF_FILTER)
    if not ok or ns.IsSecret(filteredOut) or filteredOut == nil then return nil end
    return not filteredOut
end

-- Reads one aura; pcall because secret auras throw when read from addon code.
local function ReadAura(unit, auraInstanceID, index)
    local ok, aura
    if UsableID(auraInstanceID) then
        ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraInstanceID)
    elseif index then
        ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, "HELPFUL")
    end
    return ok and aura or nil
end

-- Returns true/false, or nil when it can't be determined right now.
local function Resolve(unit, auraInstanceID, index)
    if not C_UnitAuras then return nil end

    if UsableID(auraInstanceID) then
        local cache = CacheFor(unit)
        if cache[auraInstanceID] ~= nil then return cache[auraInstanceID] end

        local result = FilterCheck(unit, auraInstanceID)
        if result == nil then result = OwnershipFromAura(ReadAura(unit, auraInstanceID)) end
        if result ~= nil then cache[auraInstanceID] = result end
        return result
    end

    if index then
        local aura = ReadAura(unit, nil, index)
        if not aura then return nil end

        local auraInstanceID = aura.auraInstanceID
        local result
        if UsableID(auraInstanceID) then result = FilterCheck(unit, auraInstanceID) end
        if result == nil then result = OwnershipFromAura(aura) end
        if result ~= nil and UsableID(auraInstanceID) then CacheFor(unit)[auraInstanceID] = result end
        return result
    end
end

-- While aura data is readable, rebuild the unit's cache from scratch. This
-- snapshots ownership before combat and prunes IDs of expired auras.
local function PrimeCache(unit)
    if ns.AurasAreSecret() or not C_UnitAuras or not UnitExists(unit) then return end

    local fresh = {}
    for i = 1, MAX_AURAS do
        local aura = ReadAura(unit, nil, i)
        if not aura then break end

        local auraInstanceID = aura.auraInstanceID
        if UsableID(auraInstanceID) then
            local result = FilterCheck(unit, auraInstanceID)
            if result == nil then result = OwnershipFromAura(aura) end
            if result == nil then return end  -- unexpectedly unreadable; keep the old cache
            fresh[auraInstanceID] = result
        end
    end
    ownerCache[unit] = fresh
end

---------------------------------------------------------------------------
-- Aura button sources
-- Each visitor calls visit(button, unit, auraInstanceID, index) for every
-- shown buff button. Modern frames expose auraInstanceID; legacy frames are
-- named buttons whose ID is the HELPFUL aura index.
---------------------------------------------------------------------------

-- IsShown can return a secret on restricted frames; testing a secret throws.
local function VisitShown(visit, button, unit, auraInstanceID, index)
    if not button then return end
    local ok, shown = pcall(button.IsShown, button)
    if ok and not ns.IsSecret(shown) and shown then visit(button, unit, auraInstanceID, index) end
end

local function VisitPlayerBuffs(visit)
    if BuffFrame and BuffFrame.auraFrames then
        for _, button in ipairs(BuffFrame.auraFrames) do
            local info = button.buttonInfo
            if info and (info.auraType == nil or info.auraType == "Buff") then
                VisitShown(visit, button, "player", info.auraInstanceID, info.index)
            end
        end
        return
    end

    for i = 1, BUFF_MAX_DISPLAY or FALLBACK_MAX_BUFFS do
        local button = _G["BuffButton" .. i]
        if button then VisitShown(visit, button, "player", nil, button:GetID()) end
    end
end

local function VisitUnitFrameBuffs(frame, unit, legacyPrefix, visit)
    if not frame or not UnitExists(unit) then return end

    -- Pooled aura buttons (10.x/11.x style).
    if frame.auraPools and frame.auraPools.EnumerateActive then
        for button in frame.auraPools:EnumerateActive() do
            if button.auraInstanceID then VisitShown(visit, button, unit, button.auraInstanceID, nil) end
        end
        return
    end

    -- Named buttons indexed by aura (classic style).
    for i = 1, MAX_TARGET_BUFFS or FALLBACK_MAX_BUFFS do
        local button = _G[legacyPrefix .. i]
        if not button then break end
        VisitShown(visit, button, unit, nil, button:GetID())
    end

    -- Otherwise (this client) the frame uses a native AuraContainer whose
    -- buttons are forbidden, so there is nothing to mark.
end

-- Each source is isolated so one failing (e.g. a restricted frame throwing)
-- can't stop the others; failures are reported once per distinct message.
local reportedErrors = {}

local function RunSource(name, source, ...)
    local ok, err = pcall(source, ...)
    if not ok and not reportedErrors[name .. tostring(err)] then
        reportedErrors[name .. tostring(err)] = true
        ns.Print("buff highlight: " .. name .. " scan failed:", err)
    end
end

local function VisitAll(visit)
    RunSource("player buffs", VisitPlayerBuffs, visit)
    RunSource("target frame", VisitUnitFrameBuffs, TargetFrame, "target", "TargetFrameBuff", visit)
    RunSource("focus frame", VisitUnitFrameBuffs, FocusFrame, "focus", "FocusFrameBuff", visit)
end

---------------------------------------------------------------------------
-- Scan
---------------------------------------------------------------------------

-- Identifies which aura a button currently shows: instance ID when exposed,
-- else its icon. nil if neither is usable.
local function AuraKey(button, auraInstanceID)
    if UsableID(auraInstanceID) then return auraInstanceID end
    local icon = GetIconRegion(button)
    local texture = icon and icon:GetTexture()
    if texture ~= nil and not ns.IsSecret(texture) then return "icon:" .. tostring(texture) end
end

local function VisitAndMark(button, unit, auraInstanceID, index)
    local key = AuraKey(button, auraInstanceID)
    local result = Resolve(unit, auraInstanceID, index)

    local last = lastResult[button]
    if result == nil and last and key ~= nil and last.unit == unit and last.key == key then
        result = last.mine
    end

    last = last or {}
    last.unit, last.key, last.mine = unit, key, result == true
    lastResult[button] = last

    visited[button] = true
    if result then mine[button] = true end
end

local function Scan()
    scanPending = false
    wipe(mine)
    wipe(visited)

    if enabled then
        for _, unit in ipairs(TRACKED_UNITS) do PrimeCache(unit) end
        VisitAll(VisitAndMark)
    end

    for button in pairs(lastResult) do
        if not visited[button] then lastResult[button] = nil end
    end
    for button, border in pairs(borders) do
        if not mine[button] then border:Hide() end
    end
    for button in pairs(mine) do
        (borders[button] or CreateBorder(button)):Show()
    end
end

local function FollowUpScan()
    followUpPending = false
    Scan()
end

-- Coalesces bursts of aura updates into one scan on the next frame, plus one
-- follow-up for frames that lay out their aura buttons later than that.
local function RequestScan()
    if not enabled then return end
    if not scanPending then
        scanPending = true
        C_Timer.After(0, Scan)
    end
    if not followUpPending then
        followUpPending = true
        C_Timer.After(FOLLOW_UP_SCAN_DELAY, FollowUpScan)
    end
end

-- The unit token now refers to someone else: their instance IDs and icons
-- say nothing about the previous unit's ownership.
local function ForgetUnit(unit)
    ownerCache[unit] = nil
    for button, last in pairs(lastResult) do
        if last.unit == unit then lastResult[button] = nil end
    end
end

---------------------------------------------------------------------------
-- Hooks & events
---------------------------------------------------------------------------

-- Post-hooks are permanent, so they no-op via RequestScan while disabled.
local function InstallHooks()
    if hooksInstalled then return end
    hooksInstalled = true

    local function HookMethod(object, method)
        if object and type(object[method]) == "function" then hooksecurefunc(object, method, RequestScan) end
    end
    local function HookGlobal(name)
        if type(_G[name]) == "function" then hooksecurefunc(name, RequestScan) end
    end

    HookMethod(BuffFrame, "Update")
    HookMethod(BuffFrame, "UpdateAuraButtons")
    HookMethod(TargetFrame, "UpdateAuras")
    HookMethod(FocusFrame, "UpdateAuras")
    HookGlobal("BuffFrame_Update")
    HookGlobal("TargetFrame_UpdateAuras")
end

-- Keeps the cache current from UNIT_AURA deltas: drop removed IDs, and learn
-- ownership of added auras whose data happens to be readable.
local function ApplyAuraUpdate(unit, updateInfo)
    if not updateInfo then return end

    local cache = ownerCache[unit]
    if cache then
        for _, auraInstanceID in ipairs(updateInfo.removedAuraInstanceIDs or {}) do
            if UsableID(auraInstanceID) then cache[auraInstanceID] = nil end
        end
    end

    for _, aura in ipairs(updateInfo.addedAuras or {}) do
        local result = OwnershipFromAura(aura)
        if result ~= nil and UsableID(aura.auraInstanceID) then CacheFor(unit)[aura.auraInstanceID] = result end
    end
end

local handlers = {}

function handlers.UNIT_AURA(unit, updateInfo)
    ApplyAuraUpdate(unit, updateInfo)
    RequestScan()
end

function handlers.PLAYER_TARGET_CHANGED()
    ForgetUnit("target")
    RequestScan()
end

function handlers.PLAYER_FOCUS_CHANGED()
    ForgetUnit("focus")
    RequestScan()
end

handlers.PLAYER_REGEN_ENABLED = RequestScan   -- data readable again; re-prime
handlers.PLAYER_ENTERING_WORLD = RequestScan

local UNITS = {
    UNIT_AURA = TRACKED_UNITS,
}

---------------------------------------------------------------------------
-- Diagnostics (/ptools auradebug)
-- Reports what this client exposes for aura ownership, ideally run in combat.
---------------------------------------------------------------------------

local function Describe(value)
    if ns.IsSecret(value) then return "<secret>" end  -- before any comparison, which would throw
    if value == nil then return "nil" end
    return tostring(value)
end

-- Calls object:method(...) and describes the result as a plain string.
-- Protected frames return secret values (or throw); a secret concatenated into
-- a string makes the whole string secret, so raw results are never used.
local function SafeGet(object, method, ...)
    local fn = object[method]
    if type(fn) ~= "function" then return "n/a" end
    local ok, result = pcall(fn, object, ...)
    if not ok then return "error" end
    if type(result) == "number" and not ns.IsSecret(result) then return ("%.0f"):format(result) end
    return Describe(result)
end

local function HasAPI(namespace, name)
    return (namespace and namespace[name]) and "yes" or "no"
end

local function DescribeButton(button, unit, auraInstanceID, index)
    local filter = "n/a"
    if UsableID(auraInstanceID) and C_UnitAuras.IsAuraFilteredOutByInstanceID then
        local ok, filteredOut = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, auraInstanceID, PLAYER_BUFF_FILTER)
        filter = ok and Describe(filteredOut) or "error"
    end

    local read
    local aura = ReadAura(unit, auraInstanceID, index)
    if not aura then
        read = "blocked/none"
    else
        read = ("ok name=%s fromPlayer=%s source=%s"):format(
            Describe(aura.name), Describe(aura.isFromPlayerOrPlayerPet), Describe(aura.sourceUnit))
    end

    local border = borders[button]
    local borderState = not border and "none" or (border:IsVisible() and "visible") or (border:IsShown() and "shown-but-hidden") or "hidden"

    return ("  [%s] id=%s index=%s cached=%s filteredOut=%s read=%s -> mine=%s | size=%sx%s icon=%s border=%s"):format(
        unit, Describe(auraInstanceID), Describe(index),
        Describe(UsableID(auraInstanceID) and ownerCache[unit] and ownerCache[unit][auraInstanceID]),
        filter, read, Describe(Resolve(unit, auraInstanceID, index)),
        SafeGet(button, "GetWidth"), SafeGet(button, "GetHeight"), GetIconRegion(button) and "yes" or "no", borderState)
end

local function PrintAuraDiagnostics()
    local lines = {}
    table.insert(lines, ("build %s | inCombat=%s | aurasSecret=%s"):format(
        Describe(select(4, GetBuildInfo())), Describe(InCombatLockdown()), Describe(ns.AurasAreSecret())))
    table.insert(lines, ("APIs: IsAuraFilteredOutByInstanceID=%s GetAuraDataByAuraInstanceID=%s ShouldUnitAuraInstanceBeSecret=%s ShouldUnitAuraIndexBeSecret=%s"):format(
        HasAPI(C_UnitAuras, "IsAuraFilteredOutByInstanceID"), HasAPI(C_UnitAuras, "GetAuraDataByAuraInstanceID"),
        HasAPI(C_Secrets, "ShouldUnitAuraInstanceBeSecret"), HasAPI(C_Secrets, "ShouldUnitAuraIndexBeSecret")))
    table.insert(lines, ("Frames: BuffFrame.auraFrames=%s TargetFrame.auraPools=%s nameplates=%s"):format(
        Describe(BuffFrame and BuffFrame.auraFrames ~= nil), Describe(TargetFrame and TargetFrame.auraPools ~= nil),
        Describe(C_NamePlate and C_NamePlate.GetNamePlates and #C_NamePlate.GetNamePlates())))

    local printed = {}
    VisitAll(function(button, unit, auraInstanceID, index)
        printed[unit] = (printed[unit] or 0) + 1
        if printed[unit] <= DEBUG_BUTTONS_PER_FRAME then
            table.insert(lines, DescribeButton(button, unit, auraInstanceID, index))
        end
    end)

    for _, line in ipairs(lines) do ns.Print(line) end
    ns.SaveDebugOutput("auradebug", lines)
end

ns.RegisterSlashCommand("auradebug", "print buff-ownership diagnostics (try it in combat)", PrintAuraDiagnostics)

-- /ptools framedebug <target|focus|nameplate|player>
-- Lists descendants of a unit frame that look like aura buttons (have an icon
-- or any "aura"-named field), to find how this client's frames expose auras.
local FRAME_DEBUG_ROOTS = {
    target = function() return TargetFrame end,
    focus = function() return FocusFrame end,
    player = function() return BuffFrame end,
    nameplate = function()
        local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("target")
        return plate and plate.UnitFrame
    end,
}
local FRAME_DEBUG_MAX_DEPTH = 7
local FRAME_DEBUG_MAX_LINES = 40
local FRAME_DEBUG_LINE_WIDTH = 220

local baseFrameMethods

-- Widget methods this object has beyond a plain Frame's, plus Lua function
-- fields (mixins), so native types like AuraContainer/AuraButton reveal
-- their API.
local function DistinctiveMethods(object)
    baseFrameMethods = baseFrameMethods or getmetatable(CreateFrame("Frame")).__index

    local names = {}
    local metatable = getmetatable(object)
    local index = metatable and metatable.__index
    if type(index) == "table" then
        for name in pairs(index) do
            if not baseFrameMethods[name] then table.insert(names, name) end
        end
    end
    for key, value in pairs(object) do
        if type(key) == "string" and type(value) == "function" and not baseFrameMethods[key] then
            table.insert(names, key .. "*")
        end
    end
    table.sort(names)
    return names
end

-- Splits a long list into chat-sized lines.
local function AppendWrapped(lines, prefix, items)
    local current = prefix
    for _, item in ipairs(items) do
        if #current + #item + 1 > FRAME_DEBUG_LINE_WIDTH then
            table.insert(lines, current)
            current = "      "
        end
        current = current .. " " .. item
    end
    table.insert(lines, current)
end

local function AuraLikeKeys(frame)
    local keys = {}
    for key, value in pairs(frame) do
        if type(key) == "string" and key:lower():find("aura") then
            table.insert(keys, key .. "=" .. (type(value) == "table" and "table" or Describe(value)))
        end
    end
    return keys
end

local FRAME_DEBUG_MAX_TABLE_KEYS = 30

local function IsWidget(value)
    return type(value) == "table" and type(value[0]) == "userdata" and type(value.GetObjectType) == "function"
end

local function DescribeWidget(widget)
    local _, parent = pcall(widget.GetParent, widget)
    return ("<%s> %s parent=%s shown=%s size=%sx%s children=%s"):format(
        SafeGet(widget, "GetObjectType"), SafeGet(widget, "GetDebugName"),
        IsWidget(parent) and SafeGet(parent, "GetDebugName") or "nil",
        SafeGet(widget, "IsShown"), SafeGet(widget, "GetWidth"), SafeGet(widget, "GetHeight"),
        SafeGet(widget, "GetNumChildren"))
end

-- Read-only getters on Blizzard's unit-frame aura container, describing how
-- it filters, sizes and lays out its buttons.
local CONTAINER_GETTERS = {
    "GetUnit", "IsEnabled", "GetBuffFilterString", "GetDebuffFilterString", "GetBuffTemplate",
    "GetDebuffTemplate", "GetMaxBuffs", "GetLargeAuraSize", "GetSmallAuraSize", "IsPlayerTarget",
    "IsTargetFriendly", "GetFlowLayoutAnchorPoint", "GetFlowLayoutAxis", "GetFlowLayoutSpacing",
    "GetFlowLayoutPadding", "GetFlowLayoutMaximumLineSize",
}

local function DescribeGetters(widget)
    local results = {}
    for _, method in ipairs(CONTAINER_GETTERS) do
        if type(widget[method]) == "function" then
            table.insert(results, method .. "=" .. SafeGet(widget, method))
        end
    end
    return results
end

local function SafeChildren(frame)
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    return ok and children or {}
end

local DumpFrameTree

-- Opens up a table found under an aura-named key: widgets get their API and
-- subtree dumped; plain tables list their keys and drill into the first
-- widget they hold.
local function InspectTable(label, value, lines, describedTypes, seenTables)
    if seenTables[value] then return end
    seenTables[value] = true

    if IsWidget(value) then
        table.insert(lines, "  " .. label .. " = " .. DescribeWidget(value))
        local getters = DescribeGetters(value)
        if #getters > 0 then AppendWrapped(lines, "    getters:", getters) end
        AppendWrapped(lines, "    methods:", DistinctiveMethods(value))
        DumpFrameTree(value, 1, lines, describedTypes, seenTables)
        return
    end

    local keys, firstWidget, firstWidgetKey = {}, nil, nil
    for key, entry in pairs(value) do
        if #keys < FRAME_DEBUG_MAX_TABLE_KEYS then
            table.insert(keys, tostring(key) .. ":" .. (IsWidget(entry) and entry:GetObjectType() or type(entry)))
        end
        if not firstWidget and IsWidget(entry) then firstWidget, firstWidgetKey = entry, key end
    end
    AppendWrapped(lines, "  " .. label .. " = table keys:", keys)
    if firstWidget then
        InspectTable(label .. "." .. tostring(firstWidgetKey), firstWidget, lines, describedTypes, seenTables)
    end
end

DumpFrameTree = function(frame, depth, lines, describedTypes, seenTables)
    if depth > FRAME_DEBUG_MAX_DEPTH then return end
    for _, child in ipairs(SafeChildren(frame)) do
        if #lines >= FRAME_DEBUG_MAX_LINES then return end

        local objectType = SafeGet(child, "GetObjectType")
        local isAuraType = objectType:find("Aura") ~= nil
        local keys = AuraLikeKeys(child)
        local hasIcon = child.Icon or child.icon
        -- Children of an aura container are its buttons; always list them.
        local parentIsContainer = type(frame.GetBuffTemplate) == "function"
        if #keys > 0 or hasIcon or isAuraType or parentIsContainer then
            table.insert(lines, ("  %s icon=%s %s"):format(
                DescribeWidget(child), hasIcon and "yes" or "no", table.concat(keys, " ")))
        end
        if parentIsContainer and not describedTypes["container child " .. objectType] then
            describedTypes["container child " .. objectType] = true
            AppendWrapped(lines, "    button methods:", DistinctiveMethods(child))
        end
        -- Print each native aura type's API once.
        if isAuraType and not describedTypes[objectType] then
            describedTypes[objectType] = true
            AppendWrapped(lines, "    methods:", DistinctiveMethods(child))
        end
        -- Aura-named tables may hold buttons that aren't children of this frame.
        for key, value in pairs(child) do
            if type(key) == "string" and type(value) == "table" and key:lower():find("aura") then
                InspectTable(child:GetDebugName() .. "." .. key, value, lines, describedTypes, seenTables)
            end
        end
        DumpFrameTree(child, depth + 1, lines, describedTypes, seenTables)
    end
end

ns.RegisterSlashCommand("framedebug", "list aura-like child frames: target|focus|nameplate|player", function(arg)
    local which = strtrim(arg or ""):lower()
    local getRoot = FRAME_DEBUG_ROOTS[which ~= "" and which or "target"]
    local root = getRoot and getRoot()
    if not root then
        ns.Print("framedebug: no frame for '" .. which .. "' (use target, focus, nameplate or player)")
        return
    end

    local lines = {}
    DumpFrameTree(root, 1, lines, {}, {})
    table.insert(lines, 1, ("framedebug %s (%s): %d line(s)"):format(root:GetDebugName(), which, #lines))
    for _, line in ipairs(lines) do ns.Print(line) end
    ns.SaveDebugOutput("framedebug " .. which, lines)
end)

---------------------------------------------------------------------------
-- Feature registration
---------------------------------------------------------------------------

ns.RegisterFeature({
    key = FEATURE_KEY,
    label = "Highlight buffs you cast",
    tooltip = "Draws a small border around buffs you provided on your own buff bar.",
    default = true,

    Enable = function()
        enabled = true
        InstallHooks()
        ns.Events.RegisterAll(FEATURE_KEY, handlers, UNITS)
        RequestScan()
    end,

    Disable = function()
        enabled = false
        ns.Events.UnregisterAll(FEATURE_KEY)
        wipe(ownerCache)
        Scan()  -- hides every border and clears lastResult
    end,
})
