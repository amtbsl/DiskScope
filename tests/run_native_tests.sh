#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
test_build_dir=$(mktemp -d "$PWD/build/.native-tests.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT
sources=(Sources/Core.swift)
if [[ -f Sources/Search.swift ]]; then sources+=(Sources/Search.swift); fi
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" "${sources[@]}" tests/test_safety_search.swift -o "$test_build_dir/safety-search"
"$test_build_dir/safety-search"
