local ADDON, BW = ...

-- BuffWarden's page and card in LibForever's shared YippYapp window (/yippyapp). Nothing has to be set
-- up, but until the bar has been dragged somewhere it sits under the middle of the screen, so the card
-- offers to place it.
local LIB = LibStub and LibStub("LibForever-1.0", true)

local ROWS = {
    { icon = "Interface\\Icons\\Spell_Holy_WordFortitude", head = "What it shows",
      text = "A small row of icons for the buffs you're missing: your own (Inner Fire, Mage Armor, "
          .. "Aspects...), the group buffs your party can give (Fortitude, Arcane Intellect, "
          .. "Mark of the Wild, Blessings), food, and the buff on your weapon - stones, oils, imbues "
          .. "and poisons. When nothing is missing, nothing is shown." },
    { icon = "Interface\\Icons\\Spell_Holy_MagicalSentry", head = "One click to fix it",
      text = "|cffffd24dGold|r: you can cast it yourself. The number is how many in your group are "
          .. "missing it, and a click casts it on the nearest one.\n"
          .. "|cff8fa6c0Grey|r: a groupmate has it. A click whispers them to ask.\n"
          .. "|cffff7a1aOrange|r: it's running out soon." },
    { icon = "Interface\\Icons\\INV_Misc_Gear_01", head = "Move, lock and settings",
      text = "Left-click the BuffWarden icon on the minimap - behind the YippYapp button if you use "
          .. "several YippYapp addons - to unlock the bar: you get a preview to drag into place, and a "
          .. "second click locks it again (/bwarden unlock and lock do the same). Right-click the icon, "
          .. "or type /bwarden, for the settings: which buffs to watch, and more. The bar hides in "
          .. "combat." },
}

local function Build(page)
    local width = page:GetWidth() - 72
    local y = -8
    for _, r in ipairs(ROWS) do
        local icon = page:CreateTexture(nil, "ARTWORK")
        icon:SetSize(28, 28)
        icon:SetPoint("TOPLEFT", 16, y)
        icon:SetTexture(r.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local head = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        head:SetPoint("TOPLEFT", 56, y)
        head:SetText(r.head)

        local text = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
        text:SetWidth(width)
        text:SetJustifyH("LEFT")
        text:SetSpacing(2)
        text:SetText(r.text)

        y = y - math.max(32, head:GetStringHeight() + 4 + text:GetStringHeight()) - 16
    end

    local place = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    place:SetSize(150, 24)
    place:SetPoint("TOPLEFT", 56, y)
    place:SetText("Place the bar now")
    place:SetScript("OnClick", function() BW:SetLocked(false) end)   -- waits for combat by itself
end

function BW:RegisterWelcome()
    if not (LIB and LIB.RegisterWelcome) then return end
    LIB.RegisterWelcome({
        id = "BuffWarden",
        title = "BuffWarden",
        subtitle = "See which buffs you and your group are missing, and fix them in one click.",
        blurb = "Shows the buffs you and your group are missing, and casts or asks for them in one click.",
        needsSetup = function() return not (BW.db and BW.db.placed) end,
        reason = "The bar is still in its default spot - place it where you want it.",
        setupLabel = "Place the bar",
        -- "Open BuffWarden" is the bar itself: this matches a left-click on its icon (the shared row
        -- uses it too). Right-click goes to the settings, and placing the bar stays the card's setup
        -- action, which opens the page below and its "Place the bar now" button.
        onOpen = function() BW:SetLocked(not BW.db.locked) end,
        icon = "Interface\\AddOns\\BuffWarden\\Media\\icon",
        version = 1,
        order = 45,
        build = Build,
    }, self.db)
end
