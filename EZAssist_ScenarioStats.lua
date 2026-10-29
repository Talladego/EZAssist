----------------------------------------------------------------
-- EZAssist.ScenarioStats
-- Live scenario / city-siege player stats stream + KD->DB->TD ranking.
-- Extracted from CustomUI GroupIcons ScenarioStats (assist-only surface).
----------------------------------------------------------------

EZAssist = EZAssist or {}
EZAssist.ScenarioStats = EZAssist.ScenarioStats or {}

local ScenarioStats = EZAssist.ScenarioStats

local m_streaming = false
local m_acquireCount = 0

local function StartEvent()
    return SystemData and SystemData.Events and SystemData.Events.SCENARIO_START_UPDATING_PLAYERS_STATS
end

local function StopEvent()
    return SystemData and SystemData.Events and SystemData.Events.SCENARIO_STOP_UPDATING_PLAYERS_STATS
end

local function SummaryWindowIsShowing()
    if type(DoesWindowExist) ~= "function" or type(WindowGetShowing) ~= "function" then
        return false
    end
    if not DoesWindowExist("ScenarioSummaryWindow") then
        return false
    end
    return WindowGetShowing("ScenarioSummaryWindow") == true
end

local function BroadcastStart()
    if m_streaming then
        return
    end
    local ev = StartEvent()
    if ev == nil or type(BroadcastEvent) ~= "function" then
        return
    end
    pcall(BroadcastEvent, ev)
    m_streaming = true
end

local function BroadcastStop()
    if not m_streaming then
        return
    end
    m_streaming = false
    if SummaryWindowIsShowing() then
        return
    end
    local ev = StopEvent()
    if ev == nil or type(BroadcastEvent) ~= "function" then
        return
    end
    pcall(BroadcastEvent, ev)
end

function ScenarioStats.IsStreaming()
    return m_streaming == true
end

function ScenarioStats.Start()
    BroadcastStart()
end

function ScenarioStats.Stop()
    if m_acquireCount > 0 then
        return
    end
    BroadcastStop()
end

function ScenarioStats.Acquire()
    m_acquireCount = m_acquireCount + 1
    BroadcastStart()
end

function ScenarioStats.Release()
    if m_acquireCount > 0 then
        m_acquireCount = m_acquireCount - 1
    end
    if m_acquireCount <= 0 then
        m_acquireCount = 0
        BroadcastStop()
    end
end

--- Kill damage from a GetScenarioPlayers() row (stock maps renownbonus -> killdamagedealt).
function ScenarioStats.RowKillDamage(row)
    if type(row) ~= "table" then
        return 0
    end
    local killDamage = tonumber(row.killdamagedealt)
    if killDamage == nil then
        killDamage = tonumber(row.renownbonus)
    end
    return killDamage or 0
end

function ScenarioStats.RowDeathBlows(row)
    if type(row) ~= "table" then
        return 0
    end
    return tonumber(row.deathblows) or 0
end

function ScenarioStats.RowTotalDamage(row)
    if type(row) ~= "table" then
        return 0
    end
    return tonumber(row.damagedealt) or 0
end

function ScenarioStats.RowHasAssistCombatData(row)
    return ScenarioStats.RowKillDamage(row) > 0
        or ScenarioStats.RowDeathBlows(row) > 0
        or ScenarioStats.RowTotalDamage(row) > 0
end

local function NameForChat(name)
    if name == nil then
        return nil
    end
    local s = nil
    if type(name) == "wstring" then
        if type(WStringToString) == "function" then
            local ok, text = pcall(WStringToString, name)
            if ok and type(text) == "string" then
                s = text
            end
        end
    elseif type(name) == "string" then
        s = name
    end
    if s == nil or s == "" then
        return nil
    end
    local caret = string.find(s, "^", 1, true)
    if caret then
        s = string.sub(s, 1, caret - 1)
    end
    if s == "" then
        return nil
    end
    return s
end

local function IsScoredRealm(realm)
    if GameData == nil or GameData.Realm == nil then
        return false
    end
    return realm == GameData.Realm.ORDER or realm == GameData.Realm.DESTRUCTION
end

local function AssistChallengerWins(challenger, incumbent)
    local akd = ScenarioStats.RowKillDamage(challenger)
    local bkd = ScenarioStats.RowKillDamage(incumbent)
    if akd ~= bkd then
        return akd > bkd
    end
    local adb = ScenarioStats.RowDeathBlows(challenger)
    local bdb = ScenarioStats.RowDeathBlows(incumbent)
    if adb ~= bdb then
        return adb > bdb
    end
    return ScenarioStats.RowTotalDamage(challenger) > ScenarioStats.RowTotalDamage(incumbent)
end

local function AssistLeadReason(winner, runnerUp)
    if winner == nil then
        return "KillDamage"
    end
    if runnerUp == nil then
        if ScenarioStats.RowKillDamage(winner) > 0 then
            return "KillDamage"
        end
        if ScenarioStats.RowDeathBlows(winner) > 0 then
            return "Deathblows"
        end
        return "Total Damage"
    end
    if ScenarioStats.RowKillDamage(winner) ~= ScenarioStats.RowKillDamage(runnerUp) then
        return "KillDamage"
    end
    if ScenarioStats.RowDeathBlows(winner) ~= ScenarioStats.RowDeathBlows(runnerUp) then
        return "Deathblows"
    end
    return "Total Damage"
end

local function FetchScenarioPlayerRows()
    if type(GameData) ~= "table" or type(GameData.GetScenarioPlayers) ~= "function" then
        return nil
    end
    local ok, list = pcall(GameData.GetScenarioPlayers)
    if not ok or type(list) ~= "table" then
        return nil
    end
    return list
end

--- Best same-realm scoreboard player for EZAssist.
--- opts.realm, opts.normalizeNameKey, opts.excludeKey, opts.accept,
--- opts.requireCombatData (default true), opts.players, opts.rowByKey.
function ScenarioStats.PickBestAssistCandidate(opts)
    opts = opts or {}
    local realm = tonumber(opts.realm)
    local normalizeNameKey = opts.normalizeNameKey
    if realm == nil or type(normalizeNameKey) ~= "function" then
        return nil
    end
    local list = opts.players
    if list == nil then
        if not IsScoredRealm(realm) then
            return nil
        end
        list = FetchScenarioPlayerRows()
    end
    if type(list) ~= "table" then
        return nil
    end

    local excludeKey = opts.excludeKey
    local accept = opts.accept
    local requireCombatData = opts.requireCombatData ~= false
    local allowRank = IsScoredRealm(realm)
    local rowByKey = opts.rowByKey
    if type(rowByKey) ~= "table" then
        rowByKey = nil
    end
    local bestRow, bestKey, bestName = nil, nil, nil
    local runnerUp = nil

    for _, row in ipairs(list) do
        if type(row) == "table" and tonumber(row.realm) == realm and row.name ~= nil then
            local key = normalizeNameKey(row.name)
            if key ~= nil then
                if rowByKey ~= nil and rowByKey[key] == nil then
                    rowByKey[key] = row
                end
                if allowRank and key ~= excludeKey then
                    local okAccept = true
                    if requireCombatData and not ScenarioStats.RowHasAssistCombatData(row) then
                        okAccept = false
                    end
                    if okAccept and type(accept) == "function" then
                        okAccept = accept(key, row) == true
                    end
                    if okAccept then
                        if bestRow == nil then
                            bestRow = row
                            bestKey = key
                            bestName = NameForChat(row.name)
                        elseif AssistChallengerWins(row, bestRow) then
                            runnerUp = bestRow
                            bestRow = row
                            bestKey = key
                            bestName = NameForChat(row.name)
                        elseif runnerUp == nil or AssistChallengerWins(row, runnerUp) then
                            runnerUp = row
                        end
                    end
                end
            end
        end
    end

    if not allowRank or bestKey == nil or bestRow == nil then
        return nil
    end
    return {
        key = bestKey,
        name = bestName,
        row = bestRow,
        killDamage = ScenarioStats.RowKillDamage(bestRow),
        deathBlows = ScenarioStats.RowDeathBlows(bestRow),
        totalDamage = ScenarioStats.RowTotalDamage(bestRow),
        reason = AssistLeadReason(bestRow, runnerUp),
    }
end
