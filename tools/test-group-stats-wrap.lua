-- GRP_STATS hook harness. Run from the repo root:
--   lua5.1 tools/test-group-stats-wrap.lua
-- Calls EnsureRpListening many times and checks one OnPacket per packet.

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

function towstring(value)
    return value
end

local function loadAddonLua(path)
    local inp = io.open(path, "r")
    if inp == nil then
        fail("could not read " .. path .. " (run from the repo root)")
        os.exit(1)
    end
    local text = inp:read("*a")
    inp:close()
    -- WAR wstring literals (L"...") are not valid Lua 5.1.
    text = text:gsub('L"([^"]*)"', '"%1"')
    local dest = os.tmpname()
    local out = io.open(dest, "w")
    if out == nil then
        fail("could not write " .. dest)
        os.exit(1)
    end
    out:write(text)
    out:close()
    dofile(dest)
    os.remove(dest)
end

loadAddonLua("EZAssist_GroupStats.lua")

local GS = EZAssist.GroupStats
local calls = 0
local realOnPacket = GS.OnPacket
GS.OnPacket = function(text)
    calls = calls + 1
    return realOnPacket(text)
end

local function resetCalls()
    calls = 0
end

local function pump(times)
    for _ = 1, times do
        local ok = GS.EnsureRpListening()
        if ok ~= true then
            fail("EnsureRpListening returned " .. tostring(ok))
            return
        end
    end
end

local function fire(fn, text)
    resetCalls()
    fn(text or "GRP_STATS:not-json")
    return calls
end

-- Table path: repeated listens must not stack wrappers.
local function testTablePath()
    GS.Shutdown()
    local foreignCalls = 0
    local function foreign(_)
        foreignCalls = foreignCalls + 1
    end
    ror_PacketHandling = {
        RP = {
            GRP_STATS = { foreign },
        },
    }
    pump(40)
    local installed = ror_PacketHandling.RP.GRP_STATS[1]
    assertTrue(installed ~= foreign, "table path should wrap the foreign handler")
    pump(40)
    assertTrue(ror_PacketHandling.RP.GRP_STATS[1] == installed, "table path re-wrapped its own handler")
    foreignCalls = 0
    assertEq(fire(installed), 1, "table path OnPacket count without a successor")
    assertEq(foreignCalls, 1, "table path should call the previous handler once")

    local function successor(text)
        installed(text)
    end
    ror_PacketHandling.RP.GRP_STATS[1] = successor
    pump(40)
    assertTrue(ror_PacketHandling.RP.GRP_STATS[1] == successor, "table path wrapped a foreign successor")
    foreignCalls = 0
    assertEq(fire(successor), 1, "table path OnPacket count with a foreign successor")
    assertEq(foreignCalls, 1, "successor chain should reach the original once")

    GS.Shutdown()
    assertTrue(ror_PacketHandling.RP.GRP_STATS[1] == successor, "shutdown removed a foreign successor")
    foreignCalls = 0
    assertEq(fire(successor), 0, "shutdown should silence the orphaned table wrapper")
    assertEq(foreignCalls, 1, "orphaned wrapper should still call the previous handler")

    -- Owning the slot restores the original, and a fresh listen wraps once.
    ror_PacketHandling.RP.GRP_STATS[1] = foreign
    pump(5)
    installed = ror_PacketHandling.RP.GRP_STATS[1]
    GS.Shutdown()
    assertTrue(ror_PacketHandling.RP.GRP_STATS[1] == foreign, "shutdown should restore the table handler we replaced")
    foreignCalls = 0
    assertEq(fire(foreign), 0, "restored table handler should not call OnPacket")
    pump(5)
    assertEq(fire(ror_PacketHandling.RP.GRP_STATS[1]), 1, "re-listen after shutdown should deliver one OnPacket")
end

-- Exclusive function path: same contract, including a successor installed after us.
local function testFunctionPath()
    GS.Shutdown()
    local foreignCalls = 0
    local function foreign(_)
        foreignCalls = foreignCalls + 1
    end
    ror_PacketHandling = {
        RP = { GRP_STATS = foreign },
    }
    pump(40)
    local installed = ror_PacketHandling.RP.GRP_STATS
    assertTrue(type(installed) == "function" and installed ~= foreign, "function path should wrap")
    pump(40)
    assertTrue(ror_PacketHandling.RP.GRP_STATS == installed, "function path re-wrapped")
    foreignCalls = 0
    assertEq(fire(installed), 1, "function path OnPacket count")
    assertEq(foreignCalls, 1, "function path should call the previous handler once")

    local function successor(text)
        installed(text)
    end
    ror_PacketHandling.RP.GRP_STATS = successor
    pump(40)
    assertTrue(ror_PacketHandling.RP.GRP_STATS == successor, "function path wrapped a foreign successor")
    foreignCalls = 0
    assertEq(fire(successor), 1, "function path OnPacket count with a foreign successor")

    GS.Shutdown()
    assertTrue(ror_PacketHandling.RP.GRP_STATS == successor, "shutdown removed a function-path successor")
    foreignCalls = 0
    assertEq(fire(successor), 0, "shutdown should silence the orphaned function wrapper")

    ror_PacketHandling.RP.GRP_STATS = foreign
    pump(3)
    GS.Shutdown()
    assertTrue(ror_PacketHandling.RP.GRP_STATS == foreign, "shutdown should restore the function we replaced")
end

-- Register is attempted once when nothing is installed yet.
local function testRegisterOnce()
    GS.Shutdown()
    local regs = 0
    local unregs = 0
    local stored = nil
    ror_PacketHandling = {
        RP = {},
        Register = function(_, fn)
            regs = regs + 1
            stored = fn
        end,
        Unregister = function(_, fn)
            unregs = unregs + 1
            if stored == fn then
                stored = nil
            end
        end,
    }
    pump(25)
    assertEq(regs, 1, "Register should run once")
    assertEq(fire(stored), 1, "registered callback should deliver one OnPacket")
    pump(10)
    assertEq(regs, 1, "later listens must not Register again")
    local callback = stored
    GS.Shutdown()
    assertEq(unregs, 1, "Shutdown should Unregister the callback it registered")
    assertEq(fire(callback), 0, "unregistered callback must not keep delivering")
end

-- Public Initialize is a no-op once listening, so a refresh loop cannot re-wrap.
local function testInitializeNoOp()
    GS.Shutdown()
    local function foreign()
    end
    ror_PacketHandling = { RP = { GRP_STATS = { foreign } } }
    GS.Initialize()
    local installed = ror_PacketHandling.RP.GRP_STATS[1]
    for _ = 1, 20 do
        GS.Initialize()
    end
    assertTrue(ror_PacketHandling.RP.GRP_STATS[1] == installed, "Initialize re-wrapped after the first listen")
    assertEq(fire(installed), 1, "Initialize loop should still deliver one OnPacket")
    assertTrue(GS.IsListening() == true, "Initialize should report listening")
end

local function testPrune()
    GS.Shutdown()
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

    GS.OnPacket(packet(1, "Alice", 10))
    GS.OnPacket(packet(2, "Bob", 20))
    GS.OnPacket(packet(3, "Cara", 5))
    assertEq(GS.Count(), 3, "three scoreboard rows before prune")

    assertEq(GS.PruneToRoster(nil), 0, "nil roster must not prune")
    assertEq(GS.PruneToRoster({}), 0, "empty roster must not prune")
    assertEq(GS.Count(), 3, "cache wiped by an empty roster")

    local removed = GS.PruneToRoster({ alice = true, cara = false })
    assertEq(removed, 1, "only Bob should leave")
    assertEq(GS.Count(), 2, "Alice and Cara should remain")
    assertTrue(GS.GetRowByKey("alice") ~= nil, "Alice was pruned")
    assertTrue(GS.GetRowByKey("bob") == nil, "Bob stayed after leaving")
    assertTrue(GS.GetRowByKey("cara") ~= nil, "a roster key set to false was treated as absent")

    GS.OnPacket(packet(2, "Bob", 9))
    assertEq(GS.Count(), 3, "a later packet can add Bob again")
    GS.PruneToRoster({ alice = true, cara = true })
    assertTrue(GS.GetRowByKey("bob") == nil, "prune should drop Bob again on the next roster pass")
    GS.Shutdown()
end

testTablePath()
testFunctionPath()
testRegisterOnce()
testInitializeNoOp()
testPrune()

if fails > 0 then
    io.stderr:write(tostring(fails) .. " assertion(s) failed\n")
    os.exit(1)
end
print("group stats wrap tests ok")
