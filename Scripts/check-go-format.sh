#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root/Backend"

unformatted=$(gofmt -l $(find . -name '*.go' -not -path './vendor/*'))
if [ -n "$unformatted" ]; then
  echo "The following Go files are not gofmt-formatted:" >&2
  echo "$unformatted" >&2
  echo "Run: mise run format" >&2
  exit 1
fi

