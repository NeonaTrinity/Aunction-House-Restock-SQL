#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# DML Auction House Maintenance Runner
# ============================================================
# EDIT THESE SETTINGS WHEN FILENAMES / SERVICES CHANGE
# ============================================================

PROJECT_DIR="${HOME}/wow-server-playerbots"

DB_SERVICE="ac-database"
WORLD_SERVICE="ac-worldserver"

MYSQL_USER="root"
MYSQL_PASSWORD="password"
MYSQL_DATABASE="acore_characters"

# SQL files are expected to be in the same folder as this script.
RESTOCK_LEVEL60="restock_engine_v7_level60.sql"
RESTOCK_LEVEL80="restock_engine_v7_80.sql"
PLAYER_SELL_SCRIPT="playerAHsellscript_v2.sql"

# ============================================================
# END EDITABLE SETTINGS
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
    echo
    echo "ERROR: $*"
    exit 1
}

service_is_running() {
    docker compose ps --status running --services 2>/dev/null |
        grep -Fxq "$1"
}

run_sql_file() {
    local sql_file="$1"
    local label="$2"

    if [[ ! -f "$sql_file" ]]; then
        die "$label SQL file not found: $sql_file"
    fi

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

echo "============================================================"
echo " DML Auction House Maintenance"
echo "============================================================"
echo

[[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR"

cd "$PROJECT_DIR" || die "Could not enter project directory: $PROJECT_DIR"

command -v docker >/dev/null 2>&1 || die "docker command not found."

if ! docker compose version >/dev/null 2>&1; then
    die "docker compose is not available."
fi

# ------------------------------------------------------------
# Database safety check
# ------------------------------------------------------------

if ! service_is_running "$DB_SERVICE"; then
    echo "Database not running."
    exit 1
fi

if ! docker compose exec -T \
    -e MYSQL_PWD="$MYSQL_PASSWORD" \
    "$DB_SERVICE" \
    mysqladmin ping -u"$MYSQL_USER" --silent >/dev/null 2>&1
then
    echo "Database container is running, but MySQL is not responding."
    exit 1
fi

echo "Database: running"

# ------------------------------------------------------------
# Worldserver safety check
# ------------------------------------------------------------

if service_is_running "$WORLD_SERVICE"; then
    echo "Worldserver: running"
    echo
    read -r -p "Stop worldserver? (y/n): " stop_answer

    case "$stop_answer" in
        y|Y)
            echo
            echo "Stopping worldserver..."
            if ! docker compose stop "$WORLD_SERVICE"; then
                die "Could not stop worldserver."
            fi

            echo "Waiting for worldserver to stop..."
            while service_is_running "$WORLD_SERVICE"; do
                sleep 1
            done

            echo "Worldserver stopped."
            ;;
        *)
            echo
            echo "Worldserver was not stopped. No SQL was run."
            exit 0
            ;;
    esac
else
    echo "Worldserver: stopped"
fi

# Final safety gate immediately before SQL.
if service_is_running "$WORLD_SERVICE"; then
    die "Worldserver is still running. No SQL was run."
fi

if ! service_is_running "$DB_SERVICE"; then
    die "Database stopped before SQL could run."
fi

# ------------------------------------------------------------
# Choose restock
# ------------------------------------------------------------

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
echo "Restock complete."

# ------------------------------------------------------------
# Optional simulated player sales
# ------------------------------------------------------------

echo
read -r -p "Run player sell script? (y/n): " sell_answer

case "$sell_answer" in
    y|Y)
        PLAYER_SELL_FILE="${SCRIPT_DIR}/${PLAYER_SELL_SCRIPT}"
        run_sql_file "$PLAYER_SELL_FILE" "Player AH simulated sales"
        echo
        echo "Player sell script complete."
        ;;
    *)
        echo
        echo "Player sell script skipped."
        ;;
esac

echo
echo "============================================================"
echo " Auction House maintenance complete."
echo " Worldserver remains STOPPED."
echo "============================================================"
