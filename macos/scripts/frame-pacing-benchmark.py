#!/usr/bin/env python3
"""Opt-in synthetic PNPlayback pacing comparison. Never launch the normal app."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'artifacts/macos/sync-frame-pacing'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['build', 'measure'])
parser.add_argument('--output', type=Path, default=BASE / 'comparison')
parser.add_argument('--seconds', type=float, default=20)
parser.add_argument('--warmup', type=float, default=3)
parser.add_argument('--repeats', type=int, default=3)
parser.add_argument('--display', type=int, default=0)
args = parser.parse_args()
build = BASE / 'harness'
binary = build / 'frame-pacing-benchmark'
metadata_path = build / 'build-metadata.json'
harness = ROOT / 'macos/Benchmarks/FramePacingBenchmark.swift'
sources = sorted(p for p in (ROOT / 'macos/DynamicPhotoWall').rglob('*.swift') if p.name != 'DynamicPhotoWallApp.swift')
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
if args.action == 'build':
    build.mkdir(parents=True, exist_ok=True)
    flags = ['-O', '-whole-module-optimization', '-parse-as-library', '-swift-version', '5',
             '-default-isolation', 'MainActor', '-target', 'arm64-apple-macos27.0']
    cmd = ['xcrun', 'swiftc', *flags, '-module-cache-path', str(build / 'ModuleCache'),
           '-module-name', 'FramePacingBenchmark', *map(str, sources), str(harness), '-o', str(binary) + '.next']
    with (build / 'build.log').open('w') as log:
        subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    Path(str(binary) + '.next').replace(binary)
    metadata_path.write_text(json.dumps({'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'flags': flags, 'harness_sha256': digest(harness), 'binary_sha256': digest(binary),
        'sources': {str(p.relative_to(ROOT)): digest(p) for p in sources}}, indent=2))
    print(binary)
    raise SystemExit()
if not all(math.isfinite(v) for v in [args.seconds, args.warmup]) or args.seconds <= 0 or args.seconds + args.warmup >= 100 or args.warmup < 0 or args.repeats < 1:
    parser.error('invalid measurement duration or repeats')
out = args.output.resolve()
if not out.is_relative_to(BASE.resolve()) or (out.exists() and any(out.iterdir())):
    parser.error('choose a new empty output directory under artifacts/macos/sync-frame-pacing')
metadata = json.loads(metadata_path.read_text())
if metadata['binary_sha256'] != digest(binary) or metadata['harness_sha256'] != digest(harness) or any(metadata['sources'].get(str(p.relative_to(ROOT))) != digest(p) for p in sources):
    parser.error('sources or binary changed; rebuild first')
out.mkdir(parents=True, exist_ok=True)
(out / 'build-metadata.json').write_text(json.dumps(metadata, indent=2))
def quantile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * fraction))] if values else 0
summary = []
for repeat in range(1, args.repeats + 1):
    for mode in (['legacy', 'displaylink'] if repeat % 2 else ['displaylink', 'legacy']):
        stem = f'{repeat}-{mode}'
        print(f'{stem}: {args.warmup}s warmup + {args.seconds}s capture', flush=True)
        with (out / f'{stem}.log').open('w') as log:
            subprocess.run([str(binary), '--driver', mode, '--seconds', str(args.seconds), '--warmup', str(args.warmup),
                '--display', str(args.display), '--output', str(out / f'{stem}.json')], cwd=ROOT,
                env=dict(os.environ, DPW_UI_TEST_PROFILE='frame-pacing-benchmark'), stdout=log, stderr=subprocess.STDOUT, check=True)
        row = json.loads((out / f'{stem}.json').read_text())
        renders, probes = row['render_rows'], row['probe_rows']
        intervals = [(b[0] - a[0]) * 1000 for a, b in zip(renders, renders[1:])]
        probe_intervals = [(b[0] - a[0]) * 1000 for a, b in zip(probes, probes[1:])]
        periods = [(p[2] - p[1]) * 1000 for p in probes if p[2] > p[1]]
        period = statistics.median(periods)
        duplicate = sum(b[3] == a[3] for a, b in zip(probes, probes[1:]))
        steps = [b[4] - a[4] for a, b in zip(probes, probes[1:])]
        if any(abs(p[4] - (-13320 + p[5] * 120)) > 1e-6 for p in probes):
            raise RuntimeError('sampled Pan geometry differs from shared elapsed time')
        waits = [(b[0] - a[0]) * 1000 - a[1] for a, b in zip(renders, renders[1:])]
        result = {'repeat': repeat, 'driver': mode, 'wall_seconds': row['wall_seconds'],
            'render_fps': (len(renders) - 1) / (renders[-1][0] - renders[0][0]),
            'duplicate_probe_count': duplicate, 'wait_p50_ms': statistics.median(waits),
            'cpu_percent': row['cpu_percent'], 'renders': len(renders),
            'probe_ticks': len(probes), 'display_period_ms': period,
            'render_interval_p50_ms': quantile(intervals, .5), 'render_interval_p95_ms': quantile(intervals, .95),
            'render_interval_max_ms': max(intervals), 'render_cost_p95_ms': quantile([r[1] for r in renders], .95),
            'render_cost_max_ms': max(r[1] for r in renders),
            'render_intervals_over_1_5_period': sum(v > period * 1.5 for v in intervals),
            'probe_interval_p95_ms': quantile(probe_intervals, .95),
            'probe_intervals_over_1_5_period': sum(v > period * 1.5 for v in probe_intervals),
            'duplicate_probe_percent': duplicate / (len(probes) - 1) * 100,
            'pan_step_p50_px': quantile(steps, .5), 'pan_step_p95_px': quantile(steps, .95),
            'pan_step_max_px': max(steps), 'screen_id': row['screen_id'], 'screen_pixels': row['screen_pixels']}
        summary.append(result)
        (out / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(result), flush=True)
