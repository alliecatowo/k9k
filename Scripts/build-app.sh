#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived="$root/DerivedData"
xcodebuild -project "$root/K9k.xcodeproj" -scheme K9k -configuration Debug -sdk macosx \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
app="$derived/Build/Products/Debug/K9k.app"
mkdir -p "$app/Contents/Resources"
cp "$root/Backend/bin/k9k-core" "$app/Contents/Resources/k9k-core"
chmod 755 "$app/Contents/Resources/k9k-core"

# The helper must be present before the final bundle seal. Xcode's
# CODE_SIGNING_ALLOWED=NO build still produces a linker-signed arm64 app; adding
# a resource afterwards invalidates that seal and macOS can SIGKILL the nested
# executable. Re-seal this local Debug artifact ad hoc after bundling. Release
# signing/notarization uses the same ordering with a real identity.
codesign --force --sign - "$app/Contents/Resources/k9k-core"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Bundled helper: $app/Contents/Resources/k9k-core"
