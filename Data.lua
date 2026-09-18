local ADDON, BW = ...

-- The buffs BuffWarden watches. Matched by aura name (enUS), so every rank counts, and the
-- group version (Prayer of Fortitude, Gift of the Wild...) satisfies the single-target one.
--
--   key       saved-variable key (BuffWardenDB.disabled[key] turns it off)
--   class     the class that provides it
--   names     any of these auras on the unit satisfies the buff
--   cast      spells to cast, best first; the first one the player knows is used
--   scope     "group" = cast on everyone in the group, "self" = only on yourself,
--             "blessing" = one per paladin in the group (special-cased in Core)
--   who       nil = everyone, "mana" = only classes that use mana
--   spellID   any rank of the spell; its texture is the icon (works even when you can't cast it)
--   icon      fallback icon path, only if the client doesn't know the spell ID
--   default   false = off until turned on with /bw toggle <key>

BW.MANA_CLASSES = {
    PRIEST = true, MAGE = true, WARLOCK = true, DRUID = true,
    PALADIN = true, SHAMAN = true, HUNTER = true,
}

local BLESSINGS = {
    "Blessing of Might", "Blessing of Wisdom", "Blessing of Kings",
    "Blessing of Salvation", "Blessing of Light", "Blessing of Sanctuary",
    "Greater Blessing of Might", "Greater Blessing of Wisdom", "Greater Blessing of Kings",
    "Greater Blessing of Salvation", "Greater Blessing of Light", "Greater Blessing of Sanctuary",
}
BW.BLESSING_NAMES = BLESSINGS

BW.BUFFS = {
    -- Group buffs -------------------------------------------------------------
    { key = "fortitude", spellID = 1243, class = "PRIEST", scope = "group",
      names = { "Power Word: Fortitude", "Prayer of Fortitude" },
      cast = { "Power Word: Fortitude" },
      icon = "Interface\\Icons\\Spell_Holy_WordFortitude" },
    { key = "spirit", spellID = 14752, class = "PRIEST", scope = "group", who = "mana",
      names = { "Divine Spirit", "Prayer of Spirit" },
      cast = { "Divine Spirit" },
      icon = "Interface\\Icons\\Spell_Holy_DivineSpirit" },
    { key = "shadowprot", spellID = 976, class = "PRIEST", scope = "group", default = false,
      names = { "Shadow Protection", "Prayer of Shadow Protection" },
      cast = { "Shadow Protection" },
      icon = "Interface\\Icons\\Spell_Shadow_AntiShadow" },
    { key = "intellect", spellID = 1459, class = "MAGE", scope = "group", who = "mana",
      names = { "Arcane Intellect", "Arcane Brilliance" },
      cast = { "Arcane Intellect" },
      icon = "Interface\\Icons\\Spell_Holy_MagicalSentry" },
    { key = "wild", spellID = 1126, class = "DRUID", scope = "group",
      names = { "Mark of the Wild", "Gift of the Wild" },
      cast = { "Mark of the Wild" },
      icon = "Interface\\Icons\\Spell_Nature_Regeneration" },
    { key = "blessing", spellID = 19740, class = "PALADIN", scope = "blessing",
      names = BLESSINGS,
      -- Core picks per target: Kings if known, else Wisdom for mana users and Might for the rest.
      cast = { "Blessing of Kings", "Blessing of Wisdom", "Blessing of Might" },
      icon = "Interface\\Icons\\Spell_Holy_FistOfJustice" },

    -- Self buffs --------------------------------------------------------------
    { key = "innerfire", spellID = 588, class = "PRIEST", scope = "self",
      names = { "Inner Fire" }, cast = { "Inner Fire" },
      icon = "Interface\\Icons\\Spell_Holy_InnerFire" },
    { key = "magearmor", spellID = 168, class = "MAGE", scope = "self",
      names = { "Frost Armor", "Ice Armor", "Mage Armor", "Molten Armor" },
      cast = { "Molten Armor", "Mage Armor", "Ice Armor", "Frost Armor" },
      icon = "Interface\\Icons\\Spell_Frost_FrostArmor02" },
    { key = "demonarmor", spellID = 687, class = "WARLOCK", scope = "self",
      names = { "Demon Skin", "Demon Armor", "Fel Armor" },
      cast = { "Fel Armor", "Demon Armor", "Demon Skin" },
      icon = "Interface\\Icons\\Spell_Shadow_RagingScream" },
    { key = "aura", spellID = 465, class = "PALADIN", scope = "self",
      names = { "Devotion Aura", "Retribution Aura", "Concentration Aura", "Sanctity Aura",
                "Shadow Resistance Aura", "Frost Resistance Aura", "Fire Resistance Aura",
                "Crusader Aura" },
      cast = { "Devotion Aura" },
      icon = "Interface\\Icons\\Spell_Holy_DevotionAura" },
    { key = "aspect", spellID = 13165, class = "HUNTER", scope = "self",
      names = { "Aspect of the Hawk", "Aspect of the Monkey", "Aspect of the Cheetah",
                "Aspect of the Pack", "Aspect of the Wild", "Aspect of the Beast",
                "Aspect of the Viper", "Aspect of the Dragonhawk" },
      cast = { "Aspect of the Dragonhawk", "Aspect of the Hawk", "Aspect of the Monkey" },
      icon = "Interface\\Icons\\Spell_Nature_RavenForm" },
    { key = "trueshot", spellID = 19506, class = "HUNTER", scope = "self",
      names = { "Trueshot Aura" }, cast = { "Trueshot Aura" },
      icon = "Interface\\Icons\\Ability_TrueShot" },
    { key = "shield", spellID = 324, class = "SHAMAN", scope = "self",
      names = { "Lightning Shield", "Water Shield" },
      cast = { "Water Shield", "Lightning Shield" },
      icon = "Interface\\Icons\\Spell_Nature_LightningShield" },
    { key = "omen", spellID = 16864, class = "DRUID", scope = "self",
      names = { "Omen of Clarity" }, cast = { "Omen of Clarity" },
      icon = "Interface\\Icons\\Spell_Nature_CrystalBall" },
}
