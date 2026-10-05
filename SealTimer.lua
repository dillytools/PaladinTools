local _, ns = ...

-- Flashes the active seal's action button once it has the configured warning
-- time or less remaining, but only while in combat. Stops when the seal is
-- recast, swapped, judged, expires, or combat ends.
--
-- Aura data is secret in combat and reading it from addon code throws. So the
-- seal is tracked from the player's own casts (seal cast starts a
-- SEAL_DURATION timer, Judgement consumes it), and aura data is only used to
-- reconcile that state when it is readable.

local FEATURE_KEY = "sealExpiryFlash"
local WARNING_OPTION_KEY = "sealWarningSeconds"
local SEAL_DURATION = 30

-- One ID per seal. Every rank shares the same localized name, so casts, auras
-- and action buttons are matched by name rather than per-rank IDs.
local SEAL_SPELL_IDS = {
    20154, -- Seal of Righteousness
    20375, -- Seal of Command
    21082, -- Seal of the Crusader
    20166, -- Seal of Wisdom
    20165, -- Seal of Light
    20164, -- Seal of Justice
}
local JUDGEMENT_SPELL_ID = 20271

local sealNames = {}  -- [localizedName] = true
local judgementName
local trackedName, trackedExpiration
local trackedNames    -- { [trackedName] = true }, stable per seal for ButtonEffects
local warningDue = false
local inCombat = false
local warnTimer

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ResolveSpellNames()
    for _, spellId in ipairs(SEAL_SPELL_IDS) do
        local name = ns.GetSpellName(spellId)
        if name then sealNames[name] = true end
    end
    judgementName = ns.GetSpellName(JUDGEMENT_SPELL_ID)
end

-- Returns readable, name, expirationTime. readable == false means aura data is
-- currently secret and the caller should keep its cast-based state.
local function ReadActiveSeal()
    if ns.AurasAreSecret() or not C_UnitAuras then return false end

    for i = 1, 40 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok then return false end
        if not aura then return true end

        local name, expirationTime = aura.name, aura.expirationTime
        if ns.IsSecret(name) or ns.IsSecret(expirationTime) then return false end
        if sealNames[name] then return true, name, expirationTime end
    end
    return true
end

---------------------------------------------------------------------------
-- Tracking
---------------------------------------------------------------------------

-- The flash shows only while the warning threshold has been reached AND the
-- player is in combat; leaving combat hides it, re-entering shows it again.
local function UpdateFlash()
    local show = warningDue and inCombat and trackedNames ~= nil
    ns.ButtonEffects.Set(FEATURE_KEY, show, trackedNames, ns.ButtonEffects.Style.Alert)
end

local function CancelWarnTimer()
    if warnTimer then
        warnTimer:Cancel()
        warnTimer = nil
    end
end

local function OnWarningDue()
    warnTimer = nil
    warningDue = true
    UpdateFlash()
end

local function Untrack()
    CancelWarnTimer()
    warningDue = false
    trackedName, trackedExpiration, trackedNames = nil, nil, nil
    UpdateFlash()
end

-- (Re)arms the warning for the currently tracked seal.
local function ScheduleWarning()
    CancelWarnTimer()
    warningDue = false

    if trackedName then
        local untilWarning = trackedExpiration - ns.GetOption(WARNING_OPTION_KEY) - GetTime()
        if untilWarning <= 0 then
            warningDue = true
        else
            warnTimer = C_Timer.NewTimer(untilWarning, OnWarningDue)
        end
    end

    UpdateFlash()
end

local function Track(name, expirationTime)
    if name == trackedName and expirationTime == trackedExpiration then return end
    if name ~= trackedName then trackedNames = { [name] = true } end
    trackedName, trackedExpiration = name, expirationTime
    ScheduleWarning()
end

-- Corrects cast-based state from real aura data when it is readable.
local function Reconcile()
    local readable, name, expirationTime = ReadActiveSeal()
    if not readable then return end

    if name and expirationTime and expirationTime > 0 then
        Track(name, expirationTime)
    else
        Untrack()
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

function handlers.UNIT_SPELLCAST_SUCCEEDED(_, _, spellId)
    if ns.IsSecret(spellId) then return end

    local name = ns.GetSpellName(spellId)
    if not name then return end

    if sealNames[name] then
        Track(name, GetTime() + SEAL_DURATION)
    elseif name == judgementName then
        Untrack()
    end
end

function handlers.UNIT_AURA()
    Reconcile()
end

function handlers.PLAYER_DEAD()
    Untrack()
end

function handlers.PLAYER_REGEN_DISABLED()
    inCombat = true
    UpdateFlash()
end

function handlers.PLAYER_REGEN_ENABLED()
    inCombat = false
    UpdateFlash()
    Reconcile()
end

function handlers.PLAYER_ENTERING_WORLD()
    ResolveSpellNames()
    inCombat = UnitAffectingCombat("player") == true
    Reconcile()
    UpdateFlash()
end

local UNITS = {
    UNIT_SPELLCAST_SUCCEEDED = { "player" },
    UNIT_AURA = { "player" },
}

---------------------------------------------------------------------------
-- Feature registration
---------------------------------------------------------------------------

ns.RegisterFeature({
    key = FEATURE_KEY,
    label = "Flash seal button before it expires",
    tooltip = "While in combat, flashes your active seal's action button red when it is about to expire.",
    default = true,

    options = {
        {
            type = "slider",
            key = WARNING_OPTION_KEY,
            label = "Warning time",
            tooltip = "Seconds before the seal expires to start flashing.",
            min = 1,
            max = 25,
            step = 1,
            default = 5,
            format = "%d sec",
            OnChanged = ScheduleWarning,
        },
    },

    Enable = function()
        ResolveSpellNames()
        inCombat = UnitAffectingCombat("player") == true
        ns.Events.RegisterAll(FEATURE_KEY, handlers, UNITS)
        Reconcile()
    end,

    Disable = function()
        ns.Events.UnregisterAll(FEATURE_KEY)
        Untrack()
    end,
})
