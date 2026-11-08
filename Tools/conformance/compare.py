#!/usr/bin/env python3
"""Compare the generic parser with upstream defuddle's expected fixture output.

usage: python3 Tools/conformance/compare.py <defuddle-repo> [name-filter] [--diff]
Builds nothing; run `swift build -c release` first.
"""
import json, os, re, subprocess, sys, difflib
from concurrent.futures import ThreadPoolExecutor

repo = sys.argv[1]
args = sys.argv[2:]
show_diff = '--diff' in args
args = [a for a in args if a != '--diff']
name_filter = args[0] if args else ''
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
binary = os.path.join(root, '.build/release/web2md')
fixtures = os.path.join(repo, 'tests/fixtures')
expected_dir = os.path.join(repo, 'tests/expected')

def run(name):
    path = os.path.join(fixtures, name + '.html')
    html = open(path, encoding='utf-8').read()
    m = re.search(r'<!--\s*(\{"url":.*?\})\s*-->', html)
    url = json.loads(m.group(1))['url'] if m else 'https://' + re.sub(r'^[a-z]+--', '', name)
    proc = subprocess.run([binary, path, '--url', url, '--json', '--no-cover'], capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        return name, None, proc.stderr.strip()
    doc = json.loads(proc.stdout)
    meta = {k: doc.get(k, '') for k in ('title', 'author', 'site', 'published')}
    out = '```json\n' + json.dumps(meta, indent=2, ensure_ascii=False) + '\n```\n\n' + doc['markdown']
    return name, out, None

names = sorted(f[:-5] for f in os.listdir(fixtures) if f.endswith('.html') and name_filter in f)
passed, failed = [], []
with ThreadPoolExecutor(8) as pool:
    for name, out, err in pool.map(run, names):
        exp_path = os.path.join(expected_dir, name + '.md')
        if not os.path.exists(exp_path):
            continue
        expected = open(exp_path, encoding='utf-8').read().strip()
        if out is not None and out.strip() == expected:
            passed.append(name)
        else:
            failed.append(name)
            if show_diff:
                print(f'===== {name} {err or ""}')
                if out is not None:
                    diff = difflib.unified_diff(expected.splitlines(), out.strip().splitlines(), 'expected', 'swift', lineterm='', n=1)
                    print('\n'.join(list(diff)[:60]))
print(f'passed {len(passed)}/{len(passed) + len(failed)}')
if not show_diff:
    print('failed:', ' '.join(failed))
