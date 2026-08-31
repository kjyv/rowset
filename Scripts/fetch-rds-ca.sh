#!/usr/bin/env bash
# Download the AWS RDS global certificate bundle into the app resources.
# Run this once. The result is committed, so the build needs no network.
set -euo pipefail

URL="https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Sources/Rowset/Resources/rds-global-bundle.pem"

echo "Downloading $URL"
curl -fsSL "$URL" -o "$DEST"

COUNT=$(grep -c 'BEGIN CERTIFICATE' "$DEST")
echo "Wrote $DEST with $COUNT certificates."
