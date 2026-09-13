#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# A macOS shell whose PATH finds the Command Line Tools clang while
# xcode-select points at Xcode leaves the compiler with no system headers.
if [ "$(uname)" = Darwin ] && [ -z "${SDKROOT:-}" ]; then
    SDKROOT=$(xcrun --show-sdk-path) && export SDKROOT
fi
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/pico2-noise-tests.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT
for module in signal_source; do
    "${CC:-clang}" -std=c11 -g -O1 -Wall -Wextra -Wno-unused-parameter \
        -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
        "${module}_test.c" -lm -o "$test_build_dir/$module"
    "$test_build_dir/$module"
done
