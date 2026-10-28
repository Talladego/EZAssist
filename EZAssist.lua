----------------------------------------------------------------
-- EZAssist
-- Standalone KillDamage → Deathblows → Total Damage /assist macro
-- (extracted from CustomUI SmartAssist).
-- Slash: /eza | /ezassist
----------------------------------------------------------------

EZAssist = EZAssist or {}
EZAssist.Settings = EZAssist.Settings or {}
EZAssist.VERSION = "1.0.0"

local CHAT_PREFIX = L"[EZAssist] "

function EZAssist.Print(msg)
    if msg == nil then
        return
    end
    if type(EA_ChatWindow) == "table" and type(EA_ChatWindow.Print) == "function" then
        EA_ChatWindow.Print(CHAT_PREFIX .. towstring(msg))
        return
    end
    if type(TextLogAddEntry) == "function" then
        TextLogAddEntry("Chat", 0, CHAT_PREFIX .. towstring(msg))
    end
end

local function PrintHelp()
    EZAssist.Print(L"v" .. towstring(EZAssist.VERSION) .. L" — KD→DB→TD assist macro")
    EZAssist.Print(L"/eza on|off — enable / disable (creates or deletes the EZAssist macro)")
    EZAssist.Print(L"/eza range <1-500> — assist range in feet (default 100)")
    EZAssist.Print(L"/eza notify on|off — chat when the assist target changes")
    EZAssist.Print(L"/eza status — diagnostic snapshot")
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

function EZAssist.Slash(input)
    local text = input
    if type(text) == "wstring" and type(WStringToString) == "function" then
        text = WStringToString(text)
    end
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or text == "help" or text == "?" then
        PrintHelp()
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
    if cmd == "notify" then
        local flag = ParseOnOff(rest)
        local s = EZAssist.EnsureSettings()
        if flag == nil then
            EZAssist.Print(L"notify = " .. (s.notify and L"on" or L"off"))
            return
        end
        s.notify = flag
        EZAssist.OnSettingsChanged()
        EZAssist.Print(L"notify = " .. (flag and L"on" or L"off"))
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
    end
end

--- Mod OnInitialize entry (controller Initialize is also available).
--- Mod OnInitialize. Controller provides Initialize / OnUpdate / Shutdown.
function EZAssist.OnInitialize()
    RegisterSlash()
    if type(EZAssist.Initialize) == "function" then
        EZAssist.Initialize()
    end
    local s = EZAssist.EnsureSettings and EZAssist.EnsureSettings() or EZAssist.Settings
    if s and s.enabled == true then
        EZAssist.Print(L"v" .. towstring(EZAssist.VERSION) .. L" ready — /eza help")
    else
        EZAssist.Print(L"v" .. towstring(EZAssist.VERSION) .. L" loaded (disabled) — /eza on")
    end
end

function EZAssist.OnShutdown()
    if type(EZAssist.Shutdown) == "function" then
        EZAssist.Shutdown()
    end
end
