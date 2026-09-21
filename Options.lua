-- BuffWarden settings page (Options > AddOns > BuffWarden). The minimap and launcher buttons are set
-- on the shared YippYapp page (LibForever), linked at the bottom.
local ADDON, BW = ...

local LIB = LibStub and LibStub("LibForever-1.0", true)
local TAG = "|cff66ccffBuffWarden|r"
local refreshers = {}

local PAD = 8          -- left edge inside the page
local COL_W = 300      -- width of one column in the buff grid

-- Everything is laid out top to bottom with a running y, so sections never overlap or leave holes.
local function Layout(parent)
    local L = { y = -6 }

    function L.Gap(h) L.y = L.y - h end

    function L.Header(text)
        L.Gap(10)
        local h = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        h:SetPoint("TOPLEFT", PAD, L.y)
        h:SetText(text)
        L.Gap(20)
    end

    function L.Note(text, indent)
        local n = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        n:SetPoint("TOPLEFT", PAD + (indent or 0), L.y)
        n:SetWidth(600 - (indent or 0))
        n:SetJustifyH("LEFT")
        n:SetText(text)
        L.Gap(n:GetStringHeight() + 6)
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
            L.Gap(24)
            L.Note(note, 30)
        end
        return cb
    end

    return L
end

function BW:BuildOptions()
    if self.panel then return end
    local panel = CreateFrame("Frame")
    panel.name = "BuffWarden"
    self.panel = panel
    local db = self.db

    local f = CreateFrame("Frame", nil, panel)
    f:SetPoint("TOPLEFT", 10, -10)
    f:SetPoint("BOTTOMRIGHT", -10, 10)
    local L = Layout(f)

    -- Title ------------------------------------------------------------------
    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD, L.y)
    title:SetText("BuffWarden |cff888888v" .. BW.version .. "|r")
    L.Gap(26)
    local sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", PAD, L.y)
    sub:SetWidth(600)
    sub:SetJustifyH("LEFT")
    sub:SetText("Shows the buffs you and your group are missing. Click an icon to cast it, or to ask the "
        .. "groupmate who has it.")
    L.Gap(sub:GetStringHeight() + 4)

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

    L.Check("Ignore groupmates who are far away",
        "Someone in another zone, or a long way off, isn't counted as missing a buff. Groupmates just "
        .. "out of casting range are still shown, marked \"out of range\".",
        function() return db.ignoreFar end,
        function(v) db.ignoreFar = v; BW:Refresh() end)

    -- Which buffs --------------------------------------------------------------
    L.Header("Which buffs")
    L.Note("Untick a buff to stop watching it. Your own class's buffs show as gold (you cast them); group "
        .. "buffs from other classes show as grey (you ask for them). A buff with less than "
        .. math.floor(db.threshold / 60 + 0.5) .. " minutes left counts as missing (/bwarden time <seconds>).")
    L.Gap(2)
    local rowY = L.y
    for i, def in ipairs(BW.BUFFS) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local name = (def.spellID and C_Spell.GetSpellName(def.spellID)) or def.cast[1]
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[def.class]
        local classText = c and ("|c%s%s|r"):format(c.colorStr, def.class:sub(1, 1) .. def.class:sub(2):lower())
            or def.class
        L.y = rowY - row * 26
        L.Check(("|T%s:16:16|t %s  %s"):format(tostring(BW.IconFor(def)), name, classText), nil,
            function() return BW.BuffEnabled(def) end,
            function(v) db.disabled[def.key] = not v; BW:Refresh() end,
            PAD + col * COL_W,
            def.scope == "self" and "A buff you put on yourself." or "A buff for the whole group.")
    end
    L.y = rowY - math.ceil(#BW.BUFFS / 2) * 26

    -- Chat ---------------------------------------------------------------------
    L.Header("Chat")
    L.Check("List what's missing on a ready check",
        "Prints the buffs you can cast and the ones you're missing when someone starts a ready check.",
        function() return db.readyCheck end,
        function(v) db.readyCheck = v end)

    -- Minimap & launcher (link to the shared YippYapp page), welcome, footer ----------
    -- The link block is one line of text with its button under it; "Welcome" sits beside that button.
    L.Gap(12)
    local block
    if LIB and LIB.LauncherOptions then
        block = LIB.LauncherOptions(f, "BuffWarden")
        block:SetPoint("TOPLEFT", PAD - 4, L.y)
    end
    if LIB and LIB.OpenWelcome then
        local welcome = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        welcome:SetSize(170, 22)
        if block and block.button then
            welcome:SetPoint("LEFT", block.button, "RIGHT", 12, 0)
        else
            welcome:SetPoint("TOPLEFT", PAD - 4, L.y)
        end
        welcome:SetText("Welcome / what's new")
        welcome:SetScript("OnClick", function()
            -- The Options panel is protected in combat; leave it open then.
            if SettingsPanel and SettingsPanel:IsShown() and not InCombatLockdown() then SettingsPanel:Close() end
            LIB.OpenWelcome("BuffWarden")
        end)
    end
    L.Gap(block and block:GetHeight() or 30)
    local footer = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("TOPLEFT", PAD, L.y)
    footer:SetWidth(600)
    footer:SetJustifyH("LEFT")
    footer:SetText("|cffffd100/bwarden|r opens this page.  |cffffd100/bwarden help|r lists the commands.\n"
        .. "Part of YippYapp - addons for WoW: Forever that work even better together.")

    panel:SetScript("OnShow", function() for _, r in ipairs(refreshers) do r() end end)

    -- A subcategory under YippYapp (LibForever); an older lib without it gets a page of its own.
    if LIB and LIB.RegisterOptionsPage then
        self.category = LIB.RegisterOptionsPage("BuffWarden", panel)
    end
    if not self.category and Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "BuffWarden")
        Settings.RegisterAddOnCategory(category)
        self.category = category
    end
end

function BW:OpenOptions()
    if not self.category then print(TAG .. ": the settings page isn't available.") return end
    -- Opening the settings panel is protected: blocked in combat.
    if InCombatLockdown() then
        print(TAG .. ": settings can't be opened during combat.")
        return
    end
    local id = self.category.GetID and self.category:GetID() or self.category.ID
    Settings.OpenToCategory(id)
end
