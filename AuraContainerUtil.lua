local _, ns = ...

-- Shared helpers for native AuraContainer frames (see the wow-forever-ui
-- skill). The client fills these itself, including in combat when aura data
-- is secret to addon code, so per-aura styling is done by splitting auras
-- into groups with their own filter strings and button initializers.

local AuraContainerUtil = {}
ns.AuraContainerUtil = AuraContainerUtil

local SUPPORT_ADDON = "Blizzard_AuraContainer"
local CONTAINER_TEMPLATE = "CustomAuraContainerTemplate"
-- Required for frames anchored to another aura container (its size is secret).
local UNTRUSTED_LAYOUT_TEMPLATE = "CustomAuraContainerTemplate, DisableUntrustedLayoutScriptsTemplate"
local ICON_TEXCOORD_INSET = 0.08

-- Loads the load-on-demand support addon. Returns ok, reason.
function AuraContainerUtil.EnsureSupport()
    if C_AddOns.IsAddOnLoaded(SUPPORT_ADDON) then return true end
    return C_AddOns.LoadAddOn(SUPPORT_ADDON)
end

-- Creates a disabled container with a horizontal, left-to-right flow.
-- anchorsToAuraContainer: the caller will anchor it to another aura container.
function AuraContainerUtil.Create(parent, anchorsToAuraContainer)
    local container
    if anchorsToAuraContainer then
        local ok, created = pcall(CreateFrame, "AuraContainer", nil, parent, UNTRUSTED_LAYOUT_TEMPLATE)
        if ok then container = created end
    end
    container = container or CreateFrame("AuraContainer", nil, parent, CONTAINER_TEMPLATE)

    -- BetterBlizzFrames seeds every container with a 1x1 size; a frame with a
    -- single anchor and no size has no valid rect, so nothing inside it draws.
    container:SetSize(1, 1)
    container:SetEnabled(false)
    if container.SetAuraProcessingPolicy and CustomAuraContainerAuraProcessingPolicy then
        container:SetAuraProcessingPolicy(CustomAuraContainerAuraProcessingPolicy.None)
    end
    container:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis.Horizontal)
    container:SetFlowLayoutAnchorPoint("TOPLEFT")
    container:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Right, AnchorUtil.FlowDirection.Down)
    return container
end

-- Returns an initializeFrame callback that builds a bordered icon with a
-- cooldown swipe: full-size colored background, icon inset on top.
-- The group layout's elementWidth/Height only spaces the slots; buttons start
-- at 0x0 and must be sized here (as ForeverAuras and BetterBlizzFrames do).
-- size: a number, or a function returning the current size (for settings
-- that can change after buttons exist; see ResizeGroups).
function AuraContainerUtil.BorderedButtonInitializer(size, color, thickness)
    return function(button)
        local pixels = type(size) == "function" and size() or size
        button:SetSize(pixels, pixels)
        button:EnableMouse(false)

        local border = button:CreateTexture(nil, "BACKGROUND")
        border:SetAllPoints(button)
        border:SetColorTexture(color.r, color.g, color.b, color.a or 1)

        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", thickness, -thickness)
        icon:SetPoint("BOTTOMRIGHT", -thickness, thickness)
        icon:SetTexCoord(ICON_TEXCOORD_INSET, 1 - ICON_TEXCOORD_INSET, ICON_TEXCOORD_INSET, 1 - ICON_TEXCOORD_INSET)
        button:SetIcon(icon)

        local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        cooldown:SetAllPoints(icon)
        cooldown:SetDrawBling(false)
        cooldown:SetHideCountdownNumbers(true)
        button:SetDurationCooldown(cooldown)
    end
end

-- Resizes a container's existing buttons and its groups' slot layout.
-- Container descendants are restricted while auras are secret, so callers
-- must only do this out of combat. groups: { { key, layoutIndex }, ... }.
function AuraContainerUtil.ResizeGroups(container, groups, size, spacing)
    for _, group in ipairs(groups) do
        container:SetAuraGroupLayout(group.key, {
            elementWidth = size,
            elementHeight = size,
            elementSpacing = spacing,
            layoutIndex = group.layoutIndex,
        })
    end
    for _, button in ipairs({ container:GetChildren() }) do
        button:SetSize(size, size)
    end
end

---------------------------------------------------------------------------
-- Diagnostics
---------------------------------------------------------------------------

local MAX_DESCRIBED_BUTTONS = 4

local function Describe(value)
    if ns.IsSecret(value) then return "<secret>" end
    if type(value) == "number" then return ("%.1f"):format(value) end
    return tostring(value)
end

local function SafeCall(object, method, ...)
    if not object or type(object[method]) ~= "function" then return "n/a" end
    local ok, result = pcall(object[method], object, ...)
    return ok and Describe(result) or "error"
end

local function DescribePoint(frame)
    local ok, point, relativeTo, relativePoint, x, y = pcall(frame.GetPoint, frame, 1)
    if not ok or not point then return "none" end
    local relativeName = relativeTo and SafeCall(relativeTo, "GetDebugName") or "nil"
    return ("%s->%s:%s(%s,%s)"):format(Describe(point), relativeName, Describe(relativePoint), Describe(x), Describe(y))
end

-- Lines describing a container and its first few buttons, for debug commands.
-- groupKeys: group names to check with HasAuraGroup.
function AuraContainerUtil.DescribeContainer(container, groupKeys)
    if not container then return { "container=nil" } end

    local groups = {}
    for _, key in ipairs(groupKeys or {}) do
        table.insert(groups, key .. "=" .. SafeCall(container, "HasAuraGroup", key))
    end

    local lines = {
        ("container shown=%s visible=%s enabled=%s unit=%s alpha=%s scale=%s"):format(
            SafeCall(container, "IsShown"), SafeCall(container, "IsVisible"), SafeCall(container, "IsEnabled"),
            SafeCall(container, "GetUnit"), SafeCall(container, "GetEffectiveAlpha"), SafeCall(container, "GetEffectiveScale")),
        ("  size=%sx%s level=%s strata=%s point=%s parent=%s groups: %s"):format(
            SafeCall(container, "GetWidth"), SafeCall(container, "GetHeight"), SafeCall(container, "GetFrameLevel"),
            SafeCall(container, "GetFrameStrata"), DescribePoint(container),
            container:GetParent() and SafeCall(container:GetParent(), "GetDebugName") or "nil", table.concat(groups, " ")),
    }

    local ok, children = pcall(function() return { container:GetChildren() } end)
    children = ok and children or {}
    table.insert(lines, ("  buttons=%d"):format(#children))
    for i = 1, math.min(#children, MAX_DESCRIBED_BUTTONS) do
        local button = children[i]
        table.insert(lines, ("  [%d] shown=%s visible=%s size=%sx%s point=%s"):format(
            i, SafeCall(button, "IsShown"), SafeCall(button, "IsVisible"),
            SafeCall(button, "GetWidth"), SafeCall(button, "GetHeight"), DescribePoint(button)))
    end
    return lines
end

-- Native AuraContainers (Blizzard's or ours) expose GetUnit + UpdateAllAuras;
-- their descendants are restricted, so frame-tree searches skip them.
function AuraContainerUtil.IsAuraContainer(frame)
    return type(frame.GetUnit) == "function" and type(frame.UpdateAllAuras) == "function"
end
