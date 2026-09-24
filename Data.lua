local ADDON, BW = ...

-- The buffs BuffWarden watches. Matched by aura name (enUS), so every rank counts, and the
-- group version (Prayer of Fortitude, Gift of the Wild...) satisfies the single-target one.
--
--   key       saved-variable key (BuffWardenDB.disabled[key] turns it off)
--   class     the class that provides it
--   names     any of these auras on the unit satisfies the buff
--   cast      spells to cast, best first; the first one the player knows is used
--   scope     "group" = cast on everyone in the group, "self" = only on yourself,
--             "blessing" = one per paladin in the group, "food" = eaten, not cast (all special-cased
--             in Core)
--   who       nil = everyone, "mana" = only classes that use mana
--   spellID   any rank of the spell; its texture is the icon (works even when you can't cast it)
--   icon      fallback icon path, only if the client doesn't know the spell ID
--   minLevel  level a groupmate needs before we suggest asking them for it (their spellbooks can't be read)
--   talent    a talent spell: only suggest asking when someone in the group already carries the buff,
--             since that proves one of them has the talent
--   short     a short, cheap buff you recast often (Battle Shout). Its own rules, all optional:
--               warnPct = share of the aura's own duration (read from the aura) that counts as running
--               out, instead of the long-buff setting; warnMin = never less than this many seconds,
--               power/cost = only remind when you have this much of that power to cast it,
--               groupOnly = only remind while in a group
--   note      settings tooltip text, when the default "buff for you / for the group" isn't enough
--   tankOnly  only reminded about while you ARE the tank, which your own talents decide (see
--             SPEC_ROLES); before any points are spent, the group's role or a shield in the off
--             hand. The player's own tick always wins either way.
--   default   false = off until turned on in the settings (or /bwarden toggle <key>)

BW.MANA_CLASSES = {
    PRIEST = true, MAGE = true, WARLOCK = true, DRUID = true,
    PALADIN = true, SHAMAN = true, HUNTER = true,
}

-- There is no Blessing of Sanctuary in Forever. The client's own spell list has Might, Wisdom,
-- Kings, Salvation and Light (plus Freedom, Protection and Sacrifice, which aren't stat blessings)
-- and nothing named Sanctuary anywhere. So a tank gets Kings, or Might - don't add Sanctuary back.
local BLESSINGS = {
    "Blessing of Might", "Blessing of Wisdom", "Blessing of Kings",
    "Blessing of Salvation", "Blessing of Light",
    "Greater Blessing of Might", "Greater Blessing of Wisdom", "Greater Blessing of Kings",
    "Greater Blessing of Salvation", "Greater Blessing of Light",
}
BW.BLESSING_NAMES = BLESSINGS

-- Which blessing a paladin can pick for someone. Whether they HAVE it is asked of the spellbook, so
-- nothing here needs a level; for reference, the client trains them at Might 4, Wisdom 14, Kings 20,
-- Salvation 26 and Light 40, which is the order the fallbacks lean on.
-- Forever has only one "spec" per class and it is named after the class, so there is nothing to read
-- about anyone ELSE's talents: their choice comes from class, role and the player. Our own talents we
-- can read - see SPEC_ROLES.
BW.BLESSING_KINDS = {
    might     = { spell = "Blessing of Might" },
    wisdom    = { spell = "Blessing of Wisdom" },
    kings     = { spell = "Blessing of Kings" },
    salvation = { spell = "Blessing of Salvation" },
    light     = { spell = "Blessing of Light" },
}
BW.BLESSING_LABEL = {
    auto = "Class default", might = "Blessing of Might", wisdom = "Blessing of Wisdom",
    kings = "Blessing of Kings", salvation = "Blessing of Salvation",
    light = "Blessing of Light",
}

-- What each of a class's three talent tabs means, in the client's own tab order. Only the classes
-- a rule actually asks about are here: the profile is class-general, so add one when something needs
-- it rather than guessing ahead for eight classes nothing reads.
BW.SPEC_ROLES = {
    PALADIN = { "healer", "tank", "melee" },   -- Holy, Protection, Retribution
}

-- The fallback for when talents can't be read: talents only a healing paladin spends points on, and
-- we can read our OWN spellbook. It misses a healer who hasn't reached them, which is exactly why
-- the talents themselves are the better signal.
BW.PALADIN_HEALER_SIGNS = { "Divine Favor", "Holy Shock" }
-- The order the blessing row shows its buttons in.
BW.BLESSING_ORDER = { "might", "wisdom", "kings", "salvation", "light" }

-- The default per class, aimed at dungeons and levelling (raids are PallyPower's job), where the
-- thing that costs a group its evening is drinking between pulls. That is why the casters default to
-- Wisdom rather than Kings: Kings wins once everyone is geared and mana stops being the limit, and
-- that is what the per-class setting below is for.
--
-- Spec is not readable in Forever - one class, one "spec" - so where a class splits, the default is
-- picked by which mistake is CHEAPER, not by which spec is more common. Might on a resto shaman is
-- worth exactly nothing; Wisdom on an enhancement shaman still pays for his shocks and for imbuing
-- his weapon again. So the classes that might heal get Wisdom, and the tooltip says "(class
-- default)" so a wrong guess is visible and one click from fixed.
--   kind     what to use once the paladin knows it
--   fallback what to use until then (Kings is level 20, Wisdom 14, Might 4)
BW.BLESSING_BY_CLASS = {
    WARRIOR = { kind = "might",  fallback = "might",  why = "warriors swing, and have no mana" },
    ROGUE   = { kind = "might",  fallback = "might",  why = "no mana" },
    -- Hunters look like an attack-power class and are not, in this client. Blessing of Might is
    -- effect aura 99 (attack power), while Aspect of the Hawk and Trueshot Aura are aura 124
    -- (RANGED attack power) - two separate stats in 1.60 data, both in use. Might does nothing for a
    -- hunter's shots, and hunters drink constantly while levelling. Do not "correct" this to Might.
    HUNTER  = { kind = "wisdom", fallback = "might",  why = "Might is melee only, and hunters burn mana" },
    SHAMAN  = { kind = "wisdom", fallback = "might",
                why = "Might does nothing for a healer, Wisdom helps either way (class default)" },
    PALADIN = { kind = "wisdom", fallback = "might",  why = "paladins cast, whatever they do (class default)" },
    PRIEST  = { kind = "wisdom", fallback = "might",  why = "they cast from mana" },
    MAGE    = { kind = "wisdom", fallback = "might",  why = "they cast from mana" },
    DRUID   = { kind = "wisdom", fallback = "might",
                why = "druids cast, even feral ones shifting (class default)" },
    -- The one exception: Life Tap turns health into mana, so mana regen is not a warlock's limit.
    WARLOCK = { kind = "kings",  fallback = "wisdom", why = "warlocks tap for mana, so Kings beats Wisdom" },
}

-- The order the settings list them in.
BW.BLESSING_CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}

BW.BUFFS = {
    -- Group buffs -------------------------------------------------------------
    { key = "fortitude", spellID = 1243, class = "PRIEST", scope = "group", minLevel = 1,
      names = { "Power Word: Fortitude", "Prayer of Fortitude" },
      cast = { "Power Word: Fortitude" },
      icon = "Interface\\Icons\\Spell_Holy_WordFortitude" },
    { key = "spirit", spellID = 14752, class = "PRIEST", scope = "group", who = "mana",
      minLevel = 30, talent = true,
      names = { "Divine Spirit", "Prayer of Spirit" },
      cast = { "Divine Spirit" },
      icon = "Interface\\Icons\\Spell_Holy_DivineSpirit" },
    { key = "shadowprot", spellID = 976, class = "PRIEST", scope = "group", default = false,
      minLevel = 30,
      names = { "Shadow Protection", "Prayer of Shadow Protection" },
      cast = { "Shadow Protection" },
      icon = "Interface\\Icons\\Spell_Shadow_AntiShadow" },
    { key = "intellect", spellID = 1459, class = "MAGE", scope = "group", who = "mana", minLevel = 1,
      names = { "Arcane Intellect", "Arcane Brilliance" },
      cast = { "Arcane Intellect" },
      icon = "Interface\\Icons\\Spell_Holy_MagicalSentry" },
    { key = "wild", spellID = 1126, class = "DRUID", scope = "group", minLevel = 1,
      names = { "Mark of the Wild", "Gift of the Wild" },
      cast = { "Mark of the Wild" },
      icon = "Interface\\Icons\\Spell_Nature_Regeneration" },
    { key = "blessing", spellID = 19740, class = "PALADIN", scope = "blessing", minLevel = 4,
      names = BLESSINGS,
      -- Core picks the blessing per target (BLESSING_BY_CLASS and the player's overrides); this
      -- list is only asked "do you know any blessing at all", so its order means nothing.
      cast = { "Blessing of Wisdom", "Blessing of Might", "Blessing of Kings" },
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

    -- Righteous Fury is threat, so it belongs to a tanking paladin and nobody else - and to a holy
    -- paladin it is dangerous, which is why the shield alone can't decide this: holy paladins carry
    -- one too. Our own talents say which we are.
    { key = "righteousfury", spellID = 25780, class = "PALADIN", scope = "self",
      tankOnly = true, default = false,
      names = { "Righteous Fury" }, cast = { "Righteous Fury" },
      note = "Tanking only: more threat from your Holy attacks. Shown when your talents say you are "
          .. "the tank - before you have spent any, when the group marks you tank or you carry a "
          .. "shield. Tick to always show it, untick to never.",
      icon = "Interface\\Icons\\Spell_Holy_SealOfFury" },

    -- Food ---------------------------------------------------------------------
    -- Well Fed comes from eating, not from a spell, so there is nothing to cast: the click runs
    -- AutoFeed's food macro when you have AutoFeed, and otherwise the icon just tells you.
    -- spellID 19705 is a Well Fed aura, so the icon is the buff's own (Spell_Misc_Food), not a food item's.
    { key = "wellfed", spellID = 19705, scope = "food",
      names = { "Well Fed" },
      cast = {},
      note = "The buff from eating proper food. With AutoFeed installed, a click eats your best food.",
      icon = "Interface\\Icons\\Spell_Misc_Food" },

    -- Short buffs -------------------------------------------------------------
    -- Battle Shout is short (its duration is read from the aura) and costs rage, which drains to nothing
    -- out of combat. Buffs can't be
    -- read in combat on Forever, so this only reminds out of combat, in a group, while you still have the
    -- rage to shout (typically right after a fight).
    { key = "battleshout", spellID = 6673, class = "WARRIOR", scope = "self",
      names = { "Battle Shout" }, cast = { "Battle Shout" },
      short = { warnPct = 0.1, warnMin = 10, power = "RAGE", cost = 10, groupOnly = true },
      note = "Only in a group and when you have the rage for it; warns when a tenth of it is left.",
      icon = "Interface\\Icons\\Ability_Warrior_BattleShout" },
}

-- ---------------------------------------------------------------------------
-- Weapon buffs: stones, weightstones and oils (temporary weapon enchants)
-- ---------------------------------------------------------------------------
-- Item ids and kinds come from the Forever client's own item data (item class 0/8, "Item Enhancement"),
-- not from item names, which are translated. rank orders them weakest to strongest.
BW.WEAPON_ENHANCERS = {
    [2862]  = { kind = "sharpening", rank = 1 },   -- Rough Sharpening Stone
    [2863]  = { kind = "sharpening", rank = 2 },   -- Coarse
    [2871]  = { kind = "sharpening", rank = 3 },   -- Heavy
    [7964]  = { kind = "sharpening", rank = 4 },   -- Solid
    [12404] = { kind = "sharpening", rank = 5 },   -- Dense
    [18262] = { kind = "sharpening", rank = 6 },   -- Elemental
    [23122] = { kind = "sharpening", rank = 7 },   -- Consecrated
    [3239]  = { kind = "weightstone", rank = 1 },  -- Rough Weightstone
    [3240]  = { kind = "weightstone", rank = 2 },  -- Coarse
    [3241]  = { kind = "weightstone", rank = 3 },  -- Heavy
    [7965]  = { kind = "weightstone", rank = 4 },  -- Solid
    [12643] = { kind = "weightstone", rank = 5 },  -- Dense
    [20744] = { kind = "oil", rank = 1 },          -- Minor Wizard Oil
    [20745] = { kind = "oil", rank = 2 },          -- Minor Mana Oil
    [20750] = { kind = "oil", rank = 3 },          -- Wizard Oil
    [20748] = { kind = "oil", rank = 4 },          -- Brilliant Mana Oil
    [20749] = { kind = "oil", rank = 5 },          -- Brilliant Wizard Oil
    [23123] = { kind = "oil", rank = 6 },          -- Blessed Wizard Oil
}

-- Which stone a weapon takes, by the weapon's own subclass: blades get sharpened, blunt weapons weighted.
-- Oils go on any of them, so they are allowed everywhere and chosen by preference instead.
BW.WEAPON_KIND_BY_SUBCLASS = {
    [0] = "sharpening", [1] = "sharpening",       -- axes
    [7] = "sharpening", [8] = "sharpening",       -- swords
    [15] = "sharpening", [6] = "sharpening",      -- daggers, polearms
    [4] = "weightstone", [5] = "weightstone",     -- maces
    [10] = "weightstone", [13] = "weightstone",   -- staves, fist weapons
}

BW.FISHING_POLE_SUBCLASS = 20

-- Shaman weapon imbues, best first for the automatic choice. The spell goes on the main hand.
BW.SHAMAN_IMBUES = { "Windfury Weapon", "Flametongue Weapon", "Frostbrand Weapon", "Rockbiter Weapon" }
BW.IMBUE_LABEL = {
    auto = "Best one I know",
    ["Windfury Weapon"] = "Windfury Weapon",
    ["Flametongue Weapon"] = "Flametongue Weapon",
    ["Frostbrand Weapon"] = "Frostbrand Weapon",
    ["Rockbiter Weapon"] = "Rockbiter Weapon",
}

-- Rogue poisons, from the client's item data (class 0/8). rank orders the ranks of one poison.
BW.POISONS = {
    [6947]  = { kind = "instant", rank = 1 },   -- Instant Poison
    [6949]  = { kind = "instant", rank = 2 },
    [6950]  = { kind = "instant", rank = 3 },
    [8926]  = { kind = "instant", rank = 4 },
    [8927]  = { kind = "instant", rank = 5 },
    [8928]  = { kind = "instant", rank = 6 },
    [2892]  = { kind = "deadly", rank = 1 },    -- Deadly Poison
    [2893]  = { kind = "deadly", rank = 2 },
    [8984]  = { kind = "deadly", rank = 3 },
    [8985]  = { kind = "deadly", rank = 4 },
    [20844] = { kind = "deadly", rank = 5 },
    [10918] = { kind = "wound", rank = 1 },     -- Wound Poison
    [10920] = { kind = "wound", rank = 2 },
    [10921] = { kind = "wound", rank = 3 },
    [10922] = { kind = "wound", rank = 4 },
    [3775]  = { kind = "crippling", rank = 1 }, -- Crippling Poison
    [3776]  = { kind = "crippling", rank = 2 },
    [5237]  = { kind = "mindnumbing", rank = 1 },  -- Mind-numbing Poison
    [6951]  = { kind = "mindnumbing", rank = 2 },
    [9186]  = { kind = "mindnumbing", rank = 3 },
}

-- What to offer when the player hasn't chosen: Instant on the main hand, Deadly on the off hand.
BW.POISON_AUTO = { [0] = "instant", [1] = "deadly" }
BW.POISON_CHOICES = { "auto", "instant", "deadly", "wound", "crippling", "mindnumbing", "none" }
BW.POISON_LABEL = {
    auto = "Automatic (Instant on main, Deadly on off hand)",
    instant = "Instant Poison", deadly = "Deadly Poison", wound = "Wound Poison",
    crippling = "Crippling Poison", mindnumbing = "Mind-numbing Poison",
    none = "Don't remind me for this hand",
}
