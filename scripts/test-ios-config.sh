#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
DEVELOPER="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
FRAMEWORKS="$DEVELOPER/Library/Frameworks"
cat > "$TEMP/main.swift" <<'SWIFT'
import XCTest
let suite = TunnelConfigurationTests.defaultTestSuite
suite.run()
guard let run = suite.testRun, run.executionCount == 9, run.totalFailureCount == 0 else { exit(1) }
SWIFT
xcrun swiftc -I "$DEVELOPER/usr/lib" -L "$DEVELOPER/usr/lib" -F "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$DEVELOPER/usr/lib" \
  -Xlinker -rpath -Xlinker "$DEVELOPER/Library/PrivateFrameworks" \
  "$ROOT/app/ios/PacketTunnel/TunnelConfiguration.swift" \
  "$ROOT/app/ios/RunnerTests/TunnelConfigurationTests.swift" \
  "$TEMP/main.swift" -o "$TEMP/tests"
"$TEMP/tests"
