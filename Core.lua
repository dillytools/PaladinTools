local addonName, ns = ...

---------------------------------------------------------------------------
-- Events
-- One event frame for the whole addon. Modules subscribe under an owner key
-- with a table of [event] = handler; dispatch is a table lookup per event.
-- Subscriber tables are copy-on-write so handlers can (un)register freely
-- while an event is being dispatched.
---------------------------------------------------------------------------

local Events = {}
ns.Events = Events

local eventFrame = CreateFrame("Frame")
local subscribers = {}  -- [event] = { [owner] = { handler = fn, units = set|nil } }

local function CopySubscribers(subs)
    local copy = {}
    for owner, entry in pairs(subs or {}) do copy[owner] = entry end
    return copy
end

local function IsEventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then return C_EventUtils.IsEventValid(event) end
    return true
end

-- units: optional array of unit tokens. For unit events, calls for other units
-- are dropped before reaching the handler.
function Events.Register(owner, event, handler, units)
    if not IsEventValid(event) then return end

    local unitSet
    if units then
        unitSet = {}
        for _, unit in ipairs(units) do unitSet[unit] = true end
    end

    local wasEmpty = subscribers[event] == nil
    local subs = CopySubscribers(subscribers[event])
    subs[owner] = { handler = handler, units = unitSet }
    subscribers[event] = subs
    if wasEmpty then eventFrame:RegisterEvent(event) end
end

function Events.Unregister(owner, event)
    local current = subscribers[event]
    if not current or not current[owner] then return end

    local subs = CopySubscribers(current)
    subs[owner] = nil
    if next(subs) == nil then
        subscribers[event] = nil
        eventFrame:UnregisterEvent(event)
    else
        subscribers[event] = subs
    end
end

-- handlers: { [event] = fn }. unitsByEvent: optional { [event] = { unit, ... } }.
function Events.RegisterAll(owner, handlers, unitsByEvent)
    for event, handler in pairs(handlers) do
        Events.Register(owner, event, handler, unitsByEvent and unitsByEvent[event])
    end
end

function Events.UnregisterAll(owner)
    for event in pairs(subscribers) do Events.Unregister(owner, event) end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local subs = subscribers[event]
    if not subs then return end

    local unit = ...
    for _, entry in pairs(subs) do
        if not entry.units or entry.units[unit] then entry.handler(...) end
    end
end)

---------------------------------------------------------------------------
-- Feature registry
-- Each feature module registers a table:
--   { key, label, tooltip, default, Enable = function(self), Disable = function(self),
--     options = { option, ... } }
-- Options are either
--   { type = "slider",   key, label, tooltip, default, min, max, step, format | formatValue, OnChanged }
--   { type = "checkbox", key, label, tooltip, default, OnChanged }
--   { type = "hidden",   key, default }  -- persisted, not shown in settings
-- OnChanged(value) only fires while the owning feature is enabled.
-- The settings panel builds one toggle per feature (plus a widget per option)
-- from this list, so adding a feature never requires touching Settings.lua.
---------------------------------------------------------------------------

ns.Features = {}
local featuresByKey = {}
local optionsByKey = {}
local optionFeatureKey = {}  -- [optionKey] = featureKey

function ns.RegisterFeature(feature)
    table.insert(ns.Features, feature)
    featuresByKey[feature.key] = feature
    for _, option in ipairs(feature.options or {}) do
        optionsByKey[option.key] = option
        optionFeatureKey[option.key] = feature.key
    end
end

function ns.IsFeatureEnabled(key)
    return ns.db.features[key] == true
end

-- A feature failing to enable/disable is reported rather than propagated, so
-- callers (settings panel, minimap button) always finish their own work.
function ns.SetFeatureEnabled(key, enabled)
    ns.db.features[key] = enabled
    local feature = featuresByKey[key]
    if not ns.isPaladin or not feature then return end

    local ok, err = pcall(enabled and feature.Enable or feature.Disable, feature)
    if not ok then ns.Print(("couldn't %s '%s': %s"):format(enabled and "enable" or "disable", key, tostring(err))) end
end

function ns.GetOption(key)
    return ns.db.options[key]
end

function ns.SetOption(key, value)
    ns.db.options[key] = value
    local option = optionsByKey[key]
    if not ns.isPaladin or not option or not option.OnChanged then return end
    if ns.IsFeatureEnabled(optionFeatureKey[key]) then option.OnChanged(value) end
end

---------------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------------

local PRINT_PREFIX = "|cffF58CBA" .. "Paladin Tools" .. "|r: "

function ns.Print(...)
    print(PRINT_PREFIX .. strjoin(" ", tostringall(...)))
end

-- Keeps the latest output of each debug command in SavedVariables
-- (WTF/Account/<account>/SavedVariables/PaladinTools.lua), written on /reload
-- or logout, so it can be read outside the game instead of copied from chat.
function ns.SaveDebugOutput(name, lines)
    ns.db.debugOutput = ns.db.debugOutput or {}
    ns.db.debugOutput[name] = { time = date("%Y-%m-%d %H:%M:%S"), lines = lines }
    ns.Print("saved to SavedVariables; /reload to write it to disk")
end

function ns.GetSpellName(spellId)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellId) end
    if GetSpellInfo then return (GetSpellInfo(spellId)) end
end

-- Secret values (combat-restricted data) throw on comparison or arithmetic,
-- so anything read from aura/unit APIs goes through this first.
function ns.IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

-- True while aura data is secret; reading it from addon code throws.
function ns.AurasAreSecret()
    return C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil and C_Secrets.ShouldAurasBeSecret() == true
end

---------------------------------------------------------------------------
-- Bootstrap
---------------------------------------------------------------------------

local function MergeDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = type(target[key]) == "table" and target[key] or {}
            MergeDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

-- Defaults are derived from the feature registry so new features/options
-- appear for existing users.
local function BuildDefaults()
    local defaults = { features = {}, options = {} }
    for _, feature in ipairs(ns.Features) do
        defaults.features[feature.key] = feature.default
    end
    for key, option in pairs(optionsByKey) do
        defaults.options[key] = option.default
    end
    return defaults
end

local coreHandlers = {}

function coreHandlers.ADDON_LOADED(loadedName)
    if loadedName ~= addonName then return end
    Events.Unregister("Core", "ADDON_LOADED")

    PaladinToolsDB = PaladinToolsDB or {}
    MergeDefaults(PaladinToolsDB, BuildDefaults())
    ns.db = PaladinToolsDB

    ns.isPaladin = select(2, UnitClass("player")) == "PALADIN"
    ns.CreateSettings()

    if not ns.isPaladin then return end
    for _, feature in ipairs(ns.Features) do
        if ns.IsFeatureEnabled(feature.key) then feature:Enable() end
    end
end

Events.RegisterAll("Core", coreHandlers)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

-- Modules add subcommands with ns.RegisterSlashCommand; a bare /ptools opens
-- the settings panel.
local slashCommands = {}

function ns.RegisterSlashCommand(name, description, handler)
    slashCommands[name] = { description = description, handler = handler }
end

ns.RegisterSlashCommand("help", "list commands", function()
    ns.Print("/ptools - open settings")
    for name, command in pairs(slashCommands) do
        ns.Print("/ptools " .. name .. " - " .. command.description)
    end
end)

SLASH_PALADINTOOLS1 = "/ptools"
SLASH_PALADINTOOLS2 = "/paladintools"
SlashCmdList.PALADINTOOLS = function(msg)
    local name, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    name = name:lower()

    if name == "" then
        if ns.settingsCategory then Settings.OpenToCategory(ns.settingsCategory:GetID()) end
        return
    end

    local command = slashCommands[name] or slashCommands.help
    command.handler(rest)
end
