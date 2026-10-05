local _, ns = ...

-- Decides which blessing a unit should get, and finds the closest other
-- friendly player who still needs one (never yourself). Pure logic over
-- unit/aura APIs; SmartBlessing owns the secure button that actually casts.
--
-- Everything here reads aura data, so it only works out of combat (aura data
-- is secret in combat); functions return nil when it can't be read.

local BlessingPlanner = {}
ns.BlessingPlanner = BlessingPlanner

local MAX_BUFFS = 40
local MAX_PARTY = 4
-- Range rings for players without an exact distance, nearest first. Each is
-- a yes/no check at a fixed range; a ring whose check can't answer on this
-- client is skipped. Items are LibRangeCheck's friendly range items.
local RANGE_RINGS = {
    { yards = 10, interactIndex = 3 },  -- duel range
    { yards = 11, interactIndex = 2 },  -- trade range
    { yards = 15, itemId = 1251 },      -- Linen Bandage
    { yards = 20, itemId = 21519 },     -- Mistletoe
    { yards = 28, interactIndex = 4 },  -- follow range
}
local BLESSING_RANGE_YARDS = 30
-- The blessing range check couldn't answer: try them, but last.
local UNKNOWN_RANGE_YARDS = 35

local Data = ns.BlessingPriorities

---------------------------------------------------------------------------
-- Safe reads
---------------------------------------------------------------------------

-- Calls fn; returns its result unless the call failed or it's secret.
local function SafeRead(fn, ...)
    if not fn then return nil end
    local ok, value = pcall(fn, ...)
    if not ok or ns.IsSecret(value) then return nil end
    return value
end

local function IsTrue(fn, ...)
    return SafeRead(fn, ...) == true
end

local function IsMine(sourceUnit)
    return sourceUnit ~= nil and IsTrue(UnitIsUnit, sourceUnit, "player")
end

---------------------------------------------------------------------------
-- Auras and spells
---------------------------------------------------------------------------

-- Returns blessings ({ [blessingKey] = "mine" | "other" }) and a set of every
-- helpful aura spell ID, or nil if aura data can't be read right now.
-- Another paladin's copy wins over yours: it blocks that blessing.
local function ScanAuras(unit)
    if not C_UnitAuras or ns.AurasAreSecret() then return nil end

    local blessings, spellIds = {}, {}
    for i = 1, MAX_BUFFS do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then return nil end
        if not aura then break end

        local spellId, sourceUnit = aura.spellId, aura.sourceUnit
        if ns.IsSecret(spellId) or ns.IsSecret(sourceUnit) then return nil end

        spellIds[spellId] = true
        local key = Data.BlessingByAuraSpellId[spellId]
        if key then
            blessings[key] = IsMine(sourceUnit) and (blessings[key] or "mine") or "other"
        end
    end
    return blessings, spellIds
end

local function KnowsSpell(spellId)
    local check = IsPlayerSpell or (C_SpellBook and C_SpellBook.IsSpellKnown) or IsSpellKnown
    if not check then return true end
    local ok, known = pcall(check, spellId)
    -- If the check itself fails, let the cast try; the client will refuse it.
    if not ok or ns.IsSecret(known) then return true end
    return known == true
end

-- Learned level the client reports for a rank, else the table's value.
local function RankLevel(rank)
    if C_Spell and C_Spell.GetSpellLevelLearned then
        local learned = SafeRead(C_Spell.GetSpellLevelLearned, rank.spellId)
        if type(learned) == "number" and learned > 0 then return learned end
    end
    return rank.level
end

-- The unit's level, or nil when unknown or hidden (skull: -1), which
-- lifts the rank limit.
local function TargetLevel(unit)
    local level = SafeRead(UnitLevel, unit)
    if type(level) ~= "number" or level <= 0 then return nil end
    return level
end

-- Highest rank you know that a target of this level can receive, plus
-- whether it's your highest known rank. nil if no rank fits.
local function PickRank(blessingKey, targetLevel)
    local ranks = Data.Blessings[blessingKey].ranks
    local isHighestKnown = true
    for i = #ranks, 1, -1 do
        local rank = ranks[i]
        if KnowsSpell(rank.spellId) then
            if not targetLevel or targetLevel >= RankLevel(rank) - Data.RankLevelAllowance then
                return rank, isHighestKnown
            end
            isHighestKnown = false
        end
    end
end

local function CanReceive(blessingKey, classFile)
    return not (blessingKey == "WISDOM" and Data.NoManaClasses[classFile])
end

function BlessingPlanner.BlessingName(blessingKey)
    return ns.GetSpellName(Data.Blessings[blessingKey].castSpellId) or blessingKey
end

-- "Rank 3", or nil for single-rank spells / when the client has no subtext.
function BlessingPlanner.RankText(spellId)
    local getSubtext = (C_Spell and C_Spell.GetSpellSubtext) or GetSpellSubtext
    local text = SafeRead(getSubtext, spellId)
    if type(text) ~= "string" or text == "" then return nil end
    return text
end

-- "Blessing of Might (Rank 3)" for a plan's choice.
function BlessingPlanner.DescribeCast(plan)
    local name = BlessingPlanner.BlessingName(plan.choice)
    local rankText = plan.rankSpellId and BlessingPlanner.RankText(plan.rankSpellId)
    return rankText and ("%s (%s)"):format(name, rankText) or name
end

---------------------------------------------------------------------------
-- Choosing
---------------------------------------------------------------------------

-- With the Classic one-blessing-per-paladin rule, your own blessing on the
-- target is the slot you're filling, so it never blocks: picking it again
-- refreshes it. Without the rule your own blessings block too, and if
-- everything is taken the best one of yours is refreshed. A blessing with no
-- rank the target's level allows is skipped like an unknown one.
-- Returns key, rank, isHighestKnownRank (all nil if nothing fits).
local function ChooseBlessing(role, classFile, blessings, onePerCaster, targetLevel)
    local refresh, refreshRank, refreshIsHighest
    for _, key in ipairs(Data.GetPriority(role, classFile)) do
        local rank, isHighest = nil, nil
        if CanReceive(key, classFile) then rank, isHighest = PickRank(key, targetLevel) end
        if rank then
            local state = blessings[key]
            if state == nil or (state == "mine" and onePerCaster) then return key, rank, isHighest end
            if state == "mine" and not refresh then refresh, refreshRank, refreshIsHighest = key, rank, isHighest end
        end
    end
    return refresh, refreshRank, refreshIsHighest
end

-- Returns a plan table for the unit, or nil if aura data is unreadable:
-- { unit, guid, name, fullName, level, role, roleSource, classFile,
--   blessings, choice, rankSpellId, isHighestRank }.
function BlessingPlanner.BuildPlan(unit, onePerCaster)
    local blessings, auraSpellIds = ScanAuras(unit)
    if not blessings then return nil end

    local role, roleSource, classFile = ns.RoleDetection.Resolve(unit, auraSpellIds)
    local level = TargetLevel(unit)
    local choice, rank, isHighestRank = ChooseBlessing(role, classFile, blessings, onePerCaster, level)
    return {
        unit = unit,
        guid = SafeRead(UnitGUID, unit),
        name = SafeRead(UnitName, unit),
        fullName = SafeRead(GetUnitName, unit, true),  -- "Name-Realm" off-realm
        level = level,
        role = role,
        roleSource = roleSource,
        classFile = classFile,
        blessings = blessings,
        choice = choice,
        rankSpellId = rank and rank.spellId,
        isHighestRank = isHighestRank,
    }
end

-- False if the unit already carries your blessing (one-per-paladin rule) or
-- has every blessing it could use; refreshes don't count as a need.
function BlessingPlanner.NeedsBlessing(plan, onePerCaster)
    if onePerCaster then
        for _, state in pairs(plan.blessings) do
            if state == "mine" then return false end
        end
    end
    return plan.choice ~= nil and plan.blessings[plan.choice] == nil
end

---------------------------------------------------------------------------
-- Closest unblessed player
---------------------------------------------------------------------------

-- Group members, then friendly nameplates (players outside your group are
-- only reachable through a nameplate unit token).
local function CollectCandidateUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do table.insert(units, "raid" .. i) end
    else
        for i = 1, math.min(GetNumSubgroupMembers(), MAX_PARTY) do table.insert(units, "party" .. i) end
    end

    if C_NamePlate and C_NamePlate.GetNamePlates then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        for _, plate in ipairs(ok and plates or {}) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit and not ns.IsSecret(unit) then table.insert(units, unit) end
        end
    end
    return units
end

local function IsPhased(unit)
    if not UnitPhaseReason then return false end
    local ok, reason = pcall(UnitPhaseReason, unit)
    return ok and not ns.IsSecret(reason) and reason ~= nil
end

local function IsEligible(unit)
    return UnitExists(unit)
        and not IsTrue(UnitIsUnit, unit, "player")
        and IsTrue(UnitIsPlayer, unit)
        and IsTrue(UnitCanAssist, "player", unit)
        and IsTrue(UnitIsConnected, unit)
        and IsTrue(UnitIsVisible, unit)
        and not IsTrue(UnitIsDeadOrGhost, unit)
        and not IsPhased(unit)
end

-- true/false, or nil when the client can't tell.
local function CheckSpellRange(spellName, unit)
    if C_Spell and C_Spell.IsSpellInRange then return SafeRead(C_Spell.IsSpellInRange, spellName, unit) end
    if IsSpellInRange then
        local result = SafeRead(IsSpellInRange, spellName, unit)
        if result == nil then return nil end
        return result == 1
    end
end

local function CheckItemRange(itemId, unit)
    local check = (C_Item and C_Item.IsItemInRange) or IsItemInRange
    return SafeRead(check, itemId, unit)
end

-- Item range checks only answer once the item's data is cached.
for _, ring in ipairs(RANGE_RINGS) do
    if ring.itemId and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, ring.itemId)
    end
end

local function IsWithinRing(ring, unit)
    if ring.interactIndex then return SafeRead(CheckInteractDistance, unit, ring.interactIndex) end
    return CheckItemRange(ring.itemId, unit)
end

-- Exact distance in yards where the client allows it (group members in the
-- open world), else nil.
local function ExactDistance(unit)
    if not UnitDistanceSquared then return nil end
    local ok, distanceSquared, checked = pcall(UnitDistanceSquared, unit)
    if not ok or ns.IsSecret(distanceSquared) or ns.IsSecret(checked) or not checked then return nil end
    return math.sqrt(distanceSquared)
end

-- Estimated distance in yards, or nil if the unit is out of blessing range.
-- Exact where available; otherwise the middle of the smallest ring the unit
-- is inside, so the search expands outward ring by ring.
local function EstimateDistance(unit, spellName)
    local inBlessingRange = CheckSpellRange(spellName, unit)
    if inBlessingRange == false then return nil end

    local exact = ExactDistance(unit)
    if exact then return exact end

    local innerYards = 0
    for _, ring in ipairs(RANGE_RINGS) do
        local within = IsWithinRing(ring, unit)
        if within == true then return (innerYards + ring.yards) / 2 end
        -- An unanswerable ring proves nothing, so the next ring's band
        -- starts at the last ring that answered "outside".
        if within == false then innerYards = ring.yards end
    end
    if inBlessingRange then return (innerYards + BLESSING_RANGE_YARDS) / 2 end
    return UNKNOWN_RANGE_YARDS
end

-- Returns the plan for the closest other player who needs a blessing, or
-- nil. skipGuids: optional { [guid] = true } of players to pass over.
function BlessingPlanner.FindClosestUnblessed(onePerCaster, skipGuids)
    local spellName = BlessingPlanner.BlessingName("MIGHT")  -- all blessings share one range
    local best, bestDistance
    local seen = {}

    -- Group tokens come first, so on a tie (or the same player also having a
    -- nameplate) the castable group token wins.
    for _, unit in ipairs(CollectCandidateUnits()) do
        local guid = SafeRead(UnitGUID, unit)
        if guid and not seen[guid] and not (skipGuids and skipGuids[guid]) and IsEligible(unit) then
            seen[guid] = true

            local distance = EstimateDistance(unit, spellName)
            if distance and (not best or distance < bestDistance) then
                local plan = BlessingPlanner.BuildPlan(unit, onePerCaster)
                if plan and BlessingPlanner.NeedsBlessing(plan, onePerCaster) then
                    plan.distance = distance
                    best, bestDistance = plan, distance
                end
            end
        end
    end
    return best
end
