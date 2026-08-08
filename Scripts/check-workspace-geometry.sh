#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

xcrun swiftc \
  "$root/K9k/App/WorkspaceGeometry.swift" \
  "$root/Scripts/check-workspace-geometry.swift" \
  -o "$temporary_directory/check-workspace-geometry"
"$temporary_directory/check-workspace-geometry"
