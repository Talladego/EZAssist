----------------------------------------------------------------
-- EZAssist.GroupStats
-- Open-world party/warband combat scoreboard via GRP_STATS chat packets
-- (same source RoRGroupScoreboard uses). Independent cache — does not read
-- or require RoRGroupScoreboard.
----------------------------------------------------------------

EZAssist = EZAssist or {}
EZAssist.GroupStats = EZAssist.GroupStats or {}

local GroupStats = EZAssist.GroupStats

local m_active = false
local m_directCallback = nil
local m_rpExclusiveOrig = nil
local m_rpExclusiveWrap = nil
local m_rpWrapTable = nil
local m_rpWrapKey = nil
local m_rpWrapOrig = nil
local m_byCharId = {} -- [charId] = row

local function NormalizeNameKey(name)
    if name == nil then
        return nil
    end
    local s = name
    if type(s) == "wstring" then
        if type(WStringsRemoveGrammar) == "function" then
            s = WStringsRemoveGrammar(s)
        end
        if type(WStringToString) == "function" then
            s = WStringToString(s)
        else
            s = tostring(s)
        end
    elseif type(s) ~= "string" then
        s = tostring(s)
    end
    if s == nil or s == "" then
        return nil
    end
    local caret = string.find(s, "^", 1, true)
    if caret then
        s = string.sub(s, 1, caret - 1)
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return nil
    end
    return string.lower(s)
end

local function SelfRealm()
    return GameData and GameData.Player and tonumber(GameData.Player.realm) or nil
end

--- Normalize a GRP_STATS scoreboard object into a ScenarioStats-compatible row.
--- Accepts raw packet keys (deathBlows/damage) and scoreboard-normalized keys (deathblows/damagedealt).
local function BuildRow(charId, v)
    local name = v.name
    if type(name) == "string" then
        name = towstring(name)
    end
    local killDamage = tonumber(v.killDamage) or tonumber(v.killdamagedealt) or 0
    local deathBlows = tonumber(v.deathBlows) or tonumber(v.deathblows) or 0
    local damage = tonumber(v.damage) or tonumber(v.damagedealt) or tonumber(v.totalDamage) or 0
    return {
        name = name,
        key = NormalizeNameKey(name),
        charId = tonumber(charId) or tonumber(v.charId),
        careerLine = tonumber(v.career) or tonumber(v.careerLine),
        careerId = nil,
        realm = SelfRealm(),
        -- ScenarioStats.Row* field names:
        killdamagedealt = killDamage,
        deathblows = deathBlows,
        damagedealt = damage,
        killDamage = killDamage,
        deathBlows = deathBlows,
        totalDamage = damage,
    }
end

local function RowKillDamage(row)
    if type(row) ~= "table" then
        return 0
    end
    return tonumber(row.killdamagedealt) or tonumber(row.killDamage) or 0
end

local function RowDeathBlows(row)
    if type(row) ~= "table" then
        return 0
    end
    return tonumber(row.deathblows) or tonumber(row.deathBlows) or 0
end

local function RowTotalDamage(row)
    if type(row) ~= "table" then
        return 0
    end
    return tonumber(row.damagedealt) or tonumber(row.totalDamage) or 0
end

function GroupStats.RowKillDamage(row)
    return RowKillDamage(row)
end

function GroupStats.RowDeathBlows(row)
    return RowDeathBlows(row)
end

function GroupStats.RowTotalDamage(row)
    return RowTotalDamage(row)
end

function GroupStats.RowHasAssistCombatData(row)
    return RowKillDamage(row) > 0 or RowDeathBlows(row) > 0 or RowTotalDamage(row) > 0
end

local function ChallengerWins(challenger, incumbent)
    local akd, bkd = RowKillDamage(challenger), RowKillDamage(incumbent)
    if akd ~= bkd then
        return akd > bkd
    end
    local adb, bdb = RowDeathBlows(challenger), RowDeathBlows(incumbent)
    if adb ~= bdb then
        return adb > bdb
    end
    return RowTotalDamage(challenger) > RowTotalDamage(incumbent)
end

local function LeadReason(winner, runnerUp)
    if winner == nil then
        return "KillDamage"
    end
    if runnerUp == nil then
        if RowKillDamage(winner) > 0 then
            return "KillDamage"
        end
        if RowDeathBlows(winner) > 0 then
            return "Deathblows"
        end
        return "Total Damage"
    end
    if RowKillDamage(winner) ~= RowKillDamage(runnerUp) then
        return "KillDamage"
    end
    if RowDeathBlows(winner) ~= RowDeathBlows(runnerUp) then
        return "Deathblows"
    end
    return "Total Damage"
end

function GroupStats.Clear()
    m_byCharId = {}
end

function GroupStats.Count()
    local n = 0
    for _ in pairs(m_byCharId) do
        n = n + 1
    end
    return n
end

function GroupStats.GetRowByKey(key)
    if key == nil then
        return nil
    end
    for _, row in pairs(m_byCharId) do
        if row.key == key then
            return row
        end
    end
    return nil
end

--- Best party/warband ally by KillDamage → Deathblows → Total Damage.
--- opts.normalizeNameKey, opts.excludeKey, opts.requireCombatData (default true),
--- opts.accept(key, row) -> bool.
function GroupStats.PickBestAssistCandidate(opts)
    opts = opts or {}
    local normalizeNameKey = opts.normalizeNameKey or NormalizeNameKey
    local excludeKey = opts.excludeKey
    local accept = opts.accept
    local requireCombatData = opts.requireCombatData ~= false
    local realm = SelfRealm()

    local bestRow, bestKey = nil, nil
    local runnerUp = nil

    for _, row in pairs(m_byCharId) do
        if type(row) == "table" and row.name ~= nil then
            row.realm = realm
            local key = row.key or normalizeNameKey(row.name)
            row.key = key
            if key ~= nil and key ~= excludeKey then
                local okAccept = true
                if requireCombatData and not GroupStats.RowHasAssistCombatData(row) then
                    okAccept = false
                end
                if okAccept and type(accept) == "function" then
                    okAccept = accept(key, row) == true
                end
                if okAccept then
                    if bestRow == nil then
                        bestRow = row
                        bestKey = key
                    elseif ChallengerWins(row, bestRow) then
                        runnerUp = bestRow
                        bestRow = row
                        bestKey = key
                    elseif runnerUp == nil or ChallengerWins(row, runnerUp) then
                        runnerUp = row
                    end
                end
            end
        end
    end

    if bestKey == nil or bestRow == nil then
        return nil
    end
    return {
        key = bestKey,
        name = bestRow.name,
        row = bestRow,
        killDamage = RowKillDamage(bestRow),
        deathBlows = RowDeathBlows(bestRow),
        totalDamage = RowTotalDamage(bestRow),
        reason = LeadReason(bestRow, runnerUp),
    }
end

local function DecodeGrpStats(text)
    if type(text) ~= "string" or type(json) ~= "table" or type(json.decode) ~= "function" then
        return nil
    end
    -- Prefer offset form used by RoRGroupScoreboard (skip "GRP_STATS:").
    local ok, decoded = pcall(json.decode, text, 11)
    if ok and type(decoded) == "table" then
        return decoded
    end
    local payload = string.gsub(text, "^GRP_STATS:", "")
    ok, decoded = pcall(json.decode, payload)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

--- Chat channel-9 payload: "GRP_STATS:{...json...}"
function GroupStats.OnPacket(text)
    local decoded = DecodeGrpStats(text)
    if decoded == nil then
        return
    end

    local charId = tonumber(decoded.characterId)
    local board = decoded.scoreboard
    if charId == nil then
        return
    end

    if type(board) ~= "table" or board.name == nil then
        m_byCharId[charId] = nil
        return
    end

    m_byCharId[charId] = BuildRow(charId, board)

    if type(EZAssist.OnGroupStatsUpdated) == "function" then
        EZAssist.OnGroupStatsUpdated()
    end
end

function GroupStats.IsListening()
    return m_active == true
end

--- Opportunistic warm-start after /reload if another addon already holds rows.
--- Ranking still uses our cache; this does not require RoRGroupScoreboard.
function GroupStats.TryBootstrap()
    if GroupStats.Count() > 0 then
        return false
    end
    if type(RoRGroupScoreboard) ~= "table" or type(RoRGroupScoreboard.playersDataRaw) ~= "table" then
        return false
    end
    local added = false
    for charId, v in pairs(RoRGroupScoreboard.playersDataRaw) do
        if type(v) == "table" and v.name ~= nil then
            local id = tonumber(charId) or tonumber(v.charId)
            if id ~= nil then
                m_byCharId[id] = BuildRow(id, v)
                added = true
            end
        end
    end
    return added
end

local function EnsureRpListening()
    if type(ror_PacketHandling) ~= "table" then
        return false
    end
    local RP = ror_PacketHandling.RP
    if type(RP) ~= "table" then
        return false
    end

    local existing = RP["GRP_STATS"]

    -- Already chained on exclusive (function) builds.
    if m_rpExclusiveWrap ~= nil and existing == m_rpExclusiveWrap then
        return true
    end

    -- Live RoR builds often store a single function (not a list). Chain it.
    if type(existing) == "function" then
        if existing == GroupStats.OnPacket or existing == m_rpExclusiveWrap then
            return true
        end
        m_rpExclusiveOrig = existing
        m_rpExclusiveWrap = function(text)
            local fn = m_rpExclusiveOrig
            if type(fn) == "function" then
                fn(text)
            end
            GroupStats.OnPacket(text)
        end
        RP["GRP_STATS"] = m_rpExclusiveWrap
        return true
    end

    -- Multi-callback list builds (VinyUI-style Register).
    if type(existing) == "table" then
        if m_directCallback ~= nil then
            return true
        end
        for key, fn in pairs(existing) do
            if type(fn) == "function" and fn ~= GroupStats.OnPacket then
                m_rpWrapTable = existing
                m_rpWrapKey = key
                m_rpWrapOrig = fn
                existing[key] = function(text)
                    m_rpWrapOrig(text)
                    GroupStats.OnPacket(text)
                end
                return true
            end
        end
        if type(ror_PacketHandling.Register) == "function" then
            m_directCallback = GroupStats.OnPacket
            ror_PacketHandling.Register("GRP_STATS", m_directCallback)
            return true
        end
        return false
    end

    if type(ror_PacketHandling.Register) == "function" then
        m_directCallback = GroupStats.OnPacket
        ror_PacketHandling.Register("GRP_STATS", m_directCallback)
        return true
    end
    return false
end

--- Listen for GRP_STATS into our own cache.
--- Important: exclusive ror_PacketHandling keeps the registered function in RP[phrase];
--- replacing RoRGroupScoreboard.Packet alone does not receive packets.
function GroupStats.Initialize()
    if EnsureRpListening() then
        m_active = true
    end
    GroupStats.TryBootstrap()
end

function GroupStats.Shutdown()
    if m_directCallback ~= nil
        and type(ror_PacketHandling) == "table"
        and type(ror_PacketHandling.Unregister) == "function"
    then
        ror_PacketHandling.Unregister("GRP_STATS", m_directCallback)
        m_directCallback = nil
    end

    if m_rpWrapTable ~= nil and m_rpWrapKey ~= nil and m_rpWrapOrig ~= nil
        and m_rpWrapTable[m_rpWrapKey] ~= nil
    then
        m_rpWrapTable[m_rpWrapKey] = m_rpWrapOrig
    end
    m_rpWrapTable = nil
    m_rpWrapKey = nil
    m_rpWrapOrig = nil

    if m_rpExclusiveWrap ~= nil
        and type(ror_PacketHandling) == "table"
        and type(ror_PacketHandling.RP) == "table"
        and ror_PacketHandling.RP["GRP_STATS"] == m_rpExclusiveWrap
        and type(m_rpExclusiveOrig) == "function"
    then
        ror_PacketHandling.RP["GRP_STATS"] = m_rpExclusiveOrig
    end
    m_rpExclusiveWrap = nil
    m_rpExclusiveOrig = nil

    m_active = false
    GroupStats.Clear()
end
