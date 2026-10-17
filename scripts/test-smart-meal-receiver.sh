#!/bin/bash
# Exact receiver/transaction/Core Data sources, synthetic data, no app or pump startup.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/smart-meal-receiver.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/Sources/Trio" "$test_root/Tests/ReceiverTests"
cp "$repo_root/Trio/Sources/Models/SmartMealProtocol.swift" "$test_root/Sources/Trio/"
for name in SmartMealReceiver SmartMealCarbBatch; do
    cp "$repo_root/Trio/Sources/Services/RemoteControl/$name.swift" "$test_root/Sources/Trio/"
done
for name in SmartMealReceiverTests SmartMealCarbBatchTests; do
    cp "$repo_root/TrioTests/$name.swift" "$test_root/Tests/ReceiverTests/"
done
cat > "$test_root/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SmartMealReceiverTests", platforms: [.macOS(.v13)], targets: [.target(name: "Trio"), .testTarget(name: "ReceiverTests", dependencies: ["Trio"])], swiftLanguageModes: [.v5])
PACKAGE
swift test --package-path "$test_root" --jobs 2
