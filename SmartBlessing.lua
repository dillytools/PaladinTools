local _, ns = ...

-- One keybind to spam while walking around: each press casts the best
-- Blessing of Kings, Wisdom or Might on the closest other player who doesn't
-- have your blessing yet and still has a blessing they could use. Never
-- yourself. Optionally ("bless your target first") a friendly target other
-- than you takes precedence.
-- BlessingPlanner decides who and what; this file owns the secure button.
--
-- Casting needs a hardware event, so the keybind (Bindings.xml) clicks a
-- secure action button. Its spell and unit attributes are set in PreClick,
-- right before the secure handler runs; addon code may only do that out of
-- combat, and aura data is secret in combat anyway, so the button is emptied
-- for combat.
--
-- Skip list: a player just blessed is passed over briefly (their aura may not
-- show yet), and one whose blessing fails with a range, line-of-sight or
-- bad-target error is passed over longer so the next press moves on.

local FEATURE_KEY = "smartBlessing"
local OPTION_ONE_PER_CASTER = "smartBlessingOnePerCaster"
-- Renamed from smartBlessingPreferTarget so the new default (off) applies.
local OPTION_TARGET_FIRST = "smartBlessingTargetFirst"
local OPTION_ANNOUNCE = "smartBlessingAnnounce"
local BUTTON_NAME = "PaladinToolsBlessButton"
-- A keybind sends a down and an up click within this window; reuse one plan.
local PLAN_REUSE_SECONDS = 0.3
-- A cast failure this soon after a press is blamed on that press's player.
local FAILURE_WINDOW_SECONDS = 1.0
local FAILED_SKIP_SECONDS = 10
-- Covers the delay before a new blessing shows on the player.
local BLESSED_SKIP_SECONDS = 2

local Data = ns.BlessingPriorities
local Planner = ns.BlessingPlanner
local GetCVarBoolCompat = (C_CVar and C_CVar.GetCVarBool) or GetCVarBool

-- Key Bindings > AddOns > Paladin Tools. The bindings UI looks these up as
-- globals by name, so they are deliberate global exceptions.
BINDING_HEADER_PALADINTOOLS = "Paladin Tools"
_G["BINDING_NAME_CLICK " .. BUTTON_NAME .. ":LeftButton"] = "Cast best blessing"

local enabled = false
local pendingClear = false  -- clear the button once combat ends
local traceClicks = false   -- /ptools blesstrace
local lastPrepared      -- { time, plan }
local lastCast          -- { guid, time } of the latest press, for its result
local warnedThisCombat = false
local skipUntil = {}    -- [guid] = GetTime() when the skip expires

local function OnePerCaster() return ns.GetOption(OPTION_ONE_PER_CASTER) == true end

local function IsTrue(fn, ...)
    local ok, value = pcall(fn, ...)
    return ok and not ns.IsSecret(value) and value == true
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------

local function HasOtherFriendlyTarget()
    return UnitExists("target")
        and not IsTrue(UnitIsUnit, "target", "player")
        and IsTrue(UnitCanAssist, "player", "target")
        and not IsTrue(UnitIsDeadOrGhost, "target")
end

local function ActiveSkips()
    local now, active = GetTime(), {}
    for guid, expires in pairs(skipUntil) do
        if expires > now then active[guid] = true else skipUntil[guid] = nil end
    end
    return active
end

-- Returns the plan for this press, or nil if nobody in range needs a
-- blessing or aura data is unreadable.
local function PlanForPress()
    if ns.GetOption(OPTION_TARGET_FIRST) and HasOtherFriendlyTarget() then
        return Planner.BuildPlan("target", OnePerCaster())
    end
    return Planner.FindClosestUnblessed(OnePerCaster(), ActiveSkips())
end

---------------------------------------------------------------------------
-- Secure button
---------------------------------------------------------------------------

local button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
-- Key bindings send a down and an up click; the secure template acts on the
-- one matching the ActionButtonUseKeyDown CVar, so listen for both.
button:RegisterForClicks("AnyDown", "AnyUp")

local CAST_ATTRIBUTES = { "type", "spell", "unit", "macrotext" }

-- Unit tokens the client accepts as a cast target. It silently refuses
-- nameplateN, so players found only through a nameplate are targeted by
-- name instead.
local function IsCastableToken(unit)
    return unit == "target" or unit:match("^party%d") ~= nil or unit:match("^raid%d") ~= nil
end

-- Target by name, cast, then put your old target back (or clear it).
local function TargetByNameMacro(fullName, castText)
    local restore = UnitExists("target") and "/targetlasttarget" or "/cleartarget"
    return ("/targetexact %s\n/cast %s\n%s"):format(fullName, castText, restore)
end

-- /cast text for the macro path. A bare name casts your highest rank, so the
-- rank is only spelled out ("Name(Rank 3)") when a lower one was picked.
local function CastText(plan, spellName)
    if plan.isHighestRank or not plan.rankSpellId then return spellName end
    local rankText = Planner.RankText(plan.rankSpellId)
    return rankText and ("%s(%s)"):format(spellName, rankText) or spellName
end

-- Loads the plan into the button, or empties it (plan nil / no choice).
-- Unit tokens (raidN, nameplateN) are only valid right now, which is fine
-- because the cast follows immediately.
local function LoadCast(plan)
    if InCombatLockdown() then return end
    for _, attribute in ipairs(CAST_ATTRIBUTES) do button:SetAttribute(attribute, nil) end

    local spellName = plan and plan.choice and ns.GetSpellName(Data.Blessings[plan.choice].castSpellId)
    if not spellName then return end

    if IsCastableToken(plan.unit) then
        -- A numeric spell attribute casts that exact rank (CastSpellByID).
        button:SetAttribute("type", "spell")
        button:SetAttribute("spell", plan.rankSpellId or spellName)
        button:SetAttribute("unit", plan.unit)
    elseif plan.fullName then
        button:SetAttribute("type", "macro")
        button:SetAttribute("macrotext", TargetByNameMacro(plan.fullName, CastText(plan, spellName)))
    end
end

local function ClearCast()
    if InCombatLockdown() then
        pendingClear = true
        return
    end
    pendingClear = false
    LoadCast(nil)
end

-- Builds the plan for this press and loads it into the button. The down and
-- up clicks of one keypress share a plan.
local function PrepareForPress()
    local now = GetTime()
    if lastPrepared and now - lastPrepared.time < PLAN_REUSE_SECONDS then
        return lastPrepared.plan
    end

    local plan = PlanForPress()
    LoadCast(plan)
    lastPrepared = { time = now, plan = plan }
    return plan
end

-- The secure template only acts on one of the two clicks a keybind sends.
local function IsActingClick(down)
    return down == (GetCVarBoolCompat ~= nil and GetCVarBoolCompat("ActionButtonUseKeyDown") == true)
end

local function DescribeRole(plan)
    return ("%s, %s"):format(Data.Roles[plan.role].label, plan.roleSource)
end

local function ReportPress(plan)
    if not plan then
        ns.Print("no one in range needs a blessing.")
    elseif not plan.choice then
        ns.Print(("%s already has every blessing you can give."):format(plan.name or "Target"))
    elseif ns.GetOption(OPTION_ANNOUNCE) then
        ns.Print(("%s on %s (%s)"):format(Planner.DescribeCast(plan), plan.name or "?", DescribeRole(plan)))
    end
end

local function Trace(stage, mouseButton, down)
    if not traceClicks then return end
    local macrotext = button:GetAttribute("macrotext")
    ns.Print(("%s button=%s down=%s acting=%s combat=%s type=%s spell=%s unit=%s macro=%s"):format(
        stage, tostring(mouseButton), tostring(down), tostring(IsActingClick(down)), tostring(InCombatLockdown()),
        tostring(button:GetAttribute("type")), tostring(button:GetAttribute("spell")), tostring(button:GetAttribute("unit")),
        macrotext and macrotext:gsub("\n", " | ") or "nil"))
end

button:SetScript("PostClick", function(_, mouseButton, down)
    Trace("post", mouseButton, down)
end)

button:SetScript("PreClick", function(_, mouseButton, down)
    Trace("pre", mouseButton, down)
    if not enabled then return end
    if InCombatLockdown() then
        if not warnedThisCombat and IsActingClick(down) then
            warnedThisCombat = true
            ns.Print("the blessing hotkey is off in combat.")
        end
        return
    end

    local plan = PrepareForPress()
    if not IsActingClick(down) then return end

    lastCast = (plan and plan.choice and plan.guid) and { guid = plan.guid, time = GetTime() } or nil
    ReportPress(plan)
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

-- Last moment attributes can change. Unit tokens and auras can't be
-- re-checked in combat, so a stale cast could bless the wrong player.
function handlers.PLAYER_REGEN_DISABLED()
    lastPrepared = nil
    warnedThisCombat = false
    ClearCast()
end

function handlers.PLAYER_REGEN_ENABLED()
    if pendingClear then ClearCast() end
end

-- Errors that mean "this player can't be blessed from here". Anything else
-- (notably "spell not ready" while spamming the key on the global cooldown)
-- says nothing about the player and must not skip them.
local PLAYER_FAILURE_MESSAGES = {}
for _, globalName in ipairs({
    "SPELL_FAILED_LINE_OF_SIGHT", "SPELL_FAILED_OUT_OF_RANGE", "ERR_OUT_OF_RANGE",
    "SPELL_FAILED_BAD_TARGETS", "SPELL_FAILED_TARGET_NOT_IN_INSTANCE", "SPELL_FAILED_LOWLEVEL",
}) do
    local message = _G[globalName]
    if type(message) == "string" then PLAYER_FAILURE_MESSAGES[message] = true end
end

local function SkipLastCast(seconds)
    if not lastCast or GetTime() - lastCast.time > FAILURE_WINDOW_SECONDS then return end
    skipUntil[lastCast.guid] = GetTime() + seconds
    lastCast = nil
end

function handlers.UI_ERROR_MESSAGE(_, message)
    if ns.IsSecret(message) or not PLAYER_FAILURE_MESSAGES[message] then return end
    SkipLastCast(FAILED_SKIP_SECONDS)
end

function handlers.UNIT_SPELLCAST_SUCCEEDED()
    SkipLastCast(BLESSED_SKIP_SECONDS)
end

local UNITS = {
    UNIT_SPELLCAST_SUCCEEDED = { "player" },
}

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function DescribeBlessings(blessings)
    local parts = {}
    for _, key in ipairs({ "KINGS", "WISDOM", "MIGHT" }) do
        if blessings[key] then table.insert(parts, ("%s (%s)"):format(Planner.BlessingName(key), blessings[key])) end
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function PrintPlan(plan)
    local distance = plan.distance and (" ~%d yd"):format(math.floor(plan.distance + 0.5)) or ""
    local level = plan.level and (" lvl %d"):format(plan.level) or ""
    ns.Print(("next: %s%s%s: %s (%s)"):format(plan.name or plan.unit, level, distance, plan.classFile or "?", DescribeRole(plan)))
    ns.Print("  has: " .. DescribeBlessings(plan.blessings))
    ns.Print("  would cast: " .. (plan.choice and Planner.DescribeCast(plan) or "nothing"))
end

ns.RegisterSlashCommand("bless", "show what the blessing hotkey would do right now", function()
    if InCombatLockdown() then
        ns.Print("buffs can't be read in combat.")
        return
    end
    local plan = PlanForPress()
    if plan then
        PrintPlan(plan)
    else
        ns.Print("no one in range needs a blessing.")
    end
end)

ns.RegisterSlashCommand("blesstrace", "toggle printing every blessing-hotkey click (debug)", function()
    traceClicks = not traceClicks
    ns.Print("blessing hotkey trace " .. (traceClicks and "on" or "off"))
end)

local function RoleNames()
    local names = {}
    for key in pairs(Data.Roles) do table.insert(names, key:lower()) end
    table.sort(names)
    return table.concat(names, "/")
end

ns.RegisterSlashCommand("role", "set your target's blessing role: " .. RoleNames() .. "/auto", function(arg)
    local role = strtrim(arg or ""):upper()
    if role == "" then
        if UnitExists("target") then
            local current, source = ns.RoleDetection.Resolve("target")
            ns.Print(("target role: %s (%s)"):format(Data.Roles[current].label, source))
        end
        ns.Print(("usage: /ptools role %s/auto"):format(RoleNames()))
        return
    end
    if role ~= "AUTO" and not Data.Roles[role] then
        ns.Print("unknown role. Use one of: " .. RoleNames() .. "/auto")
        return
    end

    local name = ns.RoleDetection.SetOverride("target", role ~= "AUTO" and role or nil)
    if not name then
        ns.Print("target a player first.")
    elseif role == "AUTO" then
        ns.Print(name .. " uses the detected role again.")
    else
        ns.Print(("%s is now treated as %s."):format(name, Data.Roles[role].label))
    end
end)

---------------------------------------------------------------------------
-- Feature registration
---------------------------------------------------------------------------

ns.RegisterFeature({
    key = FEATURE_KEY,
    label = "Smart blessing hotkey",
    tooltip = "Bind a key under Options > Keybindings > AddOns > Paladin Tools and spam it while walking around. Each press casts the best of Kings, Wisdom or Might, for their class and spec, on the closest other player who doesn't have your blessing yet. Never you. Off in combat. /ptools bless previews the next pick; /ptools role overrides a player's role.",
    default = true,
    options = {
        {
            type = "checkbox",
            key = OPTION_TARGET_FIRST,
            label = "Bless your target first",
            tooltip = "With another friendly player targeted, bless them (refreshing your blessing if they have it) instead of searching. Players outside your group are only found while their nameplate is shown.",
            default = false,
        },
        {
            type = "checkbox",
            key = OPTION_ONE_PER_CASTER,
            label = "One blessing per paladin per target",
            tooltip = "Classic rule: each paladin's new blessing replaces their previous one on that target. When on, anyone with your blessing counts as done, and pressing on your target refreshes it instead of replacing it. Turn off if your blessings stack.",
            default = true,
        },
        {
            type = "checkbox",
            key = OPTION_ANNOUNCE,
            label = "Print each blessing cast",
            tooltip = "Prints the chosen blessing, player and detected role in chat on each press.",
            default = false,
        },
    },

    Enable = function()
        enabled = true
        ns.Events.RegisterAll(FEATURE_KEY, handlers, UNITS)
        ns.RoleDetection.Start()
    end,

    Disable = function()
        enabled = false
        ns.Events.UnregisterAll(FEATURE_KEY)
        ns.RoleDetection.Stop()
        lastPrepared, lastCast = nil, nil
        wipe(skipUntil)
        ClearCast()
        -- Keep listening so a clear queued in combat still lands.
        if pendingClear then ns.Events.Register(FEATURE_KEY, "PLAYER_REGEN_ENABLED", handlers.PLAYER_REGEN_ENABLED) end
    end,
})
