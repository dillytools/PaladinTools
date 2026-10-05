local _, ns = ...

-- Data for SmartBlessing: which blessing each kind of player wants most.
-- Edit the tables here to retune priorities; no logic lives in this file.
--
-- A target is first resolved to a role (see RoleDetection.lua), then the
-- role's list is walked in order, skipping blessings the target already has
-- from someone else and blessings you don't know. Wisdom is skipped for
-- classes without mana.

local BlessingPriorities = {}
ns.BlessingPriorities = BlessingPriorities

---------------------------------------------------------------------------
-- Blessings
---------------------------------------------------------------------------

-- ranks: lowest first, with each rank's spell level (the level it's trained
-- at; the client's own value wins where it reports one). auraSpellIds: every
-- rank plus the Greater version, so a target with any of them counts as
-- having that blessing. castSpellId (rank 1, for names) is derived below.
BlessingPriorities.Blessings = {
    KINGS = {
        ranks = {
            { spellId = 20217, level = 20 },
        },
        auraSpellIds = { 20217, 25898 },
    },
    WISDOM = {
        ranks = {
            { spellId = 19742, level = 14 },
            { spellId = 19850, level = 24 },
            { spellId = 19852, level = 34 },
            { spellId = 19853, level = 44 },
            { spellId = 19854, level = 54 },
            { spellId = 25290, level = 60 },
        },
        auraSpellIds = { 19742, 19850, 19852, 19853, 19854, 25290, 25894, 25918 },
    },
    MIGHT = {
        ranks = {
            { spellId = 19740, level = 4 },
            { spellId = 19834, level = 12 },
            { spellId = 19835, level = 22 },
            { spellId = 19836, level = 32 },
            { spellId = 19837, level = 42 },
            { spellId = 19838, level = 52 },
            { spellId = 25291, level = 60 },
        },
        auraSpellIds = { 19740, 19834, 19835, 19836, 19837, 19838, 25291, 25782, 25916 },
    },
}

-- Classic rule: a buff only lands on a target whose level is at least the
-- rank's spell level minus this ("Target is too low level").
BlessingPriorities.RankLevelAllowance = 10

for _, blessing in pairs(BlessingPriorities.Blessings) do
    blessing.castSpellId = blessing.ranks[1].spellId
end

-- [auraSpellId] = blessing key
BlessingPriorities.BlessingByAuraSpellId = {}
for key, blessing in pairs(BlessingPriorities.Blessings) do
    for _, spellId in ipairs(blessing.auraSpellIds) do
        BlessingPriorities.BlessingByAuraSpellId[spellId] = key
    end
end

-- Classes that get no use from Blessing of Wisdom.
BlessingPriorities.NoManaClasses = { WARRIOR = true, ROGUE = true }

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------

-- Ordered best-first. Blessing of Might only adds melee attack power on this
-- (vanilla-content) client, so hunters and casters rank it last. Kings
-- leads for anything that soaks hits: tanks, pets, and (via
-- ClassRolePriority) the plate and bear classes even when they're dealing
-- damage.
BlessingPriorities.Roles = {
    TANK   = { label = "Tank",         priority = { "KINGS", "MIGHT", "WISDOM" } },
    MELEE  = { label = "Melee DPS",    priority = { "MIGHT", "KINGS", "WISDOM" } },
    RANGED = { label = "Ranged DPS",   priority = { "KINGS", "WISDOM", "MIGHT" } },
    CASTER = { label = "Caster DPS",   priority = { "WISDOM", "KINGS", "MIGHT" } },
    HEALER = { label = "Healer",       priority = { "WISDOM", "KINGS", "MIGHT" } },
    PET    = { label = "Pet",          priority = { "KINGS", "MIGHT", "WISDOM" } },
}

-- Per-class exceptions to a role's list: [classFile][role] = priority.
-- Warriors, paladins and druids take the most melee hits even as damage
-- dealers (off-tanking, threat slips), so Kings' stamina comes first.
BlessingPriorities.ClassRolePriority = {
    WARRIOR = { MELEE = { "KINGS", "MIGHT", "WISDOM" } },
    PALADIN = { MELEE = { "KINGS", "MIGHT", "WISDOM" } },
    DRUID   = { MELEE = { "KINGS", "MIGHT", "WISDOM" } },
}

-- The priority list for a role, with the class's exception if it has one.
function BlessingPriorities.GetPriority(role, classFile)
    local classLists = classFile and BlessingPriorities.ClassRolePriority[classFile]
    return (classLists and classLists[role]) or BlessingPriorities.Roles[role].priority
end

-- Talent tree (tab order) to role, per class.
BlessingPriorities.RoleByTalentTab = {
    WARRIOR = { "MELEE", "MELEE", "TANK" },        -- Arms, Fury, Protection
    PALADIN = { "HEALER", "TANK", "MELEE" },       -- Holy, Protection, Retribution
    HUNTER  = { "RANGED", "RANGED", "RANGED" },    -- Beast Mastery, Marksmanship, Survival
    ROGUE   = { "MELEE", "MELEE", "MELEE" },       -- Assassination, Combat, Subtlety
    PRIEST  = { "HEALER", "HEALER", "CASTER" },    -- Discipline, Holy, Shadow
    SHAMAN  = { "CASTER", "MELEE", "HEALER" },     -- Elemental, Enhancement, Restoration
    MAGE    = { "CASTER", "CASTER", "CASTER" },    -- Arcane, Fire, Frost
    WARLOCK = { "CASTER", "CASTER", "CASTER" },    -- Affliction, Demonology, Destruction
    DRUID   = { "CASTER", "MELEE", "HEALER" },     -- Balance, Feral (bear form -> TANK), Restoration
}

-- Modern specialization IDs, used if the client reports them.
BlessingPriorities.RoleBySpecId = {
    [71] = "MELEE",  [72] = "MELEE",  [73] = "TANK",                     -- Warrior
    [65] = "HEALER", [66] = "TANK",   [70] = "MELEE",                    -- Paladin
    [253] = "RANGED", [254] = "RANGED", [255] = "RANGED",                -- Hunter
    [259] = "MELEE",  [260] = "MELEE",  [261] = "MELEE",                 -- Rogue
    [256] = "HEALER", [257] = "HEALER", [258] = "CASTER",                -- Priest
    [262] = "CASTER", [263] = "MELEE",  [264] = "HEALER",                -- Shaman
    [62] = "CASTER",  [63] = "CASTER",  [64] = "CASTER",                 -- Mage
    [265] = "CASTER", [266] = "CASTER", [267] = "CASTER",                -- Warlock
    [102] = "CASTER", [103] = "MELEE",  [104] = "TANK", [105] = "HEALER", -- Druid
}

-- Auras that show what a player is doing right now and pin the role
-- regardless of talents: druid forms and tanking buffs/stances.
BlessingPriorities.RoleByAuraSpellId = {
    [5487] = "TANK",    -- Bear Form
    [9634] = "TANK",    -- Dire Bear Form
    [25780] = "TANK",   -- Righteous Fury
    [71] = "TANK",      -- Defensive Stance
    [768] = "MELEE",    -- Cat Form
    [24858] = "CASTER", -- Moonkin Form
}

-- Role for a group-assigned DAMAGER, per class.
BlessingPriorities.DamageRoleByClass = {
    WARRIOR = "MELEE", PALADIN = "MELEE", HUNTER = "RANGED", ROGUE = "MELEE",
    PRIEST = "CASTER", SHAMAN = "MELEE", MAGE = "CASTER", WARLOCK = "CASTER", DRUID = "MELEE",
}

-- Last resort when nothing else is known: the most common role per class.
BlessingPriorities.DefaultRoleByClass = {
    WARRIOR = "MELEE", PALADIN = "HEALER", HUNTER = "RANGED", ROGUE = "MELEE",
    PRIEST = "HEALER", SHAMAN = "HEALER", MAGE = "CASTER", WARLOCK = "CASTER", DRUID = "HEALER",
}
