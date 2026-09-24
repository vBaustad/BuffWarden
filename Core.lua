-- BuffWarden: keeps watch over your buffs. Shows what you (or your group) are missing, and lets you
-- cast it or ask for it in one click. WoW: Forever (modern 12.x client API).
local ADDON, BW = ...

BW.version = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
local LIB = LibStub and LibStub("LibForever-1.0", true)
local TAG = "|cff66ccffBuffWarden|r"

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------
local defaults = {
    threshold    = 300,     -- warn (orange) when a buff has fewer seconds left than this
    hideInCombat = true,    -- the bar is secure; this hides it through a state driver
    locked       = true,
    scale        = 1,
    point        = nil,     -- { point, relPoint, x, y }
    disabled     = {},      -- [buffKey] = true / false (overrides the buff's default)
    readyCheck   = true,    -- print what's missing on a ready check
    ignoreFar    = true,    -- leave out groupmates too far away to bother about
    placed       = false,   -- has the bar been dragged into place? (the welcome card asks until it has)
    blessFor     = {},      -- ["Name-Realm"] = blessing kind the player picked for them
    blessForClass = {},     -- ["MAGE"] = blessing kind the player picked for every mage
    blessKings   = false,   -- Kings to everyone it is known for, even the Might classes
    blessRow     = true,    -- paladins: the blessing buttons, in the same run as the other icons
    blessNames   = true,    -- show the next target's name on each blessing button
    perRow       = 12,      -- icons on one line before a second line starts
    weaponBuffs  = true,    -- watch the temporary enchant on your weapons (stones, oils, imbues)
    weaponPref   = "auto",  -- "auto" (oil for mana classes, stone for the rest), "stone" or "oil"
    imbuePref    = "auto",  -- shaman: "auto" (best known) or the name of one imbue
    poisonMain   = "auto",  -- rogue: "auto", a poison kind, or "none"
    poisonOff    = "auto",
}

local ASK_TEXT = "Could I get %s, please? :)"
local ASK_COOLDOWN = 30   -- seconds before the same groupmate can be asked for the same buff again

local function MyClass()
    local _, class = UnitClass("player")
    return class
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function Clean(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local knownCache = {}
local function Knows(name)
    local k = knownCache[name]
    if k ~= nil then return k end
    local info = C_Spell.GetSpellInfo(name)
    local id = info and info.spellID
    k = false
    if id then
        if IsPlayerSpell and IsPlayerSpell(id) then k = true
        elseif C_SpellBook and C_SpellBook.FindSpellBookSlotForSpell
            and C_SpellBook.FindSpellBookSlotForSpell(id) then k = true
        elseif not IsPlayerSpell then k = true end
    end
    knownCache[name] = k
    return k
end

local function FirstKnown(list)
    for _, name in ipairs(list) do
        if Knows(name) then return name end
    end
end
BW.Knows = Knows

-- ---------------------------------------------------------------------------
-- What we know about ourselves
--
-- We are blind about other players and always will be, but our own character we can read exactly:
-- class, level, where the talent points went, what is in our hands, which spells we have trained.
-- Forever gives each class one talent tree with the three old tabs inside it as node groups, and
-- the client will say how many points sit in each - none of it secret, unlike auras. So "am I
-- healing, tanking or swinging" is a question we answer rather than guess, and every rule that
-- leans on it says which signal decided, because the signals are not equally good.
-- ---------------------------------------------------------------------------
local ARMOR_CLASS, SHIELD_SUBCLASS = 4, 6
local selfProfile                    -- nil = work it out again (level or gear changed)
local specCache                      -- nil = unread, false = read and nothing spent, else the tabs

function BW.ForgetMe() selfProfile = nil end
-- Only the talent events clear this one: reading the tree is 52 calls, and a bag update is not a
-- reason to do it again.
function BW.ForgetTalents() selfProfile, specCache = nil, nil end

local function HasShield()
    local id = GetInventoryItemID("player", 17)      -- off hand
    if not id then return false end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
    return classID == ARMOR_CLASS and subClassID == SHIELD_SUBCLASS
end

-- Points per specialisation. The three display groups of our class's tree are the three old talent
-- tabs in tab order, and a node's groupIDs say which one it belongs to (a node is also in the group
-- for its row, which is why only the three we asked about are counted). Returns the tabs and the
-- one with the most points, or nil when nothing is spent or the client won't say.
-- Second return: did the client answer at all? A "no" there is worth asking again later; a "yes"
-- with nothing spent is an answer we can keep.
local function ReadSpecs()
    if not (C_Traits and C_ClassTalents and C_ClassTalents.GetActiveConfigID) then return nil, true end
    local configID = Clean(C_ClassTalents.GetActiveConfigID())
    if not configID then return nil, false end          -- not loaded yet: ask again
    local config = C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(configID)
    local treeID = config and config.treeIDs and config.treeIDs[1]
    local groups = treeID and C_Traits.GetGroupDisplayInfoByTreeID
        and C_Traits.GetGroupDisplayInfoByTreeID(treeID)
    local nodes = treeID and C_Traits.GetTreeNodes and C_Traits.GetTreeNodes(treeID)
    if not (groups and nodes and #groups > 0 and C_Traits.GetNodeInfo) then return nil, false end

    local byGroup, tabs = {}, {}
    for _, g in ipairs(groups) do
        local spec = { name = Clean(g.displayName) or "?", tab = (Clean(g.orderIndex) or 0) + 1,
                       points = 0 }
        byGroup[g.groupID] = spec
        tabs[spec.tab] = spec
    end
    for _, nodeID in ipairs(nodes) do
        local info = C_Traits.GetNodeInfo(configID, nodeID)
        local ranks = info and Clean(info.ranksPurchased)
        if ranks and ranks > 0 and info.groupIDs then
            for _, id in ipairs(info.groupIDs) do
                local spec = byGroup[id]
                if spec then spec.points = spec.points + ranks end
            end
        end
    end
    local top
    for _, spec in pairs(tabs) do
        if spec.points > 0 and (not top or spec.points > top.points) then top = spec end
    end
    if not top then return nil, true end      -- no points spent yet: say nothing rather than "Holy 0"
    return { tabs = tabs, top = top }, true
end

-- Worked out once and kept until something about us changes.
local function Me()
    if selfProfile then return selfProfile end
    local p = { class = MyClass(), level = Clean(UnitLevel("player")) or 0, shield = HasShield() }
    if specCache == nil then
        local specs, answered = ReadSpecs()
        specCache = specs or (answered and false or nil)
    end
    local specs = specCache or nil
    p.tabs, p.spec = specs and specs.tabs, specs and specs.top
    local roles = BW.SPEC_ROLES[p.class]
    p.role = (roles and p.spec) and roles[p.spec.tab] or nil
    selfProfile = p
    return p
end
BW.Me = Me

-- Are we tanking? Talents answer it once any are spent. Until then the off hand is the only signal
-- there is, and at that level a paladin with a shield is tanking or about to be - but a shield on
-- its own is a bad signal later, because a holy paladin carries one too, and telling a healer to
-- keep Righteous Fury up is how a healer dies.
local function IAmTank()
    local me = Me()
    if me.role then return me.role == "tank" end
    if UnitGroupRolesAssigned then
        local ok, r = pcall(UnitGroupRolesAssigned, "player")
        if ok and Clean(r) == "TANK" then return true end
    end
    return me.shield
end

local function BuffEnabled(def)
    local v = BW.db.disabled[def.key]
    if v ~= nil then return not v end          -- the player decided: that wins either way
    if def.tankOnly then return IAmTank() end  -- otherwise only while you are the tank
    return def.default ~= false
end
BW.BuffEnabled = BuffEnabled

-- One range check per spell and unit for each pass over the group: the same question was being asked
-- several times per refresh (once per buff, again for every tooltip line).
local rangeCache = {}
local function InRange(spell, unit)
    if UnitIsUnit(unit, "player") then return true end
    local key = tostring(spell) .. "|" .. tostring(unit)
    local hit = rangeCache[key]
    if hit ~= nil then return hit end
    local r = C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(spell, unit)
    local ok = r ~= false   -- nil = can't tell, give it the benefit of the doubt
    rangeCache[key] = ok
    return ok
end

-- How reachable is a groupmate? "range" = inside helpful spell range, "near" = further off but around
-- (worth showing, they can walk over), "far" = another zone or a long way off (left out entirely).
-- UnitInRange can be a secret value in instances, so it is cleaned and UnitIsVisible is the fallback.
local FAR_OUT, FAR_IN, FAR_DELAY = 200, 150, 10   -- yards out, yards back in, seconds before dropping
local farSince = {}                                -- [name] = when it first looked far

local function Yards(unit)
    if not (LIB and LIB.Distance and LIB.MyPosition and C_Map and C_Map.GetPlayerMapPosition) then return nil end
    local myMap, myX, myY = LIB.MyPosition()
    if not myMap then return nil end
    local theirMap = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit(unit)
    if not theirMap then return nil end
    local pos = Clean(C_Map.GetPlayerMapPosition(theirMap, unit))
    if not pos then return nil end
    local x, y = pos:GetXY()
    if not x or (x == 0 and y == 0) then return nil end
    return LIB.Distance(myMap, myX, myY, theirMap, x, y), theirMap ~= myMap
end

local function Nearness(unit, name)
    if UnitIsUnit(unit, "player") then return "range" end
    local inRange = Clean(UnitInRange(unit))
    if inRange == true then farSince[name] = nil return "range" end

    -- Not in cast range: is it a short walk, or another part of the world?
    local far
    local yards, otherMap = Yards(unit)
    if yards then
        far = yards > (farSince[name] and FAR_IN or FAR_OUT)
    elseif otherMap then
        far = true                       -- position unreadable but a different map: another zone
    else
        far = not Clean(UnitIsVisible(unit))
    end

    if not far then farSince[name] = nil return "near" end
    -- Hysteresis: only drop someone who has looked far for a while; they come back the moment they're near.
    local since = farSince[name]
    if not since then farSince[name] = GetTime() return "near" end
    return (GetTime() - since >= FAR_DELAY) and "far" or "near"
end

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function ShortName(full)
    if LIB and LIB.ShortName then return LIB.ShortName(full) end
    return (full or "?"):match("^[^-]+") or full
end

local function FmtTime(s)
    if s >= 60 then return ("%dm"):format(math.floor(s / 60 + 0.5)) end
    return ("%ds"):format(math.floor(s))
end

local function FmtLong(s)
    s = math.floor(s)
    if s >= 60 then return ("%dm %02ds"):format(math.floor(s / 60), s % 60) end
    return ("%ds"):format(s)
end

-- When does a buff count as running out? The setting (5 minutes by default), but for a short buff at
-- most a tenth of its duration (never under a minute), so a 10-minute self-buff isn't orange half the time.
local function Expiring(a, short)
    if a.left == math.huge then return false end
    if short then
        -- short buffs scale from their own duration (e.g. 3-minute Battle Shout -> 18 s); unknown -> warnMin
        local warn = (a.dur and a.dur > 0) and a.dur * (short.warnPct or 0.1) or 0
        return a.left <= math.max(short.warnMin or 10, warn)
    end
    local warn = BW.db.threshold
    if a.dur and a.dur > 0 then warn = math.min(warn, math.max(60, a.dur * 0.1)) end
    return a.left <= warn
end

-- Well Fed is eaten, not cast. AutoFeed keeps a macro pointed at the best food in your bags, so when
-- it is installed the icon can use it; without it the icon is a reminder and nothing more.
local function FoodMacro()
    local name = (type(AutoFeedDB) == "table" and AutoFeedDB.macroName) or "AutoFeed"
    if GetMacroIndexByName and GetMacroIndexByName(name) ~= 0 then return name end
    return nil
end

-- ---------------------------------------------------------------------------
-- Weapon buffs (temporary enchants)
-- ---------------------------------------------------------------------------
-- These are item state, not auras, so they have none of the secret-aura restrictions: they can be read
-- in combat, which makes them the one thing BuffWarden can still tell you mid-fight.
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local WEAPON_WARN = 180      -- seconds left that count as running out (a stone lasts 30 minutes)
local WEAPON_SLOTS = {
    { slot = 0, inv = 16, key = "weaponmain", label = "Main hand" },
    { slot = 1, inv = 17, key = "weaponoff",  label = "Off hand" },
}

-- What is on this weapon: { left = seconds, icon = fileID } - left 0 means nothing on it.
-- nil means the slot has nothing to say (no such weapon slot, or the call isn't there).
local function WeaponEnchant(slot)
    if not (C_Item and C_Item.GetWeaponEnchantInfo) then return nil end
    local ok, list = pcall(C_Item.GetWeaponEnchantInfo, slot)
    if not ok or type(list) ~= "table" then return nil end
    local state = { left = 0 }
    -- The call returns one row per enchant slot, so we look for the row that has something on it
    -- rather than taking the first.
    for _, e in ipairs(list) do
        if Clean(e.hasEnchant) then
            state.left = (Clean(e.timeLeft) or 0) / 1000
            state.icon = Clean(e.enchantIconID)
            state.kind = Clean(e.enchantType)
            break
        end
    end
    return state
end

-- The weapon in this slot, if it can take a buff at all: no shields, no held items, no fishing poles.
local function EquippedWeapon(inv)
    local id = GetInventoryItemID("player", inv)
    if not id then return nil end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
    if classID ~= 2 or subClassID == BW.FISHING_POLE_SUBCLASS then return nil end
    return id, subClassID
end

-- The best stone or oil in the bags for this weapon. Stones are matched to the weapon type (blades get
-- sharpened, blunt weapons weighted); oils fit anything, so the preference decides between them.
local enhancerCache = {}       -- [subclass|preference] = item or false; dropped when the bags change

local poisonCache = {}         -- [kind] = item or false; same reason, same lifetime

function BW.ForgetEnhancers()
    wipe(enhancerCache)
    wipe(poisonCache)
end

-- The strongest poison of this kind in the bags ("any" = whatever is best of any kind).
local function BestPoison(kind)
    local cached = poisonCache[kind]
    if cached ~= nil then return cached or nil end
    local best, bestRank
    for bag = 0, LAST_BAG do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and Clean(info.itemID)
            local e = id and BW.POISONS[id]
            if e and (kind == "any" or e.kind == kind) then
                if not bestRank or e.rank > bestRank then
                    bestRank, best = e.rank, { id = id, kind = e.kind }
                end
            end
        end
    end
    poisonCache[kind] = best or false
    return best
end

-- For the settings: is there any point offering this poison? Bags change minute to minute, so the
-- option stays on the list and simply says when there is nothing to apply.
function BW.CarryPoison(kind)
    return BestPoison(kind) ~= nil
end

local function BestEnhancer(subClassID)
    local want = BW.WEAPON_KIND_BY_SUBCLASS[subClassID]
    local myClass = MyClass()
    local pref = BW.db.weaponPref
    -- Walking every bag slot is far too much work to repeat several times a second.
    local cacheKey = tostring(subClassID) .. "|" .. tostring(pref)
    local cached = enhancerCache[cacheKey]
    if cached ~= nil then return cached or nil end
    local wantOil = pref == "oil" or (pref ~= "stone" and BW.MANA_CLASSES[myClass] and true or false)
    local best, bestScore
    for bag = 0, LAST_BAG do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and Clean(info.itemID)
            local e = id and BW.WEAPON_ENHANCERS[id]
            if e and (e.kind == want or e.kind == "oil") then
                local score = e.rank + (((e.kind == "oil") == wantOil) and 100 or 0)
                if not bestScore or score > bestScore then
                    bestScore = score
                    best = { id = id, kind = e.kind }
                end
            end
        end
    end
    enhancerCache[cacheKey] = best or false
    return best
end

-- What we'd offer for this weapon slot, or nil when there is nothing to say.
local function WeaponEntry(w)
    local itemID, subClassID = EquippedWeapon(w.inv)
    if not itemID then return nil end
    local state = WeaponEnchant(w.slot)
    if not state then return nil end
    local missing = state.left <= 0
    local expiring = (not missing) and state.left <= WEAPON_WARN and state.left or nil
    if not missing and not expiring then return nil end

    local myClass = MyClass()
    local imbue, item
    if myClass == "SHAMAN" and w.slot == 0 then
        -- A shaman imbues the weapon with a spell. The imbue goes on the main hand, so only that one.
        local pref = BW.db.imbuePref
        imbue = (pref ~= "auto" and Knows(pref) and pref) or FirstKnown(BW.SHAMAN_IMBUES)
    elseif myClass == "ROGUE" then
        -- Rogues coat each weapon separately, and which poison goes where is the player's choice.
        local pref = (w.slot == 0) and BW.db.poisonMain or BW.db.poisonOff
        if pref == "none" then return nil end
        item = BestPoison(pref == "auto" and BW.POISON_AUTO[w.slot] or pref)
        -- Asked for one they don't carry: offer what they do have rather than going quiet.
        if not item then item = BestPoison("any") end
    end
    if not imbue and not item then item = BestEnhancer(subClassID) end
    if not imbue and not item then return nil end   -- nothing usable: never nag

    -- One rule for the picture, used by the bar and by the in-combat readout alike, so it doesn't
    -- change when the fight starts: nothing on the weapon -> the icon of what we would put on;
    -- something on it and running out -> that enchant's own icon, since that is what's counting down.
    local icon
    if missing then
        icon = (imbue and C_Spell.GetSpellTexture(imbue))
            or (item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item.id))
    else
        icon = state.icon
    end
    local itemName = item and (C_Item.GetItemNameByID and C_Item.GetItemNameByID(item.id))
    return {
        key = w.key, mode = "weapon", slot = w, expiring = expiring, reachable = true,
        spell = imbue or itemName or "Weapon buff",
        imbue = imbue, item = item, itemName = itemName,
        left = state.left, missing = missing,
        icon = icon or FALLBACK_ICON,
        label = w.label,
    }
end

-- Every aura name BuffWarden cares about, and the instance IDs of those auras as last seen, so an
-- aura event about anything else (debuffs, procs, trinkets) can be ignored without a rescan.
local watchedNames
local watchedIDs = {}
local function IsWatchedName(name)
    if not watchedNames then
        watchedNames = {}
        for _, def in ipairs(BW.BUFFS) do
            for _, n in ipairs(def.names) do watchedNames[n] = true end
        end
    end
    return watchedNames[name]
end

-- Addon restrictions (combat, encounters, restricted maps...) make aura data secret, and on this client
-- asking for a secret aura is a Lua error for addon code, not a secret value. So we ask first, and while
-- auras are secret BuffWarden doesn't look at all.
local function AurasSecret()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() or false
end

local function AuraIndexSecret(unit, i)
    return C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret
        and C_Secrets.ShouldUnitAuraIndexBeSecret(unit, i, "HELPFUL") or false
end

-- All helpful auras on a unit, by name: { left = seconds or math.huge, source = unit or nil (unknown) }.
-- Second return: true when some aura couldn't be read (secret), so this unit's buffs are unknown.
local function ReadAuras(unit)
    local out, unreadable = {}, false
    if AurasSecret() then return out, true end
    local now = GetTime()
    for i = 1, 60 do
        local a
        if AuraIndexSecret(unit, i) then
            unreadable = true            -- skip it, but keep going: later indexes may be readable
        else
            a = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
            if not a then break end
        end
        local name = a and Clean(a.name)
        if not a then
            -- secret index, already noted
        elseif not name then
            unreadable = true
        else
            local exp = Clean(a.expirationTime) or 0
            out[name] = {
                dur = Clean(a.duration),
                left = (exp > 0) and (exp - now) or math.huge,
                source = Clean(a.sourceUnit),
                icon = Clean(a.icon),
            }
            local id = Clean(a.auraInstanceID)
            if id and IsWatchedName(name) then watchedIDs[id] = true end
        end
    end
    return out, unreadable
end

-- The first matching aura that still has enough time left. Returns found, secondsLeftIfExpiring.
local function HasBuff(auras, names, short)
    local best
    for _, n in ipairs(names) do
        local a = auras[n]
        if a then
            if not Expiring(a, short) then return true end
            best = math.max(best or 0, a.left)
        end
    end
    return false, best
end

-- ---------------------------------------------------------------------------
-- Group scan
-- ---------------------------------------------------------------------------
local function GroupUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end
    return units
end

-- Do we need anyone else's buffs, or only our own? Only two things look at a groupmate's auras: a group
-- buff (or blessing) WE can cast, and a talent buff we might ask for, which we only offer once someone
-- is seen carrying it. A rogue in a 40-man raid therefore reads one unit instead of forty.
local function NeedGroupAuras(providers, myClass)
    for _, def in ipairs(BW.BUFFS) do
        if BuffEnabled(def) then
            if (def.scope == "group" or def.scope == "blessing")
                and def.class == myClass and FirstKnown(def.cast) then return true end
            if def.talent and providers[def.class] then return true end
        end
    end
    return false
end

-- Everyone we can see: { unit, name, class, near, auras }. Plus the online providers per class.
local function ScanGroup()
    local myClass = MyClass()
    local members, providers = {}, {}
    wipe(watchedIDs)
    local seen = {}

    -- First pass: who is here, which class, and how far away. No aura reads yet.
    for _, u in ipairs(GroupUnits()) do
        if UnitExists(u) and UnitIsConnected(u) then
            local _, class = UnitClass(u)
            local isMe = UnitIsUnit(u, "player")
            local name = GetUnitName(u, true) or u
            seen[name] = true
            local near = Nearness(u, name)
            local skip = BW.db.ignoreFar and near == "far"
            if class and not isMe and not skip then
                providers[class] = providers[class] or {}
                table.insert(providers[class], u)
            end
            if not skip and not UnitIsDeadOrGhost(u) and (isMe or UnitIsVisible(u)) then
                members[#members + 1] = {
                    order = #members + 1,        -- group order, so the queue doesn't jump about
                    unit = isMe and "player" or u,
                    name = name,
                    class = class,
                    isMe = isMe,
                    near = near,   -- "range" or "near"; far ones aren't here at all
                }
            end
        end
    end
    for name in pairs(farSince) do
        if not seen[name] then farSince[name] = nil end   -- left the group
    end

    -- Second pass: auras, for ourselves always and for the others only when they matter.
    local others = NeedGroupAuras(providers, myClass)
    for _, m in ipairs(members) do
        if m.isMe or others then
            m.auras, m.unreadable = ReadAuras(m.unit)
        else
            -- not read, so never flagged as missing anything
            m.auras, m.unreadable = {}, true
        end
    end
    return members, providers
end

-- ---------------------------------------------------------------------------
-- Blessings: who gets which
-- ---------------------------------------------------------------------------
-- A paladin can keep one blessing on each person, so the question is never "is any blessing up" but
-- "is OURS up, and is it the one we would choose". BlessingFor answers the second half in order of
-- how much we trust the signal: what the player said, then what we know about ourselves, then the
-- group's roles, then the class default - and it returns the reason with the spell, so the tooltip
-- can always say why.
-- ---------------------------------------------------------------------------
local function Eligible(def, m)
    if def.who == "mana" then return BW.MANA_CLASSES[m.class] end
    return true
end

-- The blessing this member should get from us, and why. Returns spell, reason - the reason goes in the
-- tooltip, so a choice you disagree with is visible and can be changed with /bwarden bless.
local function KindSpell(kind)
    local k = kind and BW.BLESSING_KINDS[kind]
    local spell = k and k.spell
    return (spell and Knows(spell)) and spell or nil
end

-- The blessings this paladin has actually trained, for the settings to offer. "auto" is always
-- there: it means "follow the rules", which works at any level.
function BW.KnownBlessingKinds()
    local out = { "auto" }
    for _, kind in ipairs(BW.BLESSING_ORDER) do
        if KindSpell(kind) then out[#out + 1] = kind end
    end
    return out
end

local function PrettyClass(class)
    return class and (class:sub(1, 1) .. class:sub(2):lower()) or "?"
end

local function BlessingFor(m)
    -- 1. What the player decided for this character, by full name.
    local spell = KindSpell(m.name and BW.db.blessFor[m.name])
    if spell then return spell, "you chose this for " .. ShortName(m.name) end

    -- 2. What the player decided for the whole class.
    spell = KindSpell(m.class and BW.db.blessForClass[m.class])
    if spell then return spell, "you chose this for every " .. PrettyClass(m.class) end

    -- 3. Kings to everyone, if that is what the player asked for.
    if BW.db.blessKings then
        spell = KindSpell("kings")
        if spell then return spell, "you asked for Kings for everyone" end
    end

    -- 4. Ourselves, where we are not guessing: we can read our own spellbook. A paladin who has
    -- trained the healer talents wants Wisdom; every other paladin is meleeing, whether he is
    -- tanking in a dungeon or grinding alone, and wants Might. Gear deliberately isn't used here -
    -- a shield would call a holy paladin a tank, and Might on a healer is worth nothing.
    if m.isMe then
        local me = BW.Me()
        if me.role == "healer" then
            spell = KindSpell("wisdom")
            if spell then
                return spell, ("%d points in %s, so you're healing"):format(me.spec.points, me.spec.name)
            end
        elseif me.role then
            spell = KindSpell("might")
            if spell then
                return spell, ("%d points in %s, so mana isn't your first problem")
                    :format(me.spec.points, me.spec.name)
            end
        else
            -- No points spent yet, or the client won't say. The trained spells are the weaker
            -- signal and the gear is no signal at all here, since a shield and a two-hander both
            -- end at Might.
            local sign = FirstKnown(BW.PALADIN_HEALER_SIGNS)
            if sign then
                spell = KindSpell("wisdom")
                if spell then return spell, ("you trained %s, so you're healing"):format(sign) end
            end
            spell = KindSpell("might")
            if spell then return spell, "no talents spent yet, and you're the one meleeing" end
        end
    end

    -- 5. The role, when the group has roles at all (Forever may not: then this simply never fires,
    -- and the class defaults below carry the whole rule on their own).
    local role = m.unit and UnitGroupRolesAssigned and Clean(UnitGroupRolesAssigned(m.unit))
    if role == "TANK" then
        -- No Sanctuary in Forever, so a tank gets the next best thing.
        spell = KindSpell("kings") or KindSpell("might")
        if spell then return spell, "marked as tank in the group" end
    elseif role == "HEALER" then
        spell = KindSpell("wisdom")
        if spell then return spell, "marked as healer in the group" end
    end

    -- 6. The class default: what they want once we know it, otherwise what we can give them now.
    local byClass = m.class and BW.BLESSING_BY_CLASS[m.class]
    if byClass then
        spell = KindSpell(byClass.kind)
        if spell then return spell, byClass.why end
        -- Their blessing isn't trained yet. The reason is its own sentence rather than the class
        -- reason with a clause bolted on, which reads as nonsense ("hunters burn mana until you
        -- learn Wisdom"), and it says plainly that this is temporary.
        spell = KindSpell(byClass.fallback)
        if spell then
            return spell, ("they want %s, which you haven't learned yet"):format(
                (BW.BLESSING_KINDS[byClass.kind].spell):gsub("^Blessing of ", ""))
        end
    end

    -- 7. Neither their blessing nor its fallback is trained yet: give them whatever we do have, and
    -- say so, rather than showing nothing and looking broken.
    spell = FirstKnown({ "Blessing of Might", "Blessing of Wisdom", "Blessing of Kings",
        "Blessing of Salvation", "Blessing of Light" })
    return spell, spell and "the only blessing you know that fits" or nil
end

-- Blessings stack one per paladin, so another paladin's Kings never fills OUR slot on a target. This
-- asks only about our own blessing: is a blessing we cast on them, or - when the game won't say who cast
-- it - is the very spell we would cast already there? (Only then do we leave it alone; anything else is
-- someone else's blessing and ours is still missing.)
local function HasMyBlessing(m, mySpell)
    if m.unreadable then return true end
    for _, n in ipairs(BW.BLESSING_NAMES) do
        local a = m.auras[n]
        if a and not Expiring(a) then
            if a.source and UnitIsUnit(a.source, "player") then return true end
            if not a.source and n == mySpell then return true end
        end
    end
    return false
end

-- A blessing on us from someone else: another paladin's, or one of unknown caster that isn't the spell
-- we would cast ourselves. Returns count and the callers we could identify.
local function BlessingsFromOthers(m, mySpell)
    local count, from = 0, {}
    for _, n in ipairs(BW.BLESSING_NAMES) do
        local a = m.auras[n]
        if a and not Expiring(a) then
            local mine = (a.source and UnitIsUnit(a.source, "player")) or (not a.source and n == mySpell)
            if not mine then
                count = count + 1
                if a.source then from[#from + 1] = a.source end
            end
        end
    end
    return count, from
end

-- Groupmates of the buff's class who could plausibly cast it: high enough level, and for a talent,
-- only once someone in the group is seen carrying the buff.
local function Providers(def, list, members)
    if not list then return nil end
    if def.talent then
        local seen = false
        for _, m in ipairs(members) do
            for _, n in ipairs(def.names) do if m.auras[n] then seen = true end end
        end
        if not seen then return nil end
    end
    local out = {}
    for _, u in ipairs(list) do
        local lvl = Clean(UnitLevel(u))
        if not lvl or lvl <= 0 or lvl >= (def.minLevel or 1) then out[#out + 1] = u end
    end
    return #out > 0 and out or nil
end

-- Short buffs (Battle Shout) only when their own conditions hold: in a group, and enough of the power
-- they cost right now. Long buffs always pass.
local function ShortBuffAllowed(def)
    local sb = def.short
    if not sb then return true end
    if sb.groupOnly and not IsInGroup() then return false end
    if sb.power then
        local have = Clean(UnitPower("player", Enum.PowerType[sb.power == "RAGE" and "Rage" or sb.power]))
        if not have or have < (sb.cost or 0) then return false end
    end
    return true
end

local blessButtons = {}   -- declared here: SetStale below dims them too
local justBuffed = {}      -- [name] = when the optimistic "already done" mark expires
local retryFirst = {}      -- [name] = true: a cast that failed goes back to the FRONT of the queue

local function BuffedRecently(name)
    local until_ = justBuffed[name]
    if not until_ then return false end
    if GetTime() > until_ then justBuffed[name] = nil return false end
    return true
end

-- { { kind, spell, targets = { member, ... } }, ... } in BLESSING_ORDER, only blessings we know and
-- only where someone actually needs one. Targets keep group order, except a failed cast comes first.
local function BlessingPlan(members)
    local byKind = {}
    for _, m in ipairs(members) do
        local spell, why = BlessingFor(m)
        if spell and not HasMyBlessing(m, spell) and not BuffedRecently(m.name) then
            for kind, info in pairs(BW.BLESSING_KINDS) do
                if info.spell == spell then
                    byKind[kind] = byKind[kind] or {}
                    m.why = why
                    table.insert(byKind[kind], m)
                end
            end
        end
    end
    -- Nobody needs anything: no row at all. The row is a job list, so an empty one is noise - a
    -- solo paladin who just blessed himself should see nothing, not a line of dimmed icons that
    -- reads as "you're missing these".
    if not next(byKind) then return {} end

    local plan = {}
    for _, kind in ipairs(BW.BLESSING_ORDER) do
        local spell = KindSpell(kind)
        if spell then                      -- one button per blessing you actually know
            local list = byKind[kind] or {}
            -- a cast that failed (out of range, immune, moving) is tried again first
            table.sort(list, function(a, b)
                local ra, rb = retryFirst[a.name] and 1 or 0, retryFirst[b.name] and 1 or 0
                if ra ~= rb then return ra > rb end
                return (a.order or 0) < (b.order or 0)
            end)
            plan[#plan + 1] = {
                kind = kind, spell = spell, targets = list,
                -- Once the row is up you get every blessing you know, so you can always overrule the
                -- rules by hand. This one nobody asked for: dimmed, no count, no name, and a click
                -- puts it on whoever you point at.
                spare = #list == 0,
            }
        end
    end
    return plan
end

-- ---------------------------------------------------------------------------
-- What is missing
-- ---------------------------------------------------------------------------
-- Builds the list of things to show. Each entry:
--   { key, def, mode = "cast"|"ask", spell, icon, targets = {member...}, target, providers = {unit...}, expiring }
function BW:Compute()
    wipe(rangeCache)
    local members, providers = ScanGroup()
    local myClass = MyClass()
    local me
    for _, m in ipairs(members) do if m.isMe then me = m end end
    local entries = {}
    if not me then return entries end

    for _, def in ipairs(BW.BUFFS) do
        if BuffEnabled(def) then
            local mine = def.class == myClass and FirstKnown(def.cast)

            if def.scope == "food" then
                if not me.unreadable then
                    local ok, left = HasBuff(me.auras, def.names)
                    if not ok then
                        entries[#entries + 1] = { key = def.key, def = def, mode = "food",
                            spell = "Well Fed", macro = FoodMacro(), expiring = left, reachable = true }
                    end
                end

            elseif def.scope == "self" then
                if mine and not me.unreadable and ShortBuffAllowed(def) then
                    local ok, left = HasBuff(me.auras, def.names, def.short)
                    if not ok then
                        entries[#entries + 1] = { key = def.key, def = def, mode = "cast", spell = mine,
                            targets = { me }, target = me, expiring = left }
                    end
                end

            elseif def.scope == "group" then
                if mine then
                    local missing, target, expiring = {}, nil, nil
                    for _, m in ipairs(members) do
                        if Eligible(def, m) and not m.unreadable then
                            local ok, left = HasBuff(m.auras, def.names)
                            if not ok then
                                missing[#missing + 1] = m
                                if m.isMe then expiring = left end
                                if not target and m.near == "range" and InRange(mine, m.unit) then target = m end
                            end
                        end
                    end
                    if #missing > 0 then
                        entries[#entries + 1] = { key = def.key, def = def, mode = "cast", spell = mine,
                            targets = missing, target = target or missing[1], expiring = expiring }
                    end
                elseif Eligible(def, me) and not me.unreadable then
                    local who = Providers(def, providers[def.class], members)
                    local ok, left = HasBuff(me.auras, def.names)
                    if who and not ok then
                        entries[#entries + 1] = { key = def.key, def = def, mode = "ask", spell = def.cast[1],
                            providers = who, expiring = left }
                    end
                end

            elseif def.scope == "blessing" then
                -- As a paladin with the row on, the row shows this instead of one lumped icon.
                if def.class == myClass and BW.db.blessRow and FirstKnown(def.cast) then
                    BW.blessPlan = BlessingPlan(members)
                elseif def.class == myClass and FirstKnown(def.cast) then
                    local missing, target = {}, nil
                    for _, m in ipairs(members) do
                        if not HasMyBlessing(m, (BlessingFor(m))) then
                            missing[#missing + 1] = m
                            if not target and InRange(BlessingFor(m) or "", m.unit) then target = m end
                        end
                    end
                    if #missing > 0 then
                        target = target or missing[1]
                        local spell, why = BlessingFor(target)
                        entries[#entries + 1] = { key = def.key, def = def, mode = "cast",
                            spell = spell, why = why, targets = missing, target = target }
                    end
                end
                -- From the other paladins: you should carry one blessing from each of them.
                local pals = Providers(def, providers.PALADIN, members)
                if pals and not me.unreadable then
                    local have, from = BlessingsFromOthers(me, myClass == "PALADIN" and BlessingFor(me) or nil)
                    if have < #pals and #from == have then
                        local ask = {}
                        for _, p in ipairs(pals) do
                            local gave = false
                            for _, s in ipairs(from) do if UnitIsUnit(s, p) then gave = true end end
                            if not gave then ask[#ask + 1] = p end
                        end
                        entries[#entries + 1] = { key = def.key .. ":ask", def = def, mode = "ask",
                            spell = "a Blessing", providers = ask }
                    end
                end
            end
        end
    end

    if not (myClass == "PALADIN" and BW.db.blessRow) then BW.blessPlan = nil end

    if BW.db.weaponBuffs then
        for _, w in ipairs(WEAPON_SLOTS) do
            local e = WeaponEntry(w)
            if e then entries[#entries + 1] = e end
        end
    end

    -- Nobody in casting range? The icon is dimmed a little: still worth seeing, not actionable yet.
    for _, e in ipairs(entries) do
        if e.mode == "weapon" or e.mode == "food" then
            -- always actionable: it's about you
        elseif e.mode == "cast" and e.targets then
            e.reachable = false
            for _, m in ipairs(e.targets) do
                if m.near == "range" and InRange(e.spell, m.unit) then e.reachable = true end
            end
        else
            e.reachable = true
        end
    end
    -- Icons: the exact spell we'd cast, else the buff's own spell texture. Weapon entries brought theirs.
    -- A lookup can come back empty while the client is still fetching the spell, so fall back rather
    -- than showing an empty square.
    for _, e in ipairs(entries) do
        if e.mode == "food" then
            e.icon = BW.IconFor(e.def)
        elseif e.mode ~= "weapon" then
            e.icon = (e.mode == "cast" and C_Spell.GetSpellTexture(e.spell)) or BW.IconFor(e.def)
                or FALLBACK_ICON
        end
    end
    return entries
end

-- The buff's real spell icon, looked up by ID so it works for spells you can't cast yourself.
function BW.IconFor(def)
    return (def.spellID and C_Spell.GetSpellTexture(def.spellID)) or def.icon
end

local function SpellName(def)
    return (def.spellID and C_Spell.GetSpellName(def.spellID)) or def.cast[1] or def.names[1] or def.key
end

-- What the bar shows while unlocked: your class's real buffs, plus group buffs you'd get from others,
-- in each of the looks the bar can have. Placeholders only; they don't click.
function BW:BuildPreview()
    local myClass = MyClass()
    local out, doneGroup, doneSelf = {}, false, false
    for _, def in ipairs(BW.BUFFS) do
        if def.class == myClass and BuffEnabled(def) then
            local e = { mode = "cast", spell = SpellName(def), icon = BW.IconFor(def), targets = { {} } }
            if def.scope ~= "self" and not doneGroup then
                doneGroup = true
                e.targets = { {}, {}, {} }
                e.preview = "A buff you can cast. The number is how many in your group are missing it; "
                    .. "click casts it on the nearest one."
            elseif def.scope == "self" and not doneSelf then
                doneSelf = true
                e.expiring = 45
                e.preview = "Running out soon (orange, with the time left). Click to recast."
            else
                e.preview = "You're missing this one. Click to cast it."
            end
            out[#out + 1] = e
        end
    end
    for _, def in ipairs(BW.BUFFS) do
        if #out >= 5 then break end
        if def.class and def.class ~= myClass and (def.scope == "group" or def.scope == "blessing")
            and BuffEnabled(def) then
            out[#out + 1] = { mode = "ask", spell = SpellName(def), icon = BW.IconFor(def),
                preview = "A groupmate has this buff (grey). Click whispers them to ask for it." }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The blessing row (paladins)
-- ---------------------------------------------------------------------------
-- One button per blessing you know. Each shows how many people your rules say want it and don't have
-- it from you, and who the next click will buff. The rules (and /bwarden bless) still decide who wants
-- what; this row is only a fast way to do it.

-- ---------------------------------------------------------------------------
-- The bar
-- ---------------------------------------------------------------------------
-- Asking is a plain whisper we build ourselves: our own sentence, the spell name from our own data and
-- the groupmate's name from the client. Nothing here can be triggered from outside the game, and the
-- same person can't be asked for the same buff more often than ASK_COOLDOWN.
local askedAt = {}

local function AskFor(unit, spell)
    if not (unit and spell) or not UnitExists(unit) then return end
    local name = GetUnitName(unit, true)
    if not name or name == "" then return end
    local key = name .. "|" .. spell
    local now = GetTime()
    if askedAt[key] and now - askedAt[key] < ASK_COOLDOWN then
        local who = (LIB and LIB.ShortName and LIB.ShortName(name)) or name
        print(TAG .. ": already asked " .. who .. " for " .. spell .. " - give them a moment.")
        return
    end
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        print(TAG .. ": can't whisper right now (the game is holding chat back).")
        return
    end
    askedAt[key] = now
    -- audit: user-initiated (only the ask button's OnClick calls this) and rate-limited by askedAt
    SendChatMessage(ASK_TEXT:format(spell), "WHISPER", nil, name)
end
local SIZE, GAP = 36, 4
local ROW_H = SIZE + 14 + GAP   -- a row is an icon plus the line of text under it

-- Where icon number `index` goes, counting the bar's icons and the blessing buttons as one run, so
-- they read as a single row (and wrap together when there are more than the player allows per line).
local function PlaceIcon(frame, index, anchor)
    local perRow = math.max(2, BW.db and BW.db.perRow or 12)
    local col, row = (index - 1) % perRow, math.floor((index - 1) / perRow)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", anchor, "TOPLEFT", col * (SIZE + GAP), -row * ROW_H)
end

local function GridSize(count)
    local perRow = math.max(2, BW.db and BW.db.perRow or 12)
    local cols = math.min(perRow, math.max(1, count))
    local rows = math.max(1, math.ceil(math.max(1, count) / perRow))
    return cols * (SIZE + GAP) - GAP, rows * ROW_H - GAP
end
local holder, bar, handle
local buttons = {}

-- Always pinned by its top-left corner, so the first icon stays put and the row grows to the right.
-- (StopMovingOrSizing re-anchors to whatever point is nearest, often CENTER or RIGHT; a bar anchored
-- like that shrinks toward the middle or the right when fewer icons are shown.)
local function SavePosition(byUser)
    if InCombatLockdown() then return end
    if byUser then BW.db.placed = true end
    local l, t = bar:GetLeft(), bar:GetTop()
    if not (l and t) then return end
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
    BW.db.point = { "TOPLEFT", "BOTTOMLEFT", l, t }
end

local function ButtonOnEnter(self)
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(e.spell, 1, 0.82, 0.3)
    if BW.stale and not e.preview then
        GameTooltip:AddLine("As of the pull - buffs can't be read in combat. Updates when combat ends.",
            0.6, 0.6, 0.6, true)
    end
    if e.preview then
        GameTooltip:AddLine(e.preview, 1, 1, 1, true)
        GameTooltip:AddLine("Preview - drag to move, /bwarden lock when done.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
        return
    end
    if e.expiring then
        GameTooltip:AddLine(e.spell .. " runs out in " .. FmtLong(e.expiring), 1, 0.6, 0.2)
    end
    if e.mode == "food" then
        GameTooltip:AddLine(e.expiring and "Running out on you." or "You're not Well Fed.", 1, 1, 1)
        if e.macro then
            GameTooltip:AddLine("Click: eat your best food (AutoFeed's " .. e.macro .. " macro)", 0.4, 1, 0.4)
        else
            GameTooltip:AddLine("Eat something that gives Well Fed.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
        return
    end
    if e.mode == "weapon" then
        GameTooltip:AddLine(e.label .. ": " .. (e.expiring and "running out" or "no weapon buff"), 1, 1, 1)
        if e.imbue then
            GameTooltip:AddLine("Click: cast " .. e.imbue, 0.4, 1, 0.4)
        elseif e.itemName then
            GameTooltip:AddLine("Click: use " .. e.itemName .. " from your bags", 0.4, 1, 0.4)
        end
        GameTooltip:AddLine("Readable in combat, unlike other buffs.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
        return
    end
    if e.mode == "cast" then
        if #e.targets == 1 and e.targets[1].isMe then
            GameTooltip:AddLine("You're missing it.", 1, 1, 1)
        else
            GameTooltip:AddLine("Missing on " .. #e.targets .. ":", 1, 1, 1)
            for _, m in ipairs(e.targets) do
                local line = (LIB and LIB.ColorName(m.name, m.class) or m.name)
                if m.near ~= "range" or not InRange(e.spell, m.unit) then
                    line = line .. " |cff888888(out of range)|r"
                end
                GameTooltip:AddLine("  " .. line)
            end
        end
        GameTooltip:AddLine("Click: cast on " .. (e.target.isMe and "yourself" or e.target.name), 0.4, 1, 0.4)
        if e.why then
            GameTooltip:AddLine(e.spell:gsub("^Blessing of ", "") .. " - " .. e.why, 0.7, 0.7, 0.8, true)
        end
    else
        GameTooltip:AddLine("You're missing it. Can be given by:", 1, 1, 1)
        for _, u in ipairs(e.providers) do
            local _, c = UnitClass(u)
            local n = GetUnitName(u, true) or "?"
            GameTooltip:AddLine("  " .. (LIB and LIB.ColorName(n, c) or n))
        end
        if e.providers[1] then
            GameTooltip:AddLine("Click: whisper " .. (GetUnitName(e.providers[1], true) or "?") .. " to ask",
                0.4, 1, 0.4)
        end
    end
    GameTooltip:Show()
end

local function MakeButton(i)
    local b = CreateFrame("Button", "BuffWardenButton" .. i, bar, "SecureActionButtonTemplate")
    b:SetSize(SIZE, SIZE)
    b:RegisterForClicks("AnyUp", "AnyDown")

    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetAllPoints()
    b.border:SetColorTexture(1, 1, 1)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.timer = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Under the icon, not across the artwork: the picture stays readable and the number has room.
    b.timer:SetPoint("TOP", b, "BOTTOM", 0, -1)
    b.timer:SetWidth(SIZE + GAP * 2)
    b.timer:SetWordWrap(false)
    -- In combat every aura is secret to addons, so the bar can't know what changed: it keeps the state
    -- from the pull and wears this clock until combat ends. Plain textures, so they may change in combat.
    b.stale = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.stale:SetSize(14, 14)
    b.stale:SetPoint("BOTTOMLEFT", 1, 1)
    b.stale:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    b.stale:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.stale:Hide()

    -- HookScript, never SetScript: SecureActionButtonTemplate installs its own OnClick, and replacing
    -- it stops every cast. The hook runs after it, and only asks when this button is an "ask" (a cast
    -- button has no self.ask and its secure attributes did the work).
    b:HookScript("OnClick", function(self, _, down)
        if down then return end          -- the buttons take both down and up: ask once, on the up
        local ask = self.ask
        if ask then AskFor(ask.unit, ask.spell) end
    end)
    b:SetScript("OnEnter", ButtonOnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- While unlocked the whole bar can be dragged by any of its (preview) buttons.
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function() BW:StartDrag() end)
    b:SetScript("OnDragStop", function() bar:StopMovingOrSizing(); SavePosition(true) end)
    buttons[i] = b
    return b
end

function BW:CreateBar()
    -- The holder carries the combat state driver; the bar inside it is shown/hidden by us (out of combat).
    holder = CreateFrame("Frame", "BuffWardenHolder", UIParent, "SecureHandlerStateTemplate")
    holder:SetAllPoints(UIParent)

    bar = CreateFrame("Frame", "BuffWardenBar", holder)
    bar:SetSize(SIZE, SIZE)
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:SetScale(self.db.scale)
    local p = self.db.point
    if p then bar:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else bar:SetPoint("CENTER", UIParent, "CENTER", 0, -180) end
    SavePosition()   -- converts an older saved anchor (or the default) to top-left

    -- Unlocked marker: a blue outline drawn exactly on the icons (nothing sticks out past them, so the
    -- icons themselves meet the screen edge). Mouse goes straight through to the buttons, which drag.
    handle = CreateFrame("Frame", nil, bar)
    handle:SetAllPoints()
    handle:SetFrameLevel(bar:GetFrameLevel() + 10)
    local function Edge(p1, p2, w, h)
        local t = handle:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(0.3, 0.65, 1, 0.9)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if w then t:SetWidth(w) else t:SetHeight(h) end
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 2)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
    Edge("TOPLEFT", "BOTTOMLEFT", 2)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 2)
    -- The gaps between icons drag too.
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() BW:StartDrag() end)
    bar:SetScript("OnDragStop", function() bar:StopMovingOrSizing(); SavePosition(true) end)

    self:ApplyCombatSetting()
end

-- The bar holds secure buttons, so it can't be moved in combat (only reachable when the bar is set
-- to stay visible in combat).
function BW:StartDrag()
    if self.db.locked then return end
    if InCombatLockdown() then
        print(TAG .. ": the bar can't be moved during combat.")
        return
    end
    bar:StartMoving()
end

function BW:ApplyCombatSetting()
    if InCombatLockdown() then self.combatDirty = true return end
    if self.db.hideInCombat then
        RegisterStateDriver(holder, "visibility", "[combat] hide; show")
    else
        UnregisterStateDriver(holder, "visibility")
        holder:Show()
    end
end

-- Marks the bar as "as of the pull" (in combat) or live again. Only non-protected visuals change here.
function BW:SetStale(stale)
    if blessButtons then
        for _, b in ipairs(blessButtons) do
            b.stale:SetShown(stale and b:IsShown())
            b.icon:SetAlpha(stale and 0.55 or 1)
        end
    end
    self.stale = stale and true or nil
    for _, b in ipairs(buttons) do
        b.stale:SetShown(stale and b.entry ~= nil and not b.entry.preview)
        local reachable = not (b.entry and b.entry.reachable == false)
        b.shownAlpha = stale and 0.55 or (reachable and 1 or 0.6)
        b.icon:SetAlpha(b.shownAlpha)
        b.border:SetAlpha(stale and 0.5 or 1)
    end
end

local COLORS = {
    cast     = { 1, 0.82, 0.3 },       -- gold: you can fix this yourself
    ask      = { 0.4, 0.55, 0.7 },     -- steel: someone else has it
    expiring = { 1, 0.45, 0.1 },       -- orange: running out
    weapon   = { 0.64, 0.24, 0.90 },   -- purple, the colour the game gives a weapon enchant
    food     = { 1, 0.82, 0.3 },       -- gold: eating is yours to fix too
}

function BW:Apply(entries)
    if InCombatLockdown() then self.dirty = true return end
    self.dirty = nil
    local unlocked = not self.db.locked
    if unlocked then entries = self:BuildPreview() end

    for i, e in ipairs(entries) do
        local b = buttons[i] or MakeButton(i)
        b.entry = e
        PlaceIcon(b, i, bar)
        -- Only push what actually differs: a refresh every few seconds otherwise churns textures
        -- and font strings for nothing.
        if b.shownIcon ~= e.icon then b.shownIcon = e.icon; b.icon:SetTexture(e.icon) end
        local desat = e.mode == "ask"
        if b.shownDesat ~= desat then b.shownDesat = desat; b.icon:SetDesaturated(desat) end
        local alpha = (e.reachable == false) and 0.6 or 1
        if b.shownAlpha ~= alpha then b.shownAlpha = alpha; b.icon:SetAlpha(alpha) end
        -- A weapon buff keeps its purple, the way the game shows it; the countdown turns orange instead.
        -- COLORS.cast as the last resort: a mode without its own colour must never break the bar.
        local c = (e.mode == "weapon" and COLORS.weapon) or (e.expiring and COLORS.expiring)
            or COLORS[e.mode] or COLORS.cast
        if b.shownColor ~= c then b.shownColor = c; b.border:SetVertexColor(c[1], c[2], c[3]) end
        local count = (e.mode == "cast" and e.targets and #e.targets > 1) and tostring(#e.targets) or ""
        if b.shownCount ~= count then b.shownCount = count; b.count:SetText(count) end
        local timer = e.expiring and FmtTime(e.expiring) or ""
        if b.shownTimer ~= timer then
            b.shownTimer = timer
            b.timer:SetText(timer)
            local t = e.expiring and COLORS.expiring or COLORS.cast
            b.timer:SetTextColor(t[1], t[2], t[3])
        end

        -- Click action. Casting needs the secure attributes (only touched when they actually change);
        -- asking is our own throttled whisper, so it needs no attributes at all.
        local typ, spell, unit
        b.ask = nil
        local macro, macroName
        if e.preview then
            -- placeholders get no click action at all: nothing pretend can reach a macro
        elseif e.mode == "food" then
            if e.macro then typ, macroName = "macro", e.macro end
        elseif e.mode == "weapon" then
            if e.imbue then
                typ, spell = "spell", e.imbue          -- a shaman imbue goes on the weapon by itself
            elseif e.item then
                typ, macro = "macro", ("/use item:%d\n/use %d"):format(e.item.id, e.slot.inv)
            end
        elseif e.mode == "cast" then
            typ, spell, unit = "spell", e.spell, e.target.unit
        elseif e.providers[1] then
            b.ask = { unit = e.providers[1], spell = e.spell }
        end
        local action = (typ or "") .. "|" .. (spell or "") .. "|" .. (unit or "") .. "|" .. (macro or "")
            .. "|" .. (macroName or "")
        if b.action ~= action then
            b.action = action
            b:SetAttribute("type", typ)
            b:SetAttribute("spell", spell)
            b:SetAttribute("unit", unit)
            b:SetAttribute("macrotext", macro)
            b:SetAttribute("macro", macroName)
        end
        b:Show()
    end
    for i = #entries + 1, #buttons do
        buttons[i].entry = nil
        buttons[i]:Hide()
    end

    local n = #entries
    -- The blessing buttons continue the same run, so they count towards the grid the bar covers.
    BW.nextSlot = n + 1
    local total = n + ((not unlocked and BW.blessPlan) and #BW.blessPlan or 0)
    local w, h = GridSize(total)
    bar:SetWidth(w)
    bar:SetHeight(h)
    handle:SetShown(unlocked)
    bar:EnableMouse(unlocked)
    -- The countdown sits under the icons, so keep that line on screen too (a negative bottom inset
    -- grows the area the bar is clamped inside).
    bar:SetClampRectInsets(0, 0, 0, -14)
    -- The blessing buttons live in the bar now, so the bar has to stay up for them even when there is
    -- nothing else to show.
    local blessing = (not unlocked and BW.blessPlan) and #BW.blessPlan or 0
    bar:SetShown(n > 0 or blessing > 0)
end

-- ---------------------------------------------------------------------------
-- The blessing row's buttons
-- ---------------------------------------------------------------------------
local function BlessTooltip(self)
    local p = self.plan
    if not p then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(p.spell, 1, 0.82, 0.3)
    if BW.stale then
        GameTooltip:AddLine("As of the pull - buffs can't be read in combat.", 0.6, 0.6, 0.6, true)
    end
    if p.spare then
        GameTooltip:AddLine("Nobody needs this one by the rules.", 1, 1, 1)
        GameTooltip:AddLine("Click: whoever you point at or have targeted, else you.", 0.4, 1, 0.4)
        GameTooltip:Show()
        return
    end
    local first = p.targets[1]
    if first then
        local lvl = Clean(UnitLevel(first.unit))
        GameTooltip:AddLine(("Next: %s%s%s"):format(LIB and LIB.ColorName(first.name, first.class) or first.name,
            lvl and lvl > 0 and (" - " .. lvl) or "", first.class and (" " .. first.class:lower()) or ""), 1, 1, 1)
        if first.why then GameTooltip:AddLine(p.spell:gsub("^Blessing of ", "") .. " - " .. first.why,
            0.7, 0.7, 0.8, true) end
    end
    -- A few names, not a whole raid: the count on the button already says how many there are.
    if #p.targets > 1 then
        local names, shown = {}, 0
        for i = 2, #p.targets do
            if shown >= 3 then break end
            shown = shown + 1
            local m = p.targets[i]
            names[#names + 1] = LIB and LIB.ColorName(m.name, m.class) or ShortName(m.name)
        end
        local rest = #p.targets - 1 - shown
        GameTooltip:AddLine("Then: " .. table.concat(names, ", ")
            .. (rest > 0 and (" and " .. rest .. " more") or ""), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click: cast it and move on.", 0.4, 1, 0.4)
    GameTooltip:Show()   -- filling it is not showing it: without this the tooltip never appears
end

local function BlessButton(i)
    if blessButtons[i] then return blessButtons[i] end
    local b = CreateFrame("Button", "BuffWardenBless" .. i, bar, "SecureActionButtonTemplate")
    b:SetSize(SIZE, SIZE)
    b:RegisterForClicks("AnyUp", "AnyDown")
    -- Spelled out rather than left to defaults and frame order: these sit in the same run as the
    -- bar's icons, and the tooltip is how you see who the click will buff.
    b:EnableMouse(true)
    b:SetMotionScriptsWhileDisabled(true)
    b:SetHitRectInsets(0, 0, 0, 0)

    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetAllPoints()
    b.border:SetColorTexture(1, 1, 1)
    b.border:SetVertexColor(1, 0.82, 0.3)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.who = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.who:SetPoint("TOP", b, "BOTTOM", 0, -1)
    b.who:SetWidth(SIZE + GAP * 2)
    b.who:SetWordWrap(false)
    b.stale = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.stale:SetSize(14, 14)
    b.stale:SetPoint("BOTTOMLEFT", 1, 1)
    b.stale:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    b.stale:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.stale:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnEnter", BlessTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- HookScript, never SetScript: the secure template's own OnClick is what casts.
    b:HookScript("OnClick", function(self, _, down)
        if down then return end
        local p, unit = self.plan, self.unit
        if not (p and unit) then return end
        -- Assume it worked and move on at once, so a paladin can click down the row. A failed cast
        -- takes the mark away again (UNIT_SPELLCAST_FAILED) and that person is tried first next time.
        local m = p.targets[1]
        if m then justBuffed[m.name] = GetTime() + 2 end
        BW.lastBlessTarget = m and m.name or nil
        if not InCombatLockdown() then BW:Refresh() end
    end)
    blessButtons[i] = b
    return b
end

-- Out of combat only: secure attributes can't be touched in combat, so in combat the row keeps the
-- plan from the pull and wears the same clock the bar does.
function BW:ApplyBlessRow()
    if not self.db then return end
    if InCombatLockdown() then
        for _, b in ipairs(blessButtons) do
            b.stale:SetShown(b:IsShown())
            b.icon:SetAlpha(0.55)
        end
        return
    end

    local plan = self.blessPlan or {}
    local start = self.nextSlot or 1
    for i, p in ipairs(plan) do
        local b = BlessButton(i)
        b.plan = p
        PlaceIcon(b, start + i - 1, bar)
        -- Cast on the first one in range, so a click always lands; the count still covers everyone.
        local target = p.targets[1]
        for _, m in ipairs(p.targets) do
            if m.near == "range" and InRange(p.spell, m.unit) then target = m break end
        end
        b.unit = target and target.unit
        b.icon:SetTexture(C_Spell.GetSpellTexture(p.spell)
            or "Interface\\Icons\\Spell_Holy_FistOfJustice")
        b.icon:SetAlpha(p.spare and 0.3 or 1)
        b.stale:Hide()
        b.count:SetText(#p.targets > 1 and #p.targets or "")
        b.who:SetShown(self.db.blessNames)
        if self.db.blessNames and target then
            b.who:SetText(LIB and LIB.ColorName(target.name, target.class) or ShortName(target.name))
        else
            b.who:SetText("")
        end
        local action = p.spell .. "|" .. (b.unit or (p.spare and "spare") or "")
        if b.action ~= action then
            b.action = action
            if p.spare then
                -- Nobody's rules ask for this one, so there is no name to print and no unit to fix
                -- in advance. A macro decides at click time instead: point at someone in your party
                -- frames, or target them, and they get it - otherwise it lands on you. This is the
                -- "he's pulling aggro" click, and Salvation is why it exists. Macro conditionals are
                -- read when the button is pressed, so this one attribute works in combat too.
                b:SetAttribute("type", "macro")
                b:SetAttribute("unit", nil)
                b:SetAttribute("macrotext",
                    ("/cast [@mouseover,help,nodead][@target,help,nodead][@player] %s"):format(p.spell))
            else
                -- The rules picked a person, and the name under the icon says who. Keep the unit
                -- explicit so that name is never a lie: no mouseover override here.
                b:SetAttribute("type", "spell")
                b:SetAttribute("macrotext", nil)
                b:SetAttribute("spell", p.spell)
                b:SetAttribute("unit", b.unit)
            end
        end
        b:Show()
    end
    for i = #plan + 1, #blessButtons do
        blessButtons[i].plan = nil
        blessButtons[i]:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- The in-combat weapon readout
-- ---------------------------------------------------------------------------
-- The bar is made of secure buttons, so it can't change during combat - and every aura is secret there
-- anyway. Weapon buffs are the exception: they can be read mid-fight, so they get their own plain
-- frame (no secure children), which we are free to update in combat. Display only: applying a stone
-- still needs the bar's button, out of combat.
local readout
local readoutRows = {}

-- One icon, built like a bar icon: coloured border, the enchant's icon inset, time left on top. The
-- tooltip explains it, since the bar's own buttons are gone in combat.
local function ReadoutIcon(i)
    if readoutRows[i] then return readoutRows[i] end
    local f = CreateFrame("Frame", nil, readout)
    f:SetSize(SIZE, SIZE)
    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetAllPoints()
    f.border:SetColorTexture(1, 1, 1)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", 2, -2)
    f.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.timer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.timer:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f.timer:SetWidth(SIZE + GAP * 2)
    f.timer:SetWordWrap(false)
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine(self.label or "Weapon buff", 1, 0.82, 0.3)
        GameTooltip:AddLine(self.status or "", 1, 1, 1)
        GameTooltip:AddLine("Apply it when the fight is over.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    readoutRows[i] = f
    return f
end

-- Sits exactly where the bar sits, in the same row, so in combat it reads like the rest of BuffWarden.
function BW:UpdateWeaponReadout()
    if not self.db then return end
    if not readout then
        readout = CreateFrame("Frame", "BuffWardenWeaponReadout", UIParent)
        readout:SetPoint("LEFT", bar, "LEFT", 0, 0)
        readout:SetSize(SIZE, SIZE)
        readout:SetScale(self.db.scale or 1)
        readout:Hide()
    end
    if not (self.db.weaponBuffs and InCombatLockdown()) then readout:Hide() return end
    readout:SetScale(self.db.scale or 1)
    -- With the bar hidden in combat (the default) this takes its place; with the bar kept visible it
    -- sits just above, so the live weapon icon never covers the bar's frozen one.
    readout:ClearAllPoints()
    if self.db.hideInCombat then
        readout:SetPoint("LEFT", bar, "LEFT", 0, 0)
    else
        readout:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, GAP)
    end

    local shown = 0
    for _, w in ipairs(WEAPON_SLOTS) do
        -- Same builder as the bar: same icon, same rules about when there is anything to say at all.
        local e = WeaponEntry(w)
        if e then
            shown = shown + 1
            local f = ReadoutIcon(shown)
            PlaceIcon(f, shown, readout)
            f.icon:SetTexture(e.icon)
            f.icon:SetDesaturated(false)   -- the bar doesn't grey these out either
            local c = COLORS.weapon
            f.border:SetVertexColor(c[1], c[2], c[3])
            f.timer:SetText(e.missing and "" or FmtTime(e.left))
            local t = COLORS.expiring
            f.timer:SetTextColor(t[1], t[2], t[3])
            f.label = e.label
            f.status = e.missing and "No weapon buff." or (FmtTime(e.left) .. " left.")
            f:Show()
        end
    end
    for i = shown + 1, #readoutRows do readoutRows[i]:Hide() end
    readout:SetWidth((GridSize(shown)))
    readout:SetShown(shown > 0)
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
-- In combat the bar can't change anyway, so nothing is read until it ends (PLAYER_REGEN_ENABLED
-- refreshes). While auras are secret outside combat (an instance encounter, a restricted map) we can't
-- know what's missing, so the bar shows nothing rather than a guess; ADDON_RESTRICTION_STATE_CHANGED
-- brings it back.
function BW:Refresh()
    if not self.db then return end
    lastRefresh = GetTime()
    if InCombatLockdown() then
        self.dirty = true
        return
    end
    local entries = {}
    self.restricted = AurasSecret()
    if not self.restricted then entries = self:Compute() end
    self.entries = entries
    self:Apply(entries)
    self:ApplyBlessRow()
    self:UpdateWeaponReadout()
end

local MIN_GAP = 0.3            -- never scan more often than this, however many events arrive
local lastRefresh = 0

-- A pending refresh is rescheduled when something asks for a sooner one (buffing a party sends a burst
-- of aura events, and the old code made every one of them wait for the first timer).
function BW:ScheduleRefresh(delay)
    delay = delay or 1
    local soonest = math.max(delay, lastRefresh + MIN_GAP - GetTime())
    if self.timer then
        if (self.timerAt or 0) <= GetTime() + soonest then return end
        self.timer:Cancel()
    end
    self.timerAt = GetTime() + soonest
    self.timer = C_Timer.NewTimer(soonest, function()
        BW.timer, BW.timerAt = nil, nil
        BW:Refresh()
    end)
end

function BW:Report(prefix)
    if self.restricted or InCombatLockdown() then
        print(TAG .. ": " .. (prefix or "") .. "buffs can't be read right now (combat or an encounter).")
        return
    end
    local entries = self.entries or {}
    if #entries == 0 then print(TAG .. ": " .. (prefix or "") .. "all buffed up.") return end
    local cast, ask = {}, {}
    for _, e in ipairs(entries) do
        if e.mode == "food" then
            cast[#cast + 1] = "Well Fed"
        elseif e.mode == "weapon" then
            cast[#cast + 1] = e.label .. ": " .. (e.expiring and "running out" or "no weapon buff")
        elseif e.mode == "cast" then
            cast[#cast + 1] = e.spell .. ((#e.targets > 1 or not e.targets[1].isMe) and (" (" .. #e.targets .. ")") or "")
        else
            ask[#ask + 1] = e.spell
        end
    end
    if #cast > 0 then print(TAG .. ": " .. (prefix or "") .. "you can cast: " .. table.concat(cast, ", ")) end
    if #ask > 0 then print(TAG .. ": " .. (prefix or "") .. "you're missing: " .. table.concat(ask, ", ")) end
end

-- ---------------------------------------------------------------------------
-- Launcher, compartment, slash
-- ---------------------------------------------------------------------------
-- Safe in combat: the bar itself only changes once combat ends (Apply waits), and we say so.
function BW:SetLocked(locked)
    self.db.locked = locked and true or false
    local msg = self.db.locked and "locked." or "unlocked - showing a preview, drag it into place."
    if InCombatLockdown() then msg = msg:gsub("%.$", "") .. " (once combat ends)." end
    print(TAG .. ": bar " .. msg)
    self:Refresh()
end

local function ToggleLock() BW:SetLocked(not BW.db.locked) end

local function MissingText()
    if BW.restricted then return "Buffs can't be read right now." end
    local n = BW.entries and #BW.entries or 0
    return n == 0 and "All buffed up." or (n .. " buff" .. (n == 1 and "" or "s") .. " missing")
end

-- Family convention: left-click does the addon's main thing, right-click always opens its settings.
-- BuffWarden's main thing is the bar, so left-click locks or unlocks it (unlocked shows the preview to
-- drag). What's missing is listed by /bwarden status.
local function OnLauncherClick(button)
    if button == "RightButton" then BW:OpenOptions() else ToggleLock() end
end

function BuffWarden_OnAddonCompartmentClick(_, button) OnLauncherClick(button) end
function BuffWarden_OnAddonCompartmentEnter(_, menuButton)
    GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
    GameTooltip:AddLine(TAG)
    GameTooltip:AddLine("Left-click: unlock/lock the bar", 1, 1, 1)
    GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
    GameTooltip:Show()
end
function BuffWarden_OnAddonCompartmentLeave() GameTooltip:Hide() end

-- What BuffWarden would use on your weapons right now, for the other YippYapp addons: BagWarden keeps
-- an item this answers true for instead of offering it for deletion. A function, not a list, so it
-- follows your weapon and your setting.
function BW:PublishWeaponEnhancers()
    if not (LIB and LIB.ProvideData) then return end
    LIB.ProvideData("BuffWardenWeaponEnhancers", {
        --- Is this item the stone or oil BuffWarden is currently offering? Returns a reason or nil.
        Keep = function(itemID)
            if not (BW.db and BW.db.weaponBuffs and itemID) then return nil end
            if BW.POISONS[itemID] then
                for _, w in ipairs(WEAPON_SLOTS) do
                    local pref = (w.slot == 0) and BW.db.poisonMain or BW.db.poisonOff
                    if pref ~= "none" then
                        local best = BestPoison(pref == "auto" and BW.POISON_AUTO[w.slot] or pref)
                            or BestPoison("any")
                        if best and best.id == itemID then return "BuffWarden coats your weapon with this" end
                    end
                end
                return nil
            end
            if not BW.WEAPON_ENHANCERS[itemID] then return nil end
            for _, w in ipairs(WEAPON_SLOTS) do
                local _, subClassID = EquippedWeapon(w.inv)
                if subClassID then
                    local best = BestEnhancer(subClassID)
                    if best and best.id == itemID then return "BuffWarden uses this on your weapon" end
                end
            end
            return nil
        end,
    })
end

function BW:RegisterLauncher()
    if not (LIB and LIB.RegisterLauncher) then return end
    LIB.RegisterLauncher({
        id = "BuffWarden", label = "BuffWarden", order = 45,
        icon = "Interface\\AddOns\\BuffWarden\\Media\\notch",
        onClick = OnLauncherClick,
        status = function() return MissingText() end,
        tooltip = { "Left-click: unlock/lock the bar", "Right-click: settings" },
    }, self.db)
end

-- Minimap button (LibDBIcon through LibForever). Left-click does what the launcher button does.
function BW:RegisterMinimap()
    if not (LIB and LIB.RegisterMinimapButton) then return end
    LIB.RegisterMinimapButton("BuffWarden", {
        icon = "Interface\\AddOns\\BuffWarden\\Media\\minimap",
        label = "BuffWarden",
        OnClick = function(_, button) OnLauncherClick(button) end,
        OnTooltipShow = function(tt)
            tt:AddLine("BuffWarden", 1, 0.82, 0.3)
            tt:AddLine(MissingText(), 1, 1, 1)
            tt:AddLine("Left-click: unlock/lock the bar", 0.8, 0.8, 0.8)
            tt:AddLine("Right-click: settings", 0.8, 0.8, 0.8)
        end,
    }, self.db)
end

-- Not /bw: BigWigs owns that one.
SLASH_BUFFWARDEN1 = "/bwarden"
SLASH_BUFFWARDEN2 = "/buffwarden"
SlashCmdList.BUFFWARDEN = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    local db = BW.db
    if cmd == "lock" or cmd == "unlock" or cmd == "move" then
        BW:SetLocked(cmd == "lock")
        return
    elseif cmd == "reset" then
        if InCombatLockdown() then print(TAG .. ": not in combat.") return end
        db.point = nil
        bar:ClearAllPoints()
        bar:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
        SavePosition()
        print(TAG .. ": position reset.")
    elseif cmd == "scale" and tonumber(arg) then
        if InCombatLockdown() then print(TAG .. ": not in combat.") return end
        db.scale = math.min(2, math.max(0.5, tonumber(arg)))
        bar:SetScale(db.scale)
    elseif cmd == "time" and tonumber(arg) then
        db.threshold = math.max(30, tonumber(arg))
        print(TAG .. ": warns when a buff has less than " .. FmtLong(db.threshold) .. " left.")
    elseif cmd == "combat" then
        db.hideInCombat = not db.hideInCombat
        BW:ApplyCombatSetting()
        print(TAG .. ": " .. (db.hideInCombat and "hidden in combat" or "shown in combat")
            .. (InCombatLockdown() and " (from the next fight)." or "."))
    elseif cmd == "toggle" and arg ~= "" then
        for _, def in ipairs(BW.BUFFS) do
            if def.key == arg then
                db.disabled[arg] = BuffEnabled(def)
                print(TAG .. ": " .. arg .. " " .. (BuffEnabled(def) and "|cff66ff66on|r" or "|cffff6666off|r"))
                BW:Refresh()
                return
            end
        end
        print(TAG .. ": unknown buff '" .. arg .. "'. See /bwarden list.")
    elseif cmd == "list" then
        print(TAG .. ": watched buffs (/bwarden toggle <key>):")
        for _, def in ipairs(BW.BUFFS) do
            print(("  %s%s|r  %s - %s"):format(BuffEnabled(def) and "|cff66ff66" or "|cffff6666",
                def.key, def.class and def.class:lower() or def.scope, def.names[1]))
        end
    elseif cmd == "bless" then
        local who, kind = arg:match("^(%S*)%s*(%S*)$")
        if who == "" or who == "list" then
            print(TAG .. ": blessings you have chosen (by full name, so two Kjells don't collide):")
            local any = false
            for name, k in pairs(db.blessFor) do
                any = true
                print(("  %s -> %s"):format(name, k))
            end
            if not any then print("  none - everyone gets the class default") end
            print("  set one with: /bwarden bless <name> <kind>   (kinds: "
                .. table.concat(BW.KnownBlessingKinds(), ", ") .. ")")
            return
        end
        -- Match what they typed against the group, so the choice is stored under the full name.
        local full
        for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
            local n = UnitExists(u) and GetUnitName(u, true)
            if n and (n:lower() == who:lower() or ShortName(n):lower() == who:lower()) then full = n end
        end
        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local n = GetUnitName("raid" .. i, true)
                if n and (n:lower() == who:lower() or ShortName(n):lower() == who:lower()) then full = n end
            end
        end
        if not full then
            print(TAG .. ": nobody in your group is called '" .. who .. "'.")
            return
        end
        if kind == "" or kind == "auto" then
            db.blessFor[full] = nil
            print(TAG .. ": " .. full .. " goes back to the class default.")
        elseif BW.BLESSING_KINDS[kind] then
            db.blessFor[full] = kind
            print(TAG .. ": " .. full .. " gets " .. BW.BLESSING_KINDS[kind].spell
                .. " (stored by full name, so it follows that character only).")
            if not Knows(BW.BLESSING_KINDS[kind].spell) then
                print("  you don't know that one yet - it takes effect when you learn it.")
            end
        else
            print(TAG .. ": kinds are " .. table.concat(BW.KnownBlessingKinds(), ", "))
            return
        end
        BW:Refresh()
        return
    elseif cmd == "debug" then
        wipe(knownCache)
        BW.ForgetEnhancers()
        local _, c = UnitClass("player")
        print(TAG .. " debug (" .. tostring(c) .. "):")
        -- The settings as they are stored right now, so a wrong-looking bar can be traced to a setting.
        print(("  settings: warn=%ds hideInCombat=%s locked=%s placed=%s scale=%s ignoreFar=%s readyCheck=%s")
            :format(db.threshold, tostring(db.hideInCombat), tostring(db.locked), tostring(db.placed),
                tostring(db.scale), tostring(db.ignoreFar), tostring(db.readyCheck)))
        print(("  weapon: watch=%s stoneOrOil=%s imbue=%s poisonMain=%s poisonOff=%s"):format(
            tostring(db.weaponBuffs), tostring(db.weaponPref), tostring(db.imbuePref),
            tostring(db.poisonMain), tostring(db.poisonOff)))
        local off = {}
        for _, def in ipairs(BW.BUFFS) do
            if not BuffEnabled(def) then off[#off + 1] = def.key end
        end
        print("  buffs turned off: " .. (#off > 0 and table.concat(off, ", ") or "none"))
        print(("  food macro: %s"):format(FoodMacro() or "none (AutoFeed not installed?)"))
        local me = BW.Me()
        local spent = {}
        for i = 1, 3 do
            local t = me.tabs and me.tabs[i]
            if t then spent[#spent + 1] = ("%s %d"):format(t.name, t.points) end
        end
        print(("  me: level %d, %s, shield=%s, role=%s"):format(me.level, tostring(me.class),
            tostring(me.shield), me.role or "unknown (no talents read)"))
        print("  talents: " .. (#spent > 0 and table.concat(spent, ", ")
            or "|cffff5555nothing read|r - C_ClassTalents.GetActiveConfigID() gave "
                .. tostring(C_ClassTalents and C_ClassTalents.GetActiveConfigID
                    and C_ClassTalents.GetActiveConfigID())))
        local plan = BW.blessPlan
        print(("  blessing row: %s, %d button(s)"):format(tostring(db.blessRow),
            plan and #plan or 0))
        for i, b in ipairs(blessButtons) do
            if b:IsShown() then
                print(("    button %d: %s -> %s (mouse=%s level=%d)"):format(i,
                    b.plan and b.plan.spell or "?", tostring(b.unit),
                    tostring(b:IsMouseEnabled()), b:GetFrameLevel()))
            end
        end
        for _, w in ipairs(WEAPON_SLOTS) do
            local itemID, subClassID = EquippedWeapon(w.inv)
            if not itemID then
                print(("  %s: nothing that takes a weapon buff"):format(w.label))
            else
                local state = WeaponEnchant(w.slot)
                local stone = BestEnhancer(subClassID)
                local pref = (w.slot == 0) and db.poisonMain or db.poisonOff
                local poison = c == "ROGUE" and pref ~= "none"
                    and (BestPoison(pref == "auto" and BW.POISON_AUTO[w.slot] or pref) or BestPoison("any"))
                print(("  %s: weapon=%s subclass=%s buff=%s stone=%s poison=%s"):format(w.label,
                    tostring(itemID), tostring(subClassID),
                    state and (state.left > 0 and FmtTime(state.left) .. " left" or "none") or "unreadable",
                    stone and tostring(stone.id) or "-", poison and tostring(poison.id) or "-"))
            end
        end
        for _, def in ipairs(BW.BUFFS) do
            if def.class == c then
                for _, s in ipairs(def.cast) do print(("  %s: %s"):format(s, Knows(s) and "known" or "-")) end
            end
        end
        local auras, unreadable = ReadAuras("player")
        if unreadable then print("  (some auras are secret right now)") end
        for name, a in pairs(auras) do
            print(("  aura: %s (%s)"):format(name, a.left == math.huge and "no timer" or FmtTime(a.left)))
        end
    elseif cmd == "status" or cmd == "report" then
        BW:Report()
    elseif cmd == "welcome" then
        if LIB and LIB.OpenWelcome then LIB.OpenWelcome("BuffWarden") end
    elseif cmd == "help" then
        print(TAG .. " v" .. BW.version .. " commands:")
        print("  /bwarden  - open the settings")
        print("  /bwarden unlock | lock | reset | scale <0.5-2>")
        print("  /bwarden time <seconds>  - warn when a buff has less than this left (now " .. db.threshold .. ")")
        print("  /bwarden combat  - toggle hiding in combat")
        print("  /bwarden list | toggle <key>  - choose which buffs to watch")
        print("  /bwarden bless <name> <kind> | bless list  - which blessing someone gets")
        print("  /bwarden status | welcome")
    else
        if BW.OpenOptions then BW:OpenOptions() end
    end
    BW:Refresh()
end

-- ---------------------------------------------------------------------------
-- Self-test (/yippyapp test)
-- ---------------------------------------------------------------------------
-- The live equivalent of the offline smoke suite, for one purpose: after a cleanup round, prove that
-- nothing calls something that was deleted. So it runs everything that READS, BUILDS or DRAWS for the
-- real character - the profile, the weapon enchants, Compute, the bar, the blessing row, the preview
-- and every tooltip - and nothing that casts, whispers, saves a setting or touches another player.
-- LibForever calls it inside a pcall, so an error here is the report; the return is for the detail.
-- ---------------------------------------------------------------------------
function BW.SelfTest()
    if not BW.db then return false, "settings aren't loaded yet" end
    if InCombatLockdown() then
        -- Not a pass and not a failure: in combat the bar is frozen by design and auras are secret,
        -- so there is nothing here that could be exercised honestly.
        return true, "skipped in combat: the bar can't change and buffs can't be read there"
    end

    local said = {}
    local function note(...) said[#said + 1] = string.format(...) end

    local me = BW.Me()
    note("%s %d, role %s", tostring(me.class), me.level, me.role or "unread")
    if me.spec then note("%s %d", me.spec.name, me.spec.points) end

    -- Weapon enchants: item state, so this is the one read that works whatever else is restricted.
    local weapons = 0
    for _, w in ipairs(WEAPON_SLOTS) do
        if WeaponEntry(w) then weapons = weapons + 1 end
    end
    note("%d weapon", weapons)

    local entries = BW:Compute()
    note("%d missing", #entries)
    note("%d blessing", BW.blessPlan and #BW.blessPlan or 0)

    -- Draw it all: the bar, the blessing row and the in-combat readout.
    BW:Refresh()
    BW:UpdateWeaponReadout()

    -- The unlocked placeholders, which nothing else runs while the bar is locked.
    note("%d preview", #BW:BuildPreview())

    -- Every tooltip on every button that is showing, then the launcher's line. Hidden buttons have
    -- no entry to describe, so there is nothing to build for them.
    local tips = 0
    for _, b in ipairs(buttons) do
        if b:IsShown() and b.entry then
            tips = tips + 1
            ButtonOnEnter(b)
        end
    end
    for _, b in ipairs(blessButtons) do
        if b:IsShown() and b.plan then
            tips = tips + 1
            BlessTooltip(b)
        end
    end
    GameTooltip:Hide()
    note("%d tooltips", tips)
    note("launcher says %q", MissingText())

    return true, table.concat(said, ", ")
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("UNIT_CONNECTION")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("READY_CHECK")
f:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
f:RegisterEvent("WEAPON_ENCHANT_CHANGED")
f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
f:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
f:RegisterEvent("BAG_UPDATE_DELAYED")          -- a stone used up, or a new one picked up
f:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")   -- weapon swapped
f:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
f:RegisterEvent("PLAYER_TALENT_UPDATE")        -- a point spent changes what we think we are
f:RegisterEvent("TRAIT_CONFIG_UPDATED")
-- Is this aura update about a buff we watch? Full updates and unreadable ones count; otherwise only
-- added watched buffs, and removed or changed auras we saw as watched on the last scan.
local function AuraUpdateMatters(unit, info)
    if AurasSecret() then return false end   -- nothing to read; the restriction ending triggers a rescan
    if not info or info.isFullUpdate then return true end
    for _, a in ipairs(info.addedAuras or {}) do
        local id = Clean(a.auraInstanceID)
        if not id or (C_Secrets and C_Secrets.ShouldUnitAuraInstanceBeSecret
            and C_Secrets.ShouldUnitAuraInstanceBeSecret(unit, id)) then
            return true                      -- can't tell what it is: the rescan copes with secret ones
        end
        local name = Clean(a.name)
        if name == nil or (Clean(a.isHelpful) ~= false and IsWatchedName(name)) then return true end
    end
    for _, id in ipairs(info.removedAuraInstanceIDs or {}) do
        if watchedIDs[id] then return true end
    end
    for _, id in ipairs(info.updatedAuraInstanceIDs or {}) do
        if watchedIDs[id] then return true end
    end
    return false
end

f:SetScript("OnEvent", function(_, event, unit, info)
    if event == "PLAYER_LOGIN" then
        -- Settings from an earlier version mean the bar is already where this player wants it, so the
        -- welcome card only asks new installs to place it.
        local upgrade = BuffWardenDB ~= nil and next(BuffWardenDB) ~= nil
        BuffWardenDB = BuffWardenDB or {}
        if upgrade and BuffWardenDB.placed == nil then BuffWardenDB.placed = true end
        for k, v in pairs(defaults) do
            if BuffWardenDB[k] == nil then BuffWardenDB[k] = (type(v) == "table") and {} or v end
        end
        BuffWardenDB.askText = nil   -- saved by early dev builds; it's a constant now
        if not BuffWardenDB.warnV2 then
            -- 120 s was the old default, not a choice: move it to the new one
            if BuffWardenDB.threshold == 120 then BuffWardenDB.threshold = defaults.threshold end
            BuffWardenDB.warnV2 = true
        end
        BW.db = BuffWardenDB
        BW:CreateBar()
        if BW.BuildOptions then BW:BuildOptions() end
        BW:RegisterLauncher()
        if LIB and LIB.RegisterSelfTest then LIB.RegisterSelfTest("BuffWarden", BW.SelfTest) end
        BW:RegisterMinimap()
        BW:PublishWeaponEnhancers()
        if BW.RegisterWelcome then BW:RegisterWelcome() end
        -- Range and expiry change without events; a slow tick catches them.
        C_Timer.NewTicker(5, function() if not InCombatLockdown() then BW:Refresh() end end)
        -- in combat only the weapon readout can change, and it costs two reads
        C_Timer.NewTicker(2, function() if InCombatLockdown() then BW:UpdateWeaponReadout() end end)
        C_Timer.After(2, function() BW:Refresh() end)
        return
    end
    if not BW.db then return end
    if event == "UNIT_AURA" then
        if unit ~= "player" and not (unit and (unit:find("^party") or unit:find("^raid"))) then return end
        if InCombatLockdown() or not AuraUpdateMatters(unit, info) then return end
        BW:ScheduleRefresh(unit == "player" and 0.2 or 0.4)   -- your own cast first, a groupmate's next
    elseif event == "UNIT_POWER_UPDATE" then
        -- rage decides whether a short buff like Battle Shout is worth reminding about
        if unit == "player" and info == "RAGE" and not InCombatLockdown() then BW:ScheduleRefresh() end
    elseif event == "GROUP_ROSTER_UPDATE" then
        BW.ForgetMe()          -- roles come and go with the group
        wipe(askedAt)          -- keyed by name: never grows past one group
        wipe(justBuffed)
        wipe(retryFirst)
        BW:ScheduleRefresh()
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_LEVEL_UP" then
        wipe(knownCache)
        BW.ForgetMe()          -- the profile holds our level, and a new rank can be a new signal
        BW:ScheduleRefresh()
    elseif event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" then
        BW.ForgetTalents()     -- read the tree again: this is what decides healer from tank
        BW:ScheduleRefresh()
    elseif event == "PLAYER_REGEN_DISABLED" then
        BW:SetStale(true)
        BW:UpdateWeaponReadout()
    elseif event == "BAG_UPDATE_DELAYED" or event == "UNIT_INVENTORY_CHANGED" then
        BW.ForgetEnhancers()
        BW.ForgetMe()          -- a shield swap decides whether Righteous Fury is worth mentioning
        if not InCombatLockdown() then BW:ScheduleRefresh(0.5) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- it landed: keep the "done" mark until the aura itself shows up
        if BW.lastBlessTarget then
            justBuffed[BW.lastBlessTarget] = GetTime() + 3
            retryFirst[BW.lastBlessTarget] = nil
        end
    elseif event == "UNIT_SPELLCAST_FAILED" then
        -- out of range, immune, moving: that person goes back to the front of the queue
        local name = BW.lastBlessTarget
        if name then
            justBuffed[name] = nil
            retryFirst[name] = true
            BW.lastBlessTarget = nil
            if not InCombatLockdown() then BW:ScheduleRefresh(0.2) end
        end
    elseif event == "WEAPON_ENCHANT_CHANGED" then
        -- item state, not an aura: safe to read in combat, and the readout is ours to update there
        BW:UpdateWeaponReadout()
        if not InCombatLockdown() then BW:ScheduleRefresh(0.2) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        BW:SetStale(false)
        BW:UpdateWeaponReadout()
        if BW.combatDirty then BW.combatDirty = nil; BW:ApplyCombatSetting() end
        BW:Refresh()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        -- fired just before a restriction activates and after it lifts: look again once it has settled
        BW:ScheduleRefresh()
    elseif event == "READY_CHECK" then
        BW:Refresh()
        if BW.db.readyCheck then BW:Report("ready check - ") end
    else
        BW:ScheduleRefresh()
    end
end)
