#!/usr/bin/env python3
"""Fail CI when a reviewed native screen has no successful screenshot attachment."""
import argparse
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--manifest', type=Path, required=True)
parser.add_argument('--coverage', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
coverage = json.loads(args.coverage.read_text())
assert coverage['expected_screens'] == 41 and len(coverage['screens']) == 41
assert len({row['id'] for row in coverage['screens']}) == 41
manifest = json.loads(args.manifest.read_text())
args.output.mkdir(parents=True, exist_ok=True)
missing = []
for row in coverage['screens']:
    assert Path(row['native_view']).is_file(), row['native_view']
    found = []
    for test in manifest:
        for attachment in test.get('attachments', []):
            name = attachment.get('suggestedHumanReadableName', '')
            for style in ['dark', 'light']:
                if name.startswith(f"Prototype41-{row['id']}-{style}_") and not attachment.get('isAssociatedWithFailure'):
                    source = args.manifest.parent / attachment['exportedFileName']
                    target = args.output / f"{row['id']}-{style}.png"
                    shutil.copy2(source, target)
                    found.append(style)
    row['state'] = 'native_screenshot_verified' if 'dark' in found else 'missing_screenshot'
    row['appearances'] = sorted(found)
    if 'dark' not in found:
        missing.append(row['id'])
coverage['verified_screens'] = 41 - len(missing)
(args.output / 'coverage.json').write_text(json.dumps(coverage, ensure_ascii=False, indent=2) + '\n')
print(f"Native prototype coverage: {coverage['verified_screens']}/41 screens")
if missing:
    raise SystemExit('Missing native screenshots: ' + ', '.join(missing))
