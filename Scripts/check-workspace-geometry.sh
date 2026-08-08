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

if grep -q '\.frame(minWidth: Self\..*WorkspaceSize' "$root/K9k/App/K9kApp.swift"; then
  echo "K9kApp must not impose a fixed content width that can exceed the visible display" >&2
  exit 1
fi

if grep -q '\.windowResizability(.contentMinSize)' "$root/K9k/App/K9kApp.swift"; then
  echo "K9kApp must use the screen-aware AppKit minimum instead of a fixed SwiftUI content minimum" >&2
  exit 1
fi

if grep -q '\.inspector(isPresented:' "$root/K9k/Features/K9kRootView.swift"; then
  echo "K9kRootView must keep the trailing inspector in-flow; Tahoe can place native inspector chrome beyond the window" >&2
  exit 1
fi
