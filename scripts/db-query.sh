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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
QUERY_DIR="$ROOT_DIR/build/db-query/queries"
OUT_DIR="$ROOT_DIR/build/db-query/out"
DATA_DIR="$HOME/Library/Application Support/ArchiveOfYourOwn"

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
