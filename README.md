# Caution
 sql script depends on specific config settings and is not ready for public use without modifications. 
 

# DML Auction House Maintenance Runner

A small maintenance wrapper for the custom AzerothCore Auction House system.

It safely stops the worldserver before running direct Auction House SQL, lets you choose between the Level 60 and Level 80 restock engines, and can optionally run the simulated player-sales script afterward.

## Included Files

Place these files together in the same folder:

```text
AH_runner_sh_script/
├── run_ah_maintenance.sh
├── restock_engine_v7_level60.sql
├── restock_engine_v7_80.sql
└── playerAHsellscript_v2.sql
```

## What the Runner Does

When `run_ah_maintenance.sh` is launched, it:

1. Checks that the AzerothCore database container is running.
2. Verifies that MySQL is responding.
3. Checks whether `ac-worldserver` is running.
4. If the worldserver is running, prompts:
   ```text
   Stop worldserver? (y/n):
   ```
5. If `y` is selected, stops the worldserver and waits until it is fully stopped.
6. Performs a final safety check before any SQL is executed.
7. Prompts for the restock version:
   ```text
   1) Level 60
   2) Level 80
   ```
8. Runs the selected Auction House restock SQL.
9. Prompts:
   ```text
   Run player sell script? (y/n):
   ```
10. Optionally runs `playerAHsellscript_v2.sql`.
11. Reports completion and leaves the worldserver stopped.

The worldserver is intentionally **not restarted automatically**.

## Installation

The default project directory is:

```text
~/wow-server-playerbots
```

A convenient location for the runner files is:

```text
~/wow-server-playerbots/scripts/AH_runner_sh_script/
```

Make the runner executable:

```bash
cd ~/wow-server-playerbots/scripts/AH_runner_sh_script
chmod +x run_ah_maintenance.sh
```

Run it with:

```bash
./run_ah_maintenance.sh
```

## Editable Settings

The main settings are at the top of `run_ah_maintenance.sh`:

```bash
PROJECT_DIR="${HOME}/wow-server-playerbots"

DB_SERVICE="ac-database"
WORLD_SERVICE="ac-worldserver"

MYSQL_USER="root"
MYSQL_PASSWORD="password"
MYSQL_DATABASE="acore_characters"

RESTOCK_LEVEL60="restock_engine_v7_level60.sql"
RESTOCK_LEVEL80="restock_engine_v7_80.sql"
PLAYER_SELL_SCRIPT="playerAHsellscript_v2.sql"
```

When script versions change, only the filenames in this header need to be updated.

Example:

```bash
RESTOCK_LEVEL60="restock_engine_v8_level60.sql"
RESTOCK_LEVEL80="restock_engine_v8_80.sql"
PLAYER_SELL_SCRIPT="playerAHsellscript_v3.sql"
```

## Level 60 Restock

`restock_engine_v7_level60.sql` limits generated Auction House stock to items with:

```sql
COALESCE(it.RequiredLevel, 0) <= 60
```

This is intended for a Vanilla-style level-60 server or progression phase.

## Level 80 Restock

`restock_engine_v7_80.sql` uses the full configured item pool.

It intentionally does **not** need a `RequiredLevel <= 80` condition for a normal WoW 3.3.5a / WotLK database, because level 80 is the expansion level cap.

If custom items above level 80 are later added to the item pool and should be excluded, an explicit level filter can be added at that time.

## Restock Safety Improvements

Both V7 restock engines include the following fixes:

- Item GUID and auction-ID high-water marks are captured **before** old generated Auction House stock is deleted.
- Generated IDs continue upward instead of immediately recycling the IDs of the previous restock.
- The scripts are intended to run only while `ac-worldserver` is stopped.
- Item spell charges are initialized from `item_template`.
- Glyphs and other charged-use items receive their correct charge values.
- Item duration is initialized from `item_template`.
- Armor and weapons receive their proper `MaxDurability`.
- New items receive a valid zeroed enchantment field.
- Auction prices are calculated from the **actual generated stack size** instead of rolling a second independent stack quantity for pricing.
- Existing green BoE random-stat repair logic is preserved.

### Listing Limit

The current restock engines use an `ah_nums` helper table containing values `1` through `20`.

Because of this, `listings_per_restock` currently has an effective maximum of:

```text
20 listings per item entry
```

Values above 20 will still generate at most 20 candidates for that item.

## Simulated Player Sales

`playerAHsellscript_v2.sql` simulates market purchases of auctions posted by real players.

The configured fake Auction House sellers are excluded from simulated purchases.

The script:

- selects eligible player auctions,
- respects the configured market budget,
- respects the configured maximum number of sales per run,
- checks the configured minimum auction age,
- rejects auctions priced above the configured acceptable market value,
- creates the seller payout mail,
- removes the sold auction,
- removes the consumed auctioned item,
- performs the sale changes inside a transaction.

### Additional Safety Checks

The V2 player-sales script also rejects unsafe auction records when:

- the auction item is simultaneously referenced by character inventory,
- the auction item is simultaneously referenced by mail,
- the `item_instance` owner does not match the auction seller,
- the seller character is missing.

Auction age is calculated conservatively from the shortest normal WotLK auction duration so newly posted longer-duration auctions are not accidentally treated as old auctions.

## Required Database Tables

These scripts expect the custom Auction House configuration tables used by the DML Auction House system to already exist, including the relevant tables such as:

```text
custom_ah_restock_config
custom_ah_item_pool
custom_ah_price_overrides
custom_ah_excluded_items
custom_ah_simulated_sales_config
```

They also use the standard AzerothCore character and world database tables.

## Safe Maintenance Workflow

The recommended workflow is:

```text
Database running
      ↓
Run run_ah_maintenance.sh
      ↓
Stop worldserver when prompted
      ↓
Choose Level 60 or Level 80 restock
      ↓
Restock completes
      ↓
Optionally run simulated player sales
      ↓
Maintenance completes
      ↓
Start worldserver manually when ready
```

To start the worldserver afterward:

```bash
cd ~/wow-server-playerbots
docker compose start ac-worldserver
```

## Important Safety Rule

Do **not** directly run the restock or simulated-sales SQL while `ac-worldserver` is running.

AzerothCore maintains Auction House and item state in memory while the worldserver is active. Directly changing `auctionhouse`, `item_instance`, or related tables underneath a live worldserver can leave its in-memory state out of sync with MySQL and can cause item GUID or auction-reference corruption.

The runner exists specifically to prevent that workflow.

## Database Container

The database container should remain running while the maintenance SQL executes.

You do **not** need to stop Docker or shut down the entire AzerothCore stack.

Only the worldserver needs to be stopped:

```bash
docker compose stop ac-worldserver
```

The database remains available for the SQL scripts.

## If Something Fails

The runner exits instead of continuing when:

- the project directory cannot be found,
- Docker or Docker Compose is unavailable,
- the database container is not running,
- MySQL is not responding,
- the worldserver cannot be stopped,
- a configured SQL file cannot be found,
- an SQL script returns an error.

If an SQL script fails, the runner does **not** automatically restart the worldserver.

Review the error first, correct the issue, and rerun the maintenance process.

## Version Notes

Current bundle:

```text
Runner:                run_ah_maintenance.sh
Level 60 Restock:      restock_engine_v7_level60.sql
Level 80 Restock:      restock_engine_v7_80.sql
Player Simulated Sale: playerAHsellscript_v2.sql
```
