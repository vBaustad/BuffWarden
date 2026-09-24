# BuffWarden

## 0.1.0-beta6

- Settings page: a proper pass over the whole thing. No paragraph is cut off any more - they wrap to the window's real width instead of an assumed one, which is what clipped "Kings beats Wisdom - set it here" and the weapon-buff description. One vertical rhythm throughout, so a description sits under the setting it belongs to and away from the next heading, and every dropdown and stepper lines its control up in the same column, so those rows read like the checkbox rows above them. The blessing rows and the footer got room to breathe.
- `/bwarden debug` and the `/yippyapp test` line now say which signal decided whether you are tanking: your talents, the group's roles, or a shield with no points spent. The answer was always there; which of the three produced it was not, and they are not equally trustworthy.

## 0.1.0-beta5

- Weapon buffs: BuffWarden now watches the temporary enchant on your weapons - sharpening stones, weightstones, oils and shaman imbues - and one click applies the right one from your bags (blades get sharpened, blunt weapons weighted; "Which one to use" in the settings decides when you carry both). Nothing is shown unless you have a usable stone or oil, and never for a fishing pole.
- Well Fed: BuffWarden now tells you when you're missing the food buff. With AutoFeed installed, a click eats your best food through its macro; without it, the icon is a reminder.
- Rogues: poisons, one hand at a time, with the strongest rank you carry. Pick which poison goes on each hand in the settings (the default is Instant on the main hand, Deadly on the off hand), or turn one hand off.
- Shamans: pick which weapon imbue to be reminded about (Windfury, Flametongue, Frostbrand, Rockbiter), or let BuffWarden use the best one you know.
- Paladins: a row with one button per Blessing you know, each showing who the next click will buff. The tooltip always says which Blessing and why, and says so plainly when it's a guess. The defaults are built for dungeons and levelling, where drinking between pulls is what costs you the evening: Wisdom for anyone who casts, Might for pure melee, Kings for warlocks. Hunters get Wisdom, not Might - Blessing of Might is melee attack power and does nothing for a shot. You are the exception to your own rules: you get Might unless you have trained the healer talents, because whatever you eventually become, right now you are the one meleeing. (Forever has no Blessing of Sanctuary, so it is no longer offered anywhere.) "Blessing by class" and "Who gets which blessing" in the settings override all of it, and once the group is geared, Kings beats Wisdom.
- The blessing row only appears when someone actually needs a blessing from you, so a paladin who has blessed himself and is standing alone sees nothing. When it is up you get every blessing you know, and the ones nobody asked for are dimmed: click one and it goes to whoever you're pointing at in your party frames, or to your target, or to you - which is how you hand Salvation to the one pulling aggro off the tank.
- BuffWarden now reads your own talents, which Forever keeps in one tree per class with the three old tabs inside it. Nothing about other players changes - we still can't see their spec, and don't pretend to - but about ourselves we no longer guess.
- Fixed: a holy paladin with a shield was told to keep Righteous Fury up. That is advice that gets a healer killed, and it happened because a shield was the only way to tell a tank from a healer. Now your talents decide, and the shield is only used before you have spent a point.
- Your own blessing follows your talents too: points in Holy get you Wisdom, points in Protection or Retribution get you Might, and the tooltip says which - "31 points in Protection, so mana isn't your first problem". Spent nothing yet? You get Might, and it says so.
- `/bwarden debug` now prints what BuffWarden thinks you are: level, class, shield, role and the points in each talent tab.
- BuffWarden only offers what you can actually use. The blessing pickers list the blessings you have trained and nothing else, so a level 12 paladin is not invited to assign Kings to the mage and then wonder why nothing happens. A weapon imbue you have not trained is marked "(not learned)", a poison you are out of says "(none in your bags)", and both fall back to the best you do have.
- **This one works in combat.** Every real buff is hidden from addons during a fight on Forever, but a weapon enchant is item state, not a buff, so BuffWarden shows a small readout with the time left while you fight, and warns when it is running out. Applying it still waits until combat ends.

## 0.1.0-beta4

- Updated shared YippYapp library.

## 0.1.0-beta3

- Warriors: Battle Shout reminder. It's a short buff that costs rage, so it only reminds out of combat, in a group, while you have the rage to shout (usually right after a fight), and warns when a tenth of its duration is left (read from the buff itself, so about 18 seconds for a 3-minute shout). Untick "Battle Shout" in the settings to turn it off.
- "Running out soon" (orange) now warns at 5 minutes instead of 2, so there's time to ask for a new buff. Short buffs warn at a tenth of their duration (at least a minute), so a 10-minute self-buff isn't orange half the time.
- Orange icons show the time left, and the tooltip says e.g. "Arcane Intellect runs out in 4m 12s".
- New setting under Bar: "Warn when a buff has less than [5] min left". If you never changed it, you get the new 5-minute default.

## 0.1.0-beta2

- Groupmates who are far away (another zone or over 200 yards) no longer count. Those just out of cast range still show, dimmed, so icons don't flicker. Turn it off with "Ignore groupmates who are far away".
- In combat the bar keeps its pre-pull state with a small clock and updates when combat ends; buffs can't be read in combat on Forever.
- No more errors from reading buffs while the game keeps them hidden.

## 0.1.0-beta1

First beta, built for WoW: Forever.

- A small row of icons shows the buffs you're missing: your own (Inner Fire, Mage Armor, Demon Skin, Paladin auras, Aspects, Lightning or Water Shield...) and the group buffs someone in your party can give (Fortitude, Divine Spirit, Arcane Intellect, Mark of the Wild, Blessings). When nothing is missing, the row is gone.
- Gold icon: you can cast it. The number shows how many in your group are missing it, and a click casts it on the nearest one.
- Grey icon: a groupmate has it. A click whispers them to ask. Only groupmates high enough level to have the spell are suggested, and a talent buff like Divine Spirit only once someone in the group is seen carrying it.
- Orange icon: the buff runs out soon (under 2 minutes by default, `/bwarden time <seconds>` to change).
- Blessings: you should carry one from each paladin in the group. As a paladin, BuffWarden picks Kings, Wisdom or Might per target.
- Optionally lists what's missing in chat on a ready check.
- Unlock the bar to see a preview and drag it into place; the row always grows to the right from where you put it. Hidden in combat.
- Buffs can't be read in combat on Forever; the bar keeps its pre-pull state and updates when combat ends. If you keep the bar shown in combat, it wears a small clock until then. During some encounters the game hides buffs outside combat too, and BuffWarden shows nothing instead of guessing.
- Settings under Options > AddOns > YippYapp > BuffWarden (or `/bwarden`): which buffs to watch, hiding in combat, the ready-check list.
- Minimap button (behind the YippYapp minimap button when you use several YippYapp addons), an optional button on the YippYapp launcher bar, and a page in the shared YippYapp welcome window (`/yippyapp`).
