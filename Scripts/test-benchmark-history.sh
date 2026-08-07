#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/k9k-benchmark-history.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

xcrun swiftc \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos26.0 \
  "$root/K9k/Models/ClusterModels.swift" \
  "$root/K9k/Features/BenchmarkHistory.swift" \
  "$root/IntegrationTests/BenchmarkHistoryTests.swift" \
  -o "$scratch/benchmark-history-tests"
"$scratch/benchmark-history-tests"
