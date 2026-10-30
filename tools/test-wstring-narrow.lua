-- Name narrowing harness. Run from the repo root:
--   lua5.1 tools/test-wstring-narrow.lua
-- Rewrites WAR wstring literals to interned fake wstrings so L"" compares
-- equal to an empty engine name, then checks the hot-path helpers never call
-- WStringToString on nil, "", or empty wstrings.

local fails = 0

local function fail(msg)
    fails = fails + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
end

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        fail(msg .. " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")")
    end
end

local function assertTrue(cond, msg)
    if not cond then
        fail(msg)
    end
end

local wstringMt = {}
local intern = {}

local rawType = type

local function isWString(value)
    return rawType(value) == "table" and getmetatable(value) == wstringMt
end

function __W(text)
    text = tostring(text)
    local existing = intern[text]
    if existing ~= nil then
        return existing
    end
    local obj = { s = text }
    setmetatable(obj, wstringMt)
    intern[text] = obj
    return obj
end

local function wsText(value)
    if isWString(value) then
        return value.s
    end
    return tostring(value)
end

wstringMt.__tostring = function(self)
    return self.s
end

wstringMt.__concat = function(a, b)
    return __W(wsText(a) .. wsText(b))
end

function type(value)
    if rawType(value) == "table" and getmetatable(value) == wstringMt then
        return "wstring"
    end
    return rawType(value)
end

function towstring(value)
    if value == nil then
        return __W("")
    end
    if isWString(value) then
        return value
    end
    return __W(tostring(value))
end

SystemData = {
    MapPips = {
        GROUP_MEMBER = 1,
        WARBAND_MEMBER = 2,
        DESTRUCTION_ARMY = 3,
        ORDER_ARMY = 4,
    },
}

local wsCalls = 0
local wsInvalid = 0

local function installConverter()
    function WStringToString(value)
        wsCalls = wsCalls + 1
        if not isWString(value) or value.s == "" then
            wsInvalid = wsInvalid + 1
            return ""
        end
        return value.s
    end
end

installConverter()
WStringsRemoveGrammar = nil

local function loadRewritten(path)
    local inp = io.open(path, "r")
    if inp == nil then
        fail("could not read " .. path .. " (run from the repo root)")
        os.exit(1)
    end
    local text = inp:read("*a")
    inp:close()
    text = text:gsub('L"([^"]*)"', function(inner)
        return "__W(" .. string.format("%q", inner) .. ")"
    end)
    local dest = os.tmpname()
    local out = io.open(dest, "w")
    if out == nil then
        fail("could not write " .. dest)
        os.exit(1)
    end
    out:write(text)
    out:close()
    local ok, err = pcall(dofile, dest)
    os.remove(dest)
    if not ok then
        fail("load " .. path .. ": " .. tostring(err))
        os.exit(1)
    end
end

local function upvalue(fn, name)
    if type(fn) ~= "function" then
        fail("upvalue " .. tostring(name) .. " missing function")
        return nil
    end
    local i = 1
    while true do
        local found, value = debug.getupvalue(fn, i)
        if not found then
            local names = {}
            local j = 1
            while true do
                local label = debug.getupvalue(fn, j)
                if not label then
                    break
                end
                names[#names + 1] = label
                j = j + 1
            end
            fail("upvalue " .. name .. " not found (" .. table.concat(names, ", ") .. ")")
            return nil
        end
        if found == name then
            return value
        end
        i = i + 1
    end
end

local function assertNoInvalid(beforeCalls, msg)
    assertEq(wsInvalid, 0, msg .. " invalid WStringToString")
    assertEq(wsCalls, beforeCalls, msg .. " called WStringToString")
end

local narrowFns = {}

local function checkNarrow(narrow, label)
    local before = wsCalls
    assertEq(narrow(nil), nil, label .. " nil")
    assertEq(narrow(""), nil, label .. " empty string")
    assertEq(narrow(__W("")), nil, label .. " empty wstring")
    assertNoInvalid(before, label .. " blank")

    before = wsCalls
    assertEq(narrow("Ada"), "Ada", label .. " plain string")
    assertEq(narrow(12), "12", label .. " number")
    assertEq(narrow(true), "true", label .. " boolean")
    assertNoInvalid(before, label .. " non-wstring")

    before = wsCalls
    assertEq(narrow(__W("Ada")), "Ada", label .. " wstring")
    assertEq(wsCalls, before + 1, label .. " valid wstring should narrow once")
    assertEq(wsInvalid, 0, label .. " valid wstring was invalid")

    local saved = WStringToString
    WStringToString = function()
        error("Invalid Parameters")
    end
    local ok, result = pcall(narrow, __W("Zed"))
    WStringToString = saved
    assertTrue(ok, label .. " converter error escaped the helper")
    assertEq(result, nil, label .. " converter error should be nil")

    WStringToString = function()
        return 5
    end
    assertEq(narrow(__W("Zed")), nil, label .. " non-string converter result")
    installConverter()
end

loadRewritten("EZAssist_GroupStats.lua")

local GS = EZAssist.GroupStats
local gsNormalize = upvalue(upvalue(GS.OnPacket, "BuildRow"), "NormalizeNameKey")
local gsNarrow = upvalue(gsNormalize, "WStringToNarrow")
narrowFns[#narrowFns + 1] = { gsNarrow, "group stats" }

local function checkNormalize(normalize, label)
    local before = wsCalls
    assertEq(normalize(nil), nil, label .. " nil key")
    assertEq(normalize(""), nil, label .. " empty string key")
    assertEq(normalize(__W("")), nil, label .. " empty wstring key")
    assertEq(normalize("  "), nil, label .. " blank string key")
    assertNoInvalid(before, label .. " blank key")

    before = wsCalls
    assertEq(normalize("  Ann  "), "ann", label .. " trimmed string")
    assertEq(normalize("Bob^M"), "bob", label .. " caret string")
    assertEq(normalize(15), "15", label .. " number key")
    assertNoInvalid(before, label .. " plain key")

    before = wsCalls
    assertEq(normalize(__W("Cara^F")), "cara", label .. " caret wstring")
    assertEq(wsCalls, before + 1, label .. " caret wstring narrow count")
    assertEq(wsInvalid, 0, label .. " caret wstring invalid")
end

checkNormalize(gsNormalize, "group stats")

local grammarCalls = 0
function WStringsRemoveGrammar(value)
    grammarCalls = grammarCalls + 1
    if isWString(value) and value.s == "" then
        wsInvalid = wsInvalid + 1
        return __W("")
    end
    if isWString(value) then
        local caret = string.find(value.s, "^", 1, true)
        if caret then
            return __W(string.sub(value.s, 1, caret - 1))
        end
    end
    return value
end

local before = wsCalls
grammarCalls = 0
assertEq(gsNormalize(__W("")), nil, "grammar empty wstring key")
assertEq(grammarCalls, 0, "grammar ran on an empty wstring")
assertNoInvalid(before, "grammar empty")

before = wsCalls
grammarCalls = 0
assertEq(gsNormalize(__W("Dee^M")), "dee", "grammar strips caret")
assertEq(grammarCalls, 1, "grammar should run for a real name")
assertEq(wsInvalid, 0, "grammar strip was invalid")
assertTrue(wsCalls == before + 1, "grammar strip should still narrow once")

function WStringsRemoveGrammar()
    return __W("")
end
before = wsCalls
assertEq(gsNormalize(__W("Erin")), nil, "grammar blank result key")
assertNoInvalid(before, "grammar blank result")

function WStringsRemoveGrammar()
    error("grammar failed")
end
before = wsCalls
assertEq(gsNormalize(__W("Quill")), "quill", "grammar error should keep the name")
assertEq(wsCalls, before + 1, "grammar error should still narrow")
assertEq(wsInvalid, 0, "grammar error narrow was invalid")
WStringsRemoveGrammar = nil

json = {}
function json.decode()
    return {
        characterId = 9,
        scoreboard = { name = __W(""), killDamage = 4 },
    }
end
before = wsCalls
GS.OnPacket("GRP_STATS:blank")
assertEq(GS.Count(), 1, "blank scoreboard name should still store a row")
assertEq(GS.GetRowByKey("9"), nil, "blank scoreboard name should not rank")
assertNoInvalid(before, "GRP_STATS empty wstring")

function json.decode()
    return {
        characterId = 10,
        scoreboard = { name = "", killDamage = 2 },
    }
end
before = wsCalls
GS.OnPacket("GRP_STATS:empty-string")
assertNoInvalid(before, "GRP_STATS empty string")

function json.decode()
    return {
        characterId = 11,
        scoreboard = { name = __W("Lia^M"), killDamage = 8 },
    }
end
before = wsCalls
GS.OnPacket("GRP_STATS:lia")
assertTrue(GS.GetRowByKey("lia") ~= nil, "GRP_STATS wstring name key")
assertEq(wsInvalid, 0, "GRP_STATS real name was invalid")
assertEq(wsCalls, before + 1, "GRP_STATS real name narrow count")

loadRewritten("EZAssist_Controller.lua")

local ctlNormalize = upvalue(EZAssist.PickAssistTarget, "NormalizeNameKey")
local ctlNarrow = upvalue(ctlNormalize, "WStringToNarrow")
narrowFns[#narrowFns + 1] = { ctlNarrow, "controller" }
checkNormalize(ctlNormalize, "controller")

local isOwned = upvalue(upvalue(EZAssist.DebugStatus, "FindOwnedMacroSlot"), "IsOwnedMacroName")
before = wsCalls
assertEq(isOwned(nil), false, "nil macro name")
assertEq(isOwned(__W("")), false, "empty macro wstring")
assertEq(isOwned(__W("EZAssist")), true, "owned macro wstring")
assertNoInvalid(before, "owned macro blank")
before = wsCalls
assertEq(isOwned(__W("EZAssist (Mia)")), true, "owned suffixed macro")
assertEq(wsCalls, before + 1, "suffixed macro should narrow once")
assertEq(isOwned("EZAssist (Mia)"), true, "owned suffixed string")
assertEq(isOwned("Dance"), false, "player macro string")
assertEq(wsInvalid, 0, "macro narrow was invalid")

function DoesWindowExist()
    return true
end

function GetMapPointData(_, index)
    if index == 2 then
        return { name = __W("Dara"), pointType = 1, distance = 20 }
    end
    if index >= 1 and index <= 64 then
        return { name = __W(""), pointType = 1, distance = 10 }
    end
    return nil
end

local lookup = upvalue(upvalue(EZAssist.PickAssistTarget, "StickyStillEligible"), "LookupMapDistance")
before = wsCalls
lookup("nobody", __W("nobody"))
assertEq(wsInvalid, 0, "map scan of blank pips called WStringToString")
assertEq(wsCalls, before + 1, "map scan should narrow only the real pip")
before = wsCalls
local dist = lookup("dara", __W("Dara"))
assertTrue(dist ~= nil, "map scan should find the real pip")
assertEq(wsInvalid, 0, "cached map pip was invalid")

loadRewritten("EZAssist.lua")

local slashNarrow = upvalue(EZAssist.Slash, "WStringToNarrow")
narrowFns[#narrowFns + 1] = { slashNarrow, "slash" }

before = wsCalls
EZAssist.Slash(__W(""))
EZAssist.Slash(nil)
assertNoInvalid(before, "empty slash")

before = wsCalls
EZAssist.Slash(__W("help"))
assertEq(wsInvalid, 0, "help slash was invalid")
assertEq(wsCalls, before + 1, "help slash narrow count")

EZAssist.Settings = EZAssist.Settings or {}
before = wsCalls
EZAssist.Slash(__W("notify on"))
assertEq(EZAssist.Settings.notify, true, "notify on from a wstring")
assertEq(wsInvalid, 0, "notify slash was invalid")
assertTrue(wsCalls >= before + 1, "notify slash should narrow the wstring")

loadRewritten("EZAssist_Config.lua")

local cfgNarrow = upvalue(EZAssistConfig.ApplyCurrent, "WStringToNarrow")
narrowFns[#narrowFns + 1] = { cfgNarrow, "config" }

function ButtonGetPressedFlag()
    return false
end

function TextEditBoxGetText()
    return __W("")
end

EZAssist.Settings.range = 65
before = wsCalls
EZAssistConfig.ApplyCurrent()
assertEq(EZAssist.Settings.range, 65, "empty range wstring should keep the saved range")
assertNoInvalid(before, "empty range")

function TextEditBoxGetText()
    return __W("40")
end
before = wsCalls
EZAssistConfig.ApplyCurrent()
assertEq(EZAssist.Settings.range, 40, "range wstring should apply")
assertEq(wsCalls, before + 1, "range wstring narrow count")
assertEq(wsInvalid, 0, "range wstring was invalid")

for i = 1, #narrowFns do
    checkNarrow(narrowFns[i][1], narrowFns[i][2])
end

if fails > 0 then
    io.stderr:write(tostring(fails) .. " assertion(s) failed\n")
    os.exit(1)
end
print("wstring narrow tests ok")
