#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/Backend/bin"
cd "$root/Backend"
go build -trimpath -buildvcs=true -o "$root/Backend/bin/k9k-core" ./cmd/k9k-core

