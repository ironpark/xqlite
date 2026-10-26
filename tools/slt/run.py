#!/usr/bin/env python3
"""Run sqllogictest scripts with `xqlite slt` in parallel and group the
failures by cause.

usage: run.py [options] PATH...   (PATH: a .test file or a directory)

  -j N         parallel jobs (default: CPU count)
  --timeout S  seconds per script (default 600)
  --ref BIN    also run the C reference runner (sqllogictest built against
               sqlite3 3.54.1, see README.md) on failing scripts, and mark
               failures it shares
  --log FILE   write every failure line to FILE
  --top N      causes to list (default 40)
  -- ARGS      extra arguments for `xqlite slt`, e.g. -- --integrity-check

XQ names the xqlite binary (default: zig-out/bin/xqlite of this repo).
"""
import collections, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
XQ = os.environ.get('XQ', os.path.join(ROOT, 'zig-out', 'bin', 'xqlite'))
SUMMARY = re.compile(r'^(\d+) errors out of (\d+) tests in (.*) - (\d+) skipped\.$')
FAILURE = re.compile(r'^(.*?):(\d+): (.*)$')


def scripts(paths):
    for p in paths:
        if os.path.isdir(p):
            for d, _, files in sorted(os.walk(p)):
                for f in sorted(files):
                    if f.endswith('.test'):
                        yield os.path.join(d, f)
        else:
            yield p


def cause(msg):
    """The failure message with its specifics taken out, to group by."""
    if msg.startswith(('wrong result', 'too many result rows', 'too few result rows')):
        return msg.split(' - ')[0]
    if msg.startswith('labeled result'):
        return 'labeled result does not agree'
    m = re.match(r'(statement error|query failed): (.*)', msg)
    if m:
        detail = m.group(2)
        detail = re.sub(r'near "[^"]*"', 'near "X"', detail)
        detail = re.sub(r'\b\d+\b', 'N', detail)
        return f'{m.group(1)}: {detail}'
    return re.sub(r'\b\d+\b', 'N', msg)


def run_one(path, timeout, extra):
    try:
        r = subprocess.run([XQ, 'slt', *extra, path], capture_output=True, text=True, timeout=timeout, errors='replace')
    except subprocess.TimeoutExpired:
        return path, 'timeout', 0, 0, [], ''
    fails, total, n_err = [], 0, 0
    status = 'ok'
    for line in r.stdout.splitlines():
        m = SUMMARY.match(line)
        if m:
            n_err, total = int(m.group(1)), int(m.group(2))
            continue
        m = FAILURE.match(line)
        if m and m.group(1) == path:
            fails.append((int(m.group(2)), m.group(3)))
    if r.returncode < 0 or (r.returncode not in (0, 1)) or not SUMMARY.search(r.stdout.splitlines()[-1] if r.stdout else ''):
        status = 'crash'
    elif n_err:
        status = 'fail'
    tail = '\n'.join(r.stderr.strip().splitlines()[:3])
    return path, status, total, n_err, fails, tail


def ref_lines(ref, path, timeout):
    """The line numbers the C reference runner reports as failing."""
    try:
        r = subprocess.run([ref, '-verify', path], capture_output=True, text=True, timeout=timeout, errors='replace', cwd='/tmp')
    except subprocess.TimeoutExpired:
        return None
    return {int(m.group(2)) for m in (FAILURE.match(l) for l in (r.stdout + r.stderr).splitlines()) if m}


def main():
    argv = sys.argv[1:]
    extra = []
    if '--' in argv:
        i = argv.index('--')
        argv, extra = argv[:i], argv[i + 1:]
    opts = {'-j': str(os.cpu_count() or 4), '--timeout': '600', '--ref': None, '--log': None, '--top': '40'}
    paths = []
    i = 0
    while i < len(argv):
        if argv[i] in opts:
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            paths.append(argv[i])
            i += 1
    if not paths:
        print(__doc__)
        sys.exit(2)
    files = list(scripts(paths))
    timeout = int(opts['--timeout'])

    results = []
    with ThreadPoolExecutor(int(opts['-j'])) as pool:
        for n, res in enumerate(pool.map(lambda p: run_one(p, timeout, extra), files), 1):
            results.append(res)
            path, status, total, n_err, _, _ = res
            if status != 'ok':
                print(f'[{n}/{len(files)}] {status.upper()} {path} ({n_err}/{total})', flush=True)

    shared = {}
    if opts['--ref']:
        failing = [r[0] for r in results if r[1] == 'fail']
        with ThreadPoolExecutor(int(opts['-j'])) as pool:
            for path, lines in zip(failing, pool.map(lambda p: ref_lines(opts['--ref'], p, timeout), failing)):
                shared[path] = lines or set()

    causes = collections.Counter()
    examples = {}
    log = open(opts['--log'], 'w') if opts['--log'] else None
    n_tests = n_fail = n_shared = 0
    for path, status, total, n_err, fails, tail in results:
        n_tests += total
        if status == 'crash':
            causes['CRASH: ' + (tail.splitlines()[0] if tail else '?')] += 1
            examples.setdefault('CRASH: ' + (tail.splitlines()[0] if tail else '?'), f'{path}')
        elif status == 'timeout':
            causes['TIMEOUT'] += 1
            examples.setdefault('TIMEOUT', path)
        for line, msg in fails:
            if line in shared.get(path, ()):
                n_shared += 1
                continue
            n_fail += 1
            c = cause(msg)
            causes[c] += 1
            examples.setdefault(c, f'{path}:{line}')
            if log:
                log.write(f'{path}:{line}: {msg}\n')
    if log:
        log.close()

    by_status = collections.Counter(r[1] for r in results)
    print(f'\n{len(files)} scripts: ' + ', '.join(f'{k}={v}' for k, v in sorted(by_status.items())))
    print(f'{n_tests} tests, {n_fail} failures' + (f' (+{n_shared} the reference shares)' if opts['--ref'] else ''))
    if causes:
        print('\ncauses:')
        for c, n in causes.most_common(int(opts['--top'])):
            print(f'{n:8d}  {c}\n          e.g. {examples[c]}')
    sys.exit(0 if not causes else 1)


main()
