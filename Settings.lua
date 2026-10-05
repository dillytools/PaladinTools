local _, ns = ...

-- Builds the Options > AddOns > Paladin Tools panel: one toggle per registered
-- feature, with that feature's option widgets indented underneath it. Option
-- widgets grey out while their feature is off. The title stays put; the
-- feature list scrolls once it outgrows the panel.

local PANEL_TITLE = "Paladin Tools"
local LEFT_MARGIN = 16
local OPTION_INDENT = 30
local SLIDER_WIDTH = 220
local TITLE_HEIGHT = 44
local SCROLLBAR_GUTTER = 28  -- room for the template's scroll bar
local CONTENT_BOTTOM_PADDING = 16

-- Shared widget helpers -----------------------------------------------------

local function AttachTooltip(frame, title, text)
    if not text then return end
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(text, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

local function CreateLabeledCheckButton(panel, text, tooltip, fontObject)
    local checkButton = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")

    local label = checkButton:CreateFontString(nil, "ARTWORK", fontObject)
    label:SetPoint("LEFT", checkButton, "RIGHT", 4, 0)
    label:SetText(text)
    checkButton:SetHitRectInsets(0, -label:GetStringWidth() - 4, 0, 0)
    checkButton.label = label

    AttachTooltip(checkButton, text, tooltip)
    return checkButton
end

-- Option widgets ------------------------------------------------------------
-- Each factory lays itself out via place(region, height, indent) and returns a
-- widget with SyncFromDB() and SetEnabled(enabled).

local OPTION_FACTORIES = {}

function OPTION_FACTORIES.checkbox(panel, option, place)
    local checkButton = CreateLabeledCheckButton(panel, option.label, option.tooltip, "GameFontNormal")
    place(checkButton, 28, OPTION_INDENT)

    checkButton:SetScript("OnClick", function(self)
        ns.SetOption(option.key, self:GetChecked() and true or false)
    end)

    return {
        SyncFromDB = function()
            checkButton:SetChecked(ns.GetOption(option.key) == true)
        end,
        SetEnabled = function(_, enabled)
            checkButton:SetEnabled(enabled)
            checkButton.label:SetFontObject(enabled and "GameFontNormal" or "GameFontDisable")
        end,
    }
end

-- Template-free slider so it doesn't depend on which slider templates this
-- client ships.
function OPTION_FACTORIES.slider(panel, option, place)
    local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetText(option.label)
    place(label, 18, OPTION_INDENT)

    local slider = CreateFrame("Slider", nil, panel)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(SLIDER_WIDTH, 16)
    slider:SetMinMaxValues(option.min, option.max)
    slider:SetValueStep(option.step)
    slider:SetObeyStepOnDrag(true)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    place(slider, 30, OPTION_INDENT)

    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0.15, 0.15, 0.15, 0.9)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(6)

    local valueText = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    valueText:SetPoint("LEFT", slider, "RIGHT", 10, 0)

    -- option.formatValue(value) for custom labels (e.g. stepped choices);
    -- otherwise option.format as a format string.
    local function FormatValue(value)
        if option.formatValue then return option.formatValue(value) end
        return (option.format or "%s"):format(value)
    end

    slider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value / option.step + 0.5) * option.step
        valueText:SetText(FormatValue(value))
        if value ~= ns.GetOption(option.key) then ns.SetOption(option.key, value) end
    end)

    AttachTooltip(slider, option.label, option.tooltip)

    return {
        -- SetValue doesn't fire OnValueChanged when the value is unchanged, so set
        -- the readout explicitly.
        SyncFromDB = function()
            local value = ns.GetOption(option.key)
            slider:SetValue(value)
            valueText:SetText(FormatValue(value))
        end,
        SetEnabled = function(_, enabled)
            if enabled then slider:Enable() else slider:Disable() end
            label:SetFontObject(enabled and "GameFontNormal" or "GameFontDisable")
            slider:SetAlpha(enabled and 1 or 0.5)
        end,
    }
end

-- Panel ---------------------------------------------------------------------

-- A scroll frame filling the panel below the title, and its scroll child.
-- UIPanelScrollFrameTemplate brings the scroll bar and mouse-wheel handling
-- (the template BetterBlizzFrames uses on this client).
local function CreateScrollArea(panel)
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -TITLE_HEIGHT)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -SCROLLBAR_GUTTER, 4)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1)
    scrollFrame:SetScrollChild(content)
    scrollFrame:SetScript("OnSizeChanged", function(_, width) content:SetWidth(width) end)
    return content
end

function ns.CreateSettings()
    local panel = CreateFrame("Frame")

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetText(PANEL_TITLE)
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT_MARGIN, -16)

    local content = CreateScrollArea(panel)
    local cursorY = -4

    local function Place(region, height, indent)
        region:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT_MARGIN + (indent or 0), cursorY)
        cursorY = cursorY - height
    end

    if not ns.isPaladin then
        local note = content:CreateFontString(nil, "ARTWORK", "GameFontDisable")
        note:SetText("These features only run on paladin characters.")
        Place(note, 24)
    end

    local rows = {}  -- { featureKey, toggle, widgets }
    for _, feature in ipairs(ns.Features) do
        local row = { featureKey = feature.key, widgets = {} }

        row.toggle = CreateLabeledCheckButton(content, feature.label, feature.tooltip, "GameFontHighlight")
        Place(row.toggle, 30)

        for _, option in ipairs(feature.options or {}) do
            local factory = OPTION_FACTORIES[option.type]
            if factory then table.insert(row.widgets, factory(content, option, Place)) end
        end

        row.toggle:SetScript("OnClick", function(self)
            local enabled = self:GetChecked() and true or false
            ns.SetFeatureEnabled(feature.key, enabled)
            for _, widget in ipairs(row.widgets) do widget:SetEnabled(enabled) end
        end)

        table.insert(rows, row)
        cursorY = cursorY - 6
    end

    content:SetHeight(-cursorY + CONTENT_BOTTOM_PADDING)

    panel:SetScript("OnShow", function()
        for _, row in ipairs(rows) do
            local enabled = ns.IsFeatureEnabled(row.featureKey)
            row.toggle:SetChecked(enabled)
            for _, widget in ipairs(row.widgets) do
                widget.SyncFromDB()
                widget:SetEnabled(enabled)
            end
        end
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, PANEL_TITLE)
    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
end
