#!/bin/sh
set -eu

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "K9k requires Xcode 26 or later. Install it from Apple and select it with xcode-select." >&2
  exit 1
fi

xcodebuild -version
(cd Backend && go mod download)

