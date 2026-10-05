local _, ns = ...

-- Minimap button, in the standard round style other addons use:
--   * Left-click: turn the friendly nameplate customization off/on. Off
--     restores Blizzard's default nameplates. The icon greys out while off.
--   * Right-click: open the Paladin Tools settings.
--   * Drag: move it around the minimap edge (position is saved).
--
-- Self-contained rather than embedding LibDBIcon/LibDataBroker for a single
-- button. Uses the same textures and offsets LibDBIcon uses.

local FEATURE_KEY = "minimapButton"
local OPTION_ANGLE = "minimapButtonAngle"
local DEFAULT_ANGLE = 225                 -- degrees, bottom-left of the minimap
local ICON_TEXTURE = "Interface\\Icons\\Ability_ThunderBolt"
local EDGE_PADDING = 10                    -- pixels outside the minimap's edge
local TITLE = "Paladin Tools"

local button

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------

local function UpdatePosition()
    local angle = math.rad(ns.GetOption(OPTION_ANGLE))
    local radius = Minimap:GetWidth() / 2 + EDGE_PADDING
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local angle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    ns.SetOption(OPTION_ANGLE, angle)
    UpdatePosition()
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function IsNameplateFeatureOn()
    return ns.IsFeatureEnabled(ns.NAMEPLATE_FEATURE_KEY)
end

local function UpdateIcon()
    button.icon:SetDesaturated(not IsNameplateFeatureOn())
end

local function ShowTooltip()
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText(TITLE, 1, 1, 1)
    if IsNameplateFeatureOn() then
        GameTooltip:AddLine("Friendly nameplates: customized", 0.2, 1, 0.2)
    else
        GameTooltip:AddLine("Friendly nameplates: Blizzard default", 1, 0.82, 0)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: toggle nameplate customization", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: settings", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

local function OnClick(_, mouseButton)
    if mouseButton == "RightButton" then
        if ns.settingsCategory then Settings.OpenToCategory(ns.settingsCategory:GetID()) end
        return
    end

    local enable = not IsNameplateFeatureOn()
    ns.SetFeatureEnabled(ns.NAMEPLATE_FEATURE_KEY, enable)
    ns.Print(enable and "friendly nameplate customization on." or "friendly nameplates restored to Blizzard default.")
    UpdateIcon()
    if GameTooltip:IsOwned(button) then ShowTooltip() end
end

---------------------------------------------------------------------------
-- Button
---------------------------------------------------------------------------

local function CreateButton()
    button = CreateFrame("Button", nil, Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(ICON_TEXTURE)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", OnClick)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
    button:SetScript("OnDragStart", function(self)
        GameTooltip_Hide()
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
end

---------------------------------------------------------------------------
-- Feature registration
---------------------------------------------------------------------------

ns.RegisterFeature({
    key = FEATURE_KEY,
    label = "Show minimap button",
    tooltip = "Left-click toggles friendly nameplate customization (off restores Blizzard's default nameplates); right-click opens these settings; drag to move.",
    default = true,

    options = {
        { type = "hidden", key = OPTION_ANGLE, default = DEFAULT_ANGLE },
    },

    Enable = function()
        if not button then CreateButton() end
        UpdatePosition()
        UpdateIcon()
        button:Show()
    end,

    Disable = function()
        if button then button:Hide() end
    end,
})
