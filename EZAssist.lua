----------------------------------------------------------------
-- EZAssist
-- Standalone KillDamage > Deathblows > Total Damage /assist macro
-- (extracted from CustomUI SmartAssist).
-- Slash: /eza | /ezassist | /ezass
----------------------------------------------------------------

EZAssist = EZAssist or {}
EZAssist.Settings = EZAssist.Settings or {}
EZAssist.VERSION = "1.0.1"

-- Yellow/orange [EZAssist] chat tag; data=EZA: opens config on click.
local c_CHAT_PREFIX_TEXT = "EZAssist"
local c_CHAT_PREFIX_COLOR = { 255, 180, 60 }
local c_CHAT_LINK_DATA = "EZA:"
local c_CHAT_LINK_TAG = L"EZA:"

local m_prevOnHyperLinkLButtonUp = nil
local m_chatLinkHooked = false

local function GetChatPrefixWString(includeSpace)
    local coloredPartRaw = string.format(
        "<LINK data=\"%s\" color=\"%d,%d,%d\" text=\"%s\">",
        c_CHAT_LINK_DATA,
        c_CHAT_PREFIX_COLOR[1],
        c_CHAT_PREFIX_COLOR[2],
        c_CHAT_PREFIX_COLOR[3],
        c_CHAT_PREFIX_TEXT
    )
    local prefix = L"[" .. towstring(coloredPartRaw) .. L"]"
    if includeSpace then
        prefix = prefix .. L" "
    end
    return prefix
end

function EZAssist.Print(msg)
    if msg == nil then
        return
    end
    local line = GetChatPrefixWString(true) .. towstring(msg)
    local filter = SystemData and SystemData.SystemLogFilters and SystemData.SystemLogFilters.GENERAL or 0
    if type(EA_ChatWindow) == "table" and type(EA_ChatWindow.Print) == "function" then
        EA_ChatWindow.Print(line, filter)
        return
    end
    if type(TextLogAddEntry) == "function" then
        TextLogAddEntry("System", filter, line)
    end
end

function EZAssist.ShowConfig()
    if type(EZAssistConfig) == "table" and type(EZAssistConfig.Show) == "function" then
        EZAssistConfig.Show()
        return
    end
    EZAssist.Print(L"Config window is not available.")
end

local function IsEZAssistChatLink(linkData)
    if linkData == nil or type(wstring) ~= "table" or type(wstring.gsub) ~= "function" then
        return false
    end
    local data = linkData
    if type(data) ~= "wstring" then
        data = towstring(tostring(data))
    end
    local _, findCount = wstring.gsub(data, c_CHAT_LINK_TAG, L"")
    return (tonumber(findCount) or 0) > 0
end

local function OnEZAssistHyperLinkLButtonUp(linkData, flags, x, y)
    if IsEZAssistChatLink(linkData) then
        EZAssist.ShowConfig()
        return
    end
    if m_prevOnHyperLinkLButtonUp then
        m_prevOnHyperLinkLButtonUp(linkData, flags, x, y)
    end
end

local function InstallChatLinkHook()
    if m_chatLinkHooked then
        return
    end
    if type(EA_ChatWindow) ~= "table" or type(EA_ChatWindow.OnHyperLinkLButtonUp) ~= "function" then
        return
    end
    m_prevOnHyperLinkLButtonUp = EA_ChatWindow.OnHyperLinkLButtonUp
    EA_ChatWindow.OnHyperLinkLButtonUp = OnEZAssistHyperLinkLButtonUp
    m_chatLinkHooked = true
end

local function UninstallChatLinkHook()
    if not m_chatLinkHooked then
        return
    end
    if type(EA_ChatWindow) == "table"
        and EA_ChatWindow.OnHyperLinkLButtonUp == OnEZAssistHyperLinkLButtonUp
        and m_prevOnHyperLinkLButtonUp ~= nil
    then
        EA_ChatWindow.OnHyperLinkLButtonUp = m_prevOnHyperLinkLButtonUp
    end
    m_prevOnHyperLinkLButtonUp = nil
    m_chatLinkHooked = false
end

local function PrintHelp()
    EZAssist.Print(L"v" .. towstring(EZAssist.VERSION) .. L" - KD>DB>TD assist macro")
    EZAssist.Print(L"/ezassist or /ezass - open config")
    EZAssist.Print(L"/eza on|off - enable / disable (creates or deletes the EZAssist macro)")
    EZAssist.Print(L"/eza range <1-500> - assist range in feet (default 65)")
    EZAssist.Print(L"/eza clearhostile on|off - clear macro while you have a living hostile")
    EZAssist.Print(L"/eza glow on|off - glow when a new assist is available")
    EZAssist.Print(L"/eza notify on|off - chat when the assist target changes")
    EZAssist.Print(L"/eza status - diagnostic snapshot")
    EZAssist.Print(L"Bind the EZAssist macro and press it yourself (RoR ignores /assist from addons).")
end

local function ParseOnOff(arg)
    if arg == nil then
        return nil
    end
    local s = arg
    if type(s) == "wstring" and type(WStringToString) == "function" then
        s = WStringToString(s)
    end
    s = string.lower(tostring(s or ""))
    if s == "on" or s == "1" or s == "true" or s == "enable" or s == "enabled" then
        return true
    end
    if s == "off" or s == "0" or s == "false" or s == "disable" or s == "disabled" then
        return false
    end
    return nil
end

local function SlashToggleSetting(key, label, rest)
    local flag = ParseOnOff(rest)
    local s = EZAssist.EnsureSettings()
    if flag == nil then
        EZAssist.Print(towstring(label) .. L" = " .. (s[key] and L"on" or L"off"))
        return
    end
    s[key] = flag
    EZAssist.OnSettingsChanged()
    EZAssist.Print(towstring(label) .. L" = " .. (flag and L"on" or L"off"))
end

function EZAssist.Slash(input)
    local text = input
    if type(text) == "wstring" and type(WStringToString) == "function" then
        text = WStringToString(text)
    end
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        EZAssist.ShowConfig()
        return
    end
    if text == "help" or text == "?" then
        PrintHelp()
        return
    end
    if text == "config" or text == "settings" or text == "options" then
        EZAssist.ShowConfig()
        return
    end

    local cmd, rest = text:match("^(%S+)%s*(.*)$")
    cmd = string.lower(cmd or "")
    rest = rest or ""

    if cmd == "on" or cmd == "enable" then
        EZAssist.Enable()
        EZAssist.Print(L"enabled")
        return
    end
    if cmd == "off" or cmd == "disable" then
        EZAssist.Disable()
        EZAssist.Print(L"disabled (macro removed)")
        return
    end
    if cmd == "range" then
        local n = tonumber(rest)
        if n == nil then
            local s = EZAssist.EnsureSettings()
            EZAssist.Print(L"range = " .. towstring(tostring(s.range)))
            return
        end
        local s = EZAssist.EnsureSettings()
        s.range = n
        EZAssist.OnSettingsChanged()
        s = EZAssist.EnsureSettings()
        EZAssist.Print(L"range = " .. towstring(tostring(s.range)))
        return
    end
    if cmd == "clearhostile" or cmd == "clear" or cmd == "hostile" then
        SlashToggleSetting("clearOnHostile", "clearhostile", rest)
        return
    end
    if cmd == "glow" or cmd == "glowon" then
        SlashToggleSetting("glowOnNewAssist", "glow", rest)
        return
    end
    if cmd == "notify" then
        SlashToggleSetting("notify", "notify", rest)
        return
    end
    if cmd == "status" or cmd == "debug" then
        if type(EZAssist.DebugStatus) ~= "function" then
            EZAssist.Print(L"DebugStatus unavailable")
            return
        end
        local st = EZAssist.DebugStatus()
        local pick = st.pick
        if type(pick) == "wstring" and type(WStringToString) == "function" then
            pick = WStringToString(pick)
        end
        EZAssist.Print(
            L"en="
                .. towstring(tostring(st.enabled == true))
                .. L" ctx="
                .. towstring(tostring(st.assistContext == true))
                .. L" src="
                .. towstring(tostring(st.statsSource or "-"))
                .. L" gsc="
                .. towstring(tostring(st.groupStatsCount or 0))
                .. L" alive="
                .. towstring(tostring(st.aliveKeys or 0))
                .. L" pick="
                .. towstring(tostring(pick or "-"))
                .. L" hostile="
                .. towstring(tostring(st.hasHostileTarget == true))
        )
        return
    end

    PrintHelp()
end

local function RegisterSlash()
    if type(LibSlash) == "table" and type(LibSlash.RegisterSlashCmd) == "function" then
        LibSlash.RegisterSlashCmd("eza", function(args)
            EZAssist.Slash(args)
        end)
        LibSlash.RegisterSlashCmd("ezassist", function(args)
            EZAssist.Slash(args)
        end)
        LibSlash.RegisterSlashCmd("ezass", function(args)
            EZAssist.Slash(args)
        end)
    end
end

--- Mod OnInitialize entry (controller Initialize is also available).
function EZAssist.OnInitialize()
    RegisterSlash()
    InstallChatLinkHook()
    if type(EZAssist.Initialize) == "function" then
        EZAssist.Initialize()
    end
    local s = EZAssist.EnsureSettings and EZAssist.EnsureSettings() or EZAssist.Settings
    if s and s.enabled == true then
        EZAssist.Print(L"v" .. towstring(EZAssist.VERSION) .. L" ready - /ezassist")
    else
        EZAssist.Print(L"v" .. towstring(EZAssist.VERSION) .. L" loaded (disabled) - /ezassist")
    end
end

function EZAssist.OnShutdown()
    UninstallChatLinkHook()
    if type(EZAssist.Shutdown) == "function" then
        EZAssist.Shutdown()
    end
end
