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
    EZAssist.OnUpdate(0)
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

-- Disable keeps the owned macro as "EZAssist" with empty text, and must not
-- touch the player's macro in the cached slot.
enableWith({
    { name = "Mount", text = "/mount", iconNum = 4 },
    ownedRow(),
    emptyRow(),
})
macros[2] = { name = "Dance", text = "/dance", iconNum = 9 }
macros[3] = { name = "EZAssist", text = "/assist Alice", iconNum = 23166 }
clearWrites()
EZAssist.Disable()
EZAssist.OnUpdate(0)
assertEq(macros[2].name, "Dance", "disable deleted the player's macro in the cached slot")
assertTrue(not wroteSlot(2), "disable called SetMacroData on the player's slot")
assertEq(macros[3].name, "EZAssist", "disable should keep the EZAssist macro name")
assertEq(macros[3].text, "", "disable should clear the EZAssist macro text")
assertTrue(wroteSlot(3), "disable did not clear the assist text")

-- Cached index past the end of a short list must not error, and a real blank
-- row in that list is still a usable slot.
enableWith({
    emptyRow(),
    ownedRow(),
})
macros[2] = nil
clearWrites()
local ok, err = pcall(EZAssist.Sync)
assertTrue(ok, "cached slot past a short list errored: " .. tostring(err))
assertEq(macros[1].name, "EZAssist", "empty slot in a short list should still be claimed")
assertTrue(wroteSlot(1), "short list did not claim the empty slot")
assertTrue(not wroteSlot(2), "write used the stale slot past the end of the list")

-- Cached index into an empty list must not error or invent a row.
enableWith({
    emptyRow(),
    ownedRow(),
})
clearMacros()
clearWrites()
ok, err = pcall(EZAssist.Sync)
assertTrue(ok, "empty macro list errored: " .. tostring(err))
assertEq(macros[1], nil, "empty list should stay empty")
assertTrue(not wroteSlot(1), "empty list wrote a macro")
assertTrue(not wroteSlot(2), "empty list wrote the stale slot")

-- A blank row in the cached slot is usable, same as before the nil guard.
enableWith({
    { name = "Mount", text = "/mount", iconNum = 4 },
    ownedRow(),
})
macros[2] = emptyRow()
clearWrites()
ok, err = pcall(EZAssist.Sync)
assertTrue(ok, "blank cached slot errored: " .. tostring(err))
assertEq(macros[2].name, "EZAssist", "a blank cached slot should still be usable")
assertTrue(wroteSlot(2), "blank cached slot was not written")
assertEq(macros[1].name, "Mount", "blank-slot write touched another macro")

-- Solo: a deleted or overwritten macro is recreated without joining a group.
local savedParty = PartyUtils
PartyUtils = nil
enableWith({
    ownedRow(),
    emptyRow(),
})
macros[1] = { name = "Dance", text = "/dance", iconNum = 9 }
clearWrites()
EZAssist.Sync()
assertEq(macros[1].name, "Dance", "solo recreate overwrote the player's macro")
assertTrue(not wroteSlot(1), "solo recreate wrote the player's slot")
assertEq(macros[2].name, "EZAssist", "solo recreate should claim the empty slot")
assertEq(macros[2].text, "", "solo recreate should write an empty assist macro")
assertTrue(wroteSlot(2), "solo recreate did not write the empty slot")
macros[2] = emptyRow()
clearWrites()
EZAssist.Sync()
assertEq(macros[2].name, "EZAssist", "deleted macro should be recreated while solo")
assertEq(macros[2].text, "", "recreated solo macro should have empty text")
assertTrue(wroteSlot(2), "deleted macro was not rewritten while solo")
PartyUtils = savedParty

local function printsFull(lines)
    for i = 1, #lines do
        if string.find(lines[i], "all macro slots are full", 1, true) then
            return true
        end
    end
    return false
end

local function withMacroSources(primary, secondary, fn)
    local savedGet = GetMacrosData
    local savedPrint = EZAssist.Print
    local lines = {}
    GetMacrosData = function()
        return secondary
    end
    DataUtils = {
        GetMacros = function()
            return primary
        end,
    }
    EZAssist.Print = function(msg)
        lines[#lines + 1] = tostring(msg)
    end
    local ran, runErr = pcall(fn)
    GetMacrosData = savedGet
    DataUtils = nil
    EZAssist.Print = savedPrint
    if not ran then
        fail("split macro lists errored: " .. tostring(runErr))
    end
    return lines
end

-- When the two macro lists disagree, do not claim every slot is full.
clearWrites()
local disagreePrints = withMacroSources(
    {
        { name = "Dance", text = "/dance", iconNum = 9 },
        emptyRow(),
    },
    {
        { name = "Mount", text = "/mount", iconNum = 4 },
        { name = "Dance", text = "/dance", iconNum = 9 },
    },
    function()
        EZAssist.Settings.enabled = true
        EZAssist.Enable()
        EZAssist.OnUpdate(0)
    end
)
assertTrue(not printsFull(disagreePrints), "disagreement printed the full-slots warning")
assertEq(#writes, 0, "disagreement wrote a macro")

-- Both lists full still warns once and does not write.
clearWrites()
local fullPrints = withMacroSources(
    {
        { name = "Mount", text = "/mount", iconNum = 4 },
        { name = "Dance", text = "/dance", iconNum = 9 },
    },
    {
        { name = "Pet", text = "/pet", iconNum = 5 },
        { name = "Sit", text = "/sit", iconNum = 6 },
    },
    function()
        EZAssist.Settings.enabled = true
        EZAssist.Enable()
        EZAssist.OnUpdate(0)
    end
)
assertTrue(printsFull(fullPrints), "full lists did not warn")
assertEq(#writes, 0, "full lists wrote a macro")

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
EZAssist.OnUpdate(0)
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

-- Friendly lock clears when that ally leaves a non-empty roster, and stays
-- when they were never on the roster or the roster is empty.
clearMacros()
macros[1] = ownedRow()
macros[2] = emptyRow()
partyNames = { "Alice", "Bob" }
PartyUtils.IsPartyActive = function()
    return true
end
GameData.PlayerActions = { DO_MACRO = 7 }
function RegisterEventHandler()
end
function UnregisterEventHandler()
end
SystemData.Events = {
    GROUP_UPDATED = 1,
    BATTLEGROUP_UPDATED = 2,
    GROUP_STATUS_UPDATED = 3,
    BATTLEGROUP_MEMBER_UPDATED = 4,
    MACROS_LOADED = 5,
    PLAYER_TARGET_UPDATED = 6,
}
ActionButton = {
    OnLButtonUp = function()
    end,
}
SystemData.TargetObjectType = {
    ALLY_PLAYER = 1,
    SELF = 2,
    ENEMY_PLAYER = 3,
    ALLY_NON_PLAYER = 4,
}
local lockName = "Alice"
TargetInfo = {
    FRIENDLY_TARGET = "selffriendlytarget",
    HOSTILE_TARGET = "selfhostiletarget",
    m_Units = {
        selffriendlytarget = { healthPercent = 100 },
    },
    UnitType = function()
        return SystemData.TargetObjectType.ALLY_PLAYER
    end,
    UnitName = function()
        return lockName
    end,
}
EZAssist.Settings.enabled = true
EZAssist.Enable()
EZAssist.OnUpdate(0)
EZAssist.Sync()
EZAssist.OnUpdate(0)

local function pressMacro()
    EZAssist.OnPlayerTargetUpdated()
    EZAssist.OnUpdate(0)
    local status = EZAssist.DebugStatus()
    assertTrue(status.macroSlot ~= nil, "lock test needs an owned macro slot")
    ActionButton.OnLButtonUp({
        m_ActionType = GameData.PlayerActions.DO_MACRO,
        m_ActionId = status.macroSlot,
    }, 0, 0, 0)
    EZAssist.OnUpdate(0)
    EZAssist.OnUpdate(0)
end

lockName = "Alice"
pressMacro()
assertEq(EZAssist.DebugStatus().friendlyAssistLock, "Alice", "press should lock Alice")
partyNames = { "Bob" }
EZAssist.OnGroupUpdated()
assertEq(EZAssist.DebugStatus().friendlyAssistLock, nil, "lock should clear when Alice leaves the party")

lockName = "Carol"
pressMacro()
assertEq(EZAssist.DebugStatus().friendlyAssistLock, "Carol", "press should lock Carol")
partyNames = { "Bob", "Dave" }
EZAssist.OnGroupUpdated()
assertEq(
    EZAssist.DebugStatus().friendlyAssistLock,
    "Carol",
    "lock on a non-member should survive a group update"
)

partyNames = { "Carol", "Bob" }
EZAssist.OnGroupUpdated()
assertEq(EZAssist.DebugStatus().friendlyAssistLock, "Carol", "seeing Carol on the roster should keep the lock")
PartyUtils.IsPartyActive = function()
    return false
end
EZAssist.OnGroupUpdated()
assertEq(
    EZAssist.DebugStatus().friendlyAssistLock,
    "Carol",
    "ending the group should not clear a friendly lock"
)

if fails > 0 then
    io.stderr:write(tostring(fails) .. " assertion(s) failed\n")
    os.exit(1)
end
print("macro slot tests ok")
