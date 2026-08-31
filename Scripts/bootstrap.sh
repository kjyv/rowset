#!/usr/bin/env bash
# Set up the build. Run this after a fresh clone.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is missing. Installing it."
    brew install xcodegen
fi

if [ ! -s Sources/Rowset/Resources/rds-global-bundle.pem ]; then
    ./Scripts/fetch-rds-ca.sh
fi

xcodegen generate
echo "Done. Open Rowset.xcodeproj."
