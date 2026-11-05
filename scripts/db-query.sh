#!/bin/bash
set -euo pipefail

# Run every query in build/db-query/queries/*.sql against the encrypted
# library (or its log database) and write each result to
# build/db-query/out/<name>.txt. Prompts once for the library password.
# Read-only: never modifies either database.
#
# A query file's first line picks the database:
#   -- db: library   (default) library.db
#   -- db: log       library.db.log (debug_log table)
#
# Output contains private library data; build/ is gitignored.
#
# Migration check mode:
#   scripts/db-query.sh --migrate [snapshot.db]
# Copies a library snapshot (default: the newest file under Backups/) to a
# temp path and runs this build's schema migration on the copy, through
# the ignored Rust test `migrate_real_library_copy`. The outcome (exact
# error, or migrated row counts) lands in build/db-query/out/migrate.txt.
# Neither the library nor the snapshot is touched; the copy is deleted.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
QUERY_DIR="$ROOT_DIR/build/db-query/queries"
OUT_DIR="$ROOT_DIR/build/db-query/out"
DATA_DIR="$HOME/Library/Application Support/ArchiveOfYourOwn"

if [ "${1:-}" = "--migrate" ]; then
    snapshot="${2:-$(ls -t "$DATA_DIR"/Backups/*.db 2>/dev/null | head -1)}"
    [ -f "$snapshot" ] || { echo "No snapshot found (pass a path)"; exit 1; }
    read -rsp "Library password: " PASSWORD
    echo
    mkdir -p "$OUT_DIR"
    out="$OUT_DIR/migrate.txt"
    echo "Migrating a copy of $snapshot ..."
    # The key reaches the test process through its environment only —
    # never on a command line.
    AO3_MIGRATE_DB="$snapshot" AO3_MIGRATE_KEY="$PASSWORD" \
        "$SCRIPT_DIR/test-rust.sh" migrate_real_library_copy -- --ignored --nocapture \
        2>&1 | grep -v "^\s*Compiling\|^\s*Finished\|^\s*Running\|^\s*Checking" > "$out" || true
    unset PASSWORD
    echo "Wrote $out"
    grep -E "MIGRATION (OK|FAILED)" "$out" || echo "(no outcome line — see $out)"
    exit 0
fi

command -v sqlcipher >/dev/null || { echo "sqlcipher not found (brew install sqlcipher)"; exit 1; }
shopt -s nullglob
queries=("$QUERY_DIR"/*.sql)
[ ${#queries[@]} -gt 0 ] || { echo "No queries in $QUERY_DIR"; exit 1; }

read -rsp "Library password: " PASSWORD
echo
# SQL string literal: double any single quote.
KEY=${PASSWORD//\'/\'\'}
unset PASSWORD

mkdir -p "$OUT_DIR"
for q in "${queries[@]}"; do
    name="$(basename "$q" .sql)"
    db="$DATA_DIR/library.db"
    head -1 "$q" | grep -q -- "-- db: log" && db="$DATA_DIR/library.db.log"
    out="$OUT_DIR/$name.txt"
    {
        printf "PRAGMA key = '%s';\n.headers on\n.mode box\n" "$KEY"
        cat "$q"
    } | sqlcipher -readonly "$db" 2>&1 | sed '1{/^ok$/d;}' > "$out" || true
    if grep -q "file is not a database" "$out"; then
        echo "Wrong password (or not a database): $name"
        rm -f "$out"
        exit 1
    fi
    echo "Wrote $out"
done
unset KEY
date -u "+%Y-%m-%d %H:%M:%S UTC" > "$OUT_DIR/last-run.txt"
echo "Done."
