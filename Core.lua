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
    threshold    = 120,     -- a buff with fewer seconds left than this counts as missing
    hideInCombat = true,    -- the bar is secure; this hides it through a state driver
    locked       = true,
    scale        = 1,
    point        = nil,     -- { point, relPoint, x, y }
    disabled     = {},      -- [buffKey] = true / false (overrides the buff's default)
    askText      = "Could I get %s, please? :)",
    readyCheck   = true,    -- print what's missing on a ready check
}

local function BuffEnabled(def)
    local v = BW.db.disabled[def.key]
    if v == nil then return def.default ~= false end
    return not v
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

local function InRange(spell, unit)
    if UnitIsUnit(unit, "player") then return true end
    local r = C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(spell, unit)
    return r ~= false   -- nil = can't tell, give it the benefit of the doubt
end

local function FmtTime(s)
    if s >= 60 then return ("%dm"):format(math.floor(s / 60 + 0.5)) end
    return ("%ds"):format(math.floor(s))
end

-- All helpful auras on a unit, by name: { expires = remaining seconds or math.huge, source = unit }.
local function ReadAuras(unit)
    local out = {}
    local now = GetTime()
    for i = 1, 60 do
        local a = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
        if not a then break end
        local name = Clean(a.name)
        if name then
            local exp = Clean(a.expirationTime) or 0
            out[name] = {
                left = (exp > 0) and (exp - now) or math.huge,
                source = Clean(a.sourceUnit),
                icon = Clean(a.icon),
            }
        end
    end
    return out
end

-- The first matching aura that still has enough time left. Returns found, secondsLeftIfExpiring.
local function HasBuff(auras, names)
    local best
    for _, n in ipairs(names) do
        local a = auras[n]
        if a then
            if a.left > BW.db.threshold then return true end
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
    for _, u in ipairs(units) do
        if UnitExists(u) and UnitIsConnected(u) then
            local _, class = UnitClass(u)
            local isMe = UnitIsUnit(u, "player")
            if class and not isMe then
                providers[class] = providers[class] or {}
                table.insert(providers[class], u)
            end
            if not UnitIsDeadOrGhost(u) and (isMe or UnitIsVisible(u)) then
                members[#members + 1] = {
                    unit = isMe and "player" or u,
                    name = GetUnitName(u, true) or "?",
                    class = class,
                    isMe = isMe,
                    auras = ReadAuras(u),
                }
            end
        end
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

local function IsBlessedBy(m, byMe)
    for _, n in ipairs(BW.BLESSING_NAMES) do
        local a = m.auras[n]
        if a and a.left > BW.db.threshold then
            local mine = a.source and UnitIsUnit(a.source, "player")
            if byMe and mine then return true end
            if not byMe and not mine then return true, a.source end
        end
    end
    return false
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
                if mine then
                    local ok, left = HasBuff(me.auras, def.names)
                    if not ok then
                        entries[#entries + 1] = { key = def.key, def = def, mode = "cast", spell = mine,
                            targets = { me }, target = me, expiring = left }
                    end
                end

            elseif def.scope == "group" then
                if mine then
                    local missing, target, expiring = {}, nil, nil
                    for _, m in ipairs(members) do
                        if Eligible(def, m) then
                            local ok, left = HasBuff(m.auras, def.names)
                            if not ok then
                                missing[#missing + 1] = m
                                if m.isMe then expiring = left end
                                if not target and InRange(mine, m.unit) then target = m end
                            end
                        end
                    end
                    if #missing > 0 then
                        entries[#entries + 1] = { key = def.key, def = def, mode = "cast", spell = mine,
                            targets = missing, target = target or missing[1], expiring = expiring }
                    end
                elseif providers[def.class] and Eligible(def, me) then
                    local ok, left = HasBuff(me.auras, def.names)
                    if not ok then
                        entries[#entries + 1] = { key = def.key, def = def, mode = "ask", spell = def.cast[1],
                            providers = providers[def.class], expiring = left }
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
                local pals = providers.PALADIN
                if pals and #pals > 0 then
                    local have, from = 0, {}
                    for _, n in ipairs(BW.BLESSING_NAMES) do
                        local a = me.auras[n]
                        if a and a.left > BW.db.threshold and not (a.source and UnitIsUnit(a.source, "player")) then
                            have = have + 1
                            if a.source then from[#from + 1] = a.source end
                        end
                    end
                    if have < #pals then
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

local function SavePosition()
    local p, _, rp, x, y = bar:GetPoint(1)
    BW.db.point = { p, rp, x, y }
end

local function ButtonOnEnter(self)
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(e.spell, 1, 0.82, 0.3)
    if e.preview then
        GameTooltip:AddLine(e.preview, 1, 1, 1, true)
        GameTooltip:AddLine("Preview - drag to move, /bw lock when done.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
        return
    end
    if e.expiring then
        GameTooltip:AddLine("Running out on you: " .. FmtTime(e.expiring) .. " left", 1, 0.6, 0.2)
    end
    if e.mode == "cast" then
        if #e.targets == 1 and e.targets[1].isMe then
            GameTooltip:AddLine("You're missing it.", 1, 1, 1)
        else
            GameTooltip:AddLine("Missing on " .. #e.targets .. ":", 1, 1, 1)
            for _, m in ipairs(e.targets) do
                local near = InRange(e.spell, m.unit)
                local line = (LIB and LIB.ColorName(m.name, m.class) or m.name)
                if not near then line = line .. " |cff888888(out of range)|r" end
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

    b:SetScript("OnEnter", ButtonOnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- While unlocked the whole bar can be dragged by any of its (preview) buttons.
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function() if not BW.db.locked then bar:StartMoving() end end)
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
    bar:SetScript("OnDragStart", function() if not BW.db.locked then bar:StartMoving() end end)
    bar:SetScript("OnDragStop", function() bar:StopMovingOrSizing(); SavePosition() end)

    self:ApplyCombatSetting()
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
        local c = e.expiring and COLORS.expiring or COLORS[e.mode]
        b.border:SetVertexColor(c[1], c[2], c[3])
        b.count:SetText((e.mode == "cast" and #e.targets > 1) and #e.targets or "")
        b.timer:SetText(e.expiring and FmtTime(e.expiring) or "")

        b:SetAttribute("type", nil)
        b:SetAttribute("spell", nil)
        b:SetAttribute("unit", nil)
        b:SetAttribute("macrotext", nil)
        if e.preview then
            -- placeholders: no click actions
        elseif e.mode == "cast" then
            b:SetAttribute("type", "spell")
            b:SetAttribute("spell", e.spell)
            b:SetAttribute("unit", e.target.unit)
        elseif e.providers[1] then
            local who = GetUnitName(e.providers[1], true)
            if who then
                b:SetAttribute("type", "macro")
                b:SetAttribute("macrotext", "/w " .. who .. " " .. self.db.askText:format(e.spell))
            end
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
function BW:Refresh()
    if not self.db then return end
    local entries = self:Compute()
    self.entries = entries
    if LIB and LIB.SetLauncherBadge then LIB.SetLauncherBadge("BuffWarden", #entries) end
    self:Apply(entries)
end

function BW:ScheduleRefresh()
    if self.timer then return end
    self.timer = C_Timer.NewTimer(0.3, function()
        BW.timer = nil
        BW:Refresh()
    end)
end

function BW:Report(prefix)
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
local function ToggleLock()
    BW.db.locked = not BW.db.locked
    print(TAG .. ": bar " .. (BW.db.locked and "locked." or "unlocked - showing a preview, drag it into place."))
    BW:Refresh()
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
        status = function()
            local n = BW.entries and #BW.entries or 0
            return n == 0 and "All buffed up." or (n .. " buff" .. (n == 1 and "" or "s") .. " missing")
        end,
        tooltip = { "Left-click: lock / unlock the bar", "Right-click: list what's missing" },
    }, self.db)
end

SLASH_BUFFWARDEN1 = "/buffwarden"
SLASH_BUFFWARDEN2 = "/bw"
SlashCmdList.BUFFWARDEN = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    local db = BW.db
    if cmd == "lock" or cmd == "unlock" or cmd == "move" then
        db.locked = (cmd == "lock")
        print(TAG .. ": bar " .. (db.locked and "locked." or "unlocked - showing a preview, drag it into place."))
    elseif cmd == "reset" then
        if InCombatLockdown() then print(TAG .. ": not in combat.") return end
        db.point = nil
        bar:ClearAllPoints()
        bar:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
        print(TAG .. ": position reset.")
    elseif cmd == "scale" and tonumber(arg) then
        if InCombatLockdown() then print(TAG .. ": not in combat.") return end
        db.scale = math.min(2, math.max(0.5, tonumber(arg)))
        bar:SetScale(db.scale)
    elseif cmd == "time" and tonumber(arg) then
        db.threshold = tonumber(arg)
        print(TAG .. ": buffs with less than " .. db.threshold .. "s left count as missing.")
    elseif cmd == "combat" then
        db.hideInCombat = not db.hideInCombat
        BW:ApplyCombatSetting()
        print(TAG .. ": " .. (db.hideInCombat and "hidden in combat." or "shown in combat."))
    elseif cmd == "toggle" and arg ~= "" then
        for _, def in ipairs(BW.BUFFS) do
            if def.key == arg then
                db.disabled[arg] = BuffEnabled(def)
                print(TAG .. ": " .. arg .. " " .. (BuffEnabled(def) and "|cff66ff66on|r" or "|cffff6666off|r"))
                BW:Refresh()
                return
            end
        end
        print(TAG .. ": unknown buff '" .. arg .. "'. See /bw list.")
    elseif cmd == "list" then
        print(TAG .. ": watched buffs (/bw toggle <key>):")
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
        for name, a in pairs(ReadAuras("player")) do
            print(("  aura: %s (%s)"):format(name, a.left == math.huge and "no timer" or FmtTime(a.left)))
        end
    elseif cmd == "status" or cmd == "report" then
        BW:Report()
    else
        print(TAG .. " v" .. BW.version .. " commands:")
        print("  /bw unlock | lock | reset | scale <0.5-2>")
        print("  /bw time <seconds>  - refresh buffs with less than this left (now " .. db.threshold .. ")")
        print("  /bw combat  - toggle hiding in combat")
        print("  /bw list | toggle <key>  - choose which buffs to watch")
        print("  /bw status | debug")
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
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("READY_CHECK")
f:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" then
        BuffWardenDB = BuffWardenDB or {}
        for k, v in pairs(defaults) do
            if BuffWardenDB[k] == nil then BuffWardenDB[k] = (type(v) == "table") and {} or v end
        end
        BW.db = BuffWardenDB
        BW:CreateBar()
        BW:RegisterLauncher()
        -- Range and expiry change without events; a slow tick catches them.
        C_Timer.NewTicker(3, function() if not InCombatLockdown() then BW:Refresh() end end)
        C_Timer.After(2, function() BW:Refresh() end)
        print(TAG .. " v" .. BW.version .. " loaded. /bw for commands.")
        return
    end
    if not BW.db then return end
    if event == "UNIT_AURA" then
        if unit ~= "player" and not (unit and (unit:find("^party") or unit:find("^raid"))) then return end
        if InCombatLockdown() then return end
        BW:ScheduleRefresh()
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_LEVEL_UP" then
        wipe(knownCache)
        BW:ScheduleRefresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if BW.combatDirty then BW.combatDirty = nil; BW:ApplyCombatSetting() end
        BW:Refresh()
    elseif event == "READY_CHECK" then
        BW:Refresh()
        if BW.db.readyCheck then BW:Report("ready check - ") end
    else
        BW:ScheduleRefresh()
    end
end)
