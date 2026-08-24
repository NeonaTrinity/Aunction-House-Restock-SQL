#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# DML Auction House
# Installer / Reconfigure / Maintenance Runner
# ============================================================

PROJECT_DIR="${HOME}/wow-server-playerbots"

DB_SERVICE="ac-database"
WORLD_SERVICE="ac-worldserver"

MYSQL_USER="root"
MYSQL_PASSWORD="password"
MYSQL_DATABASE="acore_characters"

# All files are expected beside this runner.
RESTOCK_LEVEL60="restock_engine_v7_level60.sql"
RESTOCK_LEVEL80="restock_engine_v7_80.sql"
PLAYER_SELL_SCRIPT="playerAHsellscript_v2.sql"
PUBLIC_TABLES_SCRIPT="ah_public_tables.sql"
USER_CONFIG_SCRIPT="ah_user_config.sql"

WORLDSERVER_CONF="${PROJECT_DIR}/env/dist/etc/worldserver.conf"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

required_tables=(
    custom_ah_restock_config
    custom_ah_item_pool
    custom_ah_price_overrides
    custom_ah_excluded_items
    custom_ah_simulated_sales_config
)

die() {
    echo
    echo "ERROR: $*"
    exit 1
}

service_is_running() {
    docker compose ps --status running --services 2>/dev/null |
        grep -Fxq "$1"
}

mysql_scalar() {
    local query="$1"

    docker compose exec -T \
        -e MYSQL_PWD="$MYSQL_PASSWORD" \
        "$DB_SERVICE" \
        mysql -N -B -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "$query"
}

run_sql_file() {
    local sql_file="$1"
    local label="$2"

    [[ -f "$sql_file" ]] || die "$label file not found: $sql_file"

    echo
    echo "Running: $label"
    echo "File: $sql_file"
    echo

    if ! docker compose exec -T \
        -e MYSQL_PWD="$MYSQL_PASSWORD" \
        "$DB_SERVICE" \
        mysql -u"$MYSQL_USER" "$MYSQL_DATABASE" < "$sql_file"
    then
        die "$label failed. Worldserver has NOT been restarted."
    fi

    echo
    echo "$label complete."
}

run_sql_text() {
    local label="$1"
    local sql_text="$2"

    echo
    echo "Running: $label"
    echo

    if ! docker compose exec -T \
        -e MYSQL_PWD="$MYSQL_PASSWORD" \
        "$DB_SERVICE" \
        mysql -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "$sql_text"
    then
        die "$label failed. Worldserver has NOT been restarted."
    fi

    echo
    echo "$label complete."
}

table_exists() {
    local table_name="$1"
    local result

    result="$(mysql_scalar "
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema='${MYSQL_DATABASE}'
          AND table_name='${table_name}';
    " 2>/dev/null)" || return 1

    [[ "$result" == "1" ]]
}

all_required_tables_exist() {
    local table_name

    for table_name in "${required_tables[@]}"; do
        table_exists "$table_name" || return 1
    done

    return 0
}

show_install_required() {
    echo
    echo "============================================================"
    echo " Auction House is not installed/configured yet"
    echo "============================================================"
    echo
    echo "Choose:"
    echo "  2) Install / Reconfigure"
    echo
    echo "The installer will:"
    echo "  - ask for the Horde seller character name"
    echo "  - ask for the Alliance seller character name"
    echo "  - optionally import/re-import ah_public_tables.sql"
    echo "  - write those names into ah_user_config.sql"
    echo "  - resolve the real character GUIDs automatically"
    echo "  - verify the configuration before allowing AH maintenance"
    echo
}

verify_installation() {
    local table_name
    local config_count
    local sales_count
    local actual_name_1
    local actual_name_2

    INSTALL_REASON=""

    for table_name in "${required_tables[@]}"; do
        if ! table_exists "$table_name"; then
            INSTALL_REASON="missing required table: $table_name"
            return 1
        fi
    done

    config_count="$(mysql_scalar "
        SELECT COUNT(*)
        FROM custom_ah_restock_config
        WHERE config_key IN (
            'seller_alliance_name',
            'seller_alliance_guid',
            'seller_horde_name',
            'seller_horde_guid',
            'use_both_sellers',
            'auction_house_id',
            'auction_duration_seconds',
            'default_deposit'
        );
    " 2>/dev/null)" || {
        INSTALL_REASON="could not read restock configuration"
        return 1
    }

    if [[ "$config_count" != "8" ]]; then
        INSTALL_REASON="seller/server configuration has not been completed"
        return 1
    fi

    SELLER_ALLIANCE_NAME="$(mysql_scalar "SELECT config_value FROM custom_ah_restock_config WHERE config_key='seller_alliance_name' LIMIT 1;" 2>/dev/null)" || return 1
    SELLER_ALLIANCE_GUID="$(mysql_scalar "SELECT config_value FROM custom_ah_restock_config WHERE config_key='seller_alliance_guid' LIMIT 1;" 2>/dev/null)" || return 1
    SELLER_HORDE_NAME="$(mysql_scalar "SELECT config_value FROM custom_ah_restock_config WHERE config_key='seller_horde_name' LIMIT 1;" 2>/dev/null)" || return 1
    SELLER_HORDE_GUID="$(mysql_scalar "SELECT config_value FROM custom_ah_restock_config WHERE config_key='seller_horde_guid' LIMIT 1;" 2>/dev/null)" || return 1

    if [[ ! "$SELLER_ALLIANCE_GUID" =~ ^[0-9]+$ ]] ||
       [[ ! "$SELLER_HORDE_GUID" =~ ^[0-9]+$ ]]; then
        INSTALL_REASON="configured seller GUID is invalid"
        return 1
    fi

    if [[ "$SELLER_ALLIANCE_GUID" == "$SELLER_HORDE_GUID" ]]; then
        INSTALL_REASON="Alliance and Horde sellers point to the same character"
        return 1
    fi

    actual_name_1="$(mysql_scalar "SELECT name FROM characters WHERE guid=${SELLER_ALLIANCE_GUID} LIMIT 1;" 2>/dev/null)" || actual_name_1=""
    actual_name_2="$(mysql_scalar "SELECT name FROM characters WHERE guid=${SELLER_HORDE_GUID} LIMIT 1;" 2>/dev/null)" || actual_name_2=""

    if [[ -z "$actual_name_1" ]] || [[ "$actual_name_1" != "$SELLER_ALLIANCE_NAME" ]]; then
        INSTALL_REASON="configured Alliance seller does not match a real character"
        return 1
    fi

    if [[ -z "$actual_name_2" ]] || [[ "$actual_name_2" != "$SELLER_HORDE_NAME" ]]; then
        INSTALL_REASON="configured Horde seller does not match a real character"
        return 1
    fi

    sales_count="$(mysql_scalar "
        SELECT COUNT(*)
        FROM custom_ah_simulated_sales_config
        WHERE config_key IN (
            'market_budget_gold',
            'max_sales_per_run',
            'min_age_seconds',
            'sale_chance',
            'max_price_multiplier',
            'mail_delay_seconds',
            'auction_cut_rate',
            'simulated_buyer_hex',
            'unknown_item_max_multiplier',
            'custom_mail_id_start'
        );
    " 2>/dev/null)" || {
        INSTALL_REASON="simulated-sales configuration is incomplete"
        return 1
    }

    if [[ "$sales_count" != "10" ]]; then
        INSTALL_REASON="simulated-sales configuration is incomplete"
        return 1
    fi

    ENABLED_POOL_COUNT="$(mysql_scalar "SELECT COUNT(*) FROM custom_ah_item_pool WHERE enabled=1;" 2>/dev/null)" || {
        INSTALL_REASON="could not verify the AH item pool"
        return 1
    }

    if [[ ! "$ENABLED_POOL_COUNT" =~ ^[0-9]+$ ]] || (( ENABLED_POOL_COUNT == 0 )); then
        INSTALL_REASON="custom_ah_item_pool has no enabled entries"
        return 1
    fi

    return 0
}

ensure_worldserver_stopped() {
    if service_is_running "$WORLD_SERVICE"; then
        echo
        echo "Worldserver: running"
        read -r -p "Stop worldserver? (y/n): " stop_answer

        case "$stop_answer" in
            y|Y)
                echo
                echo "Stopping worldserver..."
                docker compose stop "$WORLD_SERVICE" || die "Could not stop worldserver."

                echo "Waiting for worldserver to stop..."
                while service_is_running "$WORLD_SERVICE"; do
                    sleep 1
                done

                echo "Worldserver stopped."
                ;;
            *)
                echo
                echo "Worldserver was not stopped. No Auction House mutation was run."
                return 1
                ;;
        esac
    else
        echo "Worldserver: stopped"
    fi

    return 0
}

prompt_character() {
    local label="$1"
    local expected_faction="$2"
    local __name_var="$3"
    local __guid_var="$4"
    local input
    local normalized
    local row
    local guid
    local actual_name
    local race

    while true; do
        echo
        read -r -p "${label} player name (or q to cancel): " input

        if [[ "$input" == "q" || "$input" == "Q" ]]; then
            return 1
        fi

        # WoW-style simple character names: letters only.
        if [[ ! "$input" =~ ^[A-Za-z]+$ ]]; then
            echo "Please enter a normal character name using letters only."
            continue
        fi

        # Normalize to first letter uppercase, the rest lowercase.
        normalized="${input,,}"
        normalized="${normalized^}"

        row="$(mysql_scalar "
            SELECT CONCAT(guid, '|', name, '|', race)
            FROM characters
            WHERE name='${normalized}'
            LIMIT 1;
        " 2>/dev/null)" || row=""

        if [[ -z "$row" ]]; then
            echo
            echo "Character '${normalized}' was not found."
            echo "Create that character and log into it at least once, then try again."
            continue
        fi

        IFS='|' read -r guid actual_name race <<< "$row"

        case "$expected_faction" in
            horde)
                case "$race" in
                    2|5|6|8|10) ;;
                    *)
                        echo
                        echo "'${actual_name}' exists, but is not a Horde-race character."
                        echo "Choose a Horde character."
                        continue
                        ;;
                esac
                ;;
            alliance)
                case "$race" in
                    1|3|4|7|11) ;;
                    *)
                        echo
                        echo "'${actual_name}' exists, but is not an Alliance-race character."
                        echo "Choose an Alliance character."
                        continue
                        ;;
                esac
                ;;
        esac

        printf -v "$__name_var" '%s' "$actual_name"
        printf -v "$__guid_var" '%s' "$guid"

        echo "Found: ${actual_name} (GUID ${guid})"
        return 0
    done
}

write_names_to_user_config() {
    local alliance_name="$1"
    local horde_name="$2"
    local cfg="${SCRIPT_DIR}/${USER_CONFIG_SCRIPT}"

    [[ -f "$cfg" ]] || die "User config SQL not found: $cfg"

    sed -i -E \
        "s|^SET[[:space:]]+@seller_alliance_name[[:space:]]*:=[[:space:]]*'[^']*';|SET @seller_alliance_name := '${alliance_name}';|" \
        "$cfg"

    sed -i -E \
        "s|^SET[[:space:]]+@seller_horde_name[[:space:]]*:=[[:space:]]*'[^']*';|SET @seller_horde_name    := '${horde_name}';|" \
        "$cfg"

    grep -Fq "SET @seller_alliance_name := '${alliance_name}';" "$cfg" ||
        die "Could not write Alliance seller name into $cfg"

    grep -Eq "^SET @seller_horde_name[[:space:]]+:= '${horde_name}';$" "$cfg" ||
        die "Could not write Horde seller name into $cfg"
}

check_shared_ah_setting() {
    if [[ ! -f "$WORLDSERVER_CONF" ]]; then
        echo
        echo "NOTE: Could not locate active worldserver.conf at:"
        echo "  $WORLDSERVER_CONF"
        echo "For the recommended shared AH setup, set:"
        echo "  AllowTwoSide.Interaction.Auction = 1"
        return
    fi

    local setting
    setting="$(
        grep -E "^[[:space:]]*AllowTwoSide\.Interaction\.Auction[[:space:]]*=" "$WORLDSERVER_CONF" |
        tail -n 1 |
        sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*$//'
    )"

    echo
    if [[ "$setting" == "1" ]]; then
        echo "Shared Alliance/Horde Auction House: enabled"
    else
        echo "WARNING: AllowTwoSide.Interaction.Auction is not set to 1."
        echo "The portable package is tested with the shared neutral AH:"
        echo "  AllowTwoSide.Interaction.Auction = 1"
    fi
}

cleanup_old_seller_stock_if_needed() {
    local old_alliance_guid="$1"
    local old_horde_guid="$2"
    local new_alliance_guid="$3"
    local new_horde_guid="$4"
    local old_count

    [[ "$old_alliance_guid" =~ ^[0-9]+$ ]] || return 0
    [[ "$old_horde_guid" =~ ^[0-9]+$ ]] || return 0

    if [[ "$old_alliance_guid" == "$new_alliance_guid" &&
          "$old_horde_guid" == "$new_horde_guid" ]]; then
        return 0
    fi

    old_count="$(mysql_scalar "
        SELECT COUNT(*)
        FROM auctionhouse
        WHERE itemowner IN (${old_alliance_guid}, ${old_horde_guid});
    " 2>/dev/null)" || old_count="0"

    [[ "$old_count" =~ ^[0-9]+$ ]] || old_count=0

    if (( old_count == 0 )); then
        return 0
    fi

    echo
    echo "The configured AH seller characters are changing."
    echo "There are ${old_count} auctions still owned by the OLD fake sellers."
    echo "Those must be removed before assigning the new sellers."
    echo
    read -r -p "Clean old fake-seller auctions now? (y/n): " cleanup_answer

    case "$cleanup_answer" in
        y|Y) ;;
        *)
            echo
            echo "Reconfiguration cancelled. Existing seller configuration was not changed."
            return 1
            ;;
    esac

    ensure_worldserver_stopped || return 1

    run_sql_text "Old fake-seller auction cleanup" "
        START TRANSACTION;

        DROP TEMPORARY TABLE IF EXISTS dml_old_fake_seller_items;

        CREATE TEMPORARY TABLE dml_old_fake_seller_items AS
        SELECT itemguid
        FROM auctionhouse
        WHERE itemowner IN (${old_alliance_guid}, ${old_horde_guid});

        DELETE FROM auctionhouse
        WHERE itemowner IN (${old_alliance_guid}, ${old_horde_guid});

        DELETE ii
        FROM item_instance ii
        JOIN dml_old_fake_seller_items old_item
          ON old_item.itemguid = ii.guid
        LEFT JOIN character_inventory ci
          ON ci.item = ii.guid
        LEFT JOIN mail_items mi
          ON mi.item_guid = ii.guid
        LEFT JOIN auctionhouse remaining_ah
          ON remaining_ah.itemguid = ii.guid
        WHERE ii.owner_guid IN (${old_alliance_guid}, ${old_horde_guid})
          AND ci.item IS NULL
          AND mi.item_guid IS NULL
          AND remaining_ah.itemguid IS NULL;

        COMMIT;
    "

    return 0
}

install_or_reconfigure() {
    local new_horde_name
    local new_horde_guid
    local new_alliance_name
    local new_alliance_guid
    local old_alliance_guid=""
    local old_horde_guid=""
    local import_answer
    local tables_ready=0

    echo
    echo "============================================================"
    echo " Install / Reconfigure Auction House"
    echo "============================================================"
    echo
    echo "Create the two seller characters in WoW first and log into each"
    echo "at least once. The names can be anything valid."
    echo

    prompt_character "Horde seller" "horde" new_horde_name new_horde_guid || {
        echo "Installation cancelled."
        return 0
    }

    prompt_character "Alliance seller" "alliance" new_alliance_name new_alliance_guid || {
        echo "Installation cancelled."
        return 0
    }

    if [[ "$new_horde_guid" == "$new_alliance_guid" ]]; then
        echo
        echo "The Horde and Alliance sellers must be different characters."
        return 0
    fi

    if all_required_tables_exist; then
        tables_ready=1

        old_alliance_guid="$(mysql_scalar "
            SELECT config_value
            FROM custom_ah_restock_config
            WHERE config_key='seller_alliance_guid'
            LIMIT 1;
        " 2>/dev/null)" || old_alliance_guid=""

        old_horde_guid="$(mysql_scalar "
            SELECT config_value
            FROM custom_ah_restock_config
            WHERE config_key='seller_horde_guid'
            LIMIT 1;
        " 2>/dev/null)" || old_horde_guid=""
    fi

    echo
    echo "Import/re-import custom AH tables from:"
    echo "  ${SCRIPT_DIR}/${PUBLIC_TABLES_SCRIPT}"
    echo
    echo "Y = install/reset the five custom AH tables to the packaged tested data."
    echo "N = keep the currently installed custom AH tables unchanged."
    echo
    read -r -p "Import custom tables? (y/n): " import_answer

    case "$import_answer" in
        y|Y)
            ;;
        *)
            if (( tables_ready == 0 )); then
                echo
                echo "The required custom AH tables do not exist yet."
                echo "First-time installation requires importing ${PUBLIC_TABLES_SCRIPT}."
                echo "No changes were made."
                return 0
            fi
            ;;
    esac

    if (( tables_ready == 1 )); then
        cleanup_old_seller_stock_if_needed \
            "$old_alliance_guid" \
            "$old_horde_guid" \
            "$new_alliance_guid" \
            "$new_horde_guid" || return 0
    fi

    case "$import_answer" in
        y|Y)
            echo
            echo "WARNING: Re-importing resets the five custom AH tables"
            echo "to the packaged tested market/configuration data."
            run_sql_file "${SCRIPT_DIR}/${PUBLIC_TABLES_SCRIPT}" "Public AH tables import"
            ;;
    esac

    write_names_to_user_config "$new_alliance_name" "$new_horde_name"

    run_sql_file "${SCRIPT_DIR}/${USER_CONFIG_SCRIPT}" "AH seller/server configuration"

    if ! verify_installation; then
        echo
        echo "Installation did not pass verification:"
        echo "  $INSTALL_REASON"
        return 0
    fi

    echo
    echo "============================================================"
    echo " Auction House installation/configuration complete"
    echo "============================================================"
    echo
    echo "Horde seller:    ${SELLER_HORDE_NAME} (GUID ${SELLER_HORDE_GUID})"
    echo "Alliance seller: ${SELLER_ALLIANCE_NAME} (GUID ${SELLER_ALLIANCE_GUID})"
    echo "Enabled pool items: ${ENABLED_POOL_COUNT}"

    check_shared_ah_setting

    echo
    read -r -p "Run AH maintenance now? (y/N): " run_now

    case "$run_now" in
        y|Y)
            run_maintenance
            ;;
        *)
            echo
            echo "Installation complete. AH maintenance was not run."
            if ! service_is_running "$WORLD_SERVICE"; then
                echo "Worldserver is currently STOPPED."
            fi
            ;;
    esac
}

run_maintenance() {
    if ! verify_installation; then
        show_install_required
        echo "Reason: $INSTALL_REASON"
        echo
        echo "No AH SQL was run."
        return 0
    fi

    echo
    echo "AH configuration: ready"
    echo "  Horde seller:    ${SELLER_HORDE_NAME} (GUID ${SELLER_HORDE_GUID})"
    echo "  Alliance seller: ${SELLER_ALLIANCE_NAME} (GUID ${SELLER_ALLIANCE_GUID})"
    echo "  Enabled pool items: ${ENABLED_POOL_COUNT}"

    ensure_worldserver_stopped || return 0

    if service_is_running "$WORLD_SERVICE"; then
        die "Worldserver is still running. No AH SQL was run."
    fi

    service_is_running "$DB_SERVICE" ||
        die "Database stopped before SQL could run."

    echo
    echo "Choose Auction House restock:"
    echo "  1) Level 60"
    echo "  2) Level 80"
    echo

    while true; do
        read -r -p "Selection (1/2): " level_choice

        case "$level_choice" in
            1)
                RESTOCK_FILE="${SCRIPT_DIR}/${RESTOCK_LEVEL60}"
                RESTOCK_LABEL="Level 60 AH restock"
                break
                ;;
            2)
                RESTOCK_FILE="${SCRIPT_DIR}/${RESTOCK_LEVEL80}"
                RESTOCK_LABEL="Level 80 AH restock"
                break
                ;;
            *)
                echo "Please enter 1 or 2."
                ;;
        esac
    done

    run_sql_file "$RESTOCK_FILE" "$RESTOCK_LABEL"

    echo
    read -r -p "Run player sell script? (y/n): " sell_answer

    case "$sell_answer" in
        y|Y)
            run_sql_file "${SCRIPT_DIR}/${PLAYER_SELL_SCRIPT}" "Player AH simulated sales"
            ;;
        *)
            echo
            echo "Player sell script skipped."
            ;;
    esac

echo
echo "============================================================"
echo " Auction House maintenance complete."
echo "============================================================"
echo

read -r -p "Start worldserver now? (y/n): " start_answer

case "$start_answer" in
    y|Y)
        echo
        echo "Starting worldserver..."

        if ! docker compose start "$WORLD_SERVICE"; then
            die "Could not start worldserver."
        fi

        echo
        echo "Worldserver started."
        ;;
    *)
        echo
        echo "Worldserver remains STOPPED."
        ;;
esac

echo
echo "Done."
}

# ============================================================
# STARTUP
# ============================================================

echo "============================================================"
echo " DML Auction House"
echo "============================================================"
echo

[[ -d "$PROJECT_DIR" ]] ||
    die "Project directory not found: $PROJECT_DIR"

cd "$PROJECT_DIR" ||
    die "Could not enter project directory: $PROJECT_DIR"

command -v docker >/dev/null 2>&1 ||
    die "docker command not found."

docker compose version >/dev/null 2>&1 ||
    die "docker compose is not available."

if ! service_is_running "$DB_SERVICE"; then
    die "Database service '$DB_SERVICE' is not running."
fi

if ! docker compose exec -T \
    -e MYSQL_PWD="$MYSQL_PASSWORD" \
    "$DB_SERVICE" \
    mysqladmin ping -u"$MYSQL_USER" --silent >/dev/null 2>&1
then
    die "Database container is running, but MySQL is not responding."
fi

echo "Database: running"
echo
echo "Choose an option:"
echo "  1) Run AH maintenance"
echo "  2) Install / Reconfigure"
echo "  3) Exit"
echo

while true; do
    read -r -p "Selection (1/2/3): " main_choice

    case "$main_choice" in
        1)
            run_maintenance
            exit 0
            ;;
        2)
            install_or_reconfigure
            exit 0
            ;;
        3)
            echo "Exit."
            exit 0
            ;;
        *)
            echo "Please enter 1, 2, or 3."
            ;;
    esac
done
