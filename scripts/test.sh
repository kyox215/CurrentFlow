#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT/Sources/PowerSnapshot.swift" "$TASK_ROOT/Tests/PowerSnapshotTests.swift" \
  -o "$TASK_ROOT/build/PowerSnapshotTests"
"$TASK_ROOT/build/PowerSnapshotTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT/Sources/PanelPlacement.swift" "$TASK_ROOT/Tests/PanelPlacementTests.swift" \
  -o "$TASK_ROOT/build/PanelPlacementTests"
"$TASK_ROOT/build/PanelPlacementTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT/Sources/RefreshPolicy.swift" "$TASK_ROOT/Tests/RefreshPolicyTests.swift" \
  -o "$TASK_ROOT/build/RefreshPolicyTests"
"$TASK_ROOT/build/RefreshPolicyTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" -framework IOKit \
  "$TASK_ROOT/Sources/PowerSnapshot.swift" "$TASK_ROOT/Sources/LiveSensors.swift" \
  "$TASK_ROOT/Tests/LiveSensorTests.swift" -o "$TASK_ROOT/build/LiveSensorTests"
"$TASK_ROOT/build/LiveSensorTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" -framework IOKit \
  "$TASK_ROOT/Sources/ComponentPower.swift" "$TASK_ROOT/Tests/ComponentPowerTests.swift" \
  -o "$TASK_ROOT/build/ComponentPowerTests"
"$TASK_ROOT/build/ComponentPowerTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT/Sources/PowerSnapshot.swift" "$TASK_ROOT/Sources/ProcessPower.swift" \
  "$TASK_ROOT/Tests/ProcessPowerTests.swift" -o "$TASK_ROOT/build/ProcessPowerTests"
"$TASK_ROOT/build/ProcessPowerTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" -framework Cocoa -framework IOKit -lsqlite3 \
  "$TASK_ROOT/Sources/PowerSnapshot.swift" "$TASK_ROOT/Sources/LiveSensors.swift" \
  "$TASK_ROOT/Sources/ComponentPower.swift" \
  "$TASK_ROOT/Sources/PowerReader.swift" "$TASK_ROOT/Sources/RefreshPolicy.swift" \
  "$TASK_ROOT/Sources/ProcessPower.swift" \
  "$TASK_ROOT/Sources/HistoryStore.swift" "$TASK_ROOT/Sources/PowerMonitor.swift" "$TASK_ROOT/Tests/PowerMonitorTests.swift" \
  -o "$TASK_ROOT/build/PowerMonitorTests"
"$TASK_ROOT/build/PowerMonitorTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" -framework Cocoa -framework IOKit -lsqlite3 \
  "$TASK_ROOT/Sources/PowerSnapshot.swift" "$TASK_ROOT/Sources/LiveSensors.swift" \
  "$TASK_ROOT/Sources/ComponentPower.swift" "$TASK_ROOT/Sources/ProcessPower.swift" \
  "$TASK_ROOT/Sources/PowerReader.swift" "$TASK_ROOT/Sources/RefreshPolicy.swift" \
  "$TASK_ROOT/Sources/HistoryStore.swift" "$TASK_ROOT/Sources/PowerMonitor.swift" "$TASK_ROOT/Tests/DetailsMonitorTests.swift" \
  -o "$TASK_ROOT/build/DetailsMonitorTests"
"$TASK_ROOT/build/DetailsMonitorTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" -framework Cocoa -framework ServiceManagement \
  "$TASK_ROOT/Sources/StartupSettings.swift" "$TASK_ROOT/Tests/StartupSettingsTests.swift" \
  -o "$TASK_ROOT/build/StartupSettingsTests"
"$TASK_ROOT/build/StartupSettingsTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" -lsqlite3 \
  "$TASK_ROOT/Sources/PowerSnapshot.swift" "$TASK_ROOT/Sources/HistoryStore.swift" \
  "$TASK_ROOT/Sources/HistoryTime.swift" "$TASK_ROOT/Tests/HistoryStoreTests.swift" -o "$TASK_ROOT/build/HistoryStoreTests"
"$TASK_ROOT/build/HistoryStoreTests"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TASK_ROOT/build/module-cache" -framework Cocoa -framework IOKit -lsqlite3 \
  "$TASK_ROOT/Sources/PowerSnapshot.swift" "$TASK_ROOT/Sources/LiveSensors.swift" \
  "$TASK_ROOT/Sources/ComponentPower.swift" "$TASK_ROOT/Sources/ProcessPower.swift" \
  "$TASK_ROOT/Sources/PowerReader.swift" "$TASK_ROOT/Sources/RefreshPolicy.swift" \
  "$TASK_ROOT/Sources/HistoryStore.swift" "$TASK_ROOT/Sources/PowerMonitor.swift" \
  "$TASK_ROOT/Tests/HistoryMonitorTests.swift" -o "$TASK_ROOT/build/HistoryMonitorTests"
"$TASK_ROOT/build/HistoryMonitorTests"
