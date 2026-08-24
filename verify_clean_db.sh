#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# DML Auction House - Read-Only DB Integrity Check
# ============================================================
#
# This script does NOT stop or start the worldserver.
# It only runs ah_integrity_check.sql against acore_characters.
#
# The integrity SQL is read-only and may be run while the
# worldserver is live.
# ============================================================

PROJECT_DIR="${HOME}/wow-server-playerbots"

DB_SERVICE="ac-database"

MYSQL_USER="root"
MYSQL_PASSWORD="password"
MYSQL_DATABASE="acore_characters"

INTEGRITY_SCRIPT="ah_integrity_check.sql"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INTEGRITY_FILE="${SCRIPT_DIR}/${INTEGRITY_SCRIPT}"

die() {
    echo
    echo "ERROR: $*"
    exit 1
}

service_is_running() {
    docker compose ps --status running --services 2>/dev/null |
        grep -Fxq "$1"
}

echo "============================================================"
echo " DML Auction House - DB Integrity Check"
echo "============================================================"
echo
echo "This check is READ-ONLY."
echo "It can be run while the worldserver is live."
echo

[[ -d "$PROJECT_DIR" ]] ||
    die "Project directory not found: $PROJECT_DIR"

[[ -f "$INTEGRITY_FILE" ]] ||
    die "Integrity SQL file not found: $INTEGRITY_FILE"

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

read -r -p "Run DB integrity check? (y/n): " check_answer

case "$check_answer" in
    y|Y)
        echo
        echo "Running read-only Auction House DB integrity check..."
        echo "File: $INTEGRITY_FILE"
        echo

        if ! docker compose exec -T \
            -e MYSQL_PWD="$MYSQL_PASSWORD" \
            "$DB_SERVICE" \
            mysql -u"$MYSQL_USER" "$MYSQL_DATABASE" < "$INTEGRITY_FILE"
        then
            die "DB integrity check failed."
        fi

        echo
        echo "============================================================"
        echo " DB integrity check complete."
        echo "============================================================"
        ;;
    *)
        echo
        echo "DB integrity check skipped."
        ;;
esac
