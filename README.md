# BuffWarden

**See which buffs you and your group are missing, and fix them in one click. For WoW: Forever.**

BuffWarden shows a small row of icons for the buffs you're missing: your own self-buffs, and the group buffs
someone in your party can give. When you can cast a buff yourself, a click casts it on the groupmate who needs
it. When someone else has it, a click whispers them to ask. When nothing is missing, the row is gone.

> **Status: beta (0.1.0-beta1).** Built for the WoW: Forever beta. Expect rough edges, and please report what
> you find.

## What it does

- **Your own buffs.** Inner Fire, Mage Armor, Demon Skin, Paladin auras, Aspects, Trueshot Aura, Lightning or
  Water Shield and Omen of Clarity, for the class that uses them.
- **Group buffs.** Power Word: Fortitude, Divine Spirit, Arcane Intellect, Mark of the Wild and Blessings.
  Shadow Protection can be turned on in the settings.
- **Gold icon: you can cast it.** The number shows how many in your group are missing it. A click casts it on
  the nearest one.
- **Grey icon: a groupmate has it.** A click whispers them: *"Could I get Arcane Intellect, please? :)"*.
  BuffWarden only suggests groupmates who are high enough level to have the spell, and only asks for a talent
  buff like Divine Spirit once someone in the group is seen carrying it.
- **Orange icon: running out soon.** Under 5 minutes left by default (change it in the settings); short
  buffs warn at a tenth of their duration. The icon shows the time left.
- **Blessings.** You should carry one Blessing from each paladin in the group. As a paladin you get a row
  with one button per Blessing you know, each showing who the next click will buff and why. The defaults
  suit a dungeon or levelling group, where drinking is what slows you down: Wisdom for anyone who casts,
  Might for pure melee, Kings for warlocks (Life Tap pays for their mana). Hunters get
  Wisdom, not Might: Blessing of Might is melee attack power, which does nothing for a shot. Set it per class
  or per person in the settings, and once everyone is geared, Kings beats Wisdom. The row appears only when
  somebody actually needs a blessing; when it is up, the ones nobody asked for are dimmed, and a click puts
  one on whoever you point at or have targeted - which is how you hand Salvation to the one pulling aggro.
- **Weapon buffs.** Sharpening stones, weightstones, oils and shaman imbues, with one click to apply the
  right one from your bags. A stone is matched to your weapon, and nothing is shown unless you carry one
  that fits (never for a fishing pole).
- **It knows what you are.** BuffWarden reads your own class, level, talents, weapons and trained
  spells, so advice meant for a tank doesn't reach a healer. Other players stay private: their spec is
  not readable and BuffWarden never guesses at it.
- **Ready check.** Optionally lists what you can cast and what you're missing in chat.

**The weapon buff is the exception in combat.** A weapon enchant is item state rather than a buff, so
BuffWarden reads it during a fight: a small readout shows the time left and warns when it runs out, while
everything else is hidden.

Other buffs can't be read in combat on Forever; the bar keeps its pre-pull state and updates when combat ends.
It hides in combat by default (you can keep it shown in the settings; it then wears a small clock until
combat ends). During some encounters the game hides buffs outside combat too, and BuffWarden then shows
nothing rather than guessing.

## Getting started

1. Install BuffWarden.
2. Left-click the BuffWarden icon on the minimap to unlock the bar (or type `/bwarden unlock`). If you
   use several YippYapp addons, the icon sits behind the YippYapp button there.
3. Drag the preview where you want it, then left-click the icon again to lock it.

### Commands

| Command | What it does |
|---|---|
| `/bwarden` | Open the settings |
| `/bwarden unlock` / `lock` | Show a preview to move the bar / lock it |
| `/bwarden reset` | Put the bar back in its default spot |
| `/bwarden scale <0.5-2>` | Resize the bar |
| `/bwarden time <seconds>` | Count a buff as missing when less than this is left |
| `/bwarden status` | List what's missing in chat |
| `/bwarden help` | All commands |

`/buffwarden` works too.

Settings are under **Options → AddOns → YippYapp → BuffWarden**: which buffs to watch, hiding in combat and
the ready-check list. Right-clicking the minimap icon opens them too.

## Part of YippYapp

BuffWarden is part of **YippYapp**, a set of addons for WoW: Forever that work even better together. Each one
works fully on its own. With more of them installed:

- **One minimap button.** They share a single YippYapp button on the minimap. Click it for a row with each
  addon's icon. There is also an optional launcher bar at the screen edge, off by default, that you can turn
  on in the settings.
- **One settings page.** Minimap and launcher buttons for all of them are under **Options → AddOns →
  YippYapp**.
- **One group in the AddOn list.** They appear together under **YippYapp** in the in-game AddOn list.
- **AutoFeed** keeps one-button macros for your best food, water, potions, scrolls and bandages. Together
  they cover your buffs: BuffWarden the class buffs from you and your group, AutoFeed the scroll and food
  buffs from your bags.

Other YippYapp addons:
- **Guildhall** is your guild's crafting directory: who can craft what, who has it and who wants it.
- **Skillwright** plans the cheapest or fastest route to max skill in a profession.

## Installing from source

Releases will come through CurseForge. To run the source directly:

1. Clone this repo into `Interface\AddOns\BuffWarden`.
2. Clone [LibForever-1.0](https://github.com/vBaustad/LibForever-1.0) into `BuffWarden\Libs\LibForever-1.0`.
   The packaged releases include it automatically.

## License

MIT. Bundles LibStub, CallbackHandler-1.0, LibDataBroker-1.1 and LibDBIcon-1.0 (see LICENSE).
