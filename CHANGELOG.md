# BuffWarden

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
