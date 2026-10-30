----------------------------------------------------------------
-- EZAssist
-- Managed hotbar macro "/assist <player>" for scenarios and open-world
-- party/warband. Picks the alive ally within range with best
-- KillDamage -> Deathblows -> Total Damage. Never assists self.
-- Scenario rows: EZAssist.ScenarioStats / GetScenarioPlayers.
-- Party/warband: GRP_STATS packets (EZAssist.GroupStats; not RoRGroupScoreboard).
-- Optional clearOnHostile: clears the macro while you have a living hostile player (not NPCs).
-- Friendly lock (always on): press assist while targeting an ally player to lock them;
-- press while targeting self to clear and fall back to KD ranking.
-- A lock also clears when that ally leaves the party or warband.
-- Enable seats/keeps the managed macro. Disable stops updates and clears /assist text
-- but does not wipe the macro slot (hard delete + recreate freezes with SwiftAssist
-- on MACROS_LOADED). Bind and press the macro yourself - RoR ignores /assist from addons.
----------------------------------------------------------------

EZAssist = EZAssist or {}

local SmartAssist = EZAssist

SmartAssist.MACRO_NAME = "EZAssist"
SmartAssist.ICON_ACTIVE = 23166 -- Unshakable Focus; always used
SmartAssist.DEFAULT_RANGE = 65
SmartAssist.RANGE_MIN = 1
SmartAssist.RANGE_MAX = 500
-- ActionButton overlay index for the career burn glow (same as EZGuard).
local c_GLOW_ANIM = 6
local c_GLOW_HAS_TARGET = 1 -- macro has an assist name (acked)
local c_GLOW_NEW_TARGET = 3 -- new assist until the macro is pressed once
-- Glow levels applied in OnUpdate / RefreshAssist (never in OnLButtonUp).

local c_DISTANCE_FIX = 1 / 1.06
local c_MAX_MAP_POINTS = 511
-- After one full pip walk, off-map names skip the 64-point scan for a few picks.
local c_SWEEP_RESCAN_PICKS = 8
local c_MAP_WINDOW = "EA_Window_OverheadMapMapDisplay"
local c_MAP_POINT_TYPE_FILTER = {
    [SystemData.MapPips.GROUP_MEMBER] = true,
    [SystemData.MapPips.WARBAND_MEMBER] = true,
    [SystemData.MapPips.DESTRUCTION_ARMY] = true,
    [SystemData.MapPips.ORDER_ARMY] = true,
}

-- Stickiness: map/alive flicker was causing rapid re-picks of weaker allies.
local c_SWITCH_HOLD_SEC = 8
local c_HYSTERESIS_KD = 1.20 -- challenger needs 20% more KillDamage to steal
local c_STICKY_RANGE_MULT = 1.35 -- keep current pick a bit past range edge
local c_REFRESH_INTERVAL = 0.5

local DEFAULT_SETTINGS = {
    enabled = true,
    range = SmartAssist.DEFAULT_RANGE,
    notify = false,
    clearOnHostile = false,
    glowOnNewAssist = true,
    preferFriendlyTarget = true,
}

local m_handlersRegistered = false
local m_statsHeld = false
local m_macroSlot = nil
local m_lastAssistName = nil -- wstring or nil
local m_lastAssistKey = nil -- cached NormalizeNameKey(m_lastAssistName)
local m_lastNotifyKey = nil -- normalized name; survives hostile clear so we do not re-spam
local m_fullSlotsWarned = false
local m_distCache = {} -- [nameKey] = { index, rawName, distance } or { miss = true, sweep = n }
local m_scanCursor = 1
local m_sweptPoints = 0
local m_sweepReady = false
local m_sweepId = 0
local m_picksSinceSweep = 0
local m_walkedThisPick = false
-- Reused party/warband name keys for GroupStats.PruneToRoster. Cleared in place.
local m_rosterKeys = {}
local m_updateElapsed = 0
local m_stickyKey = nil
local m_stickyHoldLeft = 0
-- Cached from EnsureSettings / Sync so OnUpdate and events do no settings work.
local m_enabled = false
local m_notify = false
local m_clearOnHostile = false
local m_glowEnabled = true
local m_preferFriendlyTarget = true
local m_boundSettings = nil
-- Events set these. OnUpdate is what ranks players and rewrites the macro.
local m_dirty = false
local m_refreshNow = false
local m_targetDirty = false
local m_assistSuppressed = false
local m_inAssistWork = false
-- Reused across picks so a refresh does not allocate a new index table.
local m_playerRowByKey = {}
-- Glow ack / friendly lock: press sets pending; OnUpdate applies (never WriteMacro in OnLButtonUp).
local m_glowOn = false
local m_glowClearPending = false
local m_macroPressPending = false
local m_pressActionId = nil -- ActionButton.m_ActionId from the deferred press
-- Press snapshot: copied from cache in OnLButtonUp (no TargetInfo calls on the click path).
local m_pressLockKind = nil -- "lock" | "clear" | nil
local m_pressLockName = nil -- wstring when kind == "lock"
-- Kept current via target updates / OnUpdate so the click wrapper stays flags-only.
local m_cachedPressLockKind = nil
local m_cachedPressLockName = nil
-- SetMacroData the frame after a lock/clear press so we do not race WindowGameAction /assist.
local m_flushMacroWrite = false
local m_pendingMacroWrite = false
local m_pendingMacroWriteName = nil -- wstring or nil (clear)
local m_friendlyAssistLock = nil -- wstring; locked by macro press on ally player
local m_friendlyLockSeenOnRoster = false
local m_glowAckName = nil -- wstring; last pick the player pressed the macro for
local m_glowAckKey = nil -- cached NormalizeNameKey(m_glowAckName)
local m_stockActionButtonOnLButtonUp = nil
local m_glowActionButtonWrapper = nil
local m_glowHookInstalled = false
-- Forward decls: early paths schedule WriteMacro / glow before those defs.
local WriteMacro
local UpdateMacroGlow
-- Enable/disable/settings apply SetMacroData; defer off UI/slash click stacks.
local m_pendingSync = false
local m_pendingGlowSync = false

local function ScenarioStats()
    return EZAssist.ScenarioStats
end

local function GroupStats()
    return EZAssist.GroupStats
end

local function RememberSettings(settings)
    m_enabled = settings.enabled == true
    m_notify = settings.notify == true
    m_clearOnHostile = settings.clearOnHostile == true
    m_glowEnabled = settings.glowOnNewAssist ~= false
    -- Friendly lock is always on (no toggle).
    m_preferFriendlyTarget = true
    settings.preferFriendlyTarget = true
end

--- Fill missing keys on `current`. Does not allocate when every default is already present.
local function mergeDefaultsInPlace(defaults, current)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(current[key]) ~= "table" then
                current[key] = {}
            end
            mergeDefaultsInPlace(value, current[key])
        elseif current[key] == nil then
            current[key] = value
        end
    end
end

local function AssignIfChanged(settings, key, value)
    if settings[key] ~= value then
        settings[key] = value
    end
end

function SmartAssist.EnsureSettings()
    if type(EZAssist.Settings) ~= "table" then
        EZAssist.Settings = {}
    end
    local settings = EZAssist.Settings
    -- Merge once per table. Saved-variable restore swaps the table; edits do not.
    if settings ~= m_boundSettings then
        mergeDefaultsInPlace(DEFAULT_SETTINGS, settings)
        m_boundSettings = settings
    end
    local range = tonumber(settings.range) or SmartAssist.DEFAULT_RANGE
    if range < SmartAssist.RANGE_MIN then
        range = SmartAssist.RANGE_MIN
    elseif range > SmartAssist.RANGE_MAX then
        range = SmartAssist.RANGE_MAX
    end
    range = math.floor(range + 0.5)
    AssignIfChanged(settings, "range", range)
    AssignIfChanged(settings, "enabled", settings.enabled == true)
    AssignIfChanged(settings, "notify", settings.notify == true)
    AssignIfChanged(settings, "clearOnHostile", settings.clearOnHostile == true)
    AssignIfChanged(settings, "glowOnNewAssist", settings.glowOnNewAssist ~= false)
    AssignIfChanged(settings, "preferFriendlyTarget", true)
    settings.autoAssist = nil -- removed; RoR ignores /assist via SendChatText
    RememberSettings(settings)
    return settings
end

-- Lua string, or nil. Nil, "", and L"" never reach WStringToString.
-- The client logs Invalid Parameters for those calls even when the result is "".
local function WStringToNarrow(value)
    if value == nil or value == "" or value == L"" then
        return nil
    end
    local kind = type(value)
    if kind == "string" then
        return value
    end
    if kind ~= "wstring" or type(WStringToString) ~= "function" then
        local s = tostring(value)
        if s == nil or s == "" then
            return nil
        end
        return s
    end
    local ok, text = pcall(WStringToString, value)
    if ok and type(text) == "string" and text ~= "" then
        return text
    end
    return nil
end

local function NormalizeNameKey(name)
    if name == nil or name == "" or name == L"" then
        return nil
    end
    local s = name
    if type(s) == "wstring" and type(WStringsRemoveGrammar) == "function" then
        local ok, stripped = pcall(WStringsRemoveGrammar, s)
        if ok then
            if stripped == nil or stripped == "" or stripped == L"" then
                return nil
            end
            s = stripped
        end
    end
    s = WStringToNarrow(s)
    if type(s) ~= "string" or s == "" then
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

local function SetLastAssistName(name)
    m_lastAssistName = name
    m_lastAssistKey = NormalizeNameKey(name)
end

local function SetGlowAckName(name)
    m_glowAckName = name
    m_glowAckKey = NormalizeNameKey(name)
end

-- Press ack copies the cached key. Do not normalize the stored name again.
local function AckGlowForLastAssist()
    m_glowAckName = m_lastAssistName
    m_glowAckKey = m_lastAssistKey
end

local function StripForAssist(name)
    if name == nil then
        return nil
    end
    local s = name
    if type(s) == "wstring" then
        if type(WStringsRemoveGrammar) == "function" then
            s = WStringsRemoveGrammar(s)
        end
    end
    if type(s) == "wstring" then
        local base = s:match(L"([^^]+)^?([^^]*)")
        if base ~= nil and base ~= L"" then
            return base
        end
        return s
    end
    local str = tostring(s)
    local caret = string.find(str, "^", 1, true)
    if caret then
        str = string.sub(str, 1, caret - 1)
    end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    if str == "" then
        return nil
    end
    return towstring(str)
end

local function SelfNameKey()
    return NormalizeNameKey(GameData and GameData.Player and GameData.Player.name)
end

local function SelfRealm()
    return GameData and GameData.Player and tonumber(GameData.Player.realm) or nil
end

local function IsScenarioContext()
    if GameData and GameData.Player then
        if GameData.Player.isInScenario == true then
            return true
        end
        if GameData.Player.isInSiege == true then
            return true
        end
    end
    return false
end

local function IsPartyOrWarband()
    if type(IsWarBandActive) == "function" and IsWarBandActive() then
        return true
    end
    if type(PartyUtils) == "table" and type(PartyUtils.IsPartyActive) == "function" then
        return PartyUtils.IsPartyActive() == true
    end
    return false
end

--- Scenario/siege or open-world party/warband.
local function IsAssistContext()
    return IsScenarioContext() or IsPartyOrWarband()
end

--- Active scoreboard for the current context (scenario vs party/warband GRP_STATS).
local function AssistStats()
    if IsScenarioContext() then
        local SS = ScenarioStats()
        if SS ~= nil and type(SS.PickBestAssistCandidate) == "function" then
            return SS, "scenario"
        end
        return nil, "scenario"
    end
    if IsPartyOrWarband() then
        local GS = GroupStats()
        if GS ~= nil and type(GS.PickBestAssistCandidate) == "function" then
            return GS, "group"
        end
        return nil, "group"
    end
    return nil, nil
end

local c_HOSTILE_UNIT_ID = (TargetInfo and TargetInfo.HOSTILE_TARGET) or "selfhostiletarget"
local c_FRIENDLY_UNIT_ID = (TargetInfo and TargetInfo.FRIENDLY_TARGET) or "selffriendlytarget"

--- healthPercent from TargetInfo unit table for a unit id.
--- Returns nil when the unit/field is missing (UnitHealth alone cannot tell nil from 0).
--- Fractional (0,1) is treated as dead (same snap GroupIcons uses).
local function TargetHealthKnown(unitId)
    if type(TargetInfo) ~= "table" or unitId == nil then
        return nil
    end
    local units = TargetInfo.m_Units
    if type(units) == "table" then
        local unit = units[unitId]
        if type(unit) ~= "table" or unit.healthPercent == nil then
            return nil
        end
        local hp = tonumber(unit.healthPercent) or 0
        if hp > 0 and hp < 1 then
            hp = 0
        end
        return hp
    end
    if type(TargetInfo.UnitHealth) ~= "function" then
        return nil
    end
    -- Fallback: stock UnitHealth collapses missing HP to 0 - cannot prove dead.
    return nil
end

local function HostileTargetHealthKnown()
    return TargetHealthKnown(c_HOSTILE_UNIT_ID)
end

local function FriendlyTargetHealthKnown()
    return TargetHealthKnown(c_FRIENDLY_UNIT_ID)
end

local function HostileTargetPresent()
    if type(TargetInfo) ~= "table" then
        return false
    end
    if type(TargetInfo.UnitEntityId) == "function" then
        local entityId = tonumber(TargetInfo:UnitEntityId(c_HOSTILE_UNIT_ID)) or 0
        if entityId > 0 then
            return true
        end
    end
    if type(TargetInfo.UnitName) == "function" then
        local name = TargetInfo:UnitName(c_HOSTILE_UNIT_ID)
        if name ~= nil and name ~= L"" then
            return true
        end
    end
    return false
end

--- True when TargetInfo has a living hostile target. Dead corpses count as no target.
--- Presence with unknown HP blocks assist (avoid filling the macro mid-tab-in).
local function HasHostileTarget()
    if not HostileTargetPresent() then
        return false
    end
    local hp = HostileTargetHealthKnown()
    if hp == nil then
        return true
    end
    return hp > 0
end

--- Living hostile *player* only (clearOnHostile). NPCs / pets do not clear the macro.
local function HasHostilePlayerTarget()
    if not HasHostileTarget() then
        return false
    end
    local types = SystemData and SystemData.TargetObjectType
    local enemyPlayer = types and types.ENEMY_PLAYER
    if type(TargetInfo.UnitType) == "function" and enemyPlayer ~= nil then
        return TargetInfo:UnitType(c_HOSTILE_UNIT_ID) == enemyPlayer
    end
    if type(TargetInfo.UnitIsNPC) == "function" and TargetInfo:UnitIsNPC(c_HOSTILE_UNIT_ID) == true then
        return false
    end
    return true
end

--- Living ally-player friendly target name for /assist, or nil (NPC / self / dead / missing).
local function GetFriendlyPlayerAssistName(selfKey)
    if type(TargetInfo) ~= "table" then
        return nil
    end
    local unitId = c_FRIENDLY_UNIT_ID
    local types = SystemData and SystemData.TargetObjectType
    local unitType = nil
    if type(TargetInfo.UnitType) == "function" then
        unitType = TargetInfo:UnitType(unitId)
    end
    local allyPlayer = types and types.ALLY_PLAYER
    local allyNpc = types and types.ALLY_NON_PLAYER
    local selfType = types and types.SELF
    if allyPlayer ~= nil then
        if unitType ~= allyPlayer then
            return nil
        end
    else
        -- Enum missing: require friendly + not NPC + not self.
        if selfType ~= nil and unitType == selfType then
            return nil
        end
        if allyNpc ~= nil and unitType == allyNpc then
            return nil
        end
        if type(TargetInfo.UnitIsFriendly) == "function" and TargetInfo:UnitIsFriendly(unitId) ~= true then
            return nil
        end
        if type(TargetInfo.UnitIsNPC) == "function" and TargetInfo:UnitIsNPC(unitId) == true then
            return nil
        end
    end
    if type(TargetInfo.UnitIsNPC) == "function" and TargetInfo:UnitIsNPC(unitId) == true then
        return nil
    end
    local rawName = nil
    if type(TargetInfo.UnitName) == "function" then
        rawName = TargetInfo:UnitName(unitId)
    end
    local assistName = StripForAssist(rawName)
    if assistName == nil or assistName == L"" then
        return nil
    end
    local key = NormalizeNameKey(assistName)
    if key == nil or (selfKey ~= nil and key == selfKey) then
        return nil
    end
    local hp = FriendlyTargetHealthKnown()
    if hp ~= nil and hp <= 0 then
        return nil
    end
    return assistName
end

--- True when the friendly target unit is yourself (self-target or matching name).
local function IsTargetingSelf(selfKey)
    if type(TargetInfo) ~= "table" then
        return false
    end
    if type(TargetInfo.UnitType) == "function" then
        local selfType = SystemData and SystemData.TargetObjectType and SystemData.TargetObjectType.SELF
        if selfType ~= nil and TargetInfo:UnitType(c_FRIENDLY_UNIT_ID) == selfType then
            return true
        end
    end
    if selfKey == nil then
        return false
    end
    local rawName = nil
    if type(TargetInfo.UnitName) == "function" then
        rawName = TargetInfo:UnitName(c_FRIENDLY_UNIT_ID)
    end
    local assistName = StripForAssist(rawName)
    if assistName == nil or assistName == L"" then
        return false
    end
    return NormalizeNameKey(assistName) == selfKey
end

local function ClearFriendlyAssistLock()
    m_friendlyAssistLock = nil
    m_friendlyLockSeenOnRoster = false
end

local function FriendlyAssistLocked()
    return m_preferFriendlyTarget == true and m_friendlyAssistLock ~= nil
end

local function PrintFriendlyLock(name)
    if type(EZAssist.Print) ~= "function" then
        return
    end
    EZAssist.Print(L"friendly assist: " .. name)
    -- Solo / open-world: client ignores /assist outside party, warband, or scenario (RoR bug 17526).
    if not IsAssistContext() then
        EZAssist.Print(L"warning: /assist won't work outside a party, warband, or scenario")
    end
end

local function PrintFriendlyUnlock()
    if type(EZAssist.Print) ~= "function" then
        return
    end
    if IsAssistContext() then
        EZAssist.Print(L"friendly assist cleared (KD ranking)")
    else
        EZAssist.Print(L"friendly assist cleared")
    end
end

--- Refresh click-path cache. Safe from OnUpdate / target events; never from OnLButtonUp.
local function RefreshFriendlyPressCache()
    m_cachedPressLockKind = nil
    m_cachedPressLockName = nil
    if m_preferFriendlyTarget ~= true or m_enabled ~= true then
        return
    end
    local selfKey = SelfNameKey()
    if IsTargetingSelf(selfKey) then
        m_cachedPressLockKind = "clear"
        return
    end
    local name = GetFriendlyPlayerAssistName(selfKey)
    if name ~= nil then
        m_cachedPressLockKind = "lock"
        m_cachedPressLockName = name
    end
end

local function ScheduleMacroWrite(assistName)
    m_pendingMacroWrite = true
    m_pendingMacroWriteName = assistName
    m_flushMacroWrite = false
end

local function FlushPendingMacroWrite()
    if m_flushMacroWrite then
        m_flushMacroWrite = false
        local name = m_pendingMacroWriteName
        m_pendingMacroWrite = false
        m_pendingMacroWriteName = nil
        -- clearOnHostile applies to friendly lock too: keep lock, blank the hotbar.
        if name ~= nil and m_clearOnHostile and HasHostilePlayerTarget() then
            m_assistSuppressed = true
            SetLastAssistName(nil)
            WriteMacro(nil)
            UpdateMacroGlow()
            return
        end
        WriteMacro(name)
        SetLastAssistName(name)
        if name ~= nil and name ~= L"" then
            SetGlowAckName(nil) -- new lock counts as a new assist until pressed
        else
            SetGlowAckName(nil)
        end
        UpdateMacroGlow()
        return
    end
    if m_pendingMacroWrite then
        -- One-frame delay after the press OnUpdate that armed the write.
        m_flushMacroWrite = true
    end
end

local function NoteAlive(alive, name, healthValue)
    local key = NormalizeNameKey(name)
    if key == nil then
        return nil
    end
    local hp = tonumber(healthValue) or 0
    if hp > 0 and hp < 1 then
        hp = 0
    end
    alive[key] = hp > 0
    return key
end

local function ClearRosterKeys()
    for key in pairs(m_rosterKeys) do
        m_rosterKeys[key] = nil
    end
end

--- Returns map nameKey -> isAlive. Empty map means "no HP data yet".
local function BuildAliveByKey()
    local alive = {}
    ClearRosterKeys()

    if IsScenarioContext()
        and type(GameData) == "table"
        and type(GameData.GetScenarioPlayerGroups) == "function"
    then
        local ok, groups = pcall(GameData.GetScenarioPlayerGroups)
        if ok and type(groups) == "table" then
            for _, player in ipairs(groups) do
                if type(player) == "table" and player.name ~= nil then
                    local hp = player.health
                    if hp == nil then
                        hp = player.healthPercent
                    end
                    NoteAlive(alive, player.name, hp)
                end
            end
        end
    end

    if type(IsWarBandActive) == "function" and IsWarBandActive() then
        local parties = nil
        if type(GetBattlegroupMemberData) == "function" then
            parties = GetBattlegroupMemberData()
        end
        if type(parties) == "table" then
            for p = 1, #parties do
                local party = parties[p]
                local players = party and party.players
                if type(players) == "table" then
                    for m = 1, #players do
                        local member = players[m]
                        -- PartyUtils.GetWarbandMember crashes on empty slots (nil member).
                        if type(member) == "table" and member.name ~= nil then
                            if type(PartyUtils) == "table" and type(PartyUtils.GetWarbandMember) == "function" then
                                local okHydrate, hydrated = pcall(PartyUtils.GetWarbandMember, p, m)
                                if okHydrate and type(hydrated) == "table" then
                                    member = hydrated
                                end
                            end
                            if type(member) == "table" and member.name ~= nil then
                                local key = NoteAlive(alive, member.name, member.healthPercent or member.health)
                                if key ~= nil then
                                    m_rosterKeys[key] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    elseif type(PartyUtils) == "table" and type(PartyUtils.IsPartyActive) == "function" and PartyUtils.IsPartyActive() then
        local data = nil
        if type(PartyUtils.GetPartyData) == "function" then
            data = PartyUtils.GetPartyData()
        elseif type(GetGroupData) == "function" then
            data = GetGroupData()
        end
        if type(data) == "table" then
            local maxMembers = tonumber(PartyUtils.PLAYERS_PER_PARTY) or 6
            for m = 1, maxMembers do
                local member = nil
                if type(PartyUtils.GetPartyMember) == "function" then
                    member = PartyUtils.GetPartyMember(m)
                else
                    member = data[m]
                end
                if type(member) == "table" and member.name ~= nil then
                    local key = NoteAlive(alive, member.name, member.healthPercent or member.health)
                    if key ~= nil then
                        m_rosterKeys[key] = true
                    end
                end
            end
        end
    end

    return alive
end

--- Nil when the party/warband roster is empty (not ready, or not in a group).
local function RosterContainsKey(key)
    if key == nil or next(m_rosterKeys) == nil then
        return nil
    end
    return m_rosterKeys[key] == true
end

--- Remember a locked ally once a non-empty roster lists them.
local function NoteFriendlyLockOnRoster()
    if m_friendlyAssistLock == nil then
        m_friendlyLockSeenOnRoster = false
        return
    end
    if RosterContainsKey(NormalizeNameKey(m_friendlyAssistLock)) == true then
        m_friendlyLockSeenOnRoster = true
    end
end

--- Clear a lock only after that ally was on the roster and a later non-empty
--- roster no longer lists them. An empty roster is not a departure.
local function ClearFriendlyLockIfDeparted()
    if m_friendlyAssistLock == nil or not m_friendlyLockSeenOnRoster then
        return false
    end
    if RosterContainsKey(NormalizeNameKey(m_friendlyAssistLock)) ~= false then
        return false
    end
    ClearFriendlyAssistLock()
    PrintFriendlyUnlock()
    return true
end

local function IsCandidateAlive(key, aliveByKey)
    if key == nil then
        return false
    end
    -- No roster HP yet: do not filter everyone out (scoreboard often arrives first).
    if next(aliveByKey) == nil then
        return true
    end
    local flag = aliveByKey[key]
    if flag == nil then
        -- On scoreboard but missing from groups: allow until proven dead.
        return true
    end
    return flag == true
end

--- Known distance must be within range; unknown distance is allowed (map pips are flaky).
local function IsWithinRange(dist, range)
    if dist == nil then
        return true
    end
    return dist <= range
end

local function AdvanceScanCursor()
    m_scanCursor = m_scanCursor + 1
    m_sweptPoints = m_sweptPoints + 1
    if not m_sweepReady and m_sweptPoints >= c_MAX_MAP_POINTS then
        m_sweepReady = true
        m_sweepId = m_sweepId + 1
        m_picksSinceSweep = 0
    end
    if m_scanCursor > c_MAX_MAP_POINTS then
        m_scanCursor = 1
        return true
    end
    return false
end

local function RememberMapMiss(nameKey)
    m_distCache[nameKey] = { miss = true, sweep = m_sweepId }
end

--- Distance in map units, or nil when the pip is unknown.
--- One 64-point walk per assist pick. After a full pass, names that were not
--- on the map are remembered so later candidates do not walk again until the
--- next sweep. Unknown distance still counts as in range.
local function LookupMapDistance(nameKey, rawName)
    if nameKey == nil or type(GetMapPointData) ~= "function" then
        return nil
    end
    if not DoesWindowExist(c_MAP_WINDOW) then
        return nil
    end

    local cache = m_distCache[nameKey]
    if cache ~= nil and cache.index ~= nil then
        local mpd = GetMapPointData(c_MAP_WINDOW, cache.index)
        if mpd
            and mpd.name
            and mpd.pointType
            and c_MAP_POINT_TYPE_FILTER[mpd.pointType]
            and NormalizeNameKey(mpd.name) == nameKey
        then
            local dist = math.floor((tonumber(mpd.distance) or 0) * c_DISTANCE_FIX)
            cache.distance = dist
            cache.rawName = mpd.name
            return dist
        end
        m_distCache[nameKey] = nil
        -- That pip moved. The completed sweep no longer covers the map.
        m_sweepReady = false
        m_sweptPoints = 0
        m_picksSinceSweep = 0
    elseif cache ~= nil and cache.miss == true and cache.sweep == m_sweepId and m_sweepReady then
        return nil
    end

    if m_sweepReady then
        RememberMapMiss(nameKey)
        return nil
    end

    if m_walkedThisPick then
        local found = m_distCache[nameKey]
        if found ~= nil and found.index ~= nil then
            return found.distance
        end
        return nil
    end
    m_walkedThisPick = true

    -- Budgeted walk from cursor. Every name we pass is cached, not only the one
    -- we were asked for.
    local scanned = 0
    local budget = 64
    while scanned < budget do
        local mpd = GetMapPointData(c_MAP_WINDOW, m_scanCursor)
        local foundDist = nil
        if mpd and mpd.name and mpd.pointType and c_MAP_POINT_TYPE_FILTER[mpd.pointType] then
            local key = NormalizeNameKey(mpd.name)
            if key ~= nil then
                local dist = math.floor((tonumber(mpd.distance) or 0) * c_DISTANCE_FIX)
                m_distCache[key] = { index = m_scanCursor, rawName = mpd.name, distance = dist }
                if key == nameKey then
                    foundDist = dist
                end
            end
        end
        local wrapped = AdvanceScanCursor()
        if foundDist ~= nil then
            return foundDist
        end
        if wrapped then
            break
        end
        scanned = scanned + 1
    end
    if m_sweepReady then
        RememberMapMiss(nameKey)
    end
    return nil
end

local function GetMacrosTable()
    if type(DataUtils) == "table" and type(DataUtils.GetMacros) == "function" then
        return DataUtils.GetMacros() or {}
    end
    if type(GetMacrosData) == "function" then
        return GetMacrosData() or {}
    end
    return {}
end

--- Stock chat career glyph from a GetScenarioPlayers() row (same as ScenarioSummaryWindow).
local function CareerIconMarkup(row)
    if type(row) ~= "table" or type(Icons) ~= "table" then
        return L""
    end
    local iconNum = nil
    local careerId = tonumber(row.careerId)
    if careerId ~= nil and careerId ~= 0 and type(Icons.GetCareerIconIDFromCareerNamesID) == "function" then
        iconNum = Icons.GetCareerIconIDFromCareerNamesID(careerId)
    end
    if (iconNum == nil or iconNum == 0)
        and tonumber(row.careerLine) ~= nil
        and tonumber(row.careerLine) ~= 0
        and type(Icons.GetCareerIconIDFromCareerLine) == "function"
    then
        iconNum = Icons.GetCareerIconIDFromCareerLine(tonumber(row.careerLine))
    end
    if iconNum == nil or iconNum == 0 then
        return L""
    end
    return L"<icon" .. towstring(iconNum) .. L"> "
end

local function FormatAssistNotifyDetail(picked)
    if type(picked) ~= "table" then
        return L""
    end
    local reason = picked.reason or "KillDamage"
    if reason == "FriendlyTarget" then
        return L"friendly target"
    end
    local kd = tonumber(picked.killDamage) or 0
    local db = tonumber(picked.deathBlows) or 0
    local td = tonumber(picked.totalDamage) or 0
    return towstring(reason)
        .. L" lead - KD "
        .. towstring(tostring(kd))
        .. L", DB "
        .. towstring(tostring(db))
        .. L", Dmg "
        .. towstring(tostring(td))
end

local function FormatAssistNotifyLine(assistName, picked)
    local icon = CareerIconMarkup(picked and picked.row)
    local detail = FormatAssistNotifyDetail(picked)
    -- Body only; EZAssist.Print already prefixes [EZAssist].
    if detail ~= nil and detail ~= L"" then
        return L"assisting " .. icon .. assistName .. L" (" .. detail .. L")"
    end
    return L"assisting " .. icon .. assistName
end

local function ClearSticky()
    m_stickyKey = nil
    m_stickyHoldLeft = 0
end

local function DetailFromRow(SS, key, row, reason)
    return {
        key = key,
        name = row and row.name or nil,
        row = row,
        killDamage = SS.RowKillDamage(row),
        deathBlows = SS.RowDeathBlows(row),
        totalDamage = SS.RowTotalDamage(row),
        reason = reason or "KillDamage",
    }
end

local function ClearPlayerRowIndex()
    for key in pairs(m_playerRowByKey) do
        m_playerRowByKey[key] = nil
    end
end

--- One scoreboard snapshot per assist pick. PickBestAssistCandidate indexes it.
local function FetchScenarioPlayerList()
    if type(GameData) ~= "table" or type(GameData.GetScenarioPlayers) ~= "function" then
        return nil
    end
    local ok, list = pcall(GameData.GetScenarioPlayers)
    if not ok or type(list) ~= "table" then
        return nil
    end
    return list
end

local function StickyStillEligible(SS, key, row, aliveByKey, range)
    if key == nil or type(row) ~= "table" or SS == nil then
        return false
    end
    if type(SS.RowHasAssistCombatData) == "function" and not SS.RowHasAssistCombatData(row) then
        return false
    end
    -- Only drop when groups explicitly mark them dead (unknown = keep).
    if aliveByKey[key] == false then
        return false
    end
    local dist = LookupMapDistance(key, row.name)
    local stickyRange = (tonumber(range) or SmartAssist.DEFAULT_RANGE) * c_STICKY_RANGE_MULT
    if dist ~= nil and dist > stickyRange then
        return false
    end
    return true
end

local function ChallengerStealsSticky(SS, challengerRow, stickyRow)
    if type(challengerRow) ~= "table" or type(stickyRow) ~= "table" or SS == nil then
        return false
    end
    local akd = SS.RowKillDamage(challengerRow)
    local bkd = SS.RowKillDamage(stickyRow)
    if bkd <= 0 then
        return akd > 0
    end
    return akd > (bkd * c_HYSTERESIS_KD)
end

local function CommitSticky(key, hold)
    m_stickyKey = key
    if hold then
        m_stickyHoldLeft = c_SWITCH_HOLD_SEC
    end
end

--- Returns assist display name (wstring) or nil; second return is pick detail table.
--- Locked friendly assist (macro press) overrides KD -> DB -> TD until cleared (self + press).
--- No ranked pick until someone has real KD/DB/damage. Sticky + hysteresis dampens flicker.
--- opts.dryRun = true: rank only; do not mutate sticky/hold state (for DebugStatus).
function SmartAssist.PickAssistTarget(opts)
    opts = opts or {}
    local dryRun = opts.dryRun == true
    local settings = SmartAssist.EnsureSettings()
    local range = tonumber(settings.range) or SmartAssist.DEFAULT_RANGE
    local selfKey = SelfNameKey()

    -- Locked friendly assist: set by pressing the macro while targeting an ally player.
    if m_preferFriendlyTarget and m_friendlyAssistLock ~= nil then
        if not dryRun then
            ClearSticky()
        end
        return m_friendlyAssistLock, {
            key = NormalizeNameKey(m_friendlyAssistLock),
            name = m_friendlyAssistLock,
            reason = "FriendlyTarget",
        }
    end

    local realm = SelfRealm()
    local SS = AssistStats()
    if realm == nil or SS == nil or type(SS.PickBestAssistCandidate) ~= "function" then
        return nil
    end

    m_walkedThisPick = false
    if m_sweepReady then
        m_picksSinceSweep = m_picksSinceSweep + 1
        if m_picksSinceSweep >= c_SWEEP_RESCAN_PICKS then
            m_sweepReady = false
            m_sweptPoints = 0
            m_picksSinceSweep = 0
        end
    end

    local aliveByKey = BuildAliveByKey()
    local groupStats = GroupStats()
    if groupStats ~= nil and type(groupStats.PruneToRoster) == "function" then
        groupStats.PruneToRoster(m_rosterKeys)
    end
    ClearPlayerRowIndex()
    local best = nil
    local accept = function(key, row)
        if not IsCandidateAlive(key, aliveByKey) then
            return false
        end
        local dist = LookupMapDistance(key, row.name)
        return IsWithinRange(dist, range)
    end

    if IsScenarioContext() then
        local playerList = FetchScenarioPlayerList()
        if playerList ~= nil then
            best = SS.PickBestAssistCandidate({
                realm = realm,
                normalizeNameKey = NormalizeNameKey,
                excludeKey = selfKey,
                requireCombatData = true,
                players = playerList,
                rowByKey = m_playerRowByKey,
                accept = accept,
            })
        end
    else
        best = SS.PickBestAssistCandidate({
            realm = realm,
            normalizeNameKey = NormalizeNameKey,
            excludeKey = selfKey,
            requireCombatData = true,
            accept = accept,
        })
    end

    local stickyKey = m_stickyKey
    if stickyKey == selfKey then
        stickyKey = nil
        if not dryRun then
            ClearSticky()
        end
    end

    local stickyRow = nil
    if stickyKey ~= nil then
        if type(SS.GetRowByKey) == "function" then
            stickyRow = SS.GetRowByKey(stickyKey)
        else
            stickyRow = m_playerRowByKey[stickyKey]
        end
    end
    local stickyOk = stickyRow ~= nil and StickyStillEligible(SS, stickyKey, stickyRow, aliveByKey, range)

    if stickyOk then
        local bestIsOther = best ~= nil and best.key ~= nil and best.key ~= stickyKey
        local maySwitch = m_stickyHoldLeft <= 0
            and bestIsOther
            and ChallengerStealsSticky(SS, best.row, stickyRow)
        if maySwitch then
            if not dryRun then
                CommitSticky(best.key, true)
            end
            return StripForAssist(best.row.name), best
        end
        local held = DetailFromRow(SS, stickyKey, stickyRow, "held")
        return StripForAssist(stickyRow.name), held
    end

    -- Sticky gone/dead/out of slack range: take best, or clear.
    if best ~= nil and best.row ~= nil then
        if not dryRun then
            CommitSticky(best.key, true)
        end
        return StripForAssist(best.row.name), best
    end

    if not dryRun then
        ClearSticky()
    end
    return nil
end

local c_MACRO_NAME_PREFIX = towstring(SmartAssist.MACRO_NAME)
local c_MACRO_NAME_OPEN = c_MACRO_NAME_PREFIX .. L" ("
local c_MACRO_NAME_OPEN_LEN = string.len(SmartAssist.MACRO_NAME .. " (")

--- True for "EZAssist" or "EZAssist (<player>)".
local function IsOwnedMacroName(name)
    if name == nil or name == L"" then
        return false
    end
    if name == c_MACRO_NAME_PREFIX then
        return true
    end
    if type(wstring) == "table" and type(wstring.sub) == "function" then
        return wstring.sub(name, 1, c_MACRO_NAME_OPEN_LEN) == c_MACRO_NAME_OPEN
    end
    local asString
    if type(name) == "wstring" then
        asString = WStringToNarrow(name)
    else
        asString = tostring(name)
    end
    return type(asString) == "string"
        and string.sub(asString, 1, c_MACRO_NAME_OPEN_LEN) == (SmartAssist.MACRO_NAME .. " (")
end

local function FormatMacroDisplayName(assistName)
    if assistName == nil or assistName == L"" then
        return c_MACRO_NAME_PREFIX
    end
    return c_MACRO_NAME_PREFIX .. L" (" .. assistName .. L")"
end

local function FindOwnedMacroSlot(macros)
    macros = macros or GetMacrosTable()
    for i = 1, #macros do
        if macros[i] and IsOwnedMacroName(macros[i].name) then
            return i
        end
    end
    return nil
end

local function FindEmptyMacroSlot(macros)
    macros = macros or GetMacrosTable()
    for i = 1, #macros do
        local row = macros[i]
        if row
            and (row.iconNum == 0 or row.iconNum == nil)
            and (row.text == nil or row.text == L"")
            and (row.name == nil or row.name == L"")
        then
            return i
        end
    end
    return nil
end

local function MacroListHasRoom(macros)
    if type(macros) ~= "table" then
        return false
    end
    return FindOwnedMacroSlot(macros) ~= nil or FindEmptyMacroSlot(macros) ~= nil
end

local function MacroRowIsEmpty(row)
    if type(row) ~= "table" then
        return false
    end
    return (row.iconNum == 0 or row.iconNum == nil)
        and (row.text == nil or row.text == L"")
        and (row.name == nil or row.name == L"")
end

--- Safe to write: the slot is blank, or it already holds the EZAssist macro.
local function MacroSlotOwnedOrEmpty(macros, slot)
    if type(macros) ~= "table" or type(slot) ~= "number" then
        return false
    end
    local row = macros[slot]
    if MacroRowIsEmpty(row) then
        return true
    end
    -- A cached index past a short or empty list is not a blank slot.
    return type(row) == "table" and IsOwnedMacroName(row.name)
end

local function MacroSlotIsOwned(macros, slot)
    return type(macros) == "table"
        and type(slot) == "number"
        and type(macros[slot]) == "table"
        and IsOwnedMacroName(macros[slot].name)
end

--- Diagnostic snapshot for /script or RoRMCP (read-only; does not mutate sticky).
function SmartAssist.DebugStatus()
    local settings = SmartAssist.EnsureSettings()
    local macros = GetMacrosTable()
    local slot = FindOwnedMacroSlot()
    local row = slot and macros[slot]
    local aliveByKey = BuildAliveByKey()
    local aliveCount = 0
    for _ in pairs(aliveByKey) do
        aliveCount = aliveCount + 1
    end
    local nPlayers = 0
    local ok, list = pcall(function()
        return GameData.GetScenarioPlayers()
    end)
    if ok and type(list) == "table" then
        nPlayers = #list
    end
    local pick, picked = SmartAssist.PickAssistTarget({ dryRun = true })
    local SS, statsSource = AssistStats()
    local GS = GroupStats()
    local groupCount = 0
    if GS ~= nil and type(GS.Count) == "function" then
        groupCount = GS.Count() or 0
    end
    return {
        enabled = settings.enabled == true,
        range = settings.range,
        notify = settings.notify == true,
        clearOnHostile = settings.clearOnHostile == true,
        glowOnNewAssist = settings.glowOnNewAssist ~= false,
        preferFriendlyTarget = settings.preferFriendlyTarget ~= false,
        inScenario = IsScenarioContext(),
        inPartyOrWarband = IsPartyOrWarband(),
        assistContext = IsAssistContext(),
        statsSource = statsSource,
        groupStatsCount = groupCount,
        realm = SelfRealm(),
        macroSlot = slot,
        macroIcon = row and row.iconNum or nil,
        hasAssistText = row ~= nil and row.text ~= nil and row.text ~= L"",
        nPlayers = nPlayers,
        aliveKeys = aliveCount,
        pick = pick,
        pickReason = picked and picked.reason or nil,
        pickKd = picked and picked.killDamage or nil,
        pickDb = picked and picked.deathBlows or nil,
        pickDmg = picked and picked.totalDamage or nil,
        stickyKey = m_stickyKey,
        stickyHoldLeft = m_stickyHoldLeft,
        hasHostileTarget = HasHostileTarget(),
        friendlyAssistLock = m_friendlyAssistLock,
        friendlyTargetPlayer = GetFriendlyPlayerAssistName(SelfNameKey()),
        streaming = SS and SS.IsStreaming and SS.IsStreaming() or false,
        statsHeld = m_statsHeld == true,
    }
end

local function ForEachMacroActionButton(macroSlot, fn)
    if not macroSlot or type(fn) ~= "function" then
        return
    end
    if type(ActionBars) ~= "table" or type(ActionBars.m_Bars) ~= "table" then
        return
    end
    local doMacro = GameData and GameData.PlayerActions and GameData.PlayerActions.DO_MACRO
    for i = 1, #ActionBars.m_Bars do
        local bar = ActionBars.m_Bars[i]
        for j = 1, #(bar.m_Buttons or {}) do
            local button = bar.m_Buttons[j]
            if button
                and button.m_ActionType == doMacro
                and button.m_ActionId == macroSlot
            then
                fn(button)
            end
        end
    end
end

--- Manual friendly lock -> Order gold (fury). Auto KD -> Destruction green (waaagh).
local function GlowTextureBase()
    if FriendlyAssistLocked() then
        return "anim_fury_"
    end
    return "anim_waaagh_"
end

--- EZGuard-style ActionButton burn glow (m_Windows[6]).
local function SetButtonGlow(button, glowLevel)
    if not button or type(button.m_Windows) ~= "table" then
        return
    end
    local glowFrame = button.m_Windows[c_GLOW_ANIM]
    if glowFrame == nil then
        return
    end
    if glowLevel and glowLevel > 0 then
        if type(glowFrame.StopAnimation) == "function" then
            glowFrame:StopAnimation(true)
        end
        if type(glowFrame.SetAnimationTexture) == "function" then
            glowFrame:SetAnimationTexture(GlowTextureBase() .. tostring(glowLevel))
        end
        if type(glowFrame.StartAnimation) == "function" then
            glowFrame:StartAnimation(0, true, false, 0)
        end
        if type(glowFrame.Show) == "function" then
            glowFrame:Show(true)
        end
    else
        if type(glowFrame.StopAnimation) == "function" then
            glowFrame:StopAnimation(true)
        end
        if type(glowFrame.Show) == "function" then
            glowFrame:Show(false)
        end
    end
end

local function SetMacroGlowLevel(level)
    level = tonumber(level) or 0
    if m_glowEnabled ~= true then
        level = 0
    end
    if level < 0 then
        level = 0
    elseif level > c_GLOW_NEW_TARGET then
        level = c_GLOW_NEW_TARGET
    end
    local slot = m_macroSlot
    if slot == nil then
        m_glowOn = false
        return
    end
    m_glowOn = level > 0
    ForEachMacroActionButton(slot, function(button)
        SetButtonGlow(button, level)
    end)
end

--- 0 = empty, 1 = has assist (acked), max = new assist not yet pressed.
UpdateMacroGlow = function()
    local key = m_lastAssistKey
    if key == nil or m_lastAssistName == nil or m_lastAssistName == L"" then
        SetMacroGlowLevel(0)
        return
    end
    if m_glowAckKey ~= nil and m_glowAckKey == key then
        SetMacroGlowLevel(c_GLOW_HAS_TARGET)
    else
        SetMacroGlowLevel(c_GLOW_NEW_TARGET)
    end
end

local function SetMacroGlow(want)
    -- Back-compat for clear paths: false clears; true means "new target" max.
    if want == true then
        SetMacroGlowLevel(c_GLOW_NEW_TARGET)
    else
        SetMacroGlowLevel(0)
    end
end

--- Thin click wrapper: flag only + tail-call stock handler. No glow/WriteMacro here.
local function InstallGlowPressHook()
    if m_glowHookInstalled and m_glowActionButtonWrapper ~= nil and m_stockActionButtonOnLButtonUp ~= nil then
        return
    end
    if type(ActionButton) ~= "table" or type(ActionButton.OnLButtonUp) ~= "function" then
        return
    end
    m_stockActionButtonOnLButtonUp = ActionButton.OnLButtonUp
    m_glowActionButtonWrapper = function(self, flags, x, y)
        local nextFn = m_stockActionButtonOnLButtonUp
        local slot = m_macroSlot
        local doMacro = GameData and GameData.PlayerActions and GameData.PlayerActions.DO_MACRO
        -- Field reads + assigns only. No TargetInfo / SetMacroData here - that drops /assist.
        if self
            and doMacro ~= nil
            and self.m_ActionType == doMacro
            and (Cursor == nil or Cursor.Data == nil)
            and (slot == nil or self.m_ActionId == slot)
        then
            m_pressActionId = self.m_ActionId
            m_glowClearPending = true
            m_macroPressPending = true
            m_pressLockKind = m_cachedPressLockKind
            m_pressLockName = m_cachedPressLockName
        end
        if nextFn then
            return nextFn(self, flags, x, y)
        end
    end
    ActionButton.OnLButtonUp = m_glowActionButtonWrapper
    m_glowHookInstalled = true
end

local function UninstallGlowPressHook()
    if not m_glowHookInstalled then
        return
    end
    if type(ActionButton) == "table"
        and ActionButton.OnLButtonUp == m_glowActionButtonWrapper
        and m_stockActionButtonOnLButtonUp ~= nil
    then
        ActionButton.OnLButtonUp = m_stockActionButtonOnLButtonUp
        m_glowActionButtonWrapper = nil
        m_stockActionButtonOnLButtonUp = nil
    end
    m_glowHookInstalled = false
    m_glowClearPending = false
    m_macroPressPending = false
    m_pressActionId = nil
    m_pressLockKind = nil
    m_pressLockName = nil
    m_pendingMacroWrite = false
    m_flushMacroWrite = false
    m_pendingMacroWriteName = nil
end

local function SyncGlowPressHook()
    -- Press hook: friendly lock (always) + optional glow clear.
    if m_enabled == true and m_handlersRegistered then
        InstallGlowPressHook()
    else
        -- Do not SetMacroGlow here (ActionBars walk during disable can freeze).
        m_glowOn = false
        UninstallGlowPressHook()
    end
end

--- Deferred macro-press work: friendly lock/unlock + glow ack (safe after /assist).
local function ApplyPendingMacroPress()
    if m_macroPressPending then
        m_macroPressPending = false
        local pressId = m_pressActionId
        local lockKind = m_pressLockKind
        local lockName = m_pressLockName
        m_pressActionId = nil
        m_pressLockKind = nil
        m_pressLockName = nil
        if m_macroSlot == nil then
            m_macroSlot = FindOwnedMacroSlot()
        end
        local ourPress = m_macroSlot ~= nil and pressId == m_macroSlot
        if ourPress and m_preferFriendlyTarget == true and m_enabled == true then
            if lockKind == "clear" then
                if m_friendlyAssistLock ~= nil then
                    ClearFriendlyAssistLock()
                    PrintFriendlyUnlock()
                    m_assistSuppressed = false
                    -- Defer SetMacroData - same-frame WriteMacro races WindowGameAction /assist.
                    ScheduleMacroWrite(nil)
                    m_dirty = true
                    m_refreshNow = true
                end
            elseif lockKind == "lock" and lockName ~= nil then
                local newKey = NormalizeNameKey(lockName)
                local oldKey = NormalizeNameKey(m_friendlyAssistLock)
                if newKey ~= oldKey then
                    m_friendlyAssistLock = lockName
                    m_friendlyLockSeenOnRoster = false
                    BuildAliveByKey()
                    NoteFriendlyLockOnRoster()
                    PrintFriendlyLock(lockName)
                    m_assistSuppressed = false
                    ScheduleMacroWrite(lockName)
                    m_lastNotifyKey = newKey
                    -- Do not refreshNow: RefreshAssist WriteMacro same frame would also race /assist.
                end
            end
        elseif not ourPress then
            -- Not our macro: do not clear glow for someone else's press.
            m_glowClearPending = false
        end
    end
    if not m_glowClearPending then
        return
    end
    m_glowClearPending = false
    AckGlowForLastAssist()
    UpdateMacroGlow()
end

-- Re-entrancy lock: SetMacroData raises MACRO_UPDATED / MACROS_LOADED (SwiftAssist etc.).
local m_inMacroMutate = false

local function WarnMacroSlotsFull(macros)
    if type(macros) == "table" and #macros > 0 and not m_fullSlotsWarned then
        EZAssist.Print(L"EZAssist: all macro slots are full.")
        m_fullSlotsWarned = true
    end
end

-- Assigned (not local function) so early ScheduleMacroWrite / SoftDisable can call it.
WriteMacro = function(assistName)
    if m_inMacroMutate or type(SetMacroData) ~= "function" then
        return false
    end
    -- Tooltip shows the macro name; include the assist target when set.
    local name = FormatMacroDisplayName(assistName)
    local text = L""
    local icon = SmartAssist.ICON_ACTIVE
    if assistName ~= nil and assistName ~= L"" then
        text = L"/assist " .. assistName
    end

    -- Confirm the cached slot is still ours (or empty) before writing.
    -- A player macro saved into that index must send us looking again.
    local macros = GetMacrosTable()
    local slot = m_macroSlot
    if slot ~= nil and not MacroSlotOwnedOrEmpty(macros, slot) then
        m_macroSlot = nil
        slot = nil
    end
    if slot == nil then
        slot = FindOwnedMacroSlot(macros)
        if slot == nil then
            slot = FindEmptyMacroSlot(macros)
        end
    end

    local confirm = macros
    local dataUtilsMacros = type(DataUtils) == "table" and type(DataUtils.GetMacros) == "function"
    if type(GetMacrosData) == "function" and dataUtilsMacros then
        local alt = GetMacrosData()
        if type(alt) == "table" then
            confirm = alt
            if slot ~= nil and not MacroSlotOwnedOrEmpty(alt, slot) then
                m_macroSlot = nil
                slot = FindOwnedMacroSlot(alt)
                if slot == nil then
                    slot = FindEmptyMacroSlot(alt)
                end
            end
        end
    end
    macros = macros or {}
    confirm = confirm or macros

    if slot == nil
        or not MacroSlotOwnedOrEmpty(macros, slot)
        or not MacroSlotOwnedOrEmpty(confirm, slot)
    then
        -- A mismatch is not "every slot is full" when either list still has room.
        local sameList = confirm == macros
        if sameList or (not MacroListHasRoom(macros) and not MacroListHasRoom(confirm)) then
            WarnMacroSlotsFull(confirm)
        end
        m_macroSlot = nil
        return false
    end
    m_macroSlot = slot
    m_fullSlotsWarned = false

    local row = confirm[slot]
    if row and row.name == name and row.text == text and tonumber(row.iconNum) == icon then
        return true
    end

    m_inMacroMutate = true
    pcall(SetMacroData, name, text, icon, slot)
    m_inMacroMutate = false
    return true
end

--- Soft-disable cleanup. Keep the EZAssist macro slot (empty /assist text).
--- Hard SetMacroData("",...,0) + recreate on enable freezes with SwiftAssist on MACROS_LOADED.
--- Ownership checks in WriteMacro still refuse to overwrite a foreign slot.
local function SoftDisableMacroState()
    m_macroSlot = FindOwnedMacroSlot() or m_macroSlot
    WriteMacro(nil)
    SetLastAssistName(nil)
    m_lastNotifyKey = nil
    ClearFriendlyAssistLock()
    SetGlowAckName(nil)
    UpdateMacroGlow()
    m_glowClearPending = false
    m_macroPressPending = false
    m_pressActionId = nil
    m_pressLockKind = nil
    m_pressLockName = nil
    m_pendingMacroWrite = false
    m_flushMacroWrite = false
    m_pendingMacroWriteName = nil
end

local function HoldStatsStream(want)
    want = want == true
    if want == m_statsHeld then
        if want then
            local SS = ScenarioStats()
            if SS and type(SS.Start) == "function" then
                SS.Start()
            end
        end
        return
    end
    local SS = ScenarioStats()
    if want then
        if SS and type(SS.Acquire) == "function" then
            SS.Acquire()
        elseif SS and type(SS.Start) == "function" then
            SS.Start()
        end
        m_statsHeld = true
    else
        if SS and type(SS.Release) == "function" then
            SS.Release()
        elseif SS and type(SS.Stop) == "function" then
            SS.Stop()
        end
        m_statsHeld = false
    end
end

local function SuppressAssistForHostile()
    m_assistSuppressed = true
    ClearSticky()
    SetLastAssistName(nil)
    SetGlowAckName(nil)
    m_glowClearPending = false
    WriteMacro(nil)
    UpdateMacroGlow()
end

local function ClearAssistOutsideContext()
    m_inAssistWork = false
    m_assistSuppressed = false
    m_targetDirty = false
    m_dirty = false
    m_updateElapsed = 0
    HoldStatsStream(false)
    ClearSticky()
    SetLastAssistName(nil)
    m_lastNotifyKey = nil
    ClearFriendlyAssistLock()
    SetGlowAckName(nil)
    m_glowClearPending = false
    m_macroPressPending = false
    m_pressActionId = nil
    m_pressLockKind = nil
    m_pressLockName = nil
    m_pendingMacroWrite = false
    m_flushMacroWrite = false
    m_pendingMacroWriteName = nil
    WriteMacro(nil)
    UpdateMacroGlow()
    local GS = GroupStats()
    if GS ~= nil and type(GS.Clear) == "function" and not IsPartyOrWarband() then
        GS.Clear()
    end
end

local function EnsureGroupStatsListening()
    local GS = GroupStats()
    if GS == nil then
        return
    end
    if type(GS.IsListening) == "function" and GS.IsListening() then
        -- Hook stays installed. Warm-start only while our cache is still empty.
        if type(GS.TryBootstrap) == "function" and type(GS.Count) == "function" and GS.Count() == 0 then
            GS.TryBootstrap()
        end
        return
    end
    if type(GS.Initialize) == "function" then
        GS.Initialize()
    end
end

local function MarkAssistDirty()
    m_dirty = true
end

local function MarkAssistDirtyNow()
    m_dirty = true
    m_refreshNow = true
end

local function RefreshAssist()
    if m_enabled ~= true then
        return
    end

    if not IsAssistContext() then
        ClearAssistOutsideContext()
        return
    end

    m_inAssistWork = true
    EnsureGroupStatsListening()
    -- Scenario scoreboard stream only; party/warband uses GRP_STATS packets.
    HoldStatsStream(IsScenarioContext())
    if IsScenarioContext() and not IsPartyOrWarband() then
        local GS = GroupStats()
        if GS ~= nil and type(GS.Clear) == "function" then
            GS.Clear()
        end
    end

    -- Optional: never set (and always clear) assist while you have a living hostile.
    -- Friendly lock is kept in memory; only the hotbar /assist text is cleared.
    if m_clearOnHostile and HasHostilePlayerTarget() then
        SuppressAssistForHostile()
        return
    end

    m_assistSuppressed = false
    local assistName, picked = SmartAssist.PickAssistTarget()
    local newKey = NormalizeNameKey(assistName)
    -- Key compare uses the cached key. Raw wstring ~= can fire every tick for the same player.
    local changed = newKey ~= m_lastAssistKey

    -- Skip SetMacroData while a post-press write is armed (avoids racing /assist).
    if not m_pendingMacroWrite and not m_flushMacroWrite then
        WriteMacro(assistName)
    end
    SetLastAssistName(assistName)

    if assistName ~= nil and assistName ~= L"" and newKey ~= nil then
        if changed then
            SetGlowAckName(nil)
        end
        UpdateMacroGlow()
        -- Notify once per player until a different ally is picked (hostile clear does not re-spam).
        if m_notify == true and newKey ~= m_lastNotifyKey then
            EZAssist.Print(FormatAssistNotifyLine(assistName, picked))
            m_lastNotifyKey = newKey
        end
    else
        SetGlowAckName(nil)
        UpdateMacroGlow()
    end
end

local function SafeUnregister(event, handlerName)
    if event == nil or handlerName == nil then
        return
    end
    pcall(UnregisterEventHandler, event, handlerName)
end

local function UnregisterHandlers()
    local E = SystemData and SystemData.Events
    if E then
        SafeUnregister(E.SCENARIO_PLAYERS_LIST_STATS_UPDATED, "EZAssist.OnScenarioStatsUpdated")
        SafeUnregister(E.SCENARIO_BEGIN, "EZAssist.OnScenarioBegin")
        SafeUnregister(E.SCENARIO_END, "EZAssist.OnScenarioEnd")
        SafeUnregister(E.LOADING_END, "EZAssist.OnLoadingEnd")
        SafeUnregister(E.MACROS_LOADED, "EZAssist.OnMacrosLoaded")
        SafeUnregister(E.PLAYER_TARGET_UPDATED, "EZAssist.OnPlayerTargetUpdated")
        SafeUnregister(E.GROUP_UPDATED, "EZAssist.OnGroupUpdated")
        SafeUnregister(E.BATTLEGROUP_UPDATED, "EZAssist.OnGroupUpdated")
        SafeUnregister(E.GROUP_STATUS_UPDATED, "EZAssist.OnGroupUpdated")
        SafeUnregister(E.BATTLEGROUP_MEMBER_UPDATED, "EZAssist.OnGroupUpdated")
    end
    m_handlersRegistered = false
    m_glowOn = false
    UninstallGlowPressHook()
end

local function RegisterHandlers()
    -- Always unregister first so re-enable never stacks duplicate handlers.
    UnregisterHandlers()
    local E = SystemData and SystemData.Events
    if not E then
        return
    end
    if E.SCENARIO_PLAYERS_LIST_STATS_UPDATED then
        RegisterEventHandler(E.SCENARIO_PLAYERS_LIST_STATS_UPDATED, "EZAssist.OnScenarioStatsUpdated")
    end
    if E.SCENARIO_BEGIN then
        RegisterEventHandler(E.SCENARIO_BEGIN, "EZAssist.OnScenarioBegin")
    end
    if E.SCENARIO_END then
        RegisterEventHandler(E.SCENARIO_END, "EZAssist.OnScenarioEnd")
    end
    if E.LOADING_END then
        RegisterEventHandler(E.LOADING_END, "EZAssist.OnLoadingEnd")
    end
    if E.MACROS_LOADED then
        RegisterEventHandler(E.MACROS_LOADED, "EZAssist.OnMacrosLoaded")
    end
    if E.PLAYER_TARGET_UPDATED then
        RegisterEventHandler(E.PLAYER_TARGET_UPDATED, "EZAssist.OnPlayerTargetUpdated")
    end
    if E.GROUP_UPDATED then
        RegisterEventHandler(E.GROUP_UPDATED, "EZAssist.OnGroupUpdated")
    end
    if E.BATTLEGROUP_UPDATED then
        RegisterEventHandler(E.BATTLEGROUP_UPDATED, "EZAssist.OnGroupUpdated")
    end
    if E.GROUP_STATUS_UPDATED then
        RegisterEventHandler(E.GROUP_STATUS_UPDATED, "EZAssist.OnGroupUpdated")
    end
    if E.BATTLEGROUP_MEMBER_UPDATED then
        RegisterEventHandler(E.BATTLEGROUP_MEMBER_UPDATED, "EZAssist.OnGroupUpdated")
    end
    m_handlersRegistered = true
    -- Install ActionButton hook next frame (same-frame wrap during Sync has frozen clients).
    m_pendingGlowSync = true
end

function SmartAssist.OnScenarioStatsUpdated()
    if m_enabled ~= true or not IsScenarioContext() then
        return
    end
    -- Scoreboard updates are folded into the next assist tick.
    MarkAssistDirty()
end

function SmartAssist.OnScenarioBegin()
    ClearSticky()
    SetLastAssistName(nil)
    m_lastNotifyKey = nil
    m_assistSuppressed = false
    if m_enabled ~= true then
        return
    end
    if not IsScenarioContext() then
        -- Begin can beat isInScenario. Blank a stale /assist now; rank once context is up.
        HoldStatsStream(false)
        WriteMacro(nil)
    end
    -- OnUpdate does the player walk. Left set if context is still false so the first
    -- in-scenario tick does not wait out the full interval.
    MarkAssistDirtyNow()
end

function SmartAssist.OnScenarioEnd()
    ClearSticky()
    SetLastAssistName(nil)
    m_lastNotifyKey = nil
    HoldStatsStream(false)
    if m_enabled ~= true then
        return
    end
    -- May still be in an open-world party/warband; re-evaluate on the next tick.
    if IsPartyOrWarband() then
        MarkAssistDirtyNow()
        return
    end
    m_refreshNow = false
    m_targetDirty = false
    m_dirty = false
    ClearAssistOutsideContext()
end

function SmartAssist.OnGroupUpdated()
    if m_enabled ~= true then
        return
    end
    -- GROUP_UPDATED / BATTLEGROUP_UPDATED (and the other group events) drop
    -- scoreboard rows for allies who left. Empty roster means the list is not
    -- ready, so PruneToRoster leaves the cache alone.
    BuildAliveByKey()
    local GS = GroupStats()
    if GS ~= nil and type(GS.PruneToRoster) == "function" then
        GS.PruneToRoster(m_rosterKeys)
    end
    if ClearFriendlyLockIfDeparted() then
        MarkAssistDirtyNow()
        return
    end
    NoteFriendlyLockOnRoster()
    MarkAssistDirty()
end

function SmartAssist.OnGroupStatsUpdated()
    if m_enabled ~= true or IsScenarioContext() then
        return
    end
    MarkAssistDirty()
end

function SmartAssist.OnLoadingEnd()
    if m_enabled ~= true or not IsAssistContext() then
        return
    end
    MarkAssistDirtyNow()
end

function SmartAssist.OnMacrosLoaded()
    if m_enabled ~= true then
        return
    end
    -- Slot indexes move when macros reload. Drop the cache; the next write rescans.
    -- Do not WriteMacro here - SetMacroData often fires MACROS_LOADED (re-entrancy).
    m_macroSlot = nil
    MarkAssistDirtyNow()
end

function SmartAssist.OnPlayerTargetUpdated()
    if m_enabled ~= true then
        return
    end
    -- Friendly-lock cache + clearOnHostile must update outside party/scenario too.
    RefreshFriendlyPressCache()
    m_targetDirty = true
end

--- Sticky hold ticks every frame while enabled. Ranking stays on c_REFRESH_INTERVAL.
--- Disabled: return before any settings read or allocation.
function SmartAssist.OnUpdate(timePassed)
    -- Enable/disable/settings: run here so SetMacroData is not on a UI click stack.
    if m_pendingSync then
        SmartAssist.Sync()
    end
    if m_pendingGlowSync then
        m_pendingGlowSync = false
        SyncGlowPressHook()
    end

    -- Macro press side-effects are deferred from the click wrapper (safe for /assist).
    ApplyPendingMacroPress()
    FlushPendingMacroWrite()

    if m_enabled ~= true then
        return
    end

    RefreshFriendlyPressCache()

    local dt = tonumber(timePassed) or 0
    if m_stickyHoldLeft > 0 then
        m_stickyHoldLeft = math.max(0, m_stickyHoldLeft - dt)
    end

    if not IsAssistContext() then
        -- Friendly lock works outside party/scenario (KD ranking does not).
        if FriendlyAssistLocked() then
            if m_targetDirty then
                m_targetDirty = false
                if m_clearOnHostile and HasHostilePlayerTarget() then
                    if not m_assistSuppressed then
                        SuppressAssistForHostile()
                    end
                elseif m_assistSuppressed then
                    m_assistSuppressed = false
                    if not m_pendingMacroWrite and not m_flushMacroWrite then
                        WriteMacro(m_friendlyAssistLock)
                        SetLastAssistName(m_friendlyAssistLock)
                        UpdateMacroGlow()
                    end
                end
            end
            if m_assistSuppressed then
                return
            end
            if (m_refreshNow or m_dirty) and not m_pendingMacroWrite and not m_flushMacroWrite then
                m_refreshNow = false
                m_dirty = false
                WriteMacro(m_friendlyAssistLock)
                SetLastAssistName(m_friendlyAssistLock)
                UpdateMacroGlow()
            end
            return
        end
        m_targetDirty = false
        if m_inAssistWork then
            -- refreshNow is left alone so a scenario-begin that raced the flag still applies.
            ClearAssistOutsideContext()
        end
        return
    end

    m_inAssistWork = true
    m_updateElapsed = m_updateElapsed + dt

    if m_targetDirty then
        m_targetDirty = false
        if m_clearOnHostile and HasHostilePlayerTarget() then
            -- Clear on this update so the macro does not keep /assist through a target swap.
            -- Later target events while the hostile is still up do not touch the macro.
            -- Friendly lock stays set; text restores when the hostile player drops.
            if not m_assistSuppressed then
                SuppressAssistForHostile()
            end
        elseif m_assistSuppressed then
            -- Dropped the hostile player (or clearOnHostile turned off): rank / restore lock once.
            m_assistSuppressed = false
            MarkAssistDirtyNow()
        end
    end

    if m_refreshNow then
        m_refreshNow = false
        m_dirty = true
        if m_updateElapsed < c_REFRESH_INTERVAL then
            m_updateElapsed = c_REFRESH_INTERVAL
        end
    end

    -- Distance keeps moving with no event, so the interval itself counts as dirty.
    if m_updateElapsed >= c_REFRESH_INTERVAL then
        m_dirty = true
    end
    if not m_dirty or m_updateElapsed < c_REFRESH_INTERVAL then
        return
    end

    m_dirty = false
    m_updateElapsed = 0
    RefreshAssist()
end

local function RequestSync()
    m_pendingSync = true
end

--- Immediate sync (safe from mod Initialize / deferred OnUpdate - not from button clicks).
function SmartAssist.Sync()
    m_pendingSync = false
    local notifyWasOn = m_notify == true
    local settings = SmartAssist.EnsureSettings()
    -- Turning notifications back on should be allowed to announce the current pick.
    if settings.notify == true and not notifyWasOn then
        m_lastNotifyKey = nil
    end
    if settings.enabled == true then
        ClearSticky()
        m_assistSuppressed = false
        m_inAssistWork = false
        m_dirty = false
        m_refreshNow = false
        m_targetDirty = false
        m_updateElapsed = 0
        RegisterHandlers()
        -- Keep an existing EZAssist macro as-is. WriteMacro skips SetMacroData
        -- when that slot already has the right content, and is only called here
        -- when the macro was deleted or overwritten.
        local owned = FindOwnedMacroSlot()
        if owned then
            m_macroSlot = owned
        else
            WriteMacro(nil)
        end
        if IsAssistContext() then
            RefreshAssist()
        end
    else
        UnregisterHandlers()
        m_targetDirty = false
        m_dirty = false
        m_refreshNow = false
        m_assistSuppressed = false
        m_inAssistWork = false
        m_updateElapsed = 0
        HoldStatsStream(false)
        ClearSticky()
        SoftDisableMacroState()
    end
end

function SmartAssist.Enable()
    local settings = SmartAssist.EnsureSettings()
    settings.enabled = true
    RememberSettings(settings)
    RequestSync()
end

function SmartAssist.Disable()
    local settings = SmartAssist.EnsureSettings()
    settings.enabled = false
    RememberSettings(settings)
    RequestSync()
end

function SmartAssist.OnSettingsChanged()
    -- Defer SetMacroData / hotbar clears off the config/slash click stack (client crash).
    RememberSettings(SmartAssist.EnsureSettings())
    RequestSync()
end

function SmartAssist.Initialize()
    SmartAssist.EnsureSettings()
    local GS = GroupStats()
    if GS ~= nil and type(GS.Initialize) == "function" then
        GS.Initialize()
    end
    SmartAssist.Sync()
end

function SmartAssist.Shutdown()
    -- Session flag only. Saved enabled is unchanged; Initialize reads it again.
    -- Stops the tick from acquiring the stats stream again during teardown.
    m_enabled = false
    m_refreshNow = false
    m_targetDirty = false
    m_dirty = false
    m_inAssistWork = false
    m_glowClearPending = false
    UnregisterHandlers()
    HoldStatsStream(false)
    local GS = GroupStats()
    if GS ~= nil and type(GS.Shutdown) == "function" then
        GS.Shutdown()
    end
    -- Leave macro in place on reload shutdown; Disable keeps the slot too.
end
