# CraftShuffle

Which recipes are worth **buying the reagents for, crafting, disenchanting and selling the materials**, for
**WoW Forever**. CraftShuffle adds the disenchant side to **CraftProfit**: a Shuffle mode in the profession
window, a planner that walks you through a whole batch, an Auction House scan for gear worth more as
materials, and a tracker that learns real disenchant results from your own casts.

**Requires CraftProfit 0.3.0 or newer** (prices, craft costs and the profession-window hooks come from it).

## Install

1. Install **CraftProfit** first.
2. Download the release zip and extract it into `World of Warcraft\_classic_beta_\Interface\AddOns\`, so you end
   up with `...\Interface\AddOns\CraftShuffle\CraftShuffle.toc`.
3. Type `/reload` (or start the game) and make sure both addons are enabled in the AddOns list.

## Getting started

1. Open the Auction House and run a **CraftProfit Scan**, so materials and reagents have prices.
2. Open a profession on a character with Enchanting and click **Shuffle** (left of the Filter button). Every
   recipe now shows what it nets when you craft it and disenchant the result.
3. Click **Plan...** on a recipe to plan a batch.

Disenchanting on an alt? `/cs enchanting off` turns on Shuffle mode without Enchanting.

## What you get

- **Shuffle mode** in the profession window: recipe tags, sort by profit and the details panel switch to
  `expected disenchant value − AH cut − craft cost`, with the expected materials and their chances.
- **Shuffle Planner** (`/cs plan`): plans a batch as Buy → Craft → Disenchant → Sell.
  - Reagent costs walk the real Auction House listings instead of using only the lowest price, and you get a
    warning when not enough is listed.
  - Reagents you can craft cheaper than buy (bolts of cloth, for example) are crafted first.
  - It knows what is already in your bags.
  - **Craft** button, **Buy Reagents** (a Shuffle tab in the Auction House with one Buy button per reagent),
    a **disenchant macro** that points at one exact bag slot: the next shuffle item, then gear you bought from the disenchant scan (never soulbound, equipped or equipment-set items), and session tracking with a comparison of
    actual results against the plan.
- **AH scans** (`/cs scan`): armor and weapons listed below their disenchant value, and items listed below what
  a vendor pays for them.
- **Disenchant tracker**: every Disenchant you cast is recorded. Yields start from the classic disenchant tables
  (with WoW Forever's changes, such as Greater Magic Essence from green weapons of item level 21-30) and shift
  toward your own results as you disenchant more. When your casts show the table is wrong for an item (a
  material it predicts never drops), the table is dropped for that item. Hold Shift over an item to see what the
  numbers rest on: "estimate", "10 recorded + table", or "10 recorded". Item tooltips show the disenchant value; the
  compact tooltip (Options, or `/cs tooltip compact`) shows it on one line with how much more or less it is worth
  than the vendor price, and Shift shows the materials.
- **Disenchanting tally** (`/cs de stats`): materials gained, their value and net per cast for plain disenchanting.
- **Disenchant benchmark** (`/cs de bench on`): logs every cast on its own with your buffs, Enchanting skill,
  cast time and the full loot (including anything that is not an enchanting material), to measure what a buff or
  camp object such as the Arcane Salvager changes. Casts are grouped by whether a salvager buff was up, or by a
  label you set (`/cs de bench label <text>`); `/cs de bench` prints the per-group yield and value per cast.
- **Recipe Browser** (`/cs recipes`): every recipe of every profession, learned or not, with its profit, to
  decide which profession is worth leveling. `/cs uses <material>` shows everything a material goes into and
  whether using it beats selling it.

## Commands

```
/cs                        list commands (also /shuffle)
/cs status                 tracker counts, mode, settings
/cs mode sell|shuffle      what the profession window shows
/cs plan [qty]             open the planner
/cs session                the running (or last) shuffle session
/cs bar                    show or hide the floating session bar
/cs macro [list|bought|bags] the disenchant macro and its queue; bought on/off, bags on/off (all greens)
/cs scan [de|vendor]       AH scan window
/cs recipes                Recipe Browser
/cs uses <item>            what a material goes into, vs selling it
/cs de <item>              estimated vs recorded disenchant results
/cs de stats               disenchanting tally window
/cs de bench [on [label]|off] disenchant benchmark: logs every cast with your buffs and full loot
/cs history                finished shuffle sessions
/cs enchanting on|off      require Enchanting for Shuffle mode
/cs options                settings (also Options > AddOns > CraftShuffle)
```

## Notes for the WoW Forever beta

- Forever is in beta and its API can change between builds. If something breaks after a patch, report it with
  the output of `/cs status`.
- Disenchant yields start as estimates from the classic tables. Forever may differ; your own disenchants
  correct them over time. Disenchant one of an item before buying it in bulk.

## Help, bugs and ideas

Discord: https://discord.gg/hbJXz7qqpJ (#addon-help, #bug-reports, #suggestions).

## License

MIT. Made by Vystery.
