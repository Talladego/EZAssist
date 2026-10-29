-- Macro slot ownership harness. Run from the repo root:
--   lua5.1 tools/test-macro-slot.lua
-- Loads the controller with WAR wstring literals rewritten to Lua strings.

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

local function rewriteController(dest)
    local inp = io.open("EZAssist_Controller.lua", "r")
    if inp == nil then
        fail("could not read EZAssist_Controller.lua (run from the repo root)")
        os.exit(1)
    end
    local text = inp:read("*a")
    inp:close()
    text = text:gsub('L"([^"]*)"', '"%1"')
    local out = io.open(dest, "w")
    out:write(text)
    out:close()
end

SystemData = {
    MapPips = {
        GROUP_MEMBER = 1,
        WARBAND_MEMBER = 2,
        DESTRUCTION_ARMY = 3,
        ORDER_ARMY = 4,
    },
}

function towstring(value)
    return value
end

EZAssist = EZAssist or {}
EZAssist.Settings = { enabled = true }
EZAssist.Print = function()
end

local macros = {}
local writes = {}

function GetMacrosData()
    return macros
end

function SetMacroData(name, text, icon, slot)
    writes[#writes + 1] = { name = name, text = text, icon = icon, slot = slot }
    macros[slot] = macros[slot] or {}
    macros[slot].name = name
    macros[slot].text = text
    macros[slot].iconNum = icon
end

local function emptyRow()
    return { name = "", text = "", iconNum = 0 }
end

local function ownedRow()
    return { name = "EZAssist", text = "", iconNum = 23166 }
end

local function clearMacros()
    for i = 1, 24 do
        macros[i] = nil
    end
end

local function clearWrites()
    for i = 1, #writes do
        writes[i] = nil
    end
end

local function wroteSlot(slot)
    for i = 1, #writes do
        if writes[i].slot == slot then
            return true
        end
    end
    return false
end

local rewritten = "/tmp/ezassist-controller-rewritten.lua"
rewriteController(rewritten)
dofile(rewritten)
os.remove(rewritten)

local function enableWith(rows)
    clearMacros()
    for i = 1, #rows do
        macros[i] = rows[i]
    end
    clearWrites()
    EZAssist.Settings.enabled = true
    EZAssist.Enable()
end

-- Cached slot was overwritten by the player. The next write must not touch it.
enableWith({
    emptyRow(),
    ownedRow(),
})
assertEq(macros[2].name, "EZAssist", "setup should keep the owned macro")
macros[2] = { name = "Dance", text = "/dance", iconNum = 9 }
clearWrites()
EZAssist.Sync()
assertEq(macros[2].name, "Dance", "write reused a slot the player had replaced")
assertTrue(not wroteSlot(2), "SetMacroData ran on the player's macro slot")
assertEq(macros[1].name, "EZAssist", "assist macro should move to an empty slot")
assertTrue(wroteSlot(1), "empty slot was not claimed after the cached slot was rejected")

-- Disable/Sync must delete the owned macro, not the player's macro in the cached slot.
enableWith({
    { name = "Mount", text = "/mount", iconNum = 4 },
    ownedRow(),
    emptyRow(),
})
macros[2] = { name = "Dance", text = "/dance", iconNum = 9 }
macros[3] = ownedRow()
clearWrites()
EZAssist.Settings.enabled = false
EZAssist.Sync()
assertEq(macros[2].name, "Dance", "disable deleted the player's macro in the cached slot")
assertTrue(not wroteSlot(2), "disable called SetMacroData on the player's slot")
assertEq(macros[3].name, "", "disable should clear the EZAssist macro it still owns")
assertTrue(wroteSlot(3), "owned macro was not deleted")

-- Departed members are removed on GROUP_UPDATED. An inactive roster must not wipe the cache.
dofile("EZAssist_GroupStats.lua")
json = {}
function json.decode(text)
    local id = tonumber(string.match(text, '"characterId":(%d+)'))
    local name = string.match(text, '"name":"([^"]+)"')
    local kd = tonumber(string.match(text, '"killDamage":(%d+)'))
    if id == nil or name == nil then
        return nil
    end
    return {
        characterId = id,
        scoreboard = { name = name, killDamage = kd or 0 },
    }
end

local function packet(id, name, kd)
    return string.format(
        '{"characterId":%d,"scoreboard":{"name":"%s","killDamage":%d}}',
        id,
        name,
        kd
    )
end

local partyNames = { "Alice" }
PartyUtils = {
    IsPartyActive = function()
        return true
    end,
    PLAYERS_PER_PARTY = 6,
    GetPartyData = function()
        return { true }
    end,
    GetPartyMember = function(index)
        local name = partyNames[index]
        if name == nil then
            return nil
        end
        return { name = name, healthPercent = 100 }
    end,
}

EZAssist.GroupStats.OnPacket(packet(1, "Alice", 10))
EZAssist.GroupStats.OnPacket(packet(2, "Bob", 30))
EZAssist.Settings.enabled = true
EZAssist.Enable()
EZAssist.OnGroupUpdated()
assertTrue(EZAssist.GroupStats.GetRowByKey("alice") ~= nil, "Alice should stay in the party cache")
assertTrue(EZAssist.GroupStats.GetRowByKey("bob") == nil, "Bob should be pruned after leaving the party")

EZAssist.GroupStats.OnPacket(packet(2, "Bob", 30))
PartyUtils.IsPartyActive = function()
    return false
end
EZAssist.OnGroupUpdated()
assertEq(EZAssist.GroupStats.Count(), 2, "group update with no roster should not wipe the cache")

-- Off-map candidates must not pay a 64-point walk on every later pick.
partyNames = { "Alice", "Bob" }
PartyUtils.IsPartyActive = function()
    return true
end
GameData = {
    Player = { realm = 1, name = "Me" },
    Realm = { ORDER = 1, DESTRUCTION = 2 },
}
function DoesWindowExist()
    return true
end
local mapCalls = 0
function GetMapPointData(_, index)
    mapCalls = mapCalls + 1
    if index == 1 then
        return {
            name = "Alice",
            pointType = SystemData.MapPips.GROUP_MEMBER,
            distance = 10,
        }
    end
    return nil
end

local sawWalk = false
local cheapAt = nil
local deltaText = ""
for n = 1, 24 do
    local before = mapCalls
    EZAssist.PickAssistTarget()
    local delta = mapCalls - before
    if deltaText ~= "" then
        deltaText = deltaText .. ","
    end
    deltaText = deltaText .. tostring(delta)
    if delta >= 64 then
        sawWalk = true
    end
    if sawWalk and delta <= 4 then
        cheapAt = n
        break
    end
end
assertTrue(sawWalk, "expected one full 64-point map walk, pick costs: " .. deltaText)
assertTrue(cheapAt ~= nil, "off-map candidate kept walking every pick, costs: " .. deltaText)

if fails > 0 then
    io.stderr:write(tostring(fails) .. " assertion(s) failed\n")
    os.exit(1)
end
print("macro slot tests ok")
