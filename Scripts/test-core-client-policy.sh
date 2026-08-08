#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/k9k-core-client-policy.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

xcrun swiftc \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos26.0 \
  "$root/K9k/Models/ClusterModels.swift" \
  "$root/K9k/IPC/CoreClient.swift" \
  "$root/IntegrationTests/CoreClientPolicyTests.swift" \
  -o "$scratch/core-client-policy-tests"
"$scratch/core-client-policy-tests"
