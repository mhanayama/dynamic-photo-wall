#!/usr/bin/env python3
"""Summarize xctrace XML exports. CPU buckets overlap; GPU intervals use unions."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cpu', type=Path)
parser.add_argument('--gpu', type=Path)
parser.add_argument('--gpu-toc', type=Path)
parser.add_argument('--pid', type=int, required=True)
args = parser.parse_args()

def load(path):
    root = ET.parse(path).getroot()
    refs = {e.get('id'): e for e in root.iter() if e.get('id')}
    def dereference(e):
        return refs[e.get('ref')] if e.get('ref') else e
    return root, dereference

def process_pid(element, dereference):
    element = dereference(element)
    pid = element.find('pid')
    return int(dereference(pid).text) if pid is not None else None

def union_seconds(intervals):
    total = end = 0
    for start, stop in sorted(intervals):
        if stop > end:
            total += stop - max(start, end)
            end = stop
    return total / 1e9

result = {'pid': args.pid}
if args.cpu:
    root, de = load(args.cpu)
    categories = {'PNSceneView.draw': ['PNSceneView.draw'], 'PNPlayback.render': ['PNPlayback.render'],
        'AmbientProcessor': ['AmbientProcessor'], 'CA transaction': ['CA::Transaction::commit', 'CA::Context::commit_transaction'],
        'Metal CPU calls': ['MetalContext', 'MTL'], 'window ordering': ['orderFront', 'Ordering', 'orderWindow']}
    buckets, leaf = Counter(), Counter()
    count = total = 0
    for row in root.iter('row'):
        values = list(row)
        if process_pid(values[2], de) != args.pid:
            continue
        weight = int(de(values[5]).text)
        names = [de(frame).get('name', '') for frame in de(values[6])]
        total += weight; count += 1
        if names:
            leaf[names[0]] += weight
        for category, terms in categories.items():
            if any(term in name for name in names for term in terms):
                buckets[category] += weight
    result['cpu'] = {'samples': count, 'weighted_cpu_seconds': total / 1e9,
        'inclusive_seconds': {key: buckets[key] / 1e9 for key in categories},
        'top_leaf_seconds': [(key, value / 1e9) for key, value in leaf.most_common(15)]}
if args.gpu:
    root, de = load(args.gpu)
    intervals, channels = [], defaultdict(list)
    for row in root.iter('row'):
        values = [de(e) for e in row]
        if process_pid(values[10], de) != args.pid or values[7].text != 'Active':
            continue
        start = int(values[0].text); stop = start + int(values[1].text)
        intervals.append((start, stop)); channels[values[2].text].append((start, stop))
    result['gpu'] = {'active_intervals': len(intervals), 'active_union_seconds': union_seconds(intervals),
        'channel_union_seconds': {key: union_seconds(values) for key, values in channels.items()}}
    if args.gpu_toc:
        result['gpu']['trace_seconds'] = float(ET.parse(args.gpu_toc).findtext('./run/info/summary/duration'))
print(json.dumps(result, indent=2))
