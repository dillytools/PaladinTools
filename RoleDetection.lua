local _, ns = ...

-- Resolves a friendly unit to a blessing role (keys of
-- BlessingPriorities.Roles). Sources, most trusted first:
--   1. Manual override, saved per player name (/ptools role).
--   2. Telling auras: druid forms (bear -> tank, cat -> melee, moonkin ->
--      caster), Righteous Fury and Defensive Stance (-> tank).
--   3. Talents: your own directly; other players through inspect, cached
--      per GUID for the session. Tries modern spec IDs, then points per tree.
--   4. Group role (UnitGroupRolesAssigned).
--   5. The class's most common role.
-- Inspect needs the player within ~28 yd and out of combat, so a fresh target
-- may resolve from a weaker source until the reply arrives.

local RoleDetection = {}
ns.RoleDetection = RoleDetection

local EVENT_OWNER = "RoleDetection"
local INSPECT_THROTTLE = 1.5    -- seconds between inspect requests
local INSPECT_DISTANCE_INDEX = 1 -- CheckInteractDistance: inspect range

local Data = ns.BlessingPriorities

local inspectedRoles = {}  -- [guid] = role, or false if inspected but unknown
local pendingGuid
local lastRequestTime = 0

---------------------------------------------------------------------------
-- Safe reads
---------------------------------------------------------------------------

-- Returns the value, or nil if the call failed or the result is secret.
local function SafeRead(fn, ...)
    if not fn then return nil end
    local ok, value = pcall(fn, ...)
    if not ok or ns.IsSecret(value) then return nil end
    return value
end

local function GetClassFile(unit)
    local ok, _, classFile = pcall(UnitClass, unit)
    if not ok or ns.IsSecret(classFile) then return nil end
    return classFile
end

-- "Name" or "Name-Realm" for other realms.
local function GetOverrideKey(unit)
    return SafeRead(GetUnitName, unit, true)
end

local function GetOverrides()
    ns.db.blessingRoleOverrides = ns.db.blessingRoleOverrides or {}
    return ns.db.blessingRoleOverrides
end

---------------------------------------------------------------------------
-- Talents
---------------------------------------------------------------------------

-- Points spent in one tree. GetTalentTabInfo's returns differ by client
-- generation: (name, icon, pointsSpent, ...) vs (id, name, description,
-- icon, pointsSpent, ...); the first return's type tells them apart.
local function PointsInTab(tab, isInspect)
    if not GetTalentTabInfo then return nil end
    local ok, first, _, third, _, fifth = pcall(GetTalentTabInfo, tab, isInspect)
    if not ok or ns.IsSecret(first) then return nil end

    local points = type(first) == "string" and third or fifth
    if ns.IsSecret(points) or type(points) ~= "number" then return nil end
    return points
end

local function RoleFromTalentPoints(classFile, isInspect)
    local tabs = Data.RoleByTalentTab[classFile]
    if not tabs then return nil end

    local bestTab, bestPoints = nil, 0
    for tab = 1, #tabs do
        local points = PointsInTab(tab, isInspect)
        if points and points > bestPoints then bestTab, bestPoints = tab, points end
    end
    return bestTab and tabs[bestTab]
end

local function RoleFromSpecId(specId)
    if type(specId) ~= "number" or specId == 0 then return nil end
    return Data.RoleBySpecId[specId]
end

local function ReadOwnRole(classFile)
    local specIndex = SafeRead(GetSpecialization)
    if type(specIndex) == "number" and GetSpecializationInfo then
        local role = RoleFromSpecId(SafeRead(GetSpecializationInfo, specIndex))
        if role then return role end
    end
    return RoleFromTalentPoints(classFile, false)
end

local function ReadInspectedRole(unit, classFile)
    local role = RoleFromSpecId(SafeRead(GetInspectSpecialization, unit))
    return role or RoleFromTalentPoints(classFile, true)
end

---------------------------------------------------------------------------
-- Inspect
---------------------------------------------------------------------------

local function UserIsInspecting()
    return InspectFrame ~= nil and InspectFrame:IsShown()
end

-- Asks the server for the unit's talents if we don't have them yet.
function RoleDetection.RequestInspect(unit)
    if InCombatLockdown() or UserIsInspecting() then return end
    if not NotifyInspect or not SafeRead(UnitIsPlayer, unit) or SafeRead(UnitIsUnit, unit, "player") then return end

    local guid = SafeRead(UnitGUID, unit)
    if not guid or inspectedRoles[guid] ~= nil then return end
    if CanInspect and not SafeRead(CanInspect, unit) then return end
    if CheckInteractDistance and not SafeRead(CheckInteractDistance, unit, INSPECT_DISTANCE_INDEX) then return end

    local now = GetTime()
    if now - lastRequestTime < INSPECT_THROTTLE then return end
    lastRequestTime = now
    pendingGuid = guid
    NotifyInspect(unit)
end

local handlers = {}

function handlers.INSPECT_READY(guid)
    if not pendingGuid or ns.IsSecret(guid) or guid ~= pendingGuid then return end
    pendingGuid = nil

    if SafeRead(UnitGUID, "target") ~= guid then return end
    local classFile = GetClassFile("target")
    inspectedRoles[guid] = (classFile and ReadInspectedRole("target", classFile)) or false

    if ClearInspectPlayer and not UserIsInspecting() then ClearInspectPlayer() end
end

function handlers.PLAYER_TARGET_CHANGED()
    RoleDetection.RequestInspect("target")
end

function RoleDetection.Start()
    ns.Events.RegisterAll(EVENT_OWNER, handlers)
    RoleDetection.RequestInspect("target")
end

function RoleDetection.Stop()
    ns.Events.UnregisterAll(EVENT_OWNER)
    pendingGuid = nil
end

---------------------------------------------------------------------------
-- Resolve
---------------------------------------------------------------------------

local function RoleFromAuras(auraSpellIds)
    for spellId in pairs(auraSpellIds or {}) do
        local role = Data.RoleByAuraSpellId[spellId]
        if role then return role end
    end
end

local function RoleFromGroup(unit, classFile)
    local assigned = SafeRead(UnitGroupRolesAssigned, unit)
    if assigned == "TANK" then return "TANK" end
    if assigned == "HEALER" then return "HEALER" end
    if assigned == "DAMAGER" then return Data.DamageRoleByClass[classFile] end
end

-- auraSpellIds: optional set of the unit's helpful aura spell IDs.
-- Returns role, source (a short label), classFile.
function RoleDetection.Resolve(unit, auraSpellIds)
    if not SafeRead(UnitIsPlayer, unit) then return "PET", "not a player" end

    local classFile = GetClassFile(unit)
    if not classFile then return "PET", "class unknown" end

    local overrideKey = GetOverrideKey(unit)
    local override = overrideKey and GetOverrides()[overrideKey]
    if override and Data.Roles[override] then return override, "manual", classFile end

    local role = RoleFromAuras(auraSpellIds)
    if role then return role, "aura", classFile end

    if SafeRead(UnitIsUnit, unit, "player") then
        role = ReadOwnRole(classFile)
        if role then return role, "talents", classFile end
    else
        local guid = SafeRead(UnitGUID, unit)
        role = guid and inspectedRoles[guid]
        if role then return role, "inspect", classFile end
    end

    role = RoleFromGroup(unit, classFile)
    if role then return role, "group role", classFile end

    return Data.DefaultRoleByClass[classFile] or "MELEE", "class default", classFile
end

-- role: a Roles key, or nil to clear. Returns the player name, or nil if the
-- unit isn't a nameable player.
function RoleDetection.SetOverride(unit, role)
    if not SafeRead(UnitIsPlayer, unit) then return nil end
    local key = GetOverrideKey(unit)
    if not key then return nil end
    GetOverrides()[key] = role
    return key
end
