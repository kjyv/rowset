#!/usr/bin/env bash
# Runs the live tests against a real database.
#
# Xcode starts the test process with a clean environment. It only forwards variables that carry
# the TEST_RUNNER_ prefix, so this script adds the prefix for you.
#
# Usage:
#   ROWSET_LIVE_HOST=... ROWSET_LIVE_DB=... ROWSET_LIVE_USER=... \
#   ROWSET_LIVE_PROFILE=... ./Scripts/live-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ROWSET_LIVE_HOST:?set ROWSET_LIVE_HOST}"
: "${ROWSET_LIVE_DB:?set ROWSET_LIVE_DB}"
: "${ROWSET_LIVE_USER:?set ROWSET_LIVE_USER}"
: "${ROWSET_LIVE_PROFILE:?set ROWSET_LIVE_PROFILE}"

export TEST_RUNNER_ROWSET_LIVE_HOST="$ROWSET_LIVE_HOST"
export TEST_RUNNER_ROWSET_LIVE_DB="$ROWSET_LIVE_DB"
export TEST_RUNNER_ROWSET_LIVE_USER="$ROWSET_LIVE_USER"
export TEST_RUNNER_ROWSET_LIVE_PROFILE="$ROWSET_LIVE_PROFILE"
export TEST_RUNNER_ROWSET_LIVE_REGION="${ROWSET_LIVE_REGION:-eu-central-1}"
export TEST_RUNNER_ROWSET_LIVE_PORT="${ROWSET_LIVE_PORT:-5432}"
export TEST_RUNNER_ROWSET_LIVE_SCHEMA="${ROWSET_LIVE_SCHEMA:-public}"
export TEST_RUNNER_ROWSET_CA_BUNDLE="$PWD/Sources/Rowset/Resources/rds-global-bundle.pem"

xcodebuild -project Rowset.xcodeproj -scheme Rowset -destination 'platform=macOS' \
    -only-testing:RowsetTests/LiveConnectionTests test
