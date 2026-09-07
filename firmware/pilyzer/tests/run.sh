#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/pilyzer-firmware-tests.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT
for module in analog logic; do
    "${CC:-clang}" -std=c11 -g -O1 -Wall -Wextra -Wno-unused-parameter \
        -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
        -I stubs "${module}_test.c" -o "$test_build_dir/$module"
    "$test_build_dir/$module"
done
