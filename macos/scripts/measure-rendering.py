#!/usr/bin/env python3
"""Run isolated rendering fixtures serially; outputs stay under artifacts/macos/."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'artifacts/macos/rendering-performance'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scenarios', nargs='+', default=['local-gallery', 'pn-gallery', 'local-gallery-off', 'local-paused', 'local-pan', 'local-zoom', 'local-scroll', 'pn-paused'])
parser.add_argument('--seconds', type=float, default=10)
parser.add_argument('--warmup', type=float, default=5)
parser.add_argument('--gallery-repeats', type=int, default=3)
parser.add_argument('--repeats', type=int, help='override repetitions for every selected scenario')
parser.add_argument('--output', type=Path, default=BASE / 'comparison')
args = parser.parse_args()
allowed = {'local-gallery', 'local-gallery-off', 'local-paused', 'local-pan', 'local-zoom', 'local-scroll', 'pn-gallery', 'pn-paused', 'pn-zoom'}
if not math.isfinite(args.seconds) or not math.isfinite(args.warmup) or any(s not in allowed for s in args.scenarios) or args.seconds <= 0 or args.warmup < 0 or args.gallery_repeats < 1 or (args.repeats is not None and args.repeats < 1):
    parser.error('invalid scenario, duration, or repeat count')
output = args.output.resolve()
if not output.is_relative_to(BASE.resolve()):
    parser.error('output must be within artifacts/macos/rendering-performance')
if output.exists() and any(output.iterdir()):
    parser.error('output is not empty; choose a new --output directory to preserve raw measurements')
output.mkdir(parents=True, exist_ok=True)
metadata = [json.loads((BASE / name / 'build-metadata.json').read_text()) for name in ['baseline', 'candidate']]
if metadata[0]['harness_sha256'] != metadata[1]['harness_sha256']:
    parser.error('baseline and candidate must use identical harnesses')
for name, build in zip(['baseline', 'candidate'], metadata):
    digest = hashlib.sha256((BASE / name / 'rendering-benchmark').read_bytes()).hexdigest()
    if build.get('binary_sha256', digest) != digest:
        parser.error(f'{name} executable no longer matches build metadata')
    build['binary_sha256'] = digest
(output / 'build-metadata.json').write_text(json.dumps(dict(zip(['baseline', 'candidate'], metadata)), indent=2))
environment = dict(os.environ, DPW_UI_TEST_PROFILE='rendering-benchmark')
results = []
for scenario in args.scenarios:
    repeats = args.repeats or (args.gallery_repeats if scenario in ['local-gallery', 'pn-gallery'] else 1)
    for repeat in range(repeats):
        order = ['baseline', 'candidate'] if repeat % 2 == 0 else ['candidate', 'baseline']
        for name in order:
            stem = f'{scenario}-{repeat + 1}-{name}'
            result = output / f'{stem}.json'
            print(f'Measuring {stem} ({args.warmup}s warmup + {args.seconds}s)', flush=True)
            with (output / f'{stem}.log').open('w') as log:
                subprocess.run([str(BASE / name / 'rendering-benchmark'), '--scenario', scenario,
                    '--seconds', str(args.seconds), '--warmup', str(args.warmup), '--output', str(result)],
                    env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, cwd=ROOT)
            row = json.loads(result.read_text()); row.update(version=name, repeat=repeat + 1)
            results.append(row)
            (output / 'all-results.json').write_text(json.dumps(results, indent=2))
            print(f"  CPU {row['average_cpu_percent']:.2f}%, draws {row['draws']}, ambient {row['generations']}", flush=True)
summary = []
for scenario in args.scenarios:
    for name in ['baseline', 'candidate']:
        rows = [r for r in results if r['scenario'] == scenario and r['version'] == name]
        summary.append({'scenario': scenario, 'version': name, 'runs': len(rows),
            'cpu_mean': statistics.mean(r['average_cpu_percent'] for r in rows),
            'cpu_min': min(r['average_cpu_percent'] for r in rows), 'cpu_max': max(r['average_cpu_percent'] for r in rows),
            'draws': [r['draws'] for r in rows], 'generations': [r['generations'] for r in rows],
            'driver_interval_p95_ms': [r['driver_interval_ms_p95'] for r in rows],
            'draw_p95_ms': [r['draw_ms_p95'] for r in rows], 'max_rss_mib': [r['max_rss_mib'] for r in rows]})
(output / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2), flush=True)
