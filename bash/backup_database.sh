#!/usr/bin/env bash
# =============================================================================
# backup_database.sh -- logical backup of one PostgreSQL database
#
# Purpose:
#   Produce a verified pg_dump archive (custom format) of a single database
#   and confirm the archive is readable by listing its contents with
#   pg_restore. A backup that has never been read back is a hope, not a
#   backup; this script treats the listing check as part of the backup.
#
# Usage:
#   ./backup_database.sh -d <database> [-h <host>] [-p <port>] [-U <user>]
#                        [-o <output_dir>] [-F <format>]
#
# Options:
#   -d   Database to back up (required)
#   -h   Host (default: $PGHOST or the local socket)
#   -p   Port (default: $PGPORT or 5432)
#   -U   User (default: $PGUSER or the OS user)
#   -o   Output directory (default: ./backups, created if missing)
#   -F   pg_dump format: c (custom, default), p (plain SQL), t (tar), d (dir)
#   -?   Print this usage
#
# Credentials:
#   None are accepted on the command line or stored anywhere. Authentication
#   is libpq's business: use the PGPASSWORD environment variable, a .pgpass
#   file, or peer/ident auth on the local socket.
#
# Exit codes (stable, see docs/script-conventions.md):
#   0  backup written and archive listing verified
#   1  usage error
#   2  could not connect to PostgreSQL
#   3  pg_dump or the archive verification failed
#
# Tested on PostgreSQL 16, Ubuntu 24.04.
# =============================================================================

set -u

DB=""
HOST="${PGHOST:-}"
PORT="${PGPORT:-5432}"
USER_NAME="${PGUSER:-}"
OUT_DIR="./backups"
FORMAT="c"

usage() {
    sed -n '2,40p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
}

while getopts ":d:h:p:U:o:F:?" opt; do
    case "$opt" in
        d) DB="$OPTARG" ;;
        h) HOST="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        U) USER_NAME="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        F) FORMAT="$OPTARG" ;;
        \?) usage; exit 0 ;;
        :) echo "ERROR: option -$OPTARG requires a value" >&2; exit 1 ;;
    esac
done

if [ -z "$DB" ]; then
    echo "ERROR: -d <database> is required" >&2
    usage >&2
    exit 1
fi

case "$FORMAT" in
    c|p|t|d) ;;
    *) echo "ERROR: -F must be one of c, p, t, d" >&2; exit 1 ;;
esac

# Build a connection argument array. Empty host/user means "libpq default"
# (local socket, OS user), which is the normal lab and cron setup.
CONN=(-p "$PORT" -d "$DB")
[ -n "$HOST" ] && CONN=(-h "$HOST" "${CONN[@]}")
[ -n "$USER_NAME" ] && CONN=(-U "$USER_NAME" "${CONN[@]}")

# Connectivity probe first, so an unreachable server is exit 2, not a
# pg_dump error that looks like a data problem.
if ! psql "${CONN[@]}" -v ON_ERROR_STOP=1 -tAc "SELECT 1" >/dev/null 2>&1; then
    echo "ERROR: could not connect to database '$DB'" >&2
    exit 2
fi

mkdir -p "$OUT_DIR" || { echo "ERROR: cannot create $OUT_DIR" >&2; exit 1; }

case "$FORMAT" in
    c) EXT="dump" ;;
    p) EXT="sql" ;;
    t) EXT="tar" ;;
    d) EXT="dir" ;;
esac
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="$OUT_DIR/${DB}_${STAMP}.${EXT}"

echo "Backing up '$DB' to $OUT_FILE (format $FORMAT)"

if ! pg_dump "${CONN[@]}" --format="$FORMAT" --file="$OUT_FILE"; then
    echo "ERROR: pg_dump failed" >&2
    exit 3
fi

if [ "$FORMAT" = "d" ]; then
    [ -d "$OUT_FILE" ] || { echo "ERROR: backup directory missing" >&2; exit 3; }
else
    [ -s "$OUT_FILE" ] || { echo "ERROR: backup file is empty" >&2; exit 3; }
fi

# Read the archive back. For custom and tar formats pg_restore --list parses
# the whole table of contents; a truncated or corrupt dump fails here.
# Plain SQL has no archive to list, so verify by counting CREATE/INSERT
# statements instead.
if [ "$FORMAT" = "c" ] || [ "$FORMAT" = "t" ]; then
    if ! pg_restore --list "$OUT_FILE" >/dev/null 2>&1; then
        echo "ERROR: archive verification failed (pg_restore --list)" >&2
        exit 3
    fi
    OBJECTS="$(pg_restore --list "$OUT_FILE" | grep -c ';')"
    echo "Archive verified: $OBJECTS archived objects"
elif [ "$FORMAT" = "p" ]; then
    STMTS="$(grep -cE '^(CREATE|INSERT|COPY)' "$OUT_FILE")"
    [ "$STMTS" -gt 0 ] || { echo "ERROR: plain dump looks empty" >&2; exit 3; }
    echo "Plain dump verified: $STMTS CREATE/INSERT/COPY statements"
fi

SIZE="$(du -h "$OUT_FILE" | cut -f1)"
echo "Backup complete: $OUT_FILE ($SIZE)"
exit 0
