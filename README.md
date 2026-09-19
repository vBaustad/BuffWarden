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
- **Orange icon: running out soon.** Under 2 minutes left by default.
- **Blessings.** You should carry one Blessing from each paladin in the group. As a paladin, BuffWarden picks
  Kings if you have it, otherwise Wisdom for mana users and Might for everyone else.
- **Ready check.** Optionally lists what you can cast and what you're missing in chat.

Buffs can't be read in combat on Forever; the bar keeps its pre-pull state and updates when combat ends.
It hides in combat by default (you can keep it shown in the settings; it then wears a small clock until
combat ends). During some encounters the game hides buffs outside combat too, and BuffWarden then shows
nothing rather than guessing.

## Getting started

1. Install BuffWarden.
2. Left-click the BuffWarden icon on the minimap, or type `/bwarden unlock`. If you use several YippYapp
   addons, the icon sits behind the YippYapp button there.
3. Drag the preview to where you want the bar, then click the icon again (or `/bwarden lock`) to lock it.

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
