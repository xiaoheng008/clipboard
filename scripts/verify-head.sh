#!/bin/zsh
# Gate for pushing: build and test exactly what HEAD contains (not the working tree).
# A partial `git add` once pushed a commit that referenced an uncommitted file (lesson L4).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$ROOT" archive HEAD | tar -x -C "$TMP"
PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
cd "$TMP"
swift build --build-tests -q 2>&1 | grep -E "error:" && { echo "HEAD does not build"; exit 1; }
swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" 2>&1 | grep -aE "Test run with|✘ Test run" | tee /dev/stderr | grep -q "✘" && { echo "HEAD tests fail"; exit 1; }
echo "HEAD verified"
