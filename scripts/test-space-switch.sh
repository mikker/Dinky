#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=$(mktemp "${TMPDIR:-/tmp}/dinky-space-switch.XXXXXX")
trap 'rm -f "$bin"' EXIT
clang -fobjc-arc -Werror -framework AppKit -framework ApplicationServices \
  -I "$root/Sources/DinkyPrivate/include" "$root/scripts/test-space-switch.m" -o "$bin"
"$bin"
