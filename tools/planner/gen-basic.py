#!/usr/bin/env python3
"""Generate random planner test cases in diff.py's format.

usage: gen-basic.py SEED NBLOCKS NQUERIES > cases.txt
"""
import random, sys

seed, nblocks, nq = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
R = random.Random(seed)

COLS = ['a', 'b', 'c', 'd', 'e']


def schema():
    tabs = []
    out = []
    for ti in range(R.randint(1, 3)):
        name = f't{ti}'
        ncol = R.randint(2, 5)
        cols = COLS[:ncol]
        kind = R.choice(['rowid', 'ipk', 'ipk', 'wr', 'plain'])
        defs = []
        for i, c in enumerate(cols):
            ty = R.choice(['INT', 'INTEGER', 'TEXT', '', 'REAL'])
            if kind == 'ipk' and i == 0:
                defs.append(f'{c} INTEGER PRIMARY KEY')
            else:
                defs.append(f'{c} {ty}'.strip())
        tail = ''
        if kind == 'wr':
            defs.append(f'PRIMARY KEY({cols[0]}{", " + cols[1] if R.random() < 0.3 else ""})')
            tail = ' WITHOUT ROWID'
        out.append(f'CREATE TABLE {name}({", ".join(defs)}){tail};')
        for ii in range(R.randint(0, 3)):
            k = R.sample(cols, R.randint(1, min(3, ncol)))
            parts = [c + (' DESC' if R.random() < 0.15 else '') for c in k]
            uniq = 'UNIQUE ' if R.random() < 0.2 else ''
            where = ''
            r = R.random()
            if r < 0.1:
                where = f' WHERE {R.choice(cols)} IS NOT NULL'
            elif r < 0.15:
                where = f' WHERE {R.choice(cols)}>10'
            if R.random() < 0.08:
                parts = [f'{k[0]}+1'] + parts[1:]
            out.append(f'CREATE {uniq}INDEX {name}i{ii} ON {name}({", ".join(parts)}){where};')
        n = R.choice([0, 5, 30, 200])
        vals = []
        for c in cols:
            m = R.choice([3, 7, 20, 1000])
            vals.append(R.choice([f'i%{m}', f"'s'||(i%{m})", f'CASE WHEN i%{R.randint(2,6)}=0 THEN NULL ELSE i%{m} END', 'i', f'(i*7)%{m}']))
        if kind in ('ipk', 'wr'):
            vals[0] = 'i'
        if n:
            out.append(f'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<{n}) '
                       f'INSERT OR IGNORE INTO {name} SELECT {", ".join(vals)} FROM n;')
        tabs.append((name, cols))
    if R.random() < 0.3:
        out.append('ANALYZE;')
    return tabs, out


def lit():
    return R.choice([str(R.randint(0, 25)), f"'s{R.randint(0, 25)}'", 'NULL', str(R.randint(0, 9)) + '.5'])


def term(tabs, alias):
    t, cols = R.choice(tabs)
    a = alias[t]
    c = f'{a}.{R.choice(cols)}'
    r = R.random()
    if r < 0.25:
        return f'{c}={lit()}'
    if r < 0.4:
        return f'{c}{R.choice(["<", ">", "<=", ">="])}{lit()}'
    if r < 0.48:
        return f'{c} BETWEEN {R.randint(0, 10)} AND {R.randint(5, 20)}'
    if r < 0.56:
        return f'{c} IN ({", ".join(lit() for _ in range(R.randint(1, 4)))})'
    if r < 0.6:
        return f'{c} IS NULL'
    if r < 0.63:
        return f'{c} IS NOT NULL'
    if r < 0.67:
        return f"{c} LIKE 's{R.randint(0, 3)}%'"
    if r < 0.75 and len(tabs) > 1:
        t2, cols2 = R.choice(tabs)
        return f'{c}={alias[t2]}.{R.choice(cols2)}'
    if r < 0.82:
        return f'({term(tabs, alias)} OR {term(tabs, alias)})'
    if r < 0.86:
        t2, cols2 = R.choice(tabs)
        return f'{c} IN (SELECT {R.choice(cols2)} FROM {t2})'
    if r < 0.88:
        return f'NOT ({term(tabs, alias)})'
    if r < 0.9:
        return f'{c} IS {lit()}'
    return f'{c}<>{lit()}'


def query(tabs):
    k = R.randint(1, len(tabs))
    use = R.sample(tabs, k)
    alias = {t: t for t, _ in tabs}
    frm = []
    for i, (t, cols) in enumerate(use):
        if i == 0:
            frm.append(t)
        else:
            j = R.choice(['JOIN', 'JOIN', ',', 'LEFT JOIN', 'CROSS JOIN', 'RIGHT JOIN', 'FULL JOIN'])
            if j == ',':
                frm.append(f', {t}')
            else:
                pt, pc = R.choice(use[:i])
                on = f' ON {t}.{R.choice(cols)}={pt}.{R.choice(pc)}'
                frm.append(f' {j} {t}{on}')
    where = ''
    nt = R.choice([0, 1, 1, 2, 2, 3])
    if nt:
        where = ' WHERE ' + ' AND '.join(term(use, alias) for _ in range(nt))
    allc = [f'{t}.{c}' for t, cols in use for c in cols]
    r = R.random()
    group = ''
    if r < 0.15:
        sel = 'count(*)'
    elif r < 0.25:
        g = R.choice(allc)
        sel = f'{g}, count(*), max({R.choice(allc)})'
        group = f' GROUP BY {g}'
    elif r < 0.3:
        sel = f'{R.choice(["min", "max"])}({R.choice(allc)})'
    elif r < 0.38:
        sel = 'DISTINCT ' + ', '.join(R.sample(allc, R.randint(1, min(2, len(allc)))))
    else:
        sel = ', '.join(R.sample(allc, R.randint(1, min(4, len(allc)))))
    order = ''
    if R.random() < 0.45:
        obs = R.sample(allc, R.randint(1, min(2, len(allc))))
        order = ' ORDER BY ' + ', '.join(o + R.choice(['', ' DESC', ' ASC']) for o in obs)
        if not group and not sel.startswith('DISTINCT') and 'count' not in sel and 'min(' not in sel and 'max(' not in sel:
            pass
    if group or 'count(*)' == sel or sel.startswith(('min(', 'max(')):
        order = order if group else ''
    limit = ''
    if R.random() < 0.25:
        limit = f' LIMIT {R.randint(1, 5)}'
        if R.random() < 0.3:
            limit += f' OFFSET {R.randint(1, 3)}'
    # Without ORDER BY the row order is plan-defined; with the same plan it
    # must match exactly, so keep such queries.
    return f'SELECT {sel} FROM {"".join(frm)}{where}{group}{order}{limit}'


def dml(tabs):
    t, cols = R.choice(tabs)
    alias = {x: x for x, _ in tabs}
    w = ' WHERE ' + term([(t, cols)], alias) if R.random() < 0.9 else ''
    if R.random() < 0.5:
        c = R.choice(cols)
        return f'UPDATE {t} SET {c}={R.choice([lit(), c + "+1"])}{w}'
    return f'DELETE FROM {t}{w}'


blocks = []
for bi in range(nblocks):
    tabs, setup = schema()
    qs = [query(tabs) for _ in range(nq)]
    qs += [dml(tabs) for _ in range(max(1, nq // 6))]
    blocks.append('\n'.join(setup) + '\n==\n' + '\n'.join(qs))
print('\n----\n'.join(blocks))
