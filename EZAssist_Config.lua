----------------------------------------------------------------
-- EZAssistConfig
-- Minimal settings window: enable, clear-on-hostile, glow, range, notify.
----------------------------------------------------------------

EZAssistConfig = {}

local c_WIN = "EZAssistConfig"
local c_CONTENTS = "EZAssistConfigContentsScrollChildSettings"

local function ClampRange(n)
    n = tonumber(n) or 100
    if n < 1 then
        n = 1
    elseif n > 500 then
        n = 500
    end
    return math.floor(n + 0.5)
end

local function EnsureSettings()
    if type(EZAssist.EnsureSettings) == "function" then
        return EZAssist.EnsureSettings()
    end
    EZAssist.Settings = EZAssist.Settings or {}
    return EZAssist.Settings
end

function EZAssistConfig.Initialize()
    local c = c_CONTENTS
    local version = (EZAssist and EZAssist.VERSION) or "1.0.1"
    LabelSetText(c_WIN .. "TitleBarText", L"EZAssist v" .. towstring(version))
    LabelSetText(c .. "Title", L"EZAssist")
    LabelSetText(c .. "EnabledLabel", L"Enable EZAssist")
    LabelSetText(
        c .. "Info",
        L"Hotbar macro <icon23166> assists the best nearby ally (KillDamage, then Deathblows, then Total Damage). Scenarios and party/warband. Never assists yourself - bind and press the macro yourself."
    )
    LabelSetText(c .. "ClearHostileLabel", L"Clear while having a hostile target")
    LabelSetText(c .. "GlowLabel", L"Glow on new assist available")
    LabelSetText(c .. "RangeLabel", L"Assist range (ft)")
    LabelSetText(c .. "NotifyLabel", L"Chat when assist target changes")
    LabelSetText(
        c .. "NotifyInfo",
        L"System chat line with reason + KD / DB / Damage when the pick changes."
    )
    ButtonSetCheckButtonFlag(c .. "EnabledButton", true)
    ButtonSetCheckButtonFlag(c .. "ClearHostileButton", true)
    ButtonSetCheckButtonFlag(c .. "GlowButton", true)
    ButtonSetCheckButtonFlag(c .. "NotifyButton", true)
    ButtonSetText(c_WIN .. "OkayButton", L"Okay")
    ButtonSetText(c_WIN .. "ApplyButton", L"Apply")
    ButtonSetText(c_WIN .. "CancelButton", L"Cancel")
end

function EZAssistConfig.UpdateFromSettings()
    local c = c_CONTENTS
    local s = EnsureSettings()
    ButtonSetPressedFlag(c .. "EnabledButton", s.enabled == true)
    ButtonSetPressedFlag(c .. "ClearHostileButton", s.clearOnHostile ~= false)
    ButtonSetPressedFlag(c .. "GlowButton", s.glowOnNewAssist ~= false)
    ButtonSetPressedFlag(c .. "NotifyButton", s.notify == true)
    if DoesWindowExist(c .. "RangeEdit") then
        TextEditBoxSetText(c .. "RangeEdit", towstring(tostring(ClampRange(s.range))))
    end
    if DoesWindowExist(c_WIN .. "Contents") and type(ScrollWindowUpdateScrollRect) == "function" then
        ScrollWindowUpdateScrollRect(c_WIN .. "Contents")
    end
end

function EZAssistConfig.ApplyCurrent()
    local c = c_CONTENTS
    local s = EnsureSettings()
    s.enabled = ButtonGetPressedFlag(c .. "EnabledButton") == true
    s.clearOnHostile = ButtonGetPressedFlag(c .. "ClearHostileButton") == true
    s.glowOnNewAssist = ButtonGetPressedFlag(c .. "GlowButton") == true
    s.notify = ButtonGetPressedFlag(c .. "NotifyButton") == true
    if DoesWindowExist(c .. "RangeEdit") then
        local text = TextEditBoxGetText(c .. "RangeEdit")
        local asString = text
        if type(text) == "wstring" and type(WStringToString) == "function" then
            asString = WStringToString(text)
        end
        s.range = ClampRange(tonumber(asString) or s.range)
    end
    if type(EZAssist.OnSettingsChanged) == "function" then
        EZAssist.OnSettingsChanged()
    end
end

function EZAssistConfig.OnShown()
    if type(WindowUtils) == "table" and type(WindowUtils.OnShown) == "function" then
        WindowUtils.OnShown()
    end
    EZAssistConfig.UpdateFromSettings()
end

function EZAssistConfig.Show()
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(c_WIN) then
        if type(CreateWindow) == "function" then
            CreateWindow(c_WIN, false)
        end
    end
    if type(DoesWindowExist) ~= "function" or not DoesWindowExist(c_WIN) then
        if type(EZAssist.Print) == "function" then
            EZAssist.Print(L"Config window is not available.")
        end
        return
    end
    if type(WindowUtils) == "table" and type(WindowUtils.ToggleShowing) == "function" then
        WindowUtils.ToggleShowing(c_WIN)
        return
    end
    WindowSetShowing(c_WIN, not WindowGetShowing(c_WIN))
end

function EZAssistConfig.OnOkay()
    EZAssistConfig.ApplyCurrent()
    WindowSetShowing(c_WIN, false)
end

function EZAssistConfig.OnApply()
    EZAssistConfig.ApplyCurrent()
    EZAssistConfig.UpdateFromSettings()
end

function EZAssistConfig.OnCancel()
    WindowSetShowing(c_WIN, false)
end

function EZAssistConfig.OnToggleEnabled()
    EA_LabelCheckButton.Toggle()
end

function EZAssistConfig.OnToggleClearHostile()
    EA_LabelCheckButton.Toggle()
end

function EZAssistConfig.OnToggleGlow()
    EA_LabelCheckButton.Toggle()
end

function EZAssistConfig.OnToggleNotify()
    EA_LabelCheckButton.Toggle()
end
