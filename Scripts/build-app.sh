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
echo "Bundled helper: $app/Contents/Resources/k9k-core"

