# DML Auction House Runner

This package supports both first-time installation and normal Auction House maintenance from one shell script.

currently designed for faction conencted neutral auctionhouse in all cities.

set AllowTwoSide.Interaction.Auction = 1 in your worldserver.conf

FIRST TIME SETUP

1. Create one Horde and one Alliance seller character.
2. Log into both characters once.
3. Run:

   ./run_ah_maintenance.sh

4. Choose:
   2) Install / Reconfigure

5. Enter the two character names.
6. Choose Y when asked to import custom AH tables.
7. When installation finishes, choose whether to run AH maintenance.

For a shared Horde/Alliance Auction House, set:
AllowTwoSide.Interaction.Auction = 1


## Main Menu

Run:

```bash
./run_ah_maintenance.sh
```

The runner displays:

```text
1) Run AH maintenance
2) Install / Reconfigure
3) Exit
```

If option 1 is selected before installation/configuration is complete, the runner exits without changing the Auction House and tells the user to choose **Install / Reconfigure** first.

## First-Time Installation

Before choosing Install / Reconfigure:

1. Create a dedicated WoW account for the AH system.
2. Create one Horde seller character.
3. Create one Alliance seller character.
4. Log into both characters at least once so they exist in `acore_characters.characters`.

The characters may have any valid names. Examples are `Auctionhorde` and `Auctionally`. The runner normalizes typed names to normal WoW capitalization: first letter uppercase, remaining letters lowercase.

Choose:

```text
2) Install / Reconfigure
```

The installer asks:

```text
Horde seller player name:
Alliance seller player name:
```

Each name must match a real character. If a character does not exist, the installer does not guess a GUID; it asks again and tells the user to create/log into the character first.

Next it asks:

```text
Import custom tables? (y/n):
```

### First install

Choose `y`.

`ah_public_tables.sql` creates and loads the tested data for:

- `custom_ah_restock_config`
- `custom_ah_item_pool`
- `custom_ah_price_overrides`
- `custom_ah_excluded_items`
- `custom_ah_simulated_sales_config`

The public table file does not contain the source server's seller GUIDs.

### Reconfigure later

Install / Reconfigure can be run again.

The user may:

- choose new Horde/Alliance seller characters;
- choose `n` to keep the existing custom AH tables;
- choose `y` to reset/re-import the packaged tested table data.

If seller characters are changed and old fake-seller auctions still exist, the runner detects them. It offers to clean the old fake-seller auctions first and requires the worldserver to be stopped for that cleanup. This prevents generated auctions from being stranded under the old seller GUIDs.

## ah_user_config.sql

During Install / Reconfigure, the runner writes the entered character names into:

```text
ah_user_config.sql
```

and then executes it.

`ah_user_config.sql` is safe to re-run manually. It resolves the seller GUIDs from the character names and uses `ON DUPLICATE KEY UPDATE`, so existing destination configuration is updated rather than duplicated.

It also removes obsolete seller-GUID keys from `custom_ah_simulated_sales_config`; the portable package uses `custom_ah_restock_config` as the single source of truth for seller identities.

## Shared Alliance/Horde Auction House

The tested/recommended configuration is:

```ini
AllowTwoSide.Interaction.Auction = 1
```

in the active `worldserver.conf`, with:

```text
auction_house_id = 7
```

The installer checks the active `worldserver.conf` and warns if the shared-AH setting is not enabled.

## Normal Maintenance

Choose:

```text
1) Run AH maintenance
```

The runner verifies before doing anything that:

- all five custom AH tables exist;
- destination seller names/GUIDs are configured;
- each GUID belongs to the configured real character;
- the sellers are different characters;
- simulated-sales configuration is complete;
- the item pool has enabled items.

If any check fails, no AH SQL is run.

When configuration is valid, the runner asks to stop `ac-worldserver`, waits for it to stop, then offers:

```text
1) Level 60
2) Level 80
```

After restocking it optionally runs the simulated player-sales script.

The worldserver remains stopped when maintenance finishes.

## Files Expected Beside the Runner

```text
run_ah_maintenance.sh
ah_public_tables.sql
ah_user_config.sql
restock_engine_v7_level60.sql
restock_engine_v7_80.sql
playerAHsellscript_v2.sql
ah_integrity_check.sql
README_AH_runner.md
```
