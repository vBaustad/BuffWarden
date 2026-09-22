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
}

local ASK_TEXT = "Could I get %s, please? :)"

local function BuffEnabled(def)
    local v = BW.db.disabled[def.key]
    if v == nil then return def.default ~= false end
    return not v
end
BW.BuffEnabled = BuffEnabled

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

local function InRange(spell, unit)
    if UnitIsUnit(unit, "player") then return true end
    local r = C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(spell, unit)
    return r ~= false   -- nil = can't tell, give it the benefit of the doubt
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
-- Everyone we can see: { unit, name, class, auras }. Plus the online providers per class.
local function ScanGroup()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end

    local members, providers = {}, {}
    wipe(watchedIDs)
    local seen = {}
    for _, u in ipairs(units) do
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
                local auras, unreadable = ReadAuras(u)
                members[#members + 1] = {
                    unit = isMe and "player" or u,
                    name = name,
                    class = class,
                    isMe = isMe,
                    near = near,               -- "range" or "near"; far ones aren't here at all
                    auras = auras,
                    unreadable = unreadable,   -- buffs unknown: never flag this one as missing anything
                }
            end
        end
    end
    for name in pairs(farSince) do
        if not seen[name] then farSince[name] = nil end   -- left the group
    end
    return members, providers
end

local function Eligible(def, m)
    if def.who == "mana" then return BW.MANA_CLASSES[m.class] end
    return true
end

-- Which blessing a paladin should put on this member.
local function BlessingFor(m)
    if Knows("Blessing of Kings") then return "Blessing of Kings" end
    if BW.MANA_CLASSES[m.class] and m.class ~= "HUNTER" and Knows("Blessing of Wisdom") then
        return "Blessing of Wisdom"
    end
    if Knows("Blessing of Might") then return "Blessing of Might" end
    return FirstKnown({ "Blessing of Wisdom", "Blessing of Salvation", "Blessing of Light" })
end

-- Does this member carry a blessing from us (byMe) or from another paladin? A blessing whose caster
-- can't be read counts either way: better to miss a rebuff than to nag about one that's there.
local function IsBlessedBy(m, byMe)
    if m.unreadable then return true end
    for _, n in ipairs(BW.BLESSING_NAMES) do
        local a = m.auras[n]
        if a and not Expiring(a) then
            if not a.source then return true end
            local mine = UnitIsUnit(a.source, "player")
            if byMe == mine then return true end
        end
    end
    return false
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

-- Builds the list of things to show. Each entry:
--   { key, def, mode = "cast"|"ask", spell, icon, targets = {member...}, target, providers = {unit...}, expiring }
function BW:Compute()
    local members, providers = ScanGroup()
    local _, myClass = UnitClass("player")
    local me
    for _, m in ipairs(members) do if m.isMe then me = m end end
    local entries = {}
    if not me then return entries end

    for _, def in ipairs(BW.BUFFS) do
        if BuffEnabled(def) then
            local mine = def.class == myClass and FirstKnown(def.cast)

            if def.scope == "self" then
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
                -- As a paladin: everyone should carry one blessing from you.
                if def.class == myClass and FirstKnown(def.cast) then
                    local missing, target = {}, nil
                    for _, m in ipairs(members) do
                        if not IsBlessedBy(m, true) then
                            missing[#missing + 1] = m
                            if not target and InRange(BlessingFor(m) or "", m.unit) then target = m end
                        end
                    end
                    if #missing > 0 then
                        target = target or missing[1]
                        entries[#entries + 1] = { key = def.key, def = def, mode = "cast",
                            spell = BlessingFor(target), targets = missing, target = target }
                    end
                end
                -- From the other paladins: you should carry one blessing from each of them.
                local pals = Providers(def, providers.PALADIN, members)
                if pals and not me.unreadable then
                    local have, from = 0, {}
                    for _, n in ipairs(BW.BLESSING_NAMES) do
                        local a = me.auras[n]
                        if a and not Expiring(a) and not (a.source and UnitIsUnit(a.source, "player")) then
                            have = have + 1
                            if a.source then from[#from + 1] = a.source end
                        end
                    end
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

    -- Nobody in casting range? The icon is dimmed a little: still worth seeing, not actionable yet.
    for _, e in ipairs(entries) do
        if e.mode == "cast" and e.targets then
            e.reachable = false
            for _, m in ipairs(e.targets) do
                if m.near == "range" and InRange(e.spell, m.unit) then e.reachable = true end
            end
        else
            e.reachable = true
        end
    end
    -- Icons: the exact spell we'd cast, else the buff's own spell texture.
    for _, e in ipairs(entries) do
        e.icon = (e.mode == "cast" and C_Spell.GetSpellTexture(e.spell)) or BW.IconFor(e.def)
    end
    return entries
end

-- The buff's real spell icon, looked up by ID so it works for spells you can't cast yourself.
function BW.IconFor(def)
    return (def.spellID and C_Spell.GetSpellTexture(def.spellID)) or def.icon
end

local function SpellName(def)
    return (def.spellID and C_Spell.GetSpellName(def.spellID)) or def.cast[1]
end

-- What the bar shows while unlocked: your class's real buffs, plus group buffs you'd get from others,
-- in each of the looks the bar can have. Placeholders only; they don't click.
function BW:BuildPreview()
    local _, myClass = UnitClass("player")
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
        if def.class ~= myClass and def.scope ~= "self" and BuffEnabled(def) then
            out[#out + 1] = { mode = "ask", spell = SpellName(def), icon = BW.IconFor(def),
                preview = "A groupmate has this buff (grey). Click whispers them to ask for it." }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The bar
-- ---------------------------------------------------------------------------
local SIZE, GAP = 36, 4
local holder, bar, handle
local buttons = {}

-- Always pinned by its top-left corner, so the first icon stays put and the row grows to the right.
-- (StopMovingOrSizing re-anchors to whatever point is nearest, often CENTER or RIGHT; a bar anchored
-- like that shrinks toward the middle or the right when fewer icons are shown.)
local function SavePosition()
    if InCombatLockdown() then return end
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
    b.timer:SetPoint("TOP", 0, -2)
    -- In combat every aura is secret to addons, so the bar can't know what changed: it keeps the state
    -- from the pull and wears this clock until combat ends. Plain textures, so they may change in combat.
    b.stale = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.stale:SetSize(14, 14)
    b.stale:SetPoint("BOTTOMLEFT", 1, 1)
    b.stale:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    b.stale:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.stale:Hide()

    b:SetScript("OnEnter", ButtonOnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- While unlocked the whole bar can be dragged by any of its (preview) buttons.
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function() BW:StartDrag() end)
    b:SetScript("OnDragStop", function() bar:StopMovingOrSizing(); SavePosition() end)
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
    bar:SetScript("OnDragStop", function() bar:StopMovingOrSizing(); SavePosition() end)

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
    self.stale = stale and true or nil
    for _, b in ipairs(buttons) do
        b.stale:SetShown(stale and b.entry ~= nil and not b.entry.preview)
        local reachable = not (b.entry and b.entry.reachable == false)
        b.icon:SetAlpha(stale and 0.55 or (reachable and 1 or 0.6))
        b.border:SetAlpha(stale and 0.5 or 1)
    end
end

local COLORS = {
    cast     = { 1, 0.82, 0.3 },    -- gold: you can fix this yourself
    ask      = { 0.4, 0.55, 0.7 },  -- steel: someone else has it
    expiring = { 1, 0.45, 0.1 },    -- orange: running out
}

function BW:Apply(entries)
    if InCombatLockdown() then self.dirty = true return end
    self.dirty = nil
    local unlocked = not self.db.locked
    if unlocked then entries = self:BuildPreview() end

    for i, e in ipairs(entries) do
        local b = buttons[i] or MakeButton(i)
        b.entry = e
        b:ClearAllPoints()
        b:SetPoint("LEFT", bar, "LEFT", (i - 1) * (SIZE + GAP), 0)
        b.icon:SetTexture(e.icon)
        b.icon:SetDesaturated(e.mode == "ask")
        b.icon:SetAlpha(e.reachable == false and 0.6 or 1)
        local c = e.expiring and COLORS.expiring or COLORS[e.mode]
        b.border:SetVertexColor(c[1], c[2], c[3])
        b.count:SetText((e.mode == "cast" and #e.targets > 1) and #e.targets or "")
        b.timer:SetText(e.expiring and FmtTime(e.expiring) or "")

        -- Click action; the secure attributes are only touched when it actually changes.
        local typ, spell, unit, macro
        if e.preview then
            -- placeholders: no click actions
        elseif e.mode == "cast" then
            typ, spell, unit = "spell", e.spell, e.target.unit
        elseif e.providers[1] then
            local who = GetUnitName(e.providers[1], true)
            if who then typ, macro = "macro", "/w " .. who .. " " .. ASK_TEXT:format(e.spell) end
        end
        local action = (typ or "") .. "|" .. (spell or "") .. "|" .. (unit or "") .. "|" .. (macro or "")
        if b.action ~= action then
            b.action = action
            b:SetAttribute("type", typ)
            b:SetAttribute("spell", spell)
            b:SetAttribute("unit", unit)
            b:SetAttribute("macrotext", macro)
        end
        b:Show()
    end
    for i = #entries + 1, #buttons do
        buttons[i].entry = nil
        buttons[i]:Hide()
    end

    local n = #entries
    bar:SetWidth(math.max(1, n) * (SIZE + GAP) - GAP)
    handle:SetShown(unlocked)
    bar:EnableMouse(unlocked)
    bar:SetShown(n > 0)
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
    if InCombatLockdown() then
        self.dirty = true
        return
    end
    local entries = {}
    self.restricted = AurasSecret()
    if not self.restricted then entries = self:Compute() end
    self.entries = entries
    self:Apply(entries)
end

function BW:ScheduleRefresh(delay)
    if self.timer then return end
    self.timer = C_Timer.NewTimer(delay or 1, function()
        BW.timer = nil
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
        if e.mode == "cast" then
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

local function OnLauncherClick(button)
    if button == "RightButton" then BW:Report() else ToggleLock() end
end

function BuffWarden_OnAddonCompartmentClick(_, button) OnLauncherClick(button) end
function BuffWarden_OnAddonCompartmentEnter(_, menuButton)
    GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
    GameTooltip:AddLine(TAG)
    GameTooltip:AddLine("Left-click: lock / unlock the bar", 1, 1, 1)
    GameTooltip:AddLine("Right-click: list what's missing", 1, 1, 1)
    GameTooltip:Show()
end
function BuffWarden_OnAddonCompartmentLeave() GameTooltip:Hide() end

function BW:RegisterLauncher()
    if not (LIB and LIB.RegisterLauncher) then return end
    LIB.RegisterLauncher({
        id = "BuffWarden", label = "BuffWarden", order = 45,
        icon = "Interface\\AddOns\\BuffWarden\\Media\\notch",
        onClick = OnLauncherClick,
        status = function() return MissingText() end,
        tooltip = { "Left-click: lock / unlock the bar", "Right-click: list what's missing" },
    }, self.db)
end

-- Minimap button (LibDBIcon through LibForever). Left-click does what the launcher button does.
function BW:RegisterMinimap()
    if not (LIB and LIB.RegisterMinimapButton) then return end
    LIB.RegisterMinimapButton("BuffWarden", {
        icon = "Interface\\AddOns\\BuffWarden\\Media\\minimap",
        label = "BuffWarden",
        OnClick = function(_, button)
            if button == "RightButton" then BW:OpenOptions() else OnLauncherClick("LeftButton") end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("BuffWarden", 1, 0.82, 0.3)
            tt:AddLine(MissingText(), 1, 1, 1)
            tt:AddLine("Left-click: lock / unlock the bar", 0.8, 0.8, 0.8)
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
                def.key, def.class:lower(), def.names[1]))
        end
    elseif cmd == "debug" then
        wipe(knownCache)
        local _, c = UnitClass("player")
        print(TAG .. " debug (" .. tostring(c) .. "):")
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
        print("  /bwarden status | welcome")
    else
        if BW.OpenOptions then BW:OpenOptions() end
    end
    BW:Refresh()
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
f:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
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
        BuffWardenDB = BuffWardenDB or {}
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
        BW:RegisterMinimap()
        if BW.RegisterWelcome then BW:RegisterWelcome() end
        -- Range and expiry change without events; a slow tick catches them.
        C_Timer.NewTicker(5, function() if not InCombatLockdown() then BW:Refresh() end end)
        C_Timer.After(2, function() BW:Refresh() end)
        return
    end
    if not BW.db then return end
    if event == "UNIT_AURA" then
        if unit ~= "player" and not (unit and (unit:find("^party") or unit:find("^raid"))) then return end
        if InCombatLockdown() or not AuraUpdateMatters(unit, info) then return end
        BW:ScheduleRefresh(unit == "player" and 0.2 or 1)   -- your own cast: gone almost at once
    elseif event == "UNIT_POWER_UPDATE" then
        -- rage decides whether a short buff like Battle Shout is worth reminding about
        if unit == "player" and info == "RAGE" and not InCombatLockdown() then BW:ScheduleRefresh() end
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_LEVEL_UP" then
        wipe(knownCache)
        BW:ScheduleRefresh()
    elseif event == "PLAYER_REGEN_DISABLED" then
        BW:SetStale(true)
    elseif event == "PLAYER_REGEN_ENABLED" then
        BW:SetStale(false)
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
