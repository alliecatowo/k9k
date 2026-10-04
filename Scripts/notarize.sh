#!/bin/sh
# Developer ID signing and notarization hook, run by package-release.sh when
# NOTARIZE=true (the release workflow sets it once the secrets below exist).
# Usage: Scripts/notarize.sh <path/to/K9k.app>
#
# Required environment:
#   DEVELOPER_ID_APPLICATION  signing identity, e.g. "Developer ID Application: Name (TEAMID)"
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   notarytool credentials
# The signing certificate must already be in the default keychain (the workflow
# imports it from the DEVELOPER_ID_CERT_P12 / DEVELOPER_ID_CERT_PASSWORD secrets).
set -eu

app=${1:?usage: notarize.sh <K9k.app>}
: "${DEVELOPER_ID_APPLICATION:?}" "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"

# Inside-out: helper first, then the bundle, both with hardened runtime.
codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$app/Contents/Resources/k9k-core"
codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
  --entitlements "$(dirname "$0")/../K9k/K9k.entitlements" "$app"
codesign --verify --deep --strict "$app"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ditto -c -k --keepParent "$app" "$tmp/notarize.zip"
xcrun notarytool submit "$tmp/notarize.zip" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"
