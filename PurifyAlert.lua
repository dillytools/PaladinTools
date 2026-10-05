local _, ns = ...

-- Glows the Purify action button whenever the player or a party member has a
-- Poison or Disease debuff.
--
-- Tracks curable debuffs per unit as a set of aura instance IDs:
--   * Aura data readable: full rescan of the unit's debuffs on every change,
--     matching dispel type exactly (authoritative).
--   * Aura data secret (combat): incremental updates from UNIT_AURA's
--     updateInfo, using the secret-safe "dispellable by me" filter check when
--     the client provides it. Best effort; corrected by a full rescan as soon
--     as data is readable again.

local FEATURE_KEY = "purifyAlert"
local PURIFY_SPELL_ID = 1152
local CURABLE_DISPEL_TYPES = { Poison = true, Disease = true }  -- non-localized tokens
local DISPELLABLE_FILTER = "HARMFUL|RAID"
local MAX_DEBUFFS = 40
local GROUP_UNITS = { "player", "party1", "party2", "party3", "party4" }

local purifyNames = {}  -- { [localizedName] = true }, passed to ButtonEffects
local curable = {}      -- [unit] = { [auraInstanceID] = true }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ResolveNames()
    local purifyName = ns.GetSpellName(PURIFY_SPELL_ID)
    if purifyName then purifyNames = { [purifyName] = true } end
end

-- Rebuilds the unit's curable set from its debuffs. Leaves the previous set in
-- place if aura data turns out to be unreadable partway through.
local function FullScan(unit)
    if not UnitExists(unit) then
        curable[unit] = nil
        return
    end
    if not C_UnitAuras then return end

    local found = {}
    for i = 1, MAX_DEBUFFS do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
        if not ok then return end
        if not aura then break end

        local dispelName, auraInstanceID = aura.dispelName, aura.auraInstanceID
        if ns.IsSecret(dispelName) or ns.IsSecret(auraInstanceID) then return end
        if dispelName and CURABLE_DISPEL_TYPES[dispelName] then found[auraInstanceID] = true end
    end
    curable[unit] = found
end

local function IsDispellableByInstance(unit, auraInstanceID)
    if ns.IsSecret(auraInstanceID) or not C_UnitAuras.IsAuraFilteredOutByInstanceID then return false end
    local ok, filteredOut = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, auraInstanceID, DISPELLABLE_FILTER)
    return ok and not ns.IsSecret(filteredOut) and filteredOut == false
end

local function ApplyIncremental(unit, updateInfo)
    local set = curable[unit] or {}
    curable[unit] = set

    for _, auraInstanceID in ipairs(updateInfo.removedAuraInstanceIDs or {}) do
        if not ns.IsSecret(auraInstanceID) then set[auraInstanceID] = nil end
    end
    for _, aura in ipairs(updateInfo.addedAuras or {}) do
        local auraInstanceID = aura.auraInstanceID
        if IsDispellableByInstance(unit, auraInstanceID) then set[auraInstanceID] = true end
    end
end

local function UpdateUnit(unit, updateInfo)
    if not ns.AurasAreSecret() then
        FullScan(unit)
        return
    end

    -- A full update while secret can't be enumerated; keep the current state
    -- until the next readable rescan.
    local isFullUpdate = updateInfo and updateInfo.isFullUpdate
    if updateInfo and not ns.IsSecret(isFullUpdate) and not isFullUpdate then
        ApplyIncremental(unit, updateInfo)
    end
end

local function RescanAll()
    local secret = ns.AurasAreSecret()
    for _, unit in ipairs(GROUP_UNITS) do
        if secret then
            -- Party tokens may now point at different people; drop stale state.
            curable[unit] = UnitExists(unit) and {} or nil
        else
            FullScan(unit)
        end
    end
end

local function UnitNeedsCure(unit)
    local set = curable[unit]
    if not set or next(set) == nil or not UnitExists(unit) then return false end

    local isDead = UnitIsDeadOrGhost(unit)
    if ns.IsSecret(isDead) then return true end
    return not isDead
end

local function Evaluate()
    local glow = false
    for _, unit in ipairs(GROUP_UNITS) do
        if UnitNeedsCure(unit) then
            glow = true
            break
        end
    end
    ns.ButtonEffects.Set(FEATURE_KEY, glow, purifyNames, ns.ButtonEffects.Style.Glow)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

function handlers.UNIT_AURA(unit, updateInfo)
    UpdateUnit(unit, updateInfo)
    Evaluate()
end

function handlers.GROUP_ROSTER_UPDATE()
    RescanAll()
    Evaluate()
end

-- Aura data becomes readable again; replace best-effort state with a real scan.
function handlers.PLAYER_REGEN_ENABLED()
    RescanAll()
    Evaluate()
end

function handlers.PLAYER_ENTERING_WORLD()
    ResolveNames()
    RescanAll()
    Evaluate()
end

local UNITS = {
    UNIT_AURA = GROUP_UNITS,
}

---------------------------------------------------------------------------
-- Feature registration
---------------------------------------------------------------------------

ns.RegisterFeature({
    key = FEATURE_KEY,
    label = "Glow Purify when a poison or disease can be cured",
    tooltip = "Glows your Purify action button whenever you or a party member has a Poison or Disease.",
    default = true,

    Enable = function()
        ResolveNames()
        ns.Events.RegisterAll(FEATURE_KEY, handlers, UNITS)
        RescanAll()
        Evaluate()
    end,

    Disable = function()
        ns.Events.UnregisterAll(FEATURE_KEY)
        wipe(curable)
        ns.ButtonEffects.Stop(FEATURE_KEY)
    end,
})
