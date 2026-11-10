#!/bin/zsh
# Fetch a URL from a site behind a human check (Cloudflare), for development.
#
#   ./scripts/site-fetch.sh [-o out] [-d form-body] [-H 'Name: value'] [--no-prompt] <url>
#
# Uses the clearance saved in build/site-fetch/clearance.json for the URL's
# host. On a 403 a WebKit window opens on the site so you can click the
# check; the cookies and User-Agent it earns are saved and the request is
# retried. Status line goes to stderr, body to stdout or -o.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/site-fetch/main.swift"
BIN_DIR="$ROOT/build/site-fetch"
BIN="$BIN_DIR/site-fetch"
mkdir -p "$BIN_DIR"
if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  echo "==> Compiling site-fetch" >&2
  xcrun swiftc -O -framework AppKit -framework WebKit -o "$BIN" "$SRC"
fi
cd "$ROOT"
exec "$BIN" --state "$BIN_DIR/clearance.json" "$@"
