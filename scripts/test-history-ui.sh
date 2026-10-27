#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d /private/tmp/currentflow-history-ui-tests.XXXXXXXX)"
trap 'rm -rf "$TEST_BUILD"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -lsqlite3 \
  -module-cache-path "$TEST_BUILD/module-cache" \
  "$TASK_ROOT/Sources/PowerSnapshot.swift" "$TASK_ROOT/Sources/HistoryStore.swift" \
  "$TASK_ROOT/Sources/HistoryNavigation.swift" "$TASK_ROOT/Sources/HistoryExplorerModel.swift" \
  "$TASK_ROOT/Tests/HistoryExplorerTests.swift" -o "$TEST_BUILD/HistoryExplorerTests"
"$TEST_BUILD/HistoryExplorerTests"
