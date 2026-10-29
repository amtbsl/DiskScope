#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
service_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/diskscope-service-tests.XXXXXX")
trap 'rm -rf "$service_test_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" Sources/Core.swift Sources/Services.swift tests/test_app_services.swift -o "$service_test_dir/services-tests" -framework AppKit -framework IOKit
"$service_test_dir/services-tests" "$@"
