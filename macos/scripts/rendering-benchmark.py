#!/usr/bin/env python3
"""Build a Release CLI harness from an exact Git ref, never launch the normal app."""
import argparse
import io
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ref', required=True, help='Git revision, or WORKTREE')
parser.add_argument('--name', required=True)
args = parser.parse_args()
if not args.name.replace('-', '').replace('_', '').isalnum():
    parser.error('name must contain letters, numbers, hyphens, or underscores')
output = ROOT / 'artifacts/macos/rendering-performance' / args.name
source = output / 'source'
if source.exists():
    shutil.rmtree(source)
source.mkdir(parents=True)
if args.ref == 'WORKTREE':
    shutil.copytree(ROOT / 'macos/DynamicPhotoWall', source / 'macos/DynamicPhotoWall', dirs_exist_ok=True)
else:
    archive = subprocess.check_output(['git', 'archive', args.ref, 'macos/DynamicPhotoWall'], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive)) as data:
        data.extractall(source, filter='data')
app = source / 'macos/DynamicPhotoWall'
# The same minimal counters are added to both revisions in the staging copy.
for filename in ['PhotoImageView.swift', 'Networking/PeerPresentation.swift']:
    file = app / filename
    text = file.read_text().replace('override func draw(_ dirtyRect: NSRect) {', '''override func draw(_ dirtyRect: NSRect) {
        let benchmarkStart = ProcessInfo.processInfo.systemUptime
        defer { BenchmarkStats.draws += 1; BenchmarkStats.drawMS.append((ProcessInfo.processInfo.systemUptime - benchmarkStart) * 1000) }''')
    file.write_text(text)
file = app / 'AmbientBackground.swift'
file.write_text(file.read_text().replace('self.updateCount += 1', 'self.updateCount += 1; BenchmarkStats.generations += 1'))
harness = output / 'RenderingBenchmark.swift'
shutil.copyfile(ROOT / 'macos/Benchmarks/RenderingBenchmark.swift', harness)
metadata = {'ref': args.ref, 'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD' if args.ref == 'WORKTREE' else args.ref], cwd=ROOT, text=True).strip(), 'harness_sha256': hashlib.sha256(harness.read_bytes()).hexdigest(), 'flags': '-O -whole-module-optimization -swift-version 5 -default-isolation MainActor -target arm64-apple-macos27.0'}
metadata_file = output / 'build-metadata.json'
metadata_file.unlink(missing_ok=True)
files = sorted(str(p) for p in app.rglob('*.swift') if p.name != 'DynamicPhotoWallApp.swift')
cmd = ['xcrun', 'swiftc', '-O', '-whole-module-optimization', '-parse-as-library', '-swift-version', '5',
       '-default-isolation', 'MainActor', '-target', 'arm64-apple-macos27.0',
       '-module-cache-path', str(output / 'ModuleCache'), '-module-name', 'DynamicPhotoWallBenchmark',
       *files, str(harness), '-o', str(output / 'rendering-benchmark.next')]
with (output / 'build.log').open('w') as log:
    subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True, cwd=ROOT)
(output / 'rendering-benchmark.next').replace(output / 'rendering-benchmark')
metadata['binary_sha256'] = hashlib.sha256((output / 'rendering-benchmark').read_bytes()).hexdigest()
metadata_file.write_text(json.dumps(metadata, indent=2))
print(output / 'rendering-benchmark')
