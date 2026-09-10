#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname)" = Darwin ]; then
  SDKROOT=$(xcrun --show-sdk-path); export SDKROOT
fi
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
clang -std=c11 -g -O1 -fsanitize=address,undefined \
  -I ../../Pico2/firmware/pilyzer/tests/stubs board_test.c -lm -o "$test_dir/board"
"$test_dir/board"
