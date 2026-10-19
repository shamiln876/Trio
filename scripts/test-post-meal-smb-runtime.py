#!/usr/bin/env python3
"""Exercise exact pure gates extracted from APSManager; no pump/app startup."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='post-meal-runtime-') as temporary:
    package = Path(temporary)
    (package/'Sources/Trio').mkdir(parents=True)
    (package/'Tests/RuntimeTests').mkdir(parents=True)
    source = (root/'Trio/Sources/APS/APSManager.swift').read_text()
    marker = 'enum PostMealSMBPumpHistoryVerifier {' if 'enum PostMealSMBPumpHistoryVerifier {' in source else 'struct PostMealSMBPumpHistoryVerifier {'
    gates = source[source.index(marker):source.index('final class BaseAPSManager:')]
    (package/'Sources/Trio/Gates.swift').write_text('import Foundation\n'+gates)
    tests = (root/'TrioTests/SettingsExportTests.swift').read_text()
    tests = tests[tests.index('    func testVerifiedPumpDoseStart'):tests.index('    // Helper function')]
    (package/'Tests/RuntimeTests/GateTests.swift').write_text('import XCTest\n@testable import Trio\nfinal class RuntimeGateTests: XCTestCase {\n'+tests+'}\n')
    (package/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "RuntimeGates", targets: [.target(name: "Trio"), .testTarget(name: "RuntimeTests", dependencies: ["Trio"])], swiftLanguageModes: [.v5])\n')
    environment = os.environ.copy()
    environment['CLANG_MODULE_CACHE_PATH'] = str(package/'module-cache')
    environment['SWIFTPM_MODULECACHE_OVERRIDE'] = str(package/'module-cache')
    subprocess.run(['swift','test','--disable-sandbox','--package-path',str(package),'--jobs','2'], env=environment, check=True)
