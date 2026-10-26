#!/usr/bin/env python3
"""Compare xqlite with sqlite3 3.54.1 on query results, EXPLAIN QUERY PLAN
and EXPLAIN bytecode.

usage: diff.py CASEFILE [-v] [-k KIND]  (KIND: res,eqp,code; default all)

XQ names the xqlite binary (default: zig-out/bin/xqlite of this repo), SQ
the reference shell (default: sqlite3 on PATH). For bytecode to match, SQ
must be 3.54.1 built without SQLITE_ENABLE_EXPLAIN_COMMENTS, which the
stock shell build enables (it adds OP_Noop comments); see
tools/planner/README.md.

CASEFILE: blocks separated by lines '----'. In each block, lines before a
line '==' are setup SQL (run once per check); each later non-empty line is
one query.
"""
import subprocess, sys, os, tempfile, shutil, re

XQ = os.environ.get('XQ', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'zig-out', 'bin', 'xqlite'))
SQ = os.environ.get('SQ', 'sqlite3')
# SQOPT=MASK: run the reference with ".testctrl optimizations MASK" (the
# optimizations to disable), e.g. for select.c transforms xqlite lacks.
SQPRE = (f".testctrl optimizations {os.environ['SQOPT']}",) if os.environ.get('SQOPT') else ()


def run(cmd, db, q, pre=(), post=(), writes=False):
    # A statement that writes runs on a copy, so the next one sees the
    # block's database as set up.
    if writes:
        work = db + '.work'
        if os.path.exists(db):
            shutil.copy(db, work)
        elif os.path.exists(work):
            os.remove(work)
        db = work
    try:
        r = subprocess.run([*cmd, db, *pre, q, *post], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return 'TIMEOUT'
    out = r.stdout
    err = r.stderr
    if SQPRE:
        # SQPRE shifts the argument numbers in sqlite3's error messages.
        err = re.sub(r'in \d+(st|nd|rd|th) command line argument', 'in Nth command line argument', err)
        if pre[:1] == SQPRE:
            out = out.split('\n', 1)[1] if '\n' in out else ''  # the .testctrl status line
    return out + (('ERR:' + err) if err else '')


def eqp_tree(out):
    rows = []
    for line in out.splitlines():
        parts = line.split('|', 3)
        if len(parts) != 4 or not parts[0].lstrip('-').isdigit():
            rows.append((None, None, line))
            continue
        rows.append((int(parts[0]), int(parts[1]), parts[3]))
    kids = {}
    for i, par, txt in rows:
        kids.setdefault(par, []).append((i, txt))
    lines = []

    def walk(par, depth):
        for i, txt in kids.get(par, []):
            lines.append('  ' * depth + txt)
            if i is not None:
                walk(i, depth + 1)
    walk(0, 0)
    for i, par, txt in rows:
        if i is None:
            lines.append(txt)
    return '\n'.join(lines)


def code_norm(out):
    # Only the main program: xqlite's EXPLAIN does not list trigger
    # sub-programs after it, as sqlite3's does.
    res = []
    for line in out.splitlines():
        f = line.split('|')
        if res and f[0] == '0':
            break
        if len(f) < 7:
            res.append(line)
            continue
        # addr opcode p1 p2 p3 p4 p5 [comment]
        res.append('|'.join(f[:7]))
    return res


def main():
    path = sys.argv[1]
    verbose = '-v' in sys.argv
    kinds = {'res', 'eqp', 'code'}
    if '-k' in sys.argv:
        kinds = set(sys.argv[sys.argv.index('-k') + 1].split(','))
    text = open(path).read()
    tmp = tempfile.mkdtemp()
    nfail = {k: 0 for k in kinds}
    ntot = 0
    for bi, block in enumerate(text.split('\n----\n')):
        if '\n==\n' in block:
            setup, qs = block.split('\n==\n', 1)
        else:
            setup, qs = '', block
        setup = '\n'.join(l for l in setup.splitlines() if not l.startswith('#'))
        queries = [l for l in qs.splitlines() if l.strip() and not l.startswith('#')]
        # Build the database once with sqlite3 so both read the same file.
        db = os.path.join(tmp, f'b{bi}.db')
        if setup.strip():
            subprocess.run([SQ, db, setup], capture_output=True, text=True)
        for q in queries:
            ntot += 1
            for kind in sorted(kinds):
                if kind == 'res':
                    # Anything but a plain query may change the database:
                    # it runs on a copy, and the result includes the dump.
                    post = ()
                    if not re.match(r'\s*(SELECT|VALUES)\b', q, re.I) or ';' in q:
                        post = ('.dump', 'PRAGMA integrity_check')
                    a = run([XQ, 'sql'], db, q, post=post, writes=bool(post))
                    b = run([SQ], db, q, pre=SQPRE, post=post, writes=bool(post))
                elif kind == 'eqp':
                    a = eqp_tree(run([XQ, 'sql'], db, 'EXPLAIN QUERY PLAN ' + q, pre=('.explain off',)))
                    b = eqp_tree(run([SQ], db, 'EXPLAIN QUERY PLAN ' + q, pre=SQPRE + ('.explain off',)))
                else:
                    a = code_norm(run([XQ, 'sql'], db, 'EXPLAIN ' + q, pre=('.explain off',)))
                    b = code_norm(run([SQ], db, 'EXPLAIN ' + q, pre=SQPRE + ('.explain off',)))
                if a != b:
                    nfail[kind] += 1
                    tag = kind
                    if kind == 'res' and sorted(a.splitlines()) == sorted(b.splitlines()):
                        tag = 'res:order-only'
                    print(f'FAIL[{tag}] block {bi}: {q}')
                    if verbose:
                        if kind == 'code':
                            import difflib
                            for d in difflib.unified_diff(b, a, 'sqlite3', 'xqlite', lineterm='', n=2):
                                print('   ', d)
                        else:
                            print('  --- sqlite3\n' + '\n'.join('    ' + l for l in b.splitlines()))
                            print('  --- xqlite\n' + '\n'.join('    ' + l for l in a.splitlines()))
    shutil.rmtree(tmp)
    print(f'{ntot} queries; failures: ' + ', '.join(f'{k}={v}' for k, v in sorted(nfail.items())))
    sys.exit(1 if any(nfail.values()) else 0)


main()
