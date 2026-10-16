#!/bin/zsh
# Runs the test suite. With Command Line Tools only (no Xcode), the default swiftbuild engine
# intermittently fails to locate the Swift Testing macro plugin; pass its path explicitly.
# See docs/scv/9-lessons-learned.md L1.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
