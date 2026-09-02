#!/usr/bin/env bash
# Takes the screenshot in the README.
#
# It opens Demo/demo.sqlite in a profile of its own, so it never touches the connections you
# work with, and it asks for a fixed window size so every shot looks the same.
#
# macOS asks the terminal for the Screen Recording permission the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

app=${1:-Rowset.app}
if [ ! -d "$app" ]; then
    echo "No $app. Run ./Scripts/build-release.sh first." >&2
    exit 1
fi
if [ ! -s Demo/demo.sqlite ]; then
    ./Scripts/make-demo-db.sh
fi

profile=$(mktemp -d)
trap 'rm -rf "$profile"' EXIT
bookmark="0F2C4B0E-5E8B-4E4E-9C2B-2A5F1D3C7A99"

cat > "$profile/bookmarks.json" <<JSON
[{"id": "$bookmark", "name": "demo", "driver": "sqlite",
  "filePath": "$PWD/Demo/demo.sqlite", "port": 5432,
  "authMethod": "password", "sslMode": "disable"}]
JSON

# The tab and the open tree rows come from the session file, so the app needs no clicking.
cat > "$profile/session.json" <<JSON
{"expandedBookmarks": ["$bookmark"],
 "expandedNodes": {"$bookmark": [{"schema": "main"}, {"schema": "main", "table": "delivery"}]},
 "tabs": [{"bookmarkID": "$bookmark", "schema": "main", "table": "delivery",
           "filterText": "", "orderByText": "", "sqlText": "", "rowLimit": 50,
           "showsValuePane": false}],
 "selectedTabIndex": 0, "inspectorHeight": 190, "sidebarVisible": true}
JSON

ROWSET_SUPPORT_DIR="$profile" "$app/Contents/MacOS/Rowset" \
    -NSWindow\ Frame\ RowsetMain "80 200 1180 720 0 0 1728 1079 " &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$profile"' EXIT

# Wait for the window, then a moment more for the rows.
for _ in $(seq 30); do
    window=$(./Scripts/window-id.swift "$pid" 2>/dev/null || true)
    [ -n "$window" ] && break
    sleep 0.5
done
if [ -z "${window:-}" ]; then
    echo "The window never appeared." >&2
    exit 1
fi
sleep 2

screencapture -o -x -l "$window" Screenshot.png
# A README is read at about 900 points wide. Half the pixels of a Retina shot still cover that,
# and they cost a third of the bytes in the repository.
sips --resampleWidth 1400 Screenshot.png >/dev/null
echo "Wrote $PWD/Screenshot.png"
