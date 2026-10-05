local _, ns = ...

-- Applies visual effects to default Blizzard action buttons whose action
-- resolves to a requested spell name. Requests are keyed by owner so multiple
-- features can affect different spells (with different effects) without
-- stomping on each other. Uses its own overlays rather than Blizzard's proc
-- glow to avoid tainting the action buttons.

local ButtonEffects = {}
ns.ButtonEffects = ButtonEffects

local EVENT_OWNER = "ButtonEffects"

local Style = {
    Alert = "alert", -- red pulse over the icon: "act on this now"
    Glow  = "glow",  -- gold pulsing border: "this is a good choice right now"
    Dim   = "dim",   -- desaturated icon: "not useful right now"
}
ButtonEffects.Style = Style

local BAR_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
}
local BUTTONS_PER_BAR = 12

local requests = {}   -- [owner] = { names = { [spellName] = true }, style = Style }
local applied = {}    -- [style] = { [button] = true }
local overlays = {}   -- [style] = { [button] = overlay frame }
local buttons         -- lazily collected list of action buttons

---------------------------------------------------------------------------
-- Button discovery
---------------------------------------------------------------------------

local function CollectButtons()
    buttons = {}
    for _, prefix in ipairs(BAR_PREFIXES) do
        for i = 1, BUTTONS_PER_BAR do
            local button = _G[prefix .. i]
            if button then table.insert(buttons, button) end
        end
    end
end

local function GetIcon(button)
    return button.icon or _G[button:GetName() .. "Icon"]
end

local function GetSlotSpellName(slot)
    if not slot or not HasAction(slot) then return end

    local actionType, id, subType = GetActionInfo(slot)
    if actionType == "spell" then
        return ns.GetSpellName(id)
    elseif actionType == "macro" then
        if subType == "spell" then return ns.GetSpellName(id) end
        -- Modern clients return a spell ID, older ones return the spell name.
        local spell = GetMacroSpell(id)
        if type(spell) == "number" then return ns.GetSpellName(spell) end
        return spell
    end
end

local function IsRequested(spellName, style)
    for _, request in pairs(requests) do
        if request.style == style and request.names[spellName] then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Effects
-- Each effect implements Apply(button, style) / Remove(button, style). Apply is
-- called on every refresh while active, so it must be idempotent.
---------------------------------------------------------------------------

local function AddPulse(overlay, fromAlpha, toAlpha, halfPeriod)
    local pulse = overlay:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local alpha = pulse:CreateAnimation("Alpha")
    alpha:SetFromAlpha(fromAlpha)
    alpha:SetToAlpha(toAlpha)
    alpha:SetDuration(halfPeriod)
    overlay.pulse = pulse
end

-- Wraps an overlay builder into an effect that lazily creates one pulsing
-- overlay frame per button.
local function PulseOverlayEffect(build)
    return {
        Apply = function(button, style)
            overlays[style] = overlays[style] or {}
            local overlay = overlays[style][button]
            if not overlay then
                overlay = CreateFrame("Frame", nil, button)
                build(button, overlay)
                overlay:Hide()
                overlays[style][button] = overlay
            end
            if not overlay:IsShown() then
                overlay:Show()
                overlay.pulse:Play()
            end
        end,

        Remove = function(button, style)
            local overlay = overlays[style] and overlays[style][button]
            if overlay then
                overlay.pulse:Stop()
                overlay:Hide()
            end
        end,
    }
end

-- Blizzard resets the icon's desaturation on its own updates (e.g. hovering
-- the button), so post-hook the icon's setters and re-assert while dimmed.
local function DimEffect()
    local dimmed = {}  -- [icon] = true
    local hooked = {}  -- [icon] = true

    local function Reassert(icon, value)
        if dimmed[icon] and not value then icon:SetDesaturated(true) end
    end

    local function HookIcon(icon)
        if hooked[icon] then return end
        hooked[icon] = true
        hooksecurefunc(icon, "SetDesaturated", Reassert)
        if icon.SetDesaturation then
            hooksecurefunc(icon, "SetDesaturation", function(self, amount)
                Reassert(self, amount and amount > 0)
            end)
        end
    end

    return {
        Apply = function(button)
            local icon = GetIcon(button)
            if not icon then return end
            HookIcon(icon)
            dimmed[icon] = true
            icon:SetDesaturated(true)
        end,

        Remove = function(button)
            local icon = GetIcon(button)
            if not icon then return end
            dimmed[icon] = nil
            icon:SetDesaturated(false)
        end,
    }
end

local EFFECTS = {
    [Style.Alert] = PulseOverlayEffect(function(button, overlay)
        overlay:SetAllPoints(GetIcon(button) or button)
        overlay:SetFrameLevel(button:GetFrameLevel() + 5)

        local texture = overlay:CreateTexture(nil, "OVERLAY")
        texture:SetAllPoints()
        texture:SetColorTexture(1, 0, 0, 1)
        texture:SetBlendMode("ADD")

        AddPulse(overlay, 0.1, 0.75, 0.4)
    end),

    [Style.Glow] = PulseOverlayEffect(function(button, overlay)
        overlay:SetAllPoints(button)
        overlay:SetFrameLevel(button:GetFrameLevel() + 6)

        local texture = overlay:CreateTexture(nil, "OVERLAY")
        texture:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        texture:SetBlendMode("ADD")
        texture:SetVertexColor(1, 0.82, 0.2)
        texture:SetPoint("CENTER")
        texture:SetSize(button:GetWidth() * 1.8, button:GetHeight() * 1.8)

        AddPulse(overlay, 0.45, 1, 0.6)
    end),

    [Style.Dim] = DimEffect(),
}

for style in pairs(EFFECTS) do applied[style] = {} end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

function ButtonEffects.Refresh()
    if not buttons then CollectButtons() end
    local anyRequests = next(requests) ~= nil

    for _, button in ipairs(buttons) do
        local spellName = anyRequests and GetSlotSpellName(button.action) or nil
        for style, effect in pairs(EFFECTS) do
            if spellName ~= nil and IsRequested(spellName, style) then
                effect.Apply(button, style)
                applied[style][button] = true
            elseif applied[style][button] then
                effect.Remove(button, style)
                applied[style][button] = nil
            end
        end
    end
end

-- Action bar paging updates button.action via secure attributes, which can land
-- after the event fires, so re-scan on the next frame.
local function DeferredRefresh()
    C_Timer.After(0, ButtonEffects.Refresh)
end

local barHandlers = {
    ACTIONBAR_SLOT_CHANGED = DeferredRefresh,
    ACTIONBAR_PAGE_CHANGED = DeferredRefresh,
    UPDATE_BONUS_ACTIONBAR = DeferredRefresh,
    PLAYER_ENTERING_WORLD  = DeferredRefresh,
}

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- spellNames: set of localized spell names ({ [name] = true }).
-- style: one of ButtonEffects.Style. Replaces any previous request from owner.
function ButtonEffects.Start(owner, spellNames, style)
    local existing = requests[owner]
    if existing and existing.names == spellNames and existing.style == style then return end

    local wasIdle = next(requests) == nil
    requests[owner] = { names = spellNames, style = style }
    if wasIdle then ns.Events.RegisterAll(EVENT_OWNER, barHandlers) end
    ButtonEffects.Refresh()
end

function ButtonEffects.Stop(owner)
    if not requests[owner] then return end
    requests[owner] = nil
    if next(requests) == nil then ns.Events.UnregisterAll(EVENT_OWNER) end
    ButtonEffects.Refresh()
end

-- Convenience for features that toggle a request on/off from a boolean.
function ButtonEffects.Set(owner, active, spellNames, style)
    if active then ButtonEffects.Start(owner, spellNames, style) else ButtonEffects.Stop(owner) end
end
