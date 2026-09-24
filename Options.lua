-- BuffWarden's settings page. LibForever hosts it in the shared YippYapp window (which also holds the
-- minimap, launcher and other shared settings), gives it the window's width and scrolls it for us.
local ADDON, BW = ...

local LIB = LibStub and LibStub("LibForever-1.0", true)
local TAG = "|cff66ccffBuffWarden|r"
local refreshers = {}

-- One set of layout rules for the whole page, so a dropdown row and a checkbox row read as the
-- same kind of thing and no paragraph is ever cut off.
--
-- Width: nothing assumes the page's width. Paragraphs are anchored to BOTH edges, so they wrap to
-- whatever the window gives us, and the vertical space reserved for them is measured at MEASURE_W,
-- the narrowest page we plan for. A wider window therefore shows a little extra air rather than
-- clipped words: the failure direction is a gap, never lost text.
--
-- Rhythm, top to bottom: BEFORE_HEAD before a heading, AFTER_HEAD under it, a control row, then
-- TEXT_GAP to that control's own description, then BLOCK_GAP before whatever comes next.
local PAD = 8            -- left edge inside the page
local INDENT = 26        -- a description, or a control, sits here under the thing it belongs to
local CONTROL_X = 200    -- every label's control starts here, so the rows line up with each other
local MEASURE_W = 468    -- the narrowest page we plan for
local COL_W = 234        -- one column of the buff grid: MEASURE_W / 2, so column two stays on the page
local BEFORE_HEAD = 16
local AFTER_HEAD = 18
local ROW_H = 26         -- a checkbox or a button row
local TEXT_GAP = 3       -- between a control and its own description
local BLOCK_GAP = 12     -- after a description, before the next control or heading

-- A paragraph that must never be cut off: anchored to BOTH edges so it wraps to whatever width the
-- page really has, with its height reserved for the narrow case.
local function Wrap(fs, parent, indent)
    fs:SetJustifyH("LEFT")
    fs:SetWidth(MEASURE_W - (indent or 0))
    local h = fs:GetStringHeight()
    fs:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
    return h
end

-- Everything is laid out top to bottom with a running y, so sections never overlap or leave holes.
local function Layout(parent)
    local L = { y = -6 }

    function L.Gap(h) L.y = L.y - h end

    function L.Header(text)
        L.Gap(BEFORE_HEAD)
        local h = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        h:SetPoint("TOPLEFT", PAD, L.y)
        h:SetText(text)
        L.Gap(AFTER_HEAD)
    end

    function L.Note(text, indent)
        local n = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        n:SetPoint("TOPLEFT", PAD + (indent or 0), L.y)
        n:SetText(text)
        L.Gap(Wrap(n, parent, indent) + BLOCK_GAP)
    end

    -- A checkbox at (x, current y); note (optional) goes under the label. Returns the checkbox.
    function L.Check(label, note, get, set, x, tooltip)
        local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetSize(26, 26)
        cb:SetPoint("TOPLEFT", (x or PAD) - 4, L.y)
        local l = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        l:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        l:SetText(label)
        cb:SetHitRectInsets(0, -math.min(260, l:GetStringWidth() + 8), 0, 0)
        cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
        if tooltip then
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(label, 1, 0.82, 0.3)
                GameTooltip:AddLine(tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        refreshers[#refreshers + 1] = function() cb:SetChecked(get()) end
        if note then
            L.Gap(ROW_H + TEXT_GAP)
            L.Note(note, INDENT)
        end
        return cb
    end

    -- "label [ value ]" - a button that steps through a few named choices.
    function L.Cycle(label, note, values, labels, get, set)
        local l = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        l:SetPoint("TOPLEFT", PAD, L.y - 5)
        l:SetText(label)
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(MEASURE_W - CONTROL_X, 22)
        btn:SetPoint("TOPLEFT", CONTROL_X, L.y)
        local function show() btn:SetText(labels[get()] or tostring(get())) end
        btn:SetScript("OnClick", function()
            local cur, nextValue = get(), values[1]
            for i, v in ipairs(values) do
                if v == cur then nextValue = values[(i % #values) + 1] end
            end
            set(nextValue)
            show()
        end)
        refreshers[#refreshers + 1] = show
        L.Gap(ROW_H + TEXT_GAP)
        if note then L.Note(note, INDENT) else L.Gap(BLOCK_GAP - TEXT_GAP) end
    end

    -- "label [-] value [+]" with a note under it; value shown by fmt(get()).
    function L.Stepper(label, note, get, set, step, lo, hi, fmt)
        local l = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        l:SetPoint("TOPLEFT", PAD, L.y - 5)
        l:SetText(label)
        local minus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        minus:SetSize(24, 22)
        minus:SetPoint("TOPLEFT", CONTROL_X, L.y)
        minus:SetText("-")
        local value = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        value:SetPoint("LEFT", minus, "RIGHT", 8, 0)
        value:SetWidth(90)
        local plus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        plus:SetSize(24, 22)
        plus:SetPoint("LEFT", value, "RIGHT", 8, 0)
        plus:SetText("+")
        local function show() value:SetText(fmt(get())) end
        minus:SetScript("OnClick", function() set(math.max(lo, get() - step)); show() end)
        plus:SetScript("OnClick", function() set(math.min(hi, get() + step)); show() end)
        refreshers[#refreshers + 1] = show
        L.Gap(ROW_H + TEXT_GAP)
        if note then L.Note(note, INDENT) else L.Gap(BLOCK_GAP - TEXT_GAP) end
    end

    -- The blessing pickers offer what this paladin has trained and nothing else: picking a blessing
    -- you cannot cast would quietly do nothing, which is worse than not offering it at all. A choice
    -- stored before it was trained still shows, marked, so the player can see why nothing happens.
    local function BlessingText(kind)
        local label = BW.BLESSING_LABEL[kind] or tostring(kind)
        local info = BW.BLESSING_KINDS[kind]
        if kind ~= "auto" and not (info and BW.Knows(info.spell)) then
            return label .. " |cffff5555(not learned)|r"
        end
        return label
    end

    local function NextBlessing(cur)
        local kinds = BW.KnownBlessingKinds()
        for i, v in ipairs(kinds) do
            if v == cur then return kinds[(i % #kinds) + 1] end
        end
        return kinds[1]      -- the current pick is untrained: step back to Class default
    end

    -- Which blessing each CLASS gets, in two columns so nine rows don't run off the page. The
    -- geometry is built from the narrow width, so the right-hand column stays on the page.
    local CLASS_ROW_H = 30
    local CLASS_BTN_W = 148
    local CLASS_LABEL_W = 64
    local CLASS_COL = math.floor(MEASURE_W / 2)   -- 234: label, button, and air before the next one
    function L.BlessingClasses()
        L.Header("Blessing by class")
        L.Note("The defaults suit a dungeon or levelling group, where drinking is what slows you "
            .. "down: Wisdom for anyone who casts, Might for pure melee, Kings for warlocks. Once "
            .. "everyone is geared, Kings beats Wisdom - set it here. One person can still be set "
            .. "below.")
        local rowY = L.y
        for i, class in ipairs(BW.BLESSING_CLASS_ORDER) do
            local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
            local x = PAD + col * CLASS_COL
            local y = rowY - row * CLASS_ROW_H
            local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
            local name = class:sub(1, 1) .. class:sub(2):lower()
            local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            label:SetPoint("TOPLEFT", x, y - 4)
            label:SetWidth(CLASS_LABEL_W)
            label:SetJustifyH("LEFT")
            label:SetText(c and ("|c%s%s|r"):format(c.colorStr, name) or name)
            local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
            btn:SetSize(CLASS_BTN_W, 22)
            btn:SetPoint("TOPLEFT", x + CLASS_LABEL_W + 6, y)
            local function show()
                local pick = BW.db.blessForClass[class]
                btn:SetText(pick and (BlessingText(pick):gsub("Blessing of ", ""))
                    or BW.BLESSING_LABEL.auto)
            end
            btn:SetScript("OnClick", function()
                local nextKind = NextBlessing(BW.db.blessForClass[class] or "auto")
                BW.db.blessForClass[class] = (nextKind ~= "auto") and nextKind or nil
                show()
                BW:Refresh()
            end)
            refreshers[#refreshers + 1] = show
        end
        L.y = rowY - math.ceil(#BW.BLESSING_CLASS_ORDER / 2) * CLASS_ROW_H
        L.Gap(BLOCK_GAP)
    end

    -- Who gets which blessing: one row per groupmate, filled in from the live group whenever the page
    -- is shown. Five rows is a full party; a raid shows your own group.
    function L.Blessings()
        L.Header("Who gets which blessing")
        L.Note("Anyone left on \"Class default\" follows the list above. You are the exception: you "
            .. "get Might unless you have trained the healer talents, since you are the one meleeing. "
            .. "The icon's tooltip always says which blessing and why.")
        local rows = {}
        for i = 1, 5 do
            local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            label:SetPoint("TOPLEFT", PAD, L.y - 4)
            label:SetWidth(150)
            label:SetJustifyH("LEFT")
            local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
            btn:SetSize(300, 22)
            btn:SetPoint("TOPLEFT", PAD + 156, L.y)
            btn:SetScript("OnClick", function(self)
                if not self.full then return end
                local nextKind = NextBlessing(BW.db.blessFor[self.full] or "auto")
                BW.db.blessFor[self.full] = (nextKind ~= "auto") and nextKind or nil
                self:SetText(BlessingText(nextKind))
                BW:Refresh()
            end)
            rows[i] = { label = label, btn = btn }
            L.Gap(ROW_H + 4)
        end
        refreshers[#refreshers + 1] = function()
            local units = { "player" }
            for i = 1, 4 do units[#units + 1] = "party" .. i end
            for i, row in ipairs(rows) do
                local u = units[i]
                local name = u and UnitExists(u) and GetUnitName(u, true)
                row.full = name or nil
                row.btn.full = row.full
                if name then
                    local _, class = UnitClass(u)
                    row.label:SetText(LIB and LIB.ColorName(name, class) or name)
                    row.btn:SetText(BlessingText(BW.db.blessFor[name] or "auto"))
                    row.label:Show()
                    row.btn:Show()
                else
                    row.label:SetText(i == 1 and "|cff888888(nobody in your group)|r" or "")
                    row.btn:Hide()
                end
            end
        end
    end

    return L
end

function BW:BuildOptions()
    if self.panel then return end
    local panel = CreateFrame("Frame")
    panel.name = "BuffWarden"
    self.panel = panel
    local db = self.db

    -- Content sits in a frame that follows the page width; the lib scrolls the page when we tell it how
    -- tall we are (the 4th argument to RegisterOptionsPage).
    local f = CreateFrame("Frame", nil, panel)
    f:SetPoint("TOPLEFT", 6, -6)
    f:SetPoint("TOPRIGHT", -6, -6)
    f:SetHeight(10)
    local L = Layout(f)

    -- Title ------------------------------------------------------------------
    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD, L.y)
    title:SetText("BuffWarden |cff888888v" .. BW.version .. "|r")
    L.Gap(ROW_H)
    local sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", PAD, L.y)
    sub:SetText("Shows the buffs you and your group are missing. Click an icon to cast it, or to ask the "
        .. "groupmate who has it.")
    L.Gap(Wrap(sub, f) + 6)

    local _, myClass = UnitClass("player")

    -- Bar --------------------------------------------------------------------
    L.Header("Bar")
    L.Check("Unlock the bar",
        "Shows a preview of the icons so you can drag the bar into place. Untick to lock it again.",
        function() return not db.locked end,
        function(v) BW:SetLocked(not v) end)   -- in combat SetLocked waits for combat to end
    L.Check("Hide in combat",
        "The icons can't change during combat, so by default they're hidden until it ends.",
        function() return db.hideInCombat end,
        function(v) db.hideInCombat = v; BW:ApplyCombatSetting() end)

    L.Stepper("Warn when a buff has less than", "The icon turns orange and shows the time left. Short "
        .. "buffs warn at a tenth of their duration instead (at least a minute).",
        function() return math.floor(db.threshold / 60 + 0.5) end,
        function(v) db.threshold = v * 60; BW:Refresh() end,
        1, 1, 15, function(v) return v .. " min left" end)

    L.Stepper("Icons on one line", "Everything BuffWarden shows - buffs, weapon buffs and the blessing "
        .. "buttons - sits on one line until there are this many, then a second line starts.",
        function() return db.perRow end,
        function(v) db.perRow = v; BW:Refresh() end,
        1, 2, 16, function(v) return v .. " icons" end)

    L.Check("Ignore groupmates who are far away",
        "Someone in another zone, or a long way off, isn't counted as missing a buff. Groupmates just "
        .. "out of casting range are still shown, marked \"out of range\".",
        function() return db.ignoreFar end,
        function(v) db.ignoreFar = v; BW:Refresh() end)

    -- Which buffs --------------------------------------------------------------
    L.Header("Which buffs")
    L.Note("Untick a buff to stop watching it. Your own class's buffs show as gold (you cast them); group "
        .. "buffs from other classes show as grey (you ask for them).")
    local rowY = L.y
    for i, def in ipairs(BW.BUFFS) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        -- Not every buff comes from a class spell: Well Fed is eaten, so it has no class and nothing
        -- to look a name up from. Fall back through what the buff does have.
        local name = (def.spellID and C_Spell.GetSpellName(def.spellID)) or def.cast[1]
            or def.names[1] or def.key
        local classText = ""
        if def.class then
            local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[def.class]
            local pretty = def.class:sub(1, 1) .. def.class:sub(2):lower()
            classText = c and ("|c%s%s|r"):format(c.colorStr, pretty) or pretty
        elseif def.scope == "food" then
            classText = "|cff888888Food|r"
        end
        L.y = rowY - row * ROW_H
        L.Check(("|T%s:16:16|t %s  %s"):format(tostring(BW.IconFor(def)), name, classText), nil,
            function() return BW.BuffEnabled(def) end,
            function(v) db.disabled[def.key] = not v; BW:Refresh() end,
            PAD + col * COL_W,
            def.note or (def.scope == "self" and "A buff you put on yourself." or "A buff for the whole group."))
    end
    L.y = rowY - math.ceil(#BW.BUFFS / 2) * ROW_H

    if myClass == "PALADIN" then
        L.Check("Show a row of blessing buttons",
            "One button per blessing you know, on the same row: how many people want it, who is next, "
            .. "and a click casts it and moves on. The row appears only when someone actually needs a "
            .. "blessing, and the ones nobody asked for are dimmed, for when you want to pick yourself.",
            function() return db.blessRow end,
            function(v) db.blessRow = v; BW:Refresh() end)
        L.Check("Name the next person on the button",
            "The name sits under each blessing button, so you see who you are about to buff. Turn it off "
            .. "for a smaller row - the tooltip still says who.",
            function() return db.blessNames end,
            function(v) db.blessNames = v; BW:Refresh() end)
        L.BlessingClasses()
        L.Blessings()
        L.Check("Kings to everyone I can",
            "Off: each class gets what the list above says. On: Blessing of Kings to everyone you "
            .. "know it for, whatever their class. The icon's tooltip always says which blessing and "
            .. "why.",
            function() return db.blessKings end,
            function(v) db.blessKings = v; BW:Refresh() end)
    end

    -- Weapon buffs ---------------------------------------------------------------
    L.Header("Weapon buffs")
    L.Check("Watch the buff on my weapons",
        "Sharpening stones, weightstones, oils and shaman imbues. Nothing is shown unless you have a "
        .. "usable stone or oil in your bags (or the imbue spell), and never for a fishing pole. This is "
        .. "the one buff BuffWarden can still read during combat, so it also shows there.",
        function() return db.weaponBuffs end,
        function(v) db.weaponBuffs = v; BW:Refresh() end)
    if myClass == "SHAMAN" then
        -- The whole list stays, since a trainer visit changes it, but one you have not trained says
        -- so instead of looking available.
        local imbueLabels = setmetatable({}, { __index = function(_, k)
            local label = BW.IMBUE_LABEL[k] or tostring(k)
            if k ~= "auto" and not BW.Knows(k) then return label .. " |cffff5555(not learned)|r" end
            return label
        end })
        L.Cycle("Weapon imbue", "Which imbue to remind you about. It goes on your main hand. Pick one "
            .. "you have not trained and BuffWarden uses the best one you know instead.",
            { "auto", "Windfury Weapon", "Flametongue Weapon", "Frostbrand Weapon", "Rockbiter Weapon" },
            imbueLabels,
            function() return db.imbuePref end,
            function(v) db.imbuePref = v; BW:Refresh() end)
    elseif myClass == "ROGUE" then
        -- Poisons are bag items, so "you cannot use that" means "none on you", and it changes as
        -- you shop. The list stays whole and says which ones you are out of.
        local poisonLabels = setmetatable({}, { __index = function(_, k)
            local label = BW.POISON_LABEL[k] or tostring(k)
            if k ~= "auto" and k ~= "none" and not BW.CarryPoison(k) then
                return label .. " |cffff5555(none in your bags)|r"
            end
            return label
        end })
        L.Cycle("Main hand poison", nil, BW.POISON_CHOICES, poisonLabels,
            function() return db.poisonMain end,
            function(v) db.poisonMain = v; BW:Refresh() end)
        L.Cycle("Off hand poison", "Whichever you pick, BuffWarden uses the strongest rank you carry. "
            .. "Don't carry the one you picked and it offers what you do have.",
            BW.POISON_CHOICES, poisonLabels,
            function() return db.poisonOff end,
            function(v) db.poisonOff = v; BW:Refresh() end)
    end
    L.Cycle("Which stone or oil", "A stone is matched to your weapon: blades sharpened, blunt weapons "
        .. "weighted. Oils fit any of them, so this decides when you carry both.",
        { "auto", "stone", "oil" },
        { auto = "Automatic (oil for casters, a stone otherwise)",
          stone = "Always a stone", oil = "Always an oil" },
        function() return db.weaponPref end,
        function(v) db.weaponPref = v; BW:Refresh() end)

    -- Chat ---------------------------------------------------------------------
    L.Header("Chat")
    L.Check("List what's missing on a ready check",
        "Prints the buffs you can cast and the ones you're missing when someone starts a ready check.",
        function() return db.readyCheck end,
        function(v) db.readyCheck = v end)

    -- Footer -------------------------------------------------------------------
    L.Gap(BEFORE_HEAD + BLOCK_GAP)
    local footer = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("TOPLEFT", PAD, L.y)
    footer:SetText("|cffffd100/bwarden|r opens this page.  |cffffd100/bwarden help|r lists the commands.\n"
        .. "Part of YippYapp - addons for WoW: Forever that work even better together.")
    L.Gap(Wrap(footer, f) + 12)
    local height = -L.y
    f:SetHeight(height)
    panel:SetHeight(height)

    -- Fill in the current values whenever the page is shown. The panel itself may already count as
    -- "shown" when Settings adopts it (so its OnShow never fires): refresh from the scroll child's OnShow,
    -- from Settings' own OnRefresh, and once now.
    local function Refresh() for _, r in ipairs(refreshers) do r() end end
    panel:HookScript("OnShow", Refresh)
    f:SetScript("OnShow", Refresh)
    panel.OnRefresh = Refresh
    Refresh()

    -- Hosted in the YippYapp window (LibForever); an older lib without it gets a Blizzard page instead.
    if LIB and LIB.RegisterOptionsPage then
        self.category = LIB.RegisterOptionsPage("BuffWarden", panel, "BuffWarden", height)
        self.hosted = self.category ~= nil
    end
    if not self.category and Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "BuffWarden")
        Settings.RegisterAddOnCategory(category)
        self.category = category
    end
end

function BW:OpenOptions()
    if not self.category then print(TAG .. ": the settings page isn't available.") return end
    -- Opening a window is protected in combat (Blizzard's panel goes through the game menu).
    if InCombatLockdown() then
        print(TAG .. ": settings can't be opened during combat.")
        return
    end
    -- Our own window first: a hosted page has no Blizzard category ID to open. Every path that fails
    -- says so, so a click never just does nothing.
    local open = LIB and (LIB.OpenAddonSettings or LIB.OpenYippYappSettings)
    if self.hosted and open then
        local ok, err = pcall(open, "BuffWarden")
        if ok then return end
        print(TAG .. ": couldn't open the YippYapp settings (" .. tostring(err) .. ").")
        return
    end
    local id = not self.hosted and self.category.GetID and self.category:GetID() or self.category.ID
    if id and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(id)
        return
    end
    print(TAG .. ": couldn't open the settings - type /bwarden help for the commands.")
end
