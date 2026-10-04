#!/bin/sh
# Builds the Release K9k.app (bundled k9k-core helper, ad-hoc signed) and zips
# it for distribution. Usage: Scripts/package-release.sh <version> [outdir]
# Output: <outdir>/K9k-<version>-macos-arm64.zip (default outdir: dist).
# The bundle is NOT notarized. Scripts/notarize.sh is the hook for that.
set -eu

version=${1:?usage: package-release.sh <version> [outdir]}
version=${version#v}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${2:-"$root/dist"}
derived="$root/DerivedData-release"
mkdir -p "$out"

"$root/Scripts/build-core.sh"
xcodebuild -project "$root/K9k.xcodeproj" -scheme K9k -configuration Release -sdk macosx \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" build
app="$derived/Build/Products/Release/K9k.app"

mkdir -p "$app/Contents/Resources"
cp "$root/Backend/bin/k9k-core" "$app/Contents/Resources/k9k-core"
chmod 755 "$app/Contents/Resources/k9k-core"

# The helper must be in place before the bundle is sealed. Seal ad hoc here;
# notarize.sh re-signs everything with a Developer ID when credentials exist.
codesign --force --sign - "$app/Contents/Resources/k9k-core"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

if [ "${NOTARIZE:-}" = "true" ]; then
  "$root/Scripts/notarize.sh" "$app"
fi

zip="$out/K9k-$version-macos-arm64.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "Packaged $zip"
