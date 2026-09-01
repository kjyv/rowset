#!/usr/bin/env bash
# Builds Rowset in the Release configuration and puts Rowset.app beside this repository.
#
#   ./Scripts/build-release.sh            writes ./Rowset.app
#   ./Scripts/build-release.sh --install  writes it and copies it to /Applications
#
# The app is not signed. macOS asks about that the first time you open it: right click the app,
# pick Open, and confirm.
set -euo pipefail
cd "$(dirname "$0")/.."

install=no
if [ "${1:-}" = "--install" ]; then
    install=yes
elif [ -n "${1:-}" ]; then
    echo "Usage: $0 [--install]" >&2
    exit 2
fi

if [ ! -d Rowset.xcodeproj ]; then
    ./Scripts/bootstrap.sh
fi

# The build folder stays, so the next run is an incremental build.
xcodebuild -project Rowset.xcodeproj \
    -scheme Rowset \
    -configuration Release \
    -derivedDataPath build \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

built=build/Build/Products/Release/Rowset.app
rm -rf Rowset.app
ditto "$built" Rowset.app
echo "Wrote $PWD/Rowset.app"

if [ "$install" = "yes" ]; then
    if pgrep -x Rowset >/dev/null 2>&1; then
        echo "Rowset is running. Quit it and run this again." >&2
        exit 1
    fi
    rm -rf /Applications/Rowset.app
    ditto Rowset.app /Applications/Rowset.app
    # macOS caches an app icon per bundle path, so a fresh icon needs a registration.
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/Rowset.app
    echo "Installed /Applications/Rowset.app"
fi
