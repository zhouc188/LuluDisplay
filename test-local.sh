#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 App/ControlLogic.swift Tests/LogicTests.swift -o "$test_dir/LogicTests"
"$test_dir/LogicTests"
