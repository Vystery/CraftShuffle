# Changelog

## 0.2.4

- Fixed: green weapons of item level 21-30 (Dire Wand and others) showed Greater Astral Essence or Lesser Astral
  Essence. On WoW Forever they give Greater Magic Essence, and the built-in table now says so.
- Fixed: green armor of item level 21-25 now uses 75% dust / 15% essence / 10% shard (was 75/20/5).
- Changed: when your own disenchants show the built-in table is wrong for an item (a material it predicts never
  drops), the table is dropped for that item instead of staying mixed in. Before, 10 casts still counted the
  table as half the data, which could show two different essences at once.
- Changed: hold Shift over an item to see what the disenchant numbers rest on, e.g. "10 recorded + table" while
  the built-in table is still part of the mix. Without Shift the line just says "Disenchant value", which keeps
  the tooltip narrow. Thanks for the report!
- Changed: disenchant materials show what one cast gives when the material drops, e.g. "Greater Magic Essence
  1-2x 75%", instead of an average over all casts ("~0.7"). The range comes from the built-in table and from
  every amount you have actually received. Casts recorded before this version only add a range when they always
  gave exactly one; otherwise the table's range (or "~1.5x", the average when it drops) is shown.

## 0.2.3

- New: compact disenchant tooltip (Options > CraftShuffle, or `/cs tooltip compact`). One line with the
  disenchant value and how much more (green) or less (red) it is worth than selling the item to a vendor. Hold
  Shift to see the materials and chances. Off by default. Thanks for the suggestion!
- Fixed: Buy Next and the Buy buttons in the Shuffle tab could reset the Auction House quantity to 1 when the
  cheapest listing had fewer units than you need. The quantity now goes in the way typing it does, and is set
  again when more listings load.

## 0.2.2

- New: disenchant benchmark (`/cs de bench on` / `off`). Every Disenchant is logged on its own with your buffs,
  Enchanting skill, cast time and the full loot, including items that are not enchanting materials, to measure
  what the Arcane Salvager (or any other buff) does. `/cs de bench` shows yield and value per cast for each
  group, `/cs de bench auras` lists your buffs and camp objects, `/cs de bench label <text>` tags the next casts by
  hand. The Salvager is detected from the Camp Benefits buff's tooltip (Forever has no buff per camp object).
- Fixed (as in 0.2.1): using the Hearthstone or any other item from the bags or a macro is no longer blocked
  with "CraftShuffle has been blocked from an action only available to the Blizzard UI".

## 0.2.1

- Fixed: using the Hearthstone (or any other item from the bags or a macro) could be blocked with "CraftShuffle
  has been blocked from an action only available to the Blizzard UI" on the newest WoW Forever build.
  CraftShuffle no longer hooks item use; disenchants are still recorded from the bag change.

## 0.2.0 (first public release)

First public release of CraftShuffle for WoW Forever. Requires CraftProfit 0.3.0 or newer.

- Shuffle mode in the profession window: every recipe shows what it nets when you craft and disenchant it.
- Shuffle Planner: buy, craft, disenchant and sell a whole batch, with reagent costs from the real Auction House
  listings and self-crafted intermediates. Built from the game's own window parts (recipe dropdown, quantity
  spinner, the profession window's Enchanting background).
- Shuffle sessions: Start Shuffle tracks crafts, disenchants, materials and what you actually paid. The cost per
  cast comes from real purchases (extra stock and items the plan does not use are left out), and the result
  shows how far luck, price changes and costs moved it from the plan. Sessions are account-wide, so a shuffle can
  be finished on another character.
- Buying: a Shuffle tab in the Auction House lists exactly what the running shuffle still needs, with one-click
  buy pages; at a vendor that sells a reagent, a panel next to the merchant buys the missing amount.
- Disenchant macro: one macro that always points at one exact bag slot: the shuffle item, then gear you bought
  from the disenchant scan. It never touches soulbound items, equipment-set items or equipped gear, and does
  nothing in combat. Sweeping every green in the bags is an opt-in option.
- Mail to an alt: set the character that does the disenchanting, and a mail window at the mailbox sends the
  shuffle items, one click per mail.
- Auction House scans for gear worth more as materials and for items listed below vendor price, in an
  Auction-House-style window with progress on the Scan button and a prompt to rescan when the data is old.
- Disenchant tracker that learns yields from your own casts, with disenchant values on item tooltips. Handles
  fast macro use and loot windows that arrive before the cast confirms.
- Disenchanting tally window for plain disenchanting, on the same Enchanting board as the planner.
- Recipe Browser: every recipe of every profession with its profit, and what each material goes into, in an
  Auction-House-style window with sortable columns.
