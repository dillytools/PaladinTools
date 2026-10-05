local _, ns = ...

-- Exorcism only works on Undead and Demons, so this makes its action button
-- reflect that:
--   * Glow:     in combat with a living, attackable Undead/Demon target
--               (optionally only while Exorcism is off cooldown).
--   * Grey out: any other time, including out of combat.

local FEATURE_KEY = "exorcismAlert"
local OWNER_GLOW = FEATURE_KEY .. ".glow"
local OWNER_DIM = FEATURE_KEY .. ".dim"
local OPTION_ONLY_OFF_CD = "exorcismOnlyOffCooldown"
local OPTION_DIM = "exorcismDimOtherwise"

local EXORCISM_SPELL_ID = 879
local GCD_SPELL_ID = 61304

-- Creature type IDs (stable across locales); English names are the fallback
-- when the client can't resolve localized names.
local CREATURE_TYPES = {
    { id = 3, fallbackName = "Demon" },
    { id = 6, fallbackName = "Undead" },
}

local Style = ns.ButtonEffects.Style

local exorcismNames = {}       -- { [localizedName] = true }, passed to ButtonEffects
local validCreatureTypes = {}  -- [localizedName] = true
local inCombat = false
local readyTimer

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ResolveNames()
    local exorcismName = ns.GetSpellName(EXORCISM_SPELL_ID)
    if exorcismName then exorcismNames = { [exorcismName] = true } end

    for _, creatureType in ipairs(CREATURE_TYPES) do
        local name = creatureType.fallbackName
        if C_CreatureInfo and C_CreatureInfo.GetCreatureTypeInfo then
            local info = C_CreatureInfo.GetCreatureTypeInfo(creatureType.id)
            if info and info.name then name = info.name end
        end
        validCreatureTypes[name] = true
    end
end

local function IsValidTarget()
    if not UnitExists("target") then return false end

    local canAttack = UnitCanAttack("player", "target")
    local isDead = UnitIsDead("target")
    local creatureType = UnitCreatureType("target")
    if ns.IsSecret(canAttack) or ns.IsSecret(isDead) or ns.IsSecret(creatureType) then return false end

    return canAttack and not isDead and creatureType ~= nil and validCreatureTypes[creatureType] == true
end

-- Returns start, duration, or nil if the values are secret.
local function GetCooldown(spellId)
    local start, duration
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellId)
        if info then start, duration = info.startTime, info.duration end
    elseif GetSpellCooldown then
        start, duration = GetSpellCooldown(spellId)
    end
    if ns.IsSecret(start) or ns.IsSecret(duration) then return nil end
    return start or 0, duration or 0
end

-- Seconds until Exorcism is ready (0 when ready or only on the GCD), or nil
-- if cooldown data is currently unreadable.
local function ExorcismCooldownRemaining()
    local start, duration = GetCooldown(EXORCISM_SPELL_ID)
    if not start then return nil end
    if duration == 0 then return 0 end

    local gcdStart, gcdDuration = GetCooldown(GCD_SPELL_ID)
    if gcdStart == start and gcdDuration == duration then return 0 end

    return math.max(0, start + duration - GetTime())
end

local function CancelReadyTimer()
    if readyTimer then
        readyTimer:Cancel()
        readyTimer = nil
    end
end

---------------------------------------------------------------------------
-- Core logic
---------------------------------------------------------------------------

local function Evaluate()
    CancelReadyTimer()

    local active = inCombat and IsValidTarget()
    local glow = active

    if glow and ns.GetOption(OPTION_ONLY_OFF_CD) then
        -- Unreadable cooldown data falls back to glowing rather than hiding the cue.
        local remaining = ExorcismCooldownRemaining()
        if remaining and remaining > 0 then
            glow = false
            readyTimer = C_Timer.NewTimer(remaining, Evaluate)
        end
    end

    ns.ButtonEffects.Set(OWNER_GLOW, glow, exorcismNames, Style.Glow)
    ns.ButtonEffects.Set(OWNER_DIM, not active and ns.GetOption(OPTION_DIM), exorcismNames, Style.Dim)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {
    PLAYER_TARGET_CHANGED = Evaluate,
    SPELL_UPDATE_COOLDOWN = Evaluate,
    -- Target death / faction changes.
    UNIT_FLAGS = Evaluate,
    UNIT_HEALTH = Evaluate,
}

function handlers.PLAYER_REGEN_DISABLED()
    inCombat = true
    Evaluate()
end

function handlers.PLAYER_REGEN_ENABLED()
    inCombat = false
    Evaluate()
end

function handlers.PLAYER_ENTERING_WORLD()
    ResolveNames()
    inCombat = UnitAffectingCombat("player") == true
    Evaluate()
end

local UNITS = {
    UNIT_FLAGS = { "target" },
    UNIT_HEALTH = { "target" },
}

---------------------------------------------------------------------------
-- Feature registration
---------------------------------------------------------------------------

ns.RegisterFeature({
    key = FEATURE_KEY,
    label = "Exorcism highlight vs Undead and Demons",
    tooltip = "While in combat, glows your Exorcism action button when your target is an attackable Undead or Demon.",
    default = true,

    options = {
        {
            type = "checkbox",
            key = OPTION_ONLY_OFF_CD,
            label = "Only glow when off cooldown",
            tooltip = "When unchecked, Exorcism glows against Undead and Demons regardless of its cooldown.",
            default = false,
            OnChanged = Evaluate,
        },
        {
            type = "checkbox",
            key = OPTION_DIM,
            label = "Grey out when not usable",
            tooltip = "Desaturates the Exorcism button unless you're in combat with an Undead or Demon target.",
            default = true,
            OnChanged = Evaluate,
        },
    },

    Enable = function()
        ResolveNames()
        inCombat = UnitAffectingCombat("player") == true
        ns.Events.RegisterAll(FEATURE_KEY, handlers, UNITS)
        Evaluate()
    end,

    Disable = function()
        ns.Events.UnregisterAll(FEATURE_KEY)
        CancelReadyTimer()
        ns.ButtonEffects.Stop(OWNER_GLOW)
        ns.ButtonEffects.Stop(OWNER_DIM)
    end,
})
