#!/bin/sh
set -eu

# Builds, notarizes and staples dist/Lifelog.app, then zips it as
# release/Lifelog-<version>.zip. Needs a Developer ID Application certificate
# and notarytool credentials stored once with:
#   xcrun notarytool store-credentials lifelog-notary \
#     --apple-id <apple id> --team-id <team id>
# Set LIFELOG_NOTARY_PROFILE to use a different profile name.

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
profile=${LIFELOG_NOTARY_PROFILE:-lifelog-notary}

LIFELOG_RELEASE=1 ./scripts/build.sh
app="$project_dir/dist/Lifelog.app"
if ! codesign -dv --verbose=2 "$app" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "Notarization needs a Developer ID Application signature." >&2
  exit 1
fi

version=$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)
mkdir -p release
zip="$project_dir/release/Lifelog-$version.zip"
rm -f "$zip"

ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

# Zip again so the download carries the stapled ticket.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "Notarized: $zip"
shasum -a 256 "$zip"
