#!/usr/bin/env python3
"""Verify executed native tests, rejecting zero/skipped/missing-case success."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('result', type=Path)
parser.add_argument('--minimum', type=int, required=True)
parser.add_argument('--require', action='append', default=[])
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--source', required=True)
args = parser.parse_args()
summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(args.result)]))
tests = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(args.result)], text=True)
if summary.get('result') != 'Passed' or summary.get('failedTests', 0) or summary.get('skippedTests', 0):
    raise SystemExit('Native tests did not pass without failures/skips')
if summary.get('passedTests', 0) < args.minimum:
    raise SystemExit('Native run executed too few tests')
missing = [name for name in args.require if name not in tests]
if missing:
    raise SystemExit('Required test cases missing: ' + ', '.join(missing))
receipt = {'source': args.source, 'passed': summary['passedTests'], 'failed': summary.get('failedTests', 0),
           'skipped': summary.get('skippedTests', 0), 'requiredCases': args.require, 'result': summary['result']}
args.output.write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
