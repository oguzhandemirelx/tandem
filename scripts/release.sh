#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 2 ]; then
  printf 'Usage: bash scripts/release.sh "Developer ID Application: Name (TEAMID)" "NotaryKeychainProfile"\n' >&2
  exit 2
fi
identity="$1"
profile="$2"
case "$identity" in
  'Developer ID Application: '*) ;;
  *) printf 'A Developer ID Application signing identity is required.\n' >&2; exit 2 ;;
esac
TANDEM_SIGNING_IDENTITY="$identity" bash scripts/build.sh
app="$PWD/build/Tandem.app"
archive="$PWD/build/Tandem.zip"
codesign --verify --strict --verbose=2 "$app"
plutil -lint "$app/Contents/Info.plist"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait --timeout 30m --output-format json > build/notarization.json
# A submission can finish with Invalid while returning valid JSON. Gate stapling
# and publication on the actual result, not only the command's exit status.
status=$(/usr/bin/plutil -extract status raw build/notarization.json)
if [ "$status" != Accepted ]; then
  printf 'Notarization did not succeed. See build/notarization.json.\n' >&2
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app"
# Distribute the stapled app, rather than the pre-notarization archive.
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$archive"
printf 'Signed and notarized archive: %s\n' "$archive"
